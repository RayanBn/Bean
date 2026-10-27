import Foundation

enum PrivacyModelStore {
    static let sizeLabel = "0.9 GB"
    private static let revision = "7ffa9a043d54d1be65afb281eddf0ffbe629385b"
    private static let files = ["config.json", "tokenizer.json", "onnx/model_q4.onnx", "onnx/model_q4.onnx_data"]

    static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["BEAN_MODELS_DIR"] { return URL(fileURLWithPath: dir).appendingPathComponent("privacy-filter") }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Bean/models/privacy-filter")
    }

    static var isInstalled: Bool {
        files.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent(($0 as NSString).lastPathComponent).path) }
    }

    static func download() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files {
            let target = directory.appendingPathComponent((file as NSString).lastPathComponent)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            let source = URL(string: "https://huggingface.co/openai/privacy-filter/resolve/\(revision)/\(file)")!
            let (temp, response) = try await URLSession.shared.download(from: source)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try FileManager.default.moveItem(at: temp, to: target)
        }
    }
}
