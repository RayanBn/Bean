import Foundation

struct PrivacySpan: Codable, Equatable {
    let kind: String
    let location: Int
    let length: Int

    var range: NSRange { NSRange(location: location, length: length) }
}

final class PrivacyModel {
    static let name = "openai/privacy-filter"
    private static let maxTokens = 2048

    private let api: OrtApi
    private let env: OpaquePointer
    private let session: OpaquePointer
    private let memory: OpaquePointer
    private let tokenizer: BPETokenizer
    private let labels: [String]
    private let lock = NSLock()

    enum Failure: LocalizedError {
        case ort(String)
        var errorDescription: String? { if case let .ort(message) = self { return message }; return nil }
    }

    init(directory: URL) throws {
        api = OrtGetApiBase().pointee.GetApi(UInt32(ORT_API_VERSION))!.pointee
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("config.json"))) as? [String: Any]
        let id2label = (config?["id2label"] as? [String: String]) ?? [:]
        labels = (0..<id2label.count).map { id2label[String($0)] ?? "O" }
        tokenizer = try BPETokenizer(url: directory.appendingPathComponent("tokenizer.json"))

        var env: OpaquePointer?
        var options: OpaquePointer?
        var session: OpaquePointer?
        var memory: OpaquePointer?
        let api = self.api
        func check(_ status: OpaquePointer?) throws {
            guard let status else { return }
            let message = String(cString: api.GetErrorMessage(status)!)
            api.ReleaseStatus(status)
            throw Failure.ort(message)
        }
        try check(api.CreateEnv(ORT_LOGGING_LEVEL_ERROR, "bean", &env))
        try check(api.CreateSessionOptions(&options))
        defer { api.ReleaseSessionOptions(options) }
        try check(api.SetIntraOpNumThreads(options, 4))
        try check(api.SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL))
        try check(directory.appendingPathComponent("model_q4.onnx").path.withCString { api.CreateSession(env, $0, options, &session) })
        try check(api.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory))
        self.env = env!
        self.session = session!
        self.memory = memory!
    }

    deinit {
        api.ReleaseMemoryInfo(memory)
        api.ReleaseSession(session)
        api.ReleaseEnv(env)
    }

    func spans(in text: String) throws -> [PrivacySpan] {
        let tokens = tokenizer.encode(text)
        var result: [PrivacySpan] = []
        var start = 0
        while start < tokens.count {
            let chunk = Array(tokens[start..<min(start + Self.maxTokens, tokens.count)])
            result += try label(chunk)
            start += Self.maxTokens
        }
        return result
    }

    private func label(_ tokens: [BPETokenizer.Token]) throws -> [PrivacySpan] {
        guard !tokens.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        var ids = tokens.map(\.id)
        var mask = [Int64](repeating: 1, count: tokens.count)
        var shape: [Int64] = [1, Int64(tokens.count)]
        let api = self.api
        func check(_ status: OpaquePointer?) throws {
            guard let status else { return }
            let message = String(cString: api.GetErrorMessage(status)!)
            api.ReleaseStatus(status)
            throw Failure.ort(message)
        }
        var idsValue: OpaquePointer?
        var maskValue: OpaquePointer?
        var output: OpaquePointer?
        defer {
            api.ReleaseValue(idsValue)
            api.ReleaseValue(maskValue)
            api.ReleaseValue(output)
        }
        let byteCount = tokens.count * MemoryLayout<Int64>.stride
        try check(api.CreateTensorWithDataAsOrtValue(memory, &ids, byteCount, &shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &idsValue))
        try check(api.CreateTensorWithDataAsOrtValue(memory, &mask, byteCount, &shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &maskValue))
        let inputs: [OpaquePointer?] = [idsValue, maskValue]
        try check(withCNames(["input_ids", "attention_mask"]) { inputNames in
            withCNames(["logits"]) { outputNames in
                inputs.withUnsafeBufferPointer { api.Run(session, nil, inputNames, $0.baseAddress, 2, outputNames, 1, &output) }
            }
        })
        var raw: UnsafeMutableRawPointer?
        try check(api.GetTensorMutableData(output, &raw))
        guard let logits = raw?.assumingMemoryBound(to: Float.self) else { return [] }

        var spans: [PrivacySpan] = []
        var open: (kind: String, start: Int, end: Int)?
        func close() {
            if let span = open { spans.append(PrivacySpan(kind: span.kind, location: span.start, length: span.end - span.start)) }
            open = nil
        }
        for (i, token) in tokens.enumerated() {
            let row = logits + i * labels.count
            let best = (0..<labels.count).max { row[$0] < row[$1] } ?? 0
            let label = labels[best]
            guard label != "O", let dash = label.firstIndex(of: "-") else { close(); continue }
            let kind = String(label[label.index(after: dash)...])
            let continues = label.first == "I" || label.first == "E"
            if continues, open?.kind == kind {
                open?.end = token.range.location + token.range.length
            } else {
                close()
                open = (kind, token.range.location, token.range.location + token.range.length)
            }
        }
        close()
        return spans
    }

    private func withCNames<T>(_ names: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> T) -> T {
        let pointers = names.map { UnsafePointer(strdup($0)!) }
        defer { pointers.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        return pointers.map { Optional($0) }.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
