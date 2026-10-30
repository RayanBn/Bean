import AppKit

struct AgentDraft: Codable, Identifiable, Equatable {
    let id: UUID
    let agentID: UUID
    let createdAt: Date
    var title: String
    var body: String
    var why: String
    var action: DraftAction
}

struct DraftAction: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case shell, connector, clipboard, connect }
    var kind: Kind
    var label: String
    var target: String?
    var command: String?
    var tool: String?
    var arguments: String?
    var url: String?
}

struct HelpSituation {
    let agent: Agent
    let persona: String
    let app: String
    let title: String?
    let text: String
    let understanding: String
    let history: [String]
}

struct HelpDecision {
    let help: Bool
    let what: String
}

protocol HelpDecider {
    func decide(_ situation: HelpSituation) async throws -> HelpDecision
}

struct MuseSparkDecider: HelpDecider {
    func decide(_ situation: HelpSituation) async throws -> HelpDecision {
        let system = """
        \(situation.persona)

        You sit on a window of \(situation.app) on your user's Mac and read it. Decide whether there is one concrete thing you could prepare right now, \
        as a draft the user approves with one click, that fits your role and would really help them. \
        Help when something in the window waits on someone and a short draft moves it forward: a review on a pull request nobody reviewed, \
        a nudge on something stalled for days, a reply to a message addressed to the user, a summary of a long thread. \
        Something left untouched for days counts as waiting, even when it is marked as a draft or a work in progress. \
        Stay quiet when nothing waits, when the user is clearly in the middle of doing it themselves, or when it is outside your role. Never propose again what is in your history.
        - help: true or false.
        - what: if true, one sentence on the draft you would prepare and where it would go. If false, one sentence on why you stay quiet.
        """
        var text = "Window title: \(situation.title ?? "untitled")\n\nWhat you understand:\n\(situation.understanding)\n\nWindow text:\n\(situation.text.prefix(3000))"
        if !situation.history.isEmpty { text += "\n\nYour history on this window:\n" + situation.history.joined(separator: "\n") }
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["help", "what"],
            "properties": ["help": ["type": "boolean"], "what": ["type": "string"]],
        ]
        let reply = try await ModelClient().json(system: system, text: text, schema: schema, effort: "low")
        struct Output: Decodable { let help: Bool; let what: String }
        guard let body = reply.text, let output = try? JSONDecoder().decode(Output.self, from: Data(body.utf8)) else {
            throw AgentMaker.MakerError.unreadable(reply.text ?? "")
        }
        return HelpDecision(help: output.help, what: output.what)
    }
}

final class AgentHelp: ObservableObject {
    static var decider: HelpDecider = MuseSparkDecider()
    static let log = JSONLog(name: "help")
    static let spacing: TimeInterval = 30

    struct Record: Codable {
        var draft: AgentDraft
        var status: String
        var result: String?
    }

    struct Entry: Encodable {
        var at = Date()
        let agent: String
        let event: String
        var what: String?
        var title: String?
        var body: String?
        var action: String?
        var calls: [String]?
        var result: String?
        var seconds: Double?
    }

    @Published private(set) var pending: [UUID: AgentDraft] = [:]
    @Published private(set) var running: Set<UUID> = []
    private let store: AgentStore
    private var thinking: Set<UUID> = []
    private var lastDecision: [UUID: Date] = [:]

    init(store: AgentStore) {
        self.store = store
        for agent in store.agents {
            if let record = Self.records(AgentFolder(agent, in: store)).last(where: { $0.status == "pending" }) {
                pending[agent.id] = record.draft
            }
        }
    }

    func isBusy(_ agentID: UUID) -> Bool {
        pending[agentID] != nil || thinking.contains(agentID) || running.contains(agentID)
    }

