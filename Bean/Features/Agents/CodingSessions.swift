import Foundation

struct CodingSession: Codable {
    let id: String
    let repo: String
    let branch: String
    let worktree: String
    var claudeSession: String?
    var costUSD: Double = 0
    var open = true
}

final class CodingSessions {
    static let budgetUSD = "1"
    static let timeout: TimeInterval = 600
    static let tools = "Read,Edit,Write,Glob,Grep"
    private static let stripped: Set<String> = ["MODEL_API_KEY", "OPENROUTER_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GH_TOKEN", "GITHUB_TOKEN"]

    struct Answer {
        let text: String
        let session: String?
        let cost: Double
        let failed: Bool
    }

    private let folder: AgentFolder
    private var root: URL { folder.url.appendingPathComponent("sessions") }
    private var file: URL { root.appendingPathComponent("sessions.json") }

    init(folder: AgentFolder) {
        self.folder = folder
    }

    var all: [CodingSession] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([CodingSession].self, from: $0) } ?? []
    }

    func session(_ id: String) -> CodingSession? { all.first { $0.id == id } }

    private func save(_ session: CodingSession) {
        var sessions = all.filter { $0.id != session.id }
        sessions.append(session)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(sessions).write(to: file, options: .atomic)
    }

    static func available() -> Bool {
        HiddenShell.run("command -v claude", timeout: 10).exit == 0
    }

    func create(repo: String, cloneURL: String) -> Result<CodingSession, ToolFailure> {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let clone = root.appendingPathComponent("repos").appendingPathComponent(repo.replacingOccurrences(of: "/", with: "-"))
        try? FileManager.default.createDirectory(at: clone.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: clone.path) {
            let cloned = Self.run("/usr/bin/git", ["clone", "--quiet", cloneURL, clone.path], in: root)
            guard cloned.exit == 0 else { return .failure(ToolFailure("clone failed: \(cloned.output.prefix(300))")) }
        } else {
            _ = Self.run("/usr/bin/git", ["fetch", "--quiet", "origin"], in: clone)
        }
        let branch = "bean/\(id)"
        let worktree = root.appendingPathComponent(id)
        let added = Self.run("/usr/bin/git", ["worktree", "add", "--quiet", "-b", branch, worktree.path, "origin/HEAD"], in: clone)
        guard added.exit == 0 else { return .failure(ToolFailure("worktree failed: \(added.output.prefix(300))")) }
        let session = CodingSession(id: id, repo: repo, branch: branch, worktree: worktree.path)
        save(session)
        return .success(session)
    }

    func send(_ prompt: String, to session: CodingSession) async -> Answer {
        var session = session
        let binary = HiddenShell.run("command -v claude", timeout: 10).output.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments = ["-p", prompt, "--restricted", "--strict-mcp-config", "--permission-mode", "acceptEdits", "--tools", Self.tools,
                         "--output-format", "json", "--max-budget-usd", Self.budgetUSD]
        if let model = ProcessInfo.processInfo.environment["BEAN_SESSION_MODEL"] { arguments += ["--model", model] }
        if let previous = session.claudeSession { arguments += ["--resume", previous] }
        let worktree = URL(fileURLWithPath: session.worktree)
        let result = await Task.detached { Self.run(binary, arguments, in: worktree, timeout: Self.timeout) }.value
        struct Output: Decodable { let session_id: String?; let result: String?; let total_cost_usd: Double?; let is_error: Bool? }
        guard let output = try? JSONDecoder().decode(Output.self, from: Data(result.output.utf8)) else {
            return Answer(text: "The session failed: \(result.output.prefix(400))", session: session.claudeSession, cost: 0, failed: true)
        }
        session.claudeSession = output.session_id ?? session.claudeSession
        session.costUSD += output.total_cost_usd ?? 0
        save(session)
        return Answer(text: output.result ?? "", session: session.claudeSession, cost: output.total_cost_usd ?? 0, failed: output.is_error == true)
    }

    func changes(_ session: CodingSession) -> String {
        let worktree = URL(fileURLWithPath: session.worktree)
        _ = Self.run("/usr/bin/git", ["add", "--intent-to-add", "."], in: worktree)
        let status = Self.run("/usr/bin/git", ["status", "--short"], in: worktree).output
        let diff = Self.run("/usr/bin/git", ["diff", "HEAD"], in: worktree).output
        return "git status:\n\(status.isEmpty ? "clean\n" : status)\ndiff:\n\(diff.prefix(5000))"
    }

    func close(_ session: CodingSession) {
        var session = session
        let clone = root.appendingPathComponent("repos").appendingPathComponent(session.repo.replacingOccurrences(of: "/", with: "-"))
        _ = Self.run("/usr/bin/git", ["worktree", "remove", "--force", session.worktree], in: clone)
        _ = Self.run("/usr/bin/git", ["branch", "-D", session.branch], in: clone)
        session.open = false
        save(session)
    }

    private static func run(_ executable: String, _ arguments: [String], in directory: URL, timeout: TimeInterval = 60) -> (exit: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.filter { !stripped.contains($0.key) && !$0.key.hasPrefix("BEAN_") }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, "could not start \(executable)") }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

struct ToolFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

