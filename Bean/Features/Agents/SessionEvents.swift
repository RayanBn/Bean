import Foundation

struct SessionEvent: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case task, text, tool, user, standIn, question, ended }
    enum ToolState: String, Codable { case running, succeeded, failed, refused }

    let id: Int
    let at: Date
    let kind: Kind
    var text: String
    var tool: String?
    var toolState: ToolState?
    var output: String?
    var toolUseId: String?
    var path: String?
    var added: Int?
    var removed: Int?
}

extension CodingSessions {
    private func eventsFile(_ id: String) -> URL { sessionsRoot.appendingPathComponent("\(id).events.jsonl") }

    // A tool's result rewrites its line under the same id, so the last line of an id is what is true.
    func record(_ event: SessionEvent, session id: String) {
        guard var data = try? JSONEncoder().encode(event) else { return }
        data.append(0x0A)
        try? FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        let handle = open(eventsFile(id).path, O_CREAT | O_APPEND | O_WRONLY, 0o600)
        guard handle >= 0 else { return }
        _ = data.withUnsafeBytes { write(handle, $0.baseAddress, $0.count) }
        Darwin.close(handle)
    }

    func events(of id: String) -> [SessionEvent] {
        guard let text = try? String(contentsOf: eventsFile(id), encoding: .utf8) else { return [] }
        var byId: [Int: SessionEvent] = [:]
        for line in text.split(separator: "\n") {
            if let event = try? JSONDecoder().decode(SessionEvent.self, from: Data(line.utf8)) { byId[event.id] = event }
        }
        return byId.values.sorted { $0.id < $1.id }
    }
}

// Writes one session's events as they come, for the page and for after a relaunch.
final class SessionEventLog {
    static let outputLimit = 4000

    private let sessions: CodingSessions
    private let session: String
    private let worker: AgentWorker
    private var next: Int
    private var running: [String: SessionEvent] = [:]
    private var refused: [String: String] = [:]

    init(sessions: CodingSessions, session: String, worker: AgentWorker) {
        self.sessions = sessions
        self.session = session
        self.worker = worker
        next = (sessions.events(of: session).last?.id ?? -1) + 1
    }

    private func publish(_ event: SessionEvent) async {
        sessions.record(event, session: session)
        let id = session
        await MainActor.run { worker.show(event, session: id) }
    }

    func add(_ kind: SessionEvent.Kind, _ text: String) async {
        let event = SessionEvent(id: next, at: Date(), kind: kind, text: OffLimits.redact(text).text)
        next += 1
        await publish(event)
    }

    func addSoon(_ kind: SessionEvent.Kind, _ text: String) {
        Task { await add(kind, text) }
    }

    func refuse(toolUseId: String?, why: String) {
        if let toolUseId { refused[toolUseId] = why }
    }

    func read(_ message: [String: Any]) async {
        let content = (message["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        for block in content {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { await add(.text, text) }
            case "tool_use":
                guard let id = block["id"] as? String, let tool = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                let shown = (input["command"] as? String) ?? (input["file_path"] as? String) ?? (input["pattern"] as? String) ?? input.json
                var event = SessionEvent(id: next, at: Date(), kind: .tool, text: OffLimits.redact(String(shown.prefix(Self.outputLimit))).text, tool: tool, toolState: .running, toolUseId: id)
                event.path = input["file_path"] as? String
                let lines = { (key: String) in (input[key] as? String).map { $0.split(separator: "\n", omittingEmptySubsequences: false).count } }
                event.added = lines("new_string") ?? lines("content")
                event.removed = lines("old_string")
                next += 1
                running[id] = event
                await publish(event)
            case "tool_result":
                guard let id = block["tool_use_id"] as? String, var event = running.removeValue(forKey: id) else { continue }
                let raw = block["content"]
                let output = raw as? String ?? (raw as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                let failed = block["is_error"] as? Bool == true
                if let why = refused[id] {
                    event.toolState = .refused
                    event.output = why
                } else {
                    event.toolState = failed ? .failed : .succeeded
                    event.output = OffLimits.redact(String(output.prefix(Self.outputLimit))).text
                }
                await publish(event)
            default: continue
            }
        }
    }

    // A tool still marked running when the stream ends did not finish.
    func closeRunning() async {
        for var event in running.values {
            event.toolState = .failed
            event.output = "The session ended before this finished."
            await publish(event)
        }
        running = [:]
    }
}
