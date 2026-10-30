import Foundation

struct AgentConnector: Codable, Equatable {
    enum Status: String, Codable { case connected, toConnect }
    let name: String
    var status: Status
    var source: String?
    var url: URL?
}

struct AgentLines: Codable, Equatable {
    var greeting: String
    var offLimits: String
}

struct AgentFolder {
    let url: URL

    init(_ agent: Agent, in store: AgentStore) {
        url = store.folder(for: agent)
    }

    var persona: URL { url.appendingPathComponent("persona.md") }
    var connectorsFile: URL { url.appendingPathComponent("connectors.json") }
    var linesFile: URL { url.appendingPathComponent("lines.json") }
    var memory: URL { url.appendingPathComponent("memory") }
    var window: URL { memory.appendingPathComponent("window.md") }
    var notes: URL { memory.appendingPathComponent("notes.md") }

    func create(agent: Agent, voice: String, lines: AgentLines, connectors: [AgentConnector]) throws {
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        let persona = """
        # \(agent.name)

        Role: \(agent.role)

        ## Personality
        \(agent.personality)

        ## How I talk
        \(voice)

        ## Connectors
        \(connectors.map { "- \($0.name) (\($0.status == .connected ? "connected" : "to connect"))" }.joined(separator: "\n"))
        """
        try persona.write(to: self.persona, atomically: true, encoding: .utf8)
        try Self.encoder.encode(connectors).write(to: connectorsFile, options: .atomic)
        try Self.encoder.encode(lines).write(to: linesFile, options: .atomic)
        if !FileManager.default.fileExists(atPath: notes.path) {
            try "# Notes\n".write(to: notes, atomically: true, encoding: .utf8)
        }
    }

    var personaText: String { (try? String(contentsOf: persona, encoding: .utf8)) ?? "" }
    var connectors: [AgentConnector] { (try? Data(contentsOf: connectorsFile)).flatMap { try? JSONDecoder().decode([AgentConnector].self, from: $0) } ?? [] }
    var lines: AgentLines? { (try? Data(contentsOf: linesFile)).flatMap { try? JSONDecoder().decode(AgentLines.self, from: $0) } }

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

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