    func consider(_ agent: Agent, app: String, snapshot: WindowSnapshot, understanding: String) {
        guard !isBusy(agent.id), lastDecision[agent.id].map({ Date().timeIntervalSince($0) > Self.spacing }) ?? true else { return }
        thinking.insert(agent.id)
        lastDecision[agent.id] = Date()
        let folder = AgentFolder(agent, in: store)
        let redacted = OffLimits.redact(snapshot.text).text
        let situation = HelpSituation(agent: agent, persona: folder.personaText, app: app, title: snapshot.title, text: redacted,
                                      understanding: understanding, history: Self.records(folder).filter { $0.status != "dropped" }.suffix(6).map { "- \($0.draft.title) (\($0.status))" })
        Task { @MainActor in
            defer { thinking.remove(agent.id) }
            let started = Date()
            guard let decision = try? await Self.decider.decide(situation) else { return }
            Self.log.append(Entry(agent: agent.name, event: decision.help ? "help" : "quiet", what: decision.what, seconds: Self.since(started)))
            guard decision.help else { return }
            let previous = store.activity[agent.id]?.bubble
            store.activity[agent.id] = AgentActivity(mood: .working, bubble: previous)
            let prepared = await Self.prepare(situation, what: decision.what, folder: folder)
            guard let draft = prepared.draft else {
                store.activity[agent.id] = AgentActivity(mood: .idle, bubble: previous)
                Self.log.append(Entry(agent: agent.name, event: "noDraft", calls: prepared.calls, result: prepared.failure, seconds: Self.since(started)))
                return
            }
            Self.save(Record(draft: draft, status: "pending"), in: folder)
            if var saved = store.agents.first(where: { $0.id == agent.id }), !Set(prepared.used).isSubset(of: saved.connectors) {
                saved.connectors = Array(Set(saved.connectors).union(prepared.used)).sorted()
                store.save(saved)
            }
            pending[agent.id] = draft
            store.activity[agent.id] = AgentActivity(mood: .needsYou, bubble: prepared.bubble)
            Self.log.append(Entry(agent: agent.name, event: "draft", title: draft.title, body: draft.body, action: "\(draft.action.kind.rawValue): \(draft.action.label)",
                                  calls: prepared.calls, result: prepared.used.joined(separator: ", "), seconds: Self.since(started)))
        }
    }

    func approve(_ agentID: UUID) {
        guard let draft = pending[agentID], !running.contains(agentID), let agent = store.agents.first(where: { $0.id == agentID }) else { return }
        running.insert(agentID)
        let folder = AgentFolder(agent, in: store)
        Task { @MainActor in
            let output = await Self.run(draft, folder: folder)
            running.remove(agentID)
            pending[agentID] = nil
            Self.save(Record(draft: draft, status: output.ok ? "approved" : "failed", result: output.text), in: folder)
            if output.ok, draft.action.kind == .connect, var saved = store.agents.first(where: { $0.id == agentID }) {
                saved.connectors = Array(Set(saved.connectors + [draft.action.target ?? draft.title])).sorted()
                store.save(saved)
            }
            let bubble = output.ok ? (draft.action.kind == .clipboard ? "Copied. Paste it when you're ready." : "Done: \(draft.action.label)") : "That didn't work: \(output.text.prefix(60))"
            store.activity[agentID] = AgentActivity(mood: .idle, bubble: bubble)
            Self.log.append(Entry(agent: agent.name, event: output.ok ? "approved" : "failed", title: draft.title, action: draft.action.label, result: String(output.text.prefix(500))))
        }
    }

    func decline(_ agentID: UUID) {
        drop(agentID, as: "declined")
        store.activity[agentID] = AgentActivity(mood: .idle, bubble: nil)
    }

    func drop(_ agentID: UUID, as status: String = "dropped") {
        guard let draft = pending[agentID], !running.contains(agentID), let agent = store.agents.first(where: { $0.id == agentID }) else { return }
        pending[agentID] = nil
        Self.save(Record(draft: draft, status: status), in: AgentFolder(agent, in: store))
        Self.log.append(Entry(agent: agent.name, event: status, title: draft.title))
    }

