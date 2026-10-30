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
    }

    @TaskLocal static var agent: String?

    static let grantUSD = 150.0
    static let prices = ["muse-spark-1.3": Price(input: 1.25, cached: 0.15, output: 4.25)]
    static let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Bean/ledger.jsonl")
    private static let lock = NSLock()

    static func record(model: String, prompt: Int, cached: Int, completion: Int) {
        let price = prices[model] ?? prices["muse-spark-1.3"]!
        let usd = (Double(prompt - cached) * price.input + Double(cached) * price.cached + Double(completion) * price.output) / 1_000_000
        let line = Line(at: Date(), model: model, agent: agent, prompt: prompt, cached: cached, completion: completion, usd: usd)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        guard var data = try? encoder.encode(line) else { return }
        data.append(0x0A)
        lock.withLock {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: file)
            }
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
        return lines.filter { $0.agent == agent && $0.at >= start }.reduce(0) { $0 + $1.usd }
    }

    static var left: Double { grantUSD - lines.reduce(0) { $0 + $1.usd } }
}
