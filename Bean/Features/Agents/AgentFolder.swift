import Foundation

struct AgentJob: Codable, Equatable {
    var goal: String
    var output: String
    var done: String
    var quiet: String
}

struct AgentFolder {
    let url: URL

    init(_ agent: Agent, in store: AgentStore) {
        url = store.folder(for: agent)
    }

    init(url: URL) {
        self.url = url
    }

    var memory: URL { url.appendingPathComponent("memory") }
    var window: URL { memory.appendingPathComponent("window.md") }
    var notes: URL { url.appendingPathComponent("notes.md") }

    var goals: String? { Goals.text }

    var understanding: String? {
        guard let text = try? String(contentsOf: window, encoding: .utf8) else { return nil }
        return text.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func saveUnderstanding(_ text: String, app: String, title: String?) {
        try? FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        let header = "# \(app)\(title.map { " — \($0)" } ?? "") · \(ISO8601DateFormatter().string(from: Date()))"
        try? (header + "\n\n" + text + "\n").write(to: window, atomically: true, encoding: .utf8)
    }

    func clearUnderstanding() {
        try? FileManager.default.removeItem(at: window)
    }
}
