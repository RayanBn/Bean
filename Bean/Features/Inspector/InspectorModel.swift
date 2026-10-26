import Foundation

final class InspectorModel: ObservableObject {
    struct LogLine: Identifiable {
        let id: Int
        let time: String
        let kind: String
        let summary: String
    }

    static let logs = ["triggers", "gate", "brain", "actions", "signals", "shell", "inventory"]
    static let refreshInterval: TimeInterval = 2

    @Published var inventory: Inventory?
    @Published var lines: [String: [LogLine]] = [:]
    @Published var updatedAt: Date?

    private let build: (@escaping (Inventory) -> Void) -> Void
    private let dataDir: URL
    private var timer: Timer?

    init(dataDir: URL, build: @escaping (@escaping (Inventory) -> Void) -> Void) {
        self.dataDir = dataDir
        self.build = build
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        build { [weak self] inventory in
            self?.inventory = inventory
            self?.updatedAt = Date()
        }
        let dataDir = dataDir
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let lines = Dictionary(uniqueKeysWithValues: Self.logs.map { ($0, Self.tail(dataDir.appendingPathComponent("\($0).jsonl"))) })
            DispatchQueue.main.async { self?.lines = lines }
        }
    }

    static func tail(_ url: URL, count: Int = 60) -> [LogLine] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 96_000 ? size - 96_000 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        let raw = data.split(separator: 0x0A).suffix(count)
        return raw.enumerated().compactMap { index, line in
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
            let at = (json["at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
            let kind = (json["kind"] ?? json["trigger"] ?? json["event"] ?? json["outcome"] ?? json["tool"] ?? json["cmd"]).map { "\($0)" } ?? ""
            let skipped: Set<String> = ["at", "terminalTail", "steps", "repo"]
            let summary = json.keys.sorted().filter { !skipped.contains($0) }.compactMap { key -> String? in
                guard let value = json[key], !(value is NSNull) else { return nil }
                let text = "\(value)".replacingOccurrences(of: "\n", with: " ")
                return "\(key)=\(text.count > 90 ? String(text.prefix(90)) + "…" : text)"
            }.joined(separator: "  ")
            return LogLine(id: index, time: at.map { Self.clock.string(from: $0) } ?? "", kind: kind, summary: summary)
        }.reversed()
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
