import AppKit

struct WindowContent: Codable, Equatable {
    let description: String
    let handle: [String: String]
}

struct SavedWindow: Codable, Equatable {
    var facts: WindowFacts
    var content: WindowContent?
    var frame: CGRect
    var space: Int?
    var fullScreen: Bool
    var minimized: Bool
    var lastFocused: Date?
    var closedAt: Date?

    var key: String { "\(facts.bundleId)|\(facts.title)" }
}

struct ProjectState: Codable, Equatable {
    let root: String
    var name: String
    var windows: [SavedWindow]
    var lastActive: Date
    var leftAt: Date?

    /// Windows closed long before the project was left were closed on purpose, not to leave it.
    func toRestore(closedSlack: TimeInterval = 600) -> [SavedWindow] {
        let end = leftAt ?? lastActive
        var seen = Set<String>()
        return windows.reversed().filter { window in
            (window.closedAt.map { $0 > end.addingTimeInterval(-closedSlack) } ?? true) && seen.insert(window.key).inserted
        }.reversed()
    }
}

final class ResumeStore {
    let url: URL
    private(set) var projects: [String: ProjectState] = [:]

    init(dataDir: URL) {
        url = dataDir.appendingPathComponent("projects.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let saved = try? decoder.decode([ProjectState].self, from: data) {
            projects = Dictionary(saved.map { ($0.root, $0) }, uniquingKeysWith: { $1 })
        }
    }

    func update(_ root: String, _ change: (inout ProjectState) -> Void) {
        var project = projects[root] ?? ProjectState(root: root, name: URL(fileURLWithPath: root).lastPathComponent, windows: [], lastActive: Date())
        change(&project)
        projects[root] = project
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(projects.values.sorted { $0.lastActive > $1.lastActive }).write(to: url, options: .atomic)
    }
}