    private static func run(_ draft: AgentDraft, folder: AgentFolder) async -> ToolOutput {
        let action = draft.action
        switch action.kind {
        case .clipboard:
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(draft.body, forType: .string)
            }
            return ToolOutput(text: "copied")
        case .shell:
            guard let command = action.command else { return ToolOutput(text: "no command", ok: false) }
            let range = NSRange(command.startIndex..., in: command)
            guard HiddenShell.blockedPattern.firstMatch(in: command, range: range) == nil else { return ToolOutput(text: "refused: \(command)", ok: false) }
            let file = folder.drafts.appendingPathComponent("\(draft.id.uuidString).md")
            let line = "export BEAN_DRAFT_FILE='\(file.path.replacingOccurrences(of: "'", with: "'\\''"))'; \(command)"
            let result = await Task.detached { HiddenShell.run(line, timeout: 60) }.value
            return ToolOutput(text: result.output.trimmingCharacters(in: .whitespacesAndNewlines), ok: result.exit == 0 && !result.timedOut)
        case .connector:
            guard let name = action.tool, let tool = await Tools.shared.tool(named: name) else { return ToolOutput(text: "no connector tool \(action.tool ?? "")", ok: false) }
            let args = action.arguments.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? JSONArgs } ?? [:]
            return await tool.run(args)
        case .connect:
            guard let connect = await Tools.shared.all(context: "", folder: nil).first(where: { $0.name == "connect" }) else { return ToolOutput(text: "connectors are not running", ok: false) }
            var args: JSONArgs = ["name": action.target ?? draft.title]
            if let url = action.url { args["url"] = url }
            if let command = action.command {
                let parts = command.split(separator: " ").map(String.init)
                args["command"] = parts.first
                args["args"] = Array(parts.dropFirst())
            }
            return await connect.run(args)
        }
    }

    struct Prepared {
        var draft: AgentDraft?
        var bubble = ""
        var used: [String] = []
        let calls: [String]
        var failure: String?
    }

    private static func prepare(_ situation: HelpSituation, what: String, folder: AgentFolder) async -> Prepared {
        let system = """
        \(situation.persona)

        You sit on a window of \(situation.app) on your user's Mac. You decided to prepare this: \(what)
        Gather what you need with your read tools, then call propose_draft with one draft, or stay_quiet if it turns out not to help.
        - You never touch the user's mouse, keyboard or windows. Your tools only read; the draft runs only when the user clicks its button.
        - To reach a service, look for what this Mac already has: connected connectors, connectors you can find with find_connectors, \
        and command-line tools installed and signed in, through run_shell (check with `command -v <tool>` and the tool's own auth or status command).
        - Pick the action: shell (one command that runs after the click, for example a signed-in command-line tool that posts; read the draft body from the file "$BEAN_DRAFT_FILE"), \
        connector (a connected connector's write tool with its JSON arguments), clipboard (the user pastes it themselves, for an app with no API such as a chat; never type into an app), \
        or connect (a service you need is missing and a connector exists for it: give its name and url).
        - Write the body in your own voice, ready to send, and short.
        """
        let text = "Window title: \(situation.title ?? "untitled")\n\nWhat you understand:\n\(situation.understanding)\n\nWindow text:\n\(situation.text.prefix(4000))"
        let reads = await Tools.shared.all(context: situation.understanding, folder: nil).filter { $0.effect == .read }
        let propose = BrainTool(name: "propose_draft", description: "Propose one draft. It runs only when the user clicks its button.", parameters: [
            "title": ["type": "string", "description": "What it is, at most 40 characters, like \"Nudge on PR #2\"."],
            "body": ["type": "string", "description": "The draft itself: the comment, reply or summary, ready to send."],
            "why": ["type": "string", "description": "One sentence on why it helps."],
            "bubble": ["type": "string", "description": "One line in your voice, at most 70 characters, telling the user you drafted it."],
            "action": ["type": "string", "enum": DraftAction.Kind.allCases.map(\.rawValue)],
            "label": ["type": "string", "description": "The button, two to five words, like \"Post comment on #2\" or \"Copy reply\"."],
            "target": ["type": "string", "description": "Where it goes, like owner/repo#2 or the channel name. For connect, the connector name."],
            "command": ["type": "string", "description": "shell: the exact command. connect: a local server's command and args."],
            "tool": ["type": "string", "description": "connector: the full tool name."],
            "arguments": ["type": "string", "description": "connector: the tool's arguments as a JSON object."],
            "url": ["type": "string", "description": "connect: the server url."],
            "used": ["type": "array", "items": ["type": "string"], "description": "The connectors or command-line tools you used or the action uses, like the CLI's name."],
        ], required: ["title", "body", "why", "bubble", "action", "label", "used"], effect: .read) { _ in ToolOutput(text: "") }
        let quiet = BrainTool(name: "stay_quiet", description: "Prepare nothing.", parameters: ["why": ["type": "string"]], effect: .read) { _ in ToolOutput(text: "") }
        let result = await AgentLoop(client: ModelClient(), maxRounds: 8).run(system: system, text: text, tools: reads + [shell], finals: [propose, quiet])
        guard result.final == "propose_draft", let kind = result.args.string("action").flatMap(DraftAction.Kind.init) else {
            return Prepared(calls: result.calls, failure: result.failure ?? result.args.string("why"))
        }
        let args = result.args
        let action = DraftAction(kind: kind, label: args.string("label") ?? "Approve", target: args.string("target"), command: args.string("command"),
                                 tool: args.string("tool"), arguments: args.string("arguments"), url: args.string("url"))
        let draft = AgentDraft(id: UUID(), agentID: situation.agent.id, createdAt: Date(), title: args.string("title") ?? what,
                               body: args.string("body") ?? "", why: args.string("why") ?? what, action: action)
        try? FileManager.default.createDirectory(at: folder.drafts, withIntermediateDirectories: true)
        try? draft.body.write(to: folder.drafts.appendingPathComponent("\(draft.id.uuidString).md"), atomically: true, encoding: .utf8)
        return Prepared(draft: draft, bubble: args.string("bubble") ?? draft.title, used: args["used"] as? [String] ?? [], calls: result.calls)
    }

    static let shell = BrainTool(name: "run_shell", description: "Run one read-only zsh command on the user's Mac and get its output, for example to find a signed-in command-line tool and read data with it. Commands that write, send, post, push, delete or redirect into files are refused.", parameters: [
        "command": ["type": "string"],
    ], effect: .read) { args in
        guard let command = args.string("command") else { return ToolOutput(text: "no command", ok: false) }
        let range = NSRange(command.startIndex..., in: command)
        if HiddenShell.requiresConsent(command) || writes.firstMatch(in: command, range: range) != nil {
            return ToolOutput(text: "refused: run_shell only reads", ok: false)
        }
        let result = await Task.detached { HiddenShell.run(command, timeout: 20) }.value
        log.append(Entry(agent: "-", event: "shell", action: command, result: "exit \(result.exit), \(result.output.count) chars"))
        return ToolOutput(text: "exit \(result.exit)\n\(result.output)", ok: result.exit == 0)
    }

    private static let writes = try! NSRegularExpression(pattern: #"(^|[^0-9&])>\s*[^&/\s]|>>|\b(rm|mv|cp|tee|touch|mkdir|chmod|chown|ln|truncate)\b|\bgh\s+\S+\s+(create|edit|delete|close|merge|comment|review|reopen|ready|lock)\b|\bgit\s+(commit|push|checkout|reset|rebase|merge|tag|branch\s+-[dD])\b"#)

    private static func records(_ folder: AgentFolder) -> [Record] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: folder.drafts, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { (try? Data(contentsOf: $0)).flatMap { try? decoder.decode(Record.self, from: $0) } }
            .sorted { $0.draft.createdAt < $1.draft.createdAt }
    }

    private static func save(_ record: Record, in folder: AgentFolder) {
        try? FileManager.default.createDirectory(at: folder.drafts, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(record).write(to: folder.drafts.appendingPathComponent("\(record.draft.id.uuidString).json"), options: .atomic)
    }

    private static func since(_ date: Date) -> Double {
        (Date().timeIntervalSince(date) * 10).rounded() / 10
    }
}
