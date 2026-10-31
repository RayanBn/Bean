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

    private static var seen: (offset: UInt64, day: Date, spent: [String: Double]) = (0, .distantPast, [:])

    // Reads only what was added since the last call: this runs before every action, and the ledger only grows.
    static func spentToday(agent: String) -> Double {
        let start = Calendar.current.startOfDay(for: Date())
        let run = ProcessInfo.processInfo.environment["BEAN_RUN_ID"]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return lock.withLock {
            if seen.day != start { seen = (0, start, [:]) }
            guard let handle = try? FileHandle(forReadingFrom: file) else { return seen.spent[agent] ?? 0 }
            defer { try? handle.close() }
            try? handle.seek(toOffset: seen.offset)
            let added = (try? handle.readToEnd()) ?? Data()
            guard let end = added.lastIndex(of: 0x0A) else { return seen.spent[agent] ?? 0 }
            for piece in added[added.startIndex...end].split(separator: 0x0A) {
                if let line = try? decoder.decode(Line.self, from: Data(piece)), line.at >= start, line.run == run, let who = line.agent { seen.spent[who, default: 0] += line.usd }
            }
            seen.offset += UInt64(end - added.startIndex + 1)
            return seen.spent[agent] ?? 0
        }
    }
}
