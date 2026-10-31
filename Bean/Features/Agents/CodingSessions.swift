import Foundation

enum SessionStatus: String, Codable {
    case running, waiting, finished, stopped
}

struct CodingSession: Codable {
    let id: String
    let repo: String
    var branch: String
    var worktree: String
    var claudeSession: String?
    var costUSD: Double = 0
    var open = true
    var task: String?
    var workId: String?
    var startedAt: Date?
    var status: SessionStatus?
    var step: String?
    var question: String?
    var pullRequest: String?
}

final class CodingSessions {
    static let budgetUSD = "1"
    static let timeout: TimeInterval = 600
    private static let stripped: Set<String> = ["MODEL_API_KEY", "OPENROUTER_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GH_TOKEN", "GITHUB_TOKEN"]

    private static let saving = NSLock()
    private static let creating = NSLock()

    private let folder: AgentFolder
    private var root: URL { folder.url.appendingPathComponent("sessions") }
    var sessionsRoot: URL { root }
    private var file: URL { root.appendingPathComponent("sessions.json") }

    init(folder: AgentFolder) {
        self.folder = folder
    }

    var all: [CodingSession] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([CodingSession].self, from: $0) } ?? []
    }

    func session(_ id: String) -> CodingSession? { all.first { $0.id == id } }

    var startedLately: String {
        let lines = all.filter { $0.task != nil && Date().timeIntervalSince($0.startedAt ?? .distantPast) < 43200 }.suffix(5).map { "- \($0.id), \($0.open ? "open" : "finished")\($0.workId.map { ", work id \($0)" } ?? ""): \(($0.task ?? "").prefix(160))" }
        return lines.isEmpty ? "" : "Coding sessions you already started. Look at these before starting any, and do not start the same work again:\n\(lines.joined(separator: "\n"))"
    }

    func save(_ session: CodingSession) {
        Self.saving.withLock {
            var sessions = all.filter { $0.id != session.id }
            sessions.append(session)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? JSONEncoder().encode(sessions).write(to: file, options: .atomic)
        }
    }

    func update(_ id: String, _ change: (inout CodingSession) -> Void) {
        Self.saving.withLock {
            var sessions = all
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
            change(&sessions[index])
            try? JSONEncoder().encode(sessions).write(to: file, options: .atomic)
        }
    }

    static func pullRequestLink(in text: String) -> String? {
        text.firstMatch(of: /https:\/\/\S+\/pull\/\d+/).map { String($0.0) }
    }

    // A session can change branch or open its own pull request, so what is true is read from its folder.
    func currentBranch(of session: CodingSession) -> String? {
        let name = Self.run("/usr/bin/git", ["branch", "--show-current"], in: URL(fileURLWithPath: session.worktree)).output.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    func pullRequestLink(of session: CodingSession) -> String? {
        let view = HiddenShell.run("gh pr view --json url --jq .url", in: session.worktree, timeout: 15)
        return view.exit == 0 ? Self.pullRequestLink(in: view.output) : nil
    }

    static func available() -> Bool {
        HiddenShell.run("command -v claude", timeout: 10).exit == 0
    }

    func create(repo: String, cloneURL: String, onBranch: String? = nil) -> Result<CodingSession, ToolFailure> {
        Self.creating.lock()
        defer { Self.creating.unlock() }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let clone = root.appendingPathComponent("repos").appendingPathComponent(repo.replacingOccurrences(of: "/", with: "-"))
        try? FileManager.default.createDirectory(at: clone.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: clone.path) {
            let cloned = Self.run("/usr/bin/git", ["clone", "--quiet", cloneURL, clone.path], in: root)
            guard cloned.exit == 0 else { return .failure(ToolFailure("clone failed: \(cloned.output.prefix(300))")) }
        } else {
            _ = Self.run("/usr/bin/git", ["fetch", "--quiet", "origin"], in: clone)
        }
        let branch = onBranch ?? "bean/\(id)"
        let worktree = root.appendingPathComponent(id)
        let added = Self.run("/usr/bin/git", ["worktree", "add", "--quiet", "-B", branch, worktree.path, onBranch.map { "origin/\($0)" } ?? "origin/HEAD"], in: clone)
        guard added.exit == 0 else { return .failure(ToolFailure("worktree failed: \(added.output.prefix(300))")) }
        let session = CodingSession(id: id, repo: repo, branch: branch, worktree: worktree.path)
        save(session)
        return .success(session)
    }

    func changes(_ session: CodingSession) -> String {
        guard !session.worktree.isEmpty else { return "" }
        let worktree = URL(fileURLWithPath: session.worktree)
        _ = Self.run("/usr/bin/git", ["add", "--intent-to-add", "."], in: worktree)
        let status = Self.run("/usr/bin/git", ["status", "--short"], in: worktree).output
        let diff = Self.run("/usr/bin/git", ["diff", "HEAD"], in: worktree).output
        return "git status:\n\(status.isEmpty ? "clean\n" : status)\ndiff:\n\(diff.prefix(5000))"
    }

    func closeIfBranchIsGone(repo: String) {
        for session in all where session.open && session.repo.caseInsensitiveCompare(repo) == .orderedSame {
            let worktree = URL(fileURLWithPath: session.worktree)
            if Self.run("/usr/bin/git", ["ls-remote", "--heads", "origin", session.branch], in: worktree).output.isEmpty { close(session) }
        }
    }

    func isFinished(_ session: CodingSession) -> Bool {
        guard !session.worktree.isEmpty, FileManager.default.fileExists(atPath: session.worktree) else { return true }
        let worktree = URL(fileURLWithPath: session.worktree)
        return Self.run("/usr/bin/git", ["status", "--short"], in: worktree).output.isEmpty
            && Self.run("/usr/bin/git", ["log", "--oneline", "HEAD", "--not", "--remotes"], in: worktree).output.isEmpty
    }

    // Its work is pushed. The folder stays for a while, so the user can open the session in a terminal.
    func finish(_ session: CodingSession) {
        update(session.id) { $0.open = false }
    }

    func removeOldFolders() {
        for session in all where !session.open && !session.worktree.isEmpty && Date().timeIntervalSince(session.startedAt ?? .distantPast) > 86400 && FileManager.default.fileExists(atPath: session.worktree) {
            close(session)
        }
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

enum CodeRepos {
    struct Repo {
        let name: String
        let about: String
    }

    private static let lock = NSLock()
    private static var read: (at: Date, available: Bool, repos: [Repo])?

    static var known: [Repo] { lock.withLock { read?.repos ?? [] } }
    static var described: String { known.map { $0.about.isEmpty ? $0.name : "\($0.name) (\($0.about.prefix(80)))" }.joined(separator: "; ") }
    static var sessionsAvailable: Bool { lock.withLock { read?.available ?? false } }

    static let dryRun = AgentWorker.dryRun && ProcessInfo.processInfo.environment["BEAN_REAL_SESSIONS"] != "1"

    static func refresh() async {
        if let at = lock.withLock({ read?.repos.isEmpty == false ? read?.at : nil }), Date().timeIntervalSince(at) < 3600 { return }
        let found = await Task.detached { (CodingSessions.available(), repos()) }.value
        lock.withLock { read = (Date(), found.0, found.1) }
    }

    private static func repos() -> [Repo] {
        let environment = ProcessInfo.processInfo.environment
        let listed = environment["BEAN_CODE_REPOS"] ?? (environment["BEAN_DATA_DIR"] == nil ? HiddenShell.run("gh repo list --limit 15 --no-archived --json nameWithOwner,description --jq '.[] | .nameWithOwner + \"\\t\" + (.description // \"\")'", timeout: 20).output : "")
        return listed.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard let name = parts.first, name.contains("/"), OffLimits.match(String(line)) == nil else { return nil }
            return Repo(name: name, about: parts.count > 1 ? parts[1] : "")
        }
    }
}

extension AgentMission {
    func reaching(_ repo: String) -> AgentMission {
        var mission = self
        if !mission.scope.contains(where: { $0.caseInsensitiveCompare(repo) == .orderedSame }) { mission.scope.append(repo) }
        return mission
    }
}

struct ToolFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

extension AgentWorker {
    func sessionTools(_ agent: Agent, _ mission: AgentMission, _ folder: AgentFolder) -> [BrainTool] {
        guard CodingSessions.available(), sessionAbilityOn(agent, mission: mission, folder: folder) else { return [] }
        let sessions = CodingSessions(folder: folder)
        func refusal(repo: String, url: String) -> String? {
            let targeted = repo.contains("/") && mission.scope.contains { $0.caseInsensitiveCompare(repo) == .orderedSame } && mission.covers(url)
            let listed = url == "https://github.com/\(repo).git" && CodeRepos.known.contains { $0.name.caseInsensitiveCompare(repo) == .orderedSame }
            guard (targeted || listed), url.hasPrefix("https://"), OffLimits.match(repo + " " + url) == nil else {
                return "\(repo) is not a repo you can work in. Choose one of these by its owner/name: \(CodeRepos.described). If you cannot tell which, ask_user with the likely ones as options"
            }
            return CodeRepos.dryRun ? "dry run: no session started" : nil
        }
        var drive = BrainTool(name: "session_drive", description: "Get code written: start a coding session (the coding agent installed on this Mac) in a fresh worktree of a repo in your targets or listed for you, or continue one. A stand-in answers its questions and permission requests on the user's behalf, and the user watches it on Bean's page. This returns at once. Then finish your run: you are woken with the outcome and the changes when it ends, with nothing to wait for. One piece of work gets one session: to fix or check what a session did, continue it with its id instead of starting another.", parameters: [
            "repo": ["type": "string", "description": "The repo's owner/name exactly as listed: \(CodeRepos.described)."],
            "clone_url": ["type": "string", "description": "The repo's https git URL, if it is not on GitHub."],
            "branch": ["type": "string", "description": "To work on a branch that already exists, such as the one of an open pull request. Leave empty for a new branch."],
            "task": ["type": "string", "description": "The full task, as you would write it to a colleague who knows nothing yet. Tell it to leave its changes uncommitted: once it returns, you commit, push and open the pull request yourself with session_act. Never ask a session to do those."],
            "session": ["type": "string", "description": "To continue an open session: its id. Leave empty to start one."],
            "work_id": ["type": "string", "description": "To start one: the exact id of this work, the one you were given or its ticket id. The same id can only run once at a time."],
            "why": ["type": "string", "description": "Why, in one sentence."],
        ], required: ["task", "why"], effect: .read) { [weak self] args in
            guard let self, let task = args.string("task") else { return ToolOutput(text: "task is needed", ok: false) }
            if await MainActor.run(body: { self.isOverBudget(agent) }) { return ToolOutput(text: "your budget for today is spent: call finish now", ok: false) }
            let why = args.string("why") ?? ""
            let session: CodingSession
            if let id = args.string("session") {
                guard let found = sessions.session(id), FileManager.default.fileExists(atPath: found.worktree) else { return ToolOutput(text: "no session with that id still has its folder", ok: false) }
                if await MainActor.run(body: { self.drivingSessions.contains(id) }) { return ToolOutput(text: "session \(id) is still running: you are woken when it ends", ok: false) }
                sessions.update(id) { $0.open = true }
                session = found
            } else {
                guard let repo = args.string("repo") else { return ToolOutput(text: "repo is needed to start a session: name it exactly as listed", ok: false) }
                let url = args.string("clone_url") ?? "https://github.com/\(repo).git"
                if let refusal = refusal(repo: repo, url: url) {
                    await MainActor.run { self.note(.refused, "Start a session on \(repo): \(task.prefix(240))", why, refusal, agent) }
                    return ToolOutput(text: "refused: \(refusal)", ok: false)
                }
                guard let workId = args.string("work_id") else { return ToolOutput(text: "work_id is needed to start a session", ok: false) }
                if let held = await self.claim(workId, agent: agent) { return ToolOutput(text: held, ok: false) }
                let root = await MainActor.run { self.storeForBrain.root }
                switch await Task.detached(operation: { sessions.create(repo: repo, cloneURL: url, onBranch: args.string("branch")) }).value {
                case var .success(created):
                    created.task = task
                    created.workId = workId
                    created.startedAt = Date()
                    sessions.save(created)
                    SessionClaims.set(SessionClaim(key: workId, session: created.id, agent: agent.name, at: Date()), in: root)
                    session = created
                case let .failure(failure):
                    SessionClaims.release(workId, in: root)
                    await MainActor.run { self.note(.failed, "Start a session on \(repo)", why, failure.message, agent) }
                    return ToolOutput(text: failure.message, ok: false)
                }
            }
            await MainActor.run { self.startDriving(session, task: task, why: why, agent: agent, mission: mission, folder: folder) }
            return ToolOutput(text: "Session \(session.id) is running on branch \(session.branch), and the user can watch it on Bean's page. Do not start this work again. Finish your run now: you are woken with the outcome and the changes when it ends.")
        }
        drive.runsAtOnce = true
        let act = BrainTool(name: "session_act", description: "Accept a session's work: run one plain command inside its worktree. In order: `git add -A`, then `git commit -F \"$\(ActionGuard.bodyVariable)\"` with the message in body, then `git push -u origin HEAD`, then `gh pr create --draft --repo <owner/name> --title \"<title>\" --body-file \"$\(ActionGuard.bodyVariable)\"`. Long text goes in body, read from the file \"$\(ActionGuard.bodyVariable)\". Quote any argument with spaces.", parameters: [
            "session": ["type": "string"],
            "command": ["type": "string"],
            "body": ["type": "string"],
            "did": ["type": "string", "description": "What this does, in plain words, for the journal."],
            "why": ["type": "string", "description": "Why, in one sentence."],
            "undo": ["type": "string", "description": "How to undo it, in plain words, if it can be undone."],
            "undo_command": ["type": "string", "description": "The one command that undoes it, if there is one."],
        ], required: ["session", "command", "did", "why"], effect: .read) { [weak self] args in
            guard let self, let id = args.string("session"), let command = args.string("command"), let session = sessions.session(id), session.open, !session.worktree.isEmpty else { return ToolOutput(text: "no open session with that id", ok: false) }
            let worktree = URL(fileURLWithPath: session.worktree)
            let reach = mission.reaching(session.repo)
            if ActionGuard(mission: reach, worktree: worktree, abilities: folder.abilities).isUnknown(command) { await self.learn(command, agent: agent, mission: reach, folder: folder) }
            let check = ActionGuard(mission: reach, worktree: worktree, abilities: folder.abilities)
            let output = await self.act(command, args: args, cwd: session.worktree, guardBy: check, agent: agent, folder: folder)
            if output.ok, let link = CodingSessions.pullRequestLink(in: output.text) {
                sessions.update(id) { $0.pullRequest = link }
                await MainActor.run { self.refresh() }
            }
            return output
        }
        let close = BrainTool(name: "session_close", description: "End a session and remove its worktree: after its work is pushed, or to refuse it for good.", parameters: [
            "session": ["type": "string"],
            "why": ["type": "string", "description": "Why, in one sentence."],
        ], effect: .read) { [weak self] args in
            guard let id = args.string("session"), let session = sessions.session(id), session.open else { return ToolOutput(text: "no open session with that id", ok: false) }
            await Task.detached { sessions.close(session) }.value
            await MainActor.run {
                self?.releaseClaim(of: session, agent: agent, why: "the session was closed")
                self?.note(.session, "Closed the session on \(session.repo)", args.string("why") ?? "", String(format: "$%.3f in all", session.costUSD), agent)
            }
            return ToolOutput(text: "closed")
        }
        return [drive, act, close]
    }
}
