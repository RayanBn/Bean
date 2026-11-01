import Foundation

struct Sense: Decodable {
    enum Level: String, Decodable { case signal, read, capture }

    struct Emit: Decodable {
        let summary: String
        var whenNoModel: Double?
        var onAgentWindow: Double?
        var contentless: Bool?
        var logOnly: Bool?
    }

    let id: String
    let title: String
    let sentence: String
    let driver: String
    let level: Level
    var beanHolds: Bool?
    var perSubscription: Bool?
    var params: [String: String]?
    let settle: TimeInterval
    var repeatWindow: TimeInterval?
    let dedupe: String
    let emits: [String: Emit]

    static let all: [Sense] = {
        guard let url = Bundle.main.url(forResource: "senses", withExtension: "json"), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Sense].self, from: data)) ?? []
    }()

    static func named(_ id: String) -> Sense? { all.first { $0.id == id } }
}

struct SenseSignal {
    let type: String
    var at = Date()
    var app: String?
    var bundleId: String?
    var pid: pid_t?
    var window: Int?
    var title: String?
    var detail: String?
}

struct SenseEvent {
    let sense: Sense
    let signal: SenseSignal
    var only: UUID?
    var watching: String?

    var type: String { signal.type }
    var at: Date { signal.at }
    var app: String? { signal.app }
    var bundleId: String? { signal.bundleId }
    var pid: pid_t? { signal.pid }
    var window: Int? { signal.window }
    var title: String? { signal.title }
    var detail: String? { signal.detail }
    var emit: Sense.Emit? { sense.emits[type] }

    var summary: String { fill(emit?.summary ?? type) }
    var dedupeKey: String { fill(sense.dedupe) }

    // What reaches the model unless the private check says the title may go.
    var summaryWithoutTitle: String { fill(emit?.summary ?? type, showingTitle: false) }

    private func fill(_ template: String, showingTitle: Bool = true) -> String {
        let title = showingTitle ? title : nil
        let place = [app, title].compactMap { $0 }.joined(separator: ", ")
        let values: [String: String] = [
            "type": type, "app": app ?? "an app", "title": title ?? "", "place": place, "pid": pid.map(String.init) ?? "",
            "number": window.map { " (window \($0))" } ?? "", "where": window.map(String.init) ?? app ?? "",
        ]
        return values.reduce(template) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }
}

struct SenseSubscription: Codable, Equatable {
    let sense: String
    var params: [String: String] = [:]
    var why: String = ""
    var grantedAt = Date()
    var lastSeen: String?
    var paused = false
}

extension AgentFolder {
    private var sensesFile: URL { url.appendingPathComponent("senses.json") }

    func subscriptions(of agent: Agent) -> [SenseSubscription] {
        if let data = try? Data(contentsOf: sensesFile), let saved = try? JSONDecoder().decode([SenseSubscription].self, from: data) { return saved }
        return agent.isBean ? Sense.all.filter { $0.beanHolds == true }.map { SenseSubscription(sense: $0.id, why: "Bean watches the Mac for you.") } : []
    }

    func save(_ subscriptions: [SenseSubscription]) {
        try? JSONEncoder().encode(subscriptions).write(to: sensesFile, options: .atomic)
    }
}