extension AgentWorker {
    func sessionTools(_ agent: Agent, _ mission: AgentMission, _ folder: AgentFolder) -> [BrainTool] {
        guard mission.mayRunSessions, CodingSessions.available() else { return [] }
        let sessions = CodingSessions(folder: folder)
        let start = BrainTool(name: "session_start", description: "Start a coding session (Claude Code, installed on this Mac) in a fresh worktree of a repo in your scope. It can only read and edit files in that worktree: no commands, no network. You drive it like its user: it returns its answer, its changes, and any question it asks.", parameters: [
            "repo": ["type": "string", "description": "The repo's name exactly as in your scope."],
            "clone_url": ["type": "string", "description": "The repo's https git URL."],
            "prompt": ["type": "string", "description": "The full task, as you would write it to a colleague who knows nothing yet. Tell it that it cannot run commands."],
            "why": ["type": "string", "description": "Why you start it, in one sentence."],
        ], effect: .read) { [weak self] args in
            guard let repo = args.string("repo"), let url = args.string("clone_url"), let prompt = args.string("prompt") else { return ToolOutput(text: "repo, clone_url and prompt are needed", ok: false) }
            guard mission.scope.contains(where: { $0.caseInsensitiveCompare(repo) == .orderedSame }), mission.covers(url), url.hasPrefix("https://"), OffLimits.match(repo + " " + url) == nil, !Self.dryRun else {
                let refusal = Self.dryRun ? "dry run: no session started" : "outside your scope: \(repo)"
                await MainActor.run { self?.note(.refused, "Start a session on \(repo)", args.string("why") ?? "", refusal, agent) }
                return ToolOutput(text: "refused: \(refusal)", ok: false)
            }
            let session: CodingSession
            switch await Task.detached(operation: { sessions.create(repo: repo, cloneURL: url) }).value {
            case let .success(created): session = created
            case let .failure(failure):
                await MainActor.run { self?.note(.failed, "Start a session on \(repo)", args.string("why") ?? "", failure.message, agent) }
                return ToolOutput(text: failure.message, ok: false)
            }
            let answer = await sessions.send(prompt, to: session)
            let current = sessions.session(session.id) ?? session
            await MainActor.run {
                self?.note(answer.failed ? .failed : .session, "Started session \(session.id) on \(repo)", args.string("why") ?? "", "\(String(format: "$%.3f", answer.cost)): \(answer.text.prefix(400))", agent)
                self?.markUsed("claude", by: agent)
            }
            return ToolOutput(text: "session \(session.id), branch \(session.branch)\nanswer:\n\(answer.text)\n\n\(sessions.changes(current))", ok: !answer.failed)
        }
        let reply = BrainTool(name: "session_reply", description: "Answer a session's question, refuse what it proposed and say what to change, or give it the next step. It continues with its full context.", parameters: [
            "session": ["type": "string"],
            "text": ["type": "string", "description": "What you say to it, as its user."],
            "why": ["type": "string", "description": "Why, in one sentence."],
        ], effect: .read) { [weak self] args in
            guard let id = args.string("session"), let text = args.string("text"), let session = sessions.session(id), session.open else { return ToolOutput(text: "no open session with that id", ok: false) }
            let answer = await sessions.send(text, to: session)
            await MainActor.run { self?.note(answer.failed ? .failed : .session, "Answered session \(id): \(text.prefix(120))", args.string("why") ?? "", "\(String(format: "$%.3f", answer.cost)): \(answer.text.prefix(400))", agent) }
            return ToolOutput(text: "answer:\n\(answer.text)\n\n\(sessions.changes(session))", ok: !answer.failed)
        }
        let act = BrainTool(name: "session_act", description: "Accept a session's work: run one plain command inside its worktree. In order: `git add -A`, then `git commit -F \"$\(ActionGuard.bodyVariable)\"` with the message in body, then `git push -u origin HEAD`, then open a draft pull request naming the repo. Long text goes in body, read from the file \"$\(ActionGuard.bodyVariable)\". Quote any argument with spaces.", parameters: [
            "session": ["type": "string"],
            "command": ["type": "string"],
            "body": ["type": "string"],
            "did": ["type": "string", "description": "What this does, in plain words, for the journal."],
            "why": ["type": "string", "description": "Why, in one sentence."],
            "undo": ["type": "string", "description": "How to undo it, in plain words, if it can be undone."],
            "undo_command": ["type": "string", "description": "The one command that undoes it, if there is one."],
        ], required: ["session", "command", "did", "why"], effect: .read) { [weak self] args in
            guard let self, let id = args.string("session"), let command = args.string("command"), let session = sessions.session(id), session.open else { return ToolOutput(text: "no open session with that id", ok: false) }
            let check = ActionGuard(mission: mission, worktree: URL(fileURLWithPath: session.worktree))
            return await self.act(command, args: args, cwd: session.worktree, guardBy: check, agent: agent, folder: folder)
        }
        let close = BrainTool(name: "session_close", description: "End a session and remove its worktree: after its work is pushed, or to refuse it for good.", parameters: [
            "session": ["type": "string"],
            "why": ["type": "string", "description": "Why, in one sentence."],
        ], effect: .read) { [weak self] args in
            guard let id = args.string("session"), let session = sessions.session(id), session.open else { return ToolOutput(text: "no open session with that id", ok: false) }
            await Task.detached { sessions.close(session) }.value
            await MainActor.run { self?.note(.session, "Closed session \(id)", args.string("why") ?? "", String(format: "$%.3f in all", session.costUSD), agent) }
            return ToolOutput(text: "closed")
        }
        return [start, reply, act, close]
    }
}
