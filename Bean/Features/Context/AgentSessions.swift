import Foundation

enum AgentSessions {
    static let window: TimeInterval = 86400
    private static let tailBytes = 400_000
    private static let home = URL(fileURLWithPath: NSHomeDirectory())
    private static let environment = ProcessInfo.processInfo.environment
    private static let desktopSessions = environment["BEAN_AGENT_SESSIONS_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    private static let transcripts = environment["BEAN_AGENT_TRANSCRIPTS_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude/projects")

    static func all() -> [AgentSession] {
        let files = FileManager.default.enumerator(at: desktopSessions, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent.hasPrefix("local_") && $0.pathExtension == "json" } ?? []
        return files.compactMap(session).sorted { $0.lastActivity > $1.lastActivity }
    }

    private static func session(_ file: URL) -> AgentSession? {
        struct Stored: Decodable {
            let sessionId: String
            let cliSessionId: String?
            let cwd: String
            let title: String?
            let lastActivityAt: Double?
            let lastFocusedAt: Double?
            let isArchived: Bool?
        }
        guard let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.isArchived != true, let activityMs = stored.lastActivityAt else { return nil }
        let lastActivity = Date(timeIntervalSince1970: activityMs / 1000)
        guard Date().timeIntervalSince(lastActivity) < window else { return nil }
        let turn = stored.cliSessionId.flatMap(transcript).map(lastTurn) ?? Turn(state: .idle, question: nil, lastWords: nil)
        let age = Date().timeIntervalSince(lastActivity)
        let state: AgentSession.State = turn.state == .working && age > 600 ? .idle : turn.state
        return AgentSession(
            id: stored.sessionId, title: stored.title ?? "Untitled", cwd: stored.cwd, state: state, lastActivity: lastActivity,
            lastFocused: stored.lastFocusedAt.map { Date(timeIntervalSince1970: $0 / 1000) }, question: turn.question, lastWords: turn.lastWords
        )
    }

    private static func transcript(_ cliSessionId: String) -> URL? {
        let name = cliSessionId + ".jsonl"
        let folders = (try? FileManager.default.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil)) ?? []
        return folders.lazy.map { $0.appendingPathComponent(name) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    struct Turn {
        let state: AgentSession.State
        let question: String?
        let lastWords: String?
    }

    static func lastTurn(_ url: URL) -> Turn {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Turn(state: .idle, question: nil, lastWords: nil) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        let entries = data.split(separator: 0x0A).reversed().lazy.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .filter { ($0["type"] as? String == "assistant" || $0["type"] as? String == "user") && $0["isSidechain"] as? Bool != true }

        var question: String?
        var recap: String?
        var finalText = ""
        for (index, entry) in entries.prefix(40).enumerated() {
            let message = entry["message"] as? [String: Any] ?? [:]
            let blocks = message["content"] as? [[String: Any]] ?? []
            if entry["type"] as? String == "user" {
                if index == 0 { return Turn(state: .working, question: nil, lastWords: nil) }
                if blocks.contains(where: { $0["type"] as? String == "text" }) || message["content"] is String { break }
                continue
            }
            for block in blocks where block["type"] as? String == "tool_use" {
                let input = block["input"] as? [String: Any] ?? [:]
                switch block["name"] as? String {
                case "AskUserQuestion":
                    let first = (input["questions"] as? [[String: Any]])?.first?["question"] as? String
                    if index == 0 { return Turn(state: .asking, question: first, lastWords: nil) }
                case "mcp__ccd_turn__wrap_up":
                    question = question ?? (input["ask"] as? String)
                    recap = recap ?? (input["recap"] as? String)
                default:
                    if index == 0 { return Turn(state: .working, question: nil, lastWords: nil) }
                }
            }
            if index == 0, message["stop_reason"] as? String != "end_turn" { return Turn(state: .working, question: nil, lastWords: nil) }
            if index == 0 { finalText = blocks.compactMap { $0["text"] as? String }.joined(separator: " ") }
        }
        if question == nil, let last = finalText.split(whereSeparator: \.isNewline).last, last.hasSuffix("?") { question = String(last.prefix(300)) }
        let words = recap ?? (finalText.isEmpty ? nil : finalText)
        return Turn(state: question == nil ? .finished : .asking, question: question, lastWords: words.map { String($0.prefix(500)) })
    }
}
