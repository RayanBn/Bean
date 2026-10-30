import Foundation

enum CostLedger {
    struct Price {
        let input, cached, output: Double
    }

    struct Line: Codable {
        let at: Date
        let model: String
        let agent: String?
        let prompt: Int
        let cached: Int
        let completion: Int
        let usd: Double
        var run: String?
    }

    @TaskLocal static var agent: String?

    private struct Base: Decodable {
        let left: Double
        let at: Date
    }

    static let prices = ["muse-spark-1.3": Price(input: 1.25, cached: 0.15, output: 4.25)]
    static let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Bean/ledger.jsonl")
    private static let lock = NSLock()

    static func record(model: String, prompt: Int, cached: Int, completion: Int) {
        let price = prices[model] ?? prices["muse-spark-1.3"]!
        let usd = (Double(prompt - cached) * price.input + Double(cached) * price.cached + Double(completion) * price.output) / 1_000_000
        let line = Line(at: Date(), model: model, agent: agent, prompt: prompt, cached: cached, completion: completion, usd: usd, run: ProcessInfo.processInfo.environment["BEAN_RUN_ID"])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        guard var data = try? encoder.encode(line) else { return }
        data.append(0x0A)
        lock.withLock {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            // O_APPEND, because test runs and the app write this file at the same time.
            let descriptor = open(file.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            data.withUnsafeBytes { _ = write(descriptor, $0.baseAddress, $0.count) }
        }
    }

    static var lines: [Line] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let text = lock.withLock { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
        return text.split(separator: "\n").compactMap { try? decoder.decode(Line.self, from: Data($0.utf8)) }
    }

    static func spentToday(agent: String) -> Double {
        let start = Calendar.current.startOfDay(for: Date())
        let run = ProcessInfo.processInfo.environment["BEAN_RUN_ID"]
        return lines.filter { $0.agent == agent && $0.at >= start && $0.run == run }.reduce(0) { $0 + $1.usd }
    }

    static func setBase(left: Double) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        struct Saved: Encodable { let left: Double; let at: Date }
        try? encoder.encode(Saved(left: left, at: Date())).write(to: file.deletingLastPathComponent().appendingPathComponent("credits-base.json"), options: .atomic)
    }

    static var left: Double? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let base = (try? Data(contentsOf: file.deletingLastPathComponent().appendingPathComponent("credits-base.json"))).flatMap({ try? decoder.decode(Base.self, from: $0) }) else { return nil }
        return base.left - lines.filter { $0.at >= base.at }.reduce(0) { $0 + $1.usd }
    }
}
