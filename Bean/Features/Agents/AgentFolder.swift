import Foundation

struct AgentLines: Codable, Equatable {
    var greeting: String
    var offLimits: String
}

struct AgentJob: Codable, Equatable {
    var goal: String
    var output: String
    var done: String
    var first: String
    var quiet: String

    var card: String {
        """
        ## My job
        Goal: \(goal)
        What the person gets: \(output)
        Done means: \(done)
        First move: \(first)
        Stay quiet when: \(quiet)
        """
    }
}

struct AgentFolder {
    let url: URL

    init(_ agent: Agent, in store: AgentStore) {
        url = store.folder(for: agent)
    }

    init(url: URL) {
        self.url = url
    }

    var persona: URL { url.appendingPathComponent("persona.md") }
    var linesFile: URL { url.appendingPathComponent("lines.json") }
    var memory: URL { url.appendingPathComponent("memory") }
    var window: URL { memory.appendingPathComponent("window.md") }
    var notes: URL { memory.appendingPathComponent("notes.md") }

    func create(agent: Agent, voice: String, lines: AgentLines, job: AgentJob? = nil) throws {
        try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        let persona = """
        # \(agent.name)
        \(job == nil ? "\nRole: \(agent.role)\n\n## Personality\n\(agent.personality)\n" : "")
        ## How I talk
        \(voice)
        """
        try persona.write(to: self.persona, atomically: true, encoding: .utf8)
        if let job { try Self.encoder.encode(job).write(to: jobFile, options: .atomic) }
        try Self.encoder.encode(lines).write(to: linesFile, options: .atomic)
    }

    var goalsFile: URL { url.appendingPathComponent("goals.md") }
    var goals: String? { (try? String(contentsOf: goalsFile, encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 } }

    func addGoal(_ goal: String) {
        try? ((goals ?? "") + "- \(goal)\n").write(to: goalsFile, atomically: true, encoding: .utf8)
    }

    var jobFile: URL { url.appendingPathComponent("job.json") }
    func save(_ job: AgentJob) { try? Self.encoder.encode(job).write(to: jobFile, options: .atomic) }
    var job: AgentJob? {
        guard var job = (try? Data(contentsOf: jobFile)).flatMap({ try? JSONDecoder().decode(AgentJob.self, from: $0) }) else { return nil }
        if let goal = mission?.mission { job.goal = goal }
        return job
    }
    var personaText: String {
        let written = ((try? String(contentsOf: persona, encoding: .utf8)) ?? "").components(separatedBy: "## How I talk").first ?? ""
        return written.trimmingCharacters(in: .whitespacesAndNewlines) + (job.map { "\n\n" + $0.card } ?? "")
    }
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
