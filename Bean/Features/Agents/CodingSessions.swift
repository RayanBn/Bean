import Foundation

struct CodingSession: Codable {
    let id: String
    let repo: String
    let branch: String
    let worktree: String
    var claudeSession: String?
    var costUSD: Double = 0
    var open = true
    var workspace: Bool?
    var task: String?
    var startedAt: Date?
    var mainAt: String?
}

enum AppSessionState {
    case notStarted, running, stalled(String), finished(String)
}

enum SessionGuards {
    private static let gitReads = ["status", "diff", "log", "show", "rev-parse", "ls-files", "ls-remote", "fetch", "describe", "blame", "branch", "remote -v", "remote get-url"]
    private static let commands = ["ls", "cat", "head", "tail", "wc", "grep", "pwd", "npm test", "pnpm test", "yarn test", "pytest", "python3 -m pytest", "swift test", "swift build", "cargo test", "go test", "make test"]
    private static let refused = ["git push", "git commit", "git merge", "git rebase", "git reset", "git checkout", "git switch", "git branch -D", "git branch -d", "git branch -m", "git remote add", "git remote set-url", "git config", "gh", "curl", "wget", "ssh", "rm -rf"]

    static func settings(for folder: URL) -> [String: Any] {
        let reads = gitReads.flatMap { ["git \($0)", "git -C \(folder.path) \($0)"] }
        let denied = refused + refused.filter { $0.hasPrefix("git ") }.map { "git -C \(folder.path) \($0.dropFirst(4))" }
        return ["permissions": [
            "defaultMode": "dontAsk",
            "allow": ["Edit", "Write"] + (reads + commands).map { "Bash(\($0)*)" },
            "deny": denied.map { "Bash(\($0)*)" },
        ]]
    }

    static func install(in folder: URL, branch: String) throws {
        let file = folder.appendingPathComponent(".claude/settings.local.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: settings(for: folder), options: [.prettyPrinted]).write(to: file)
        let git = folder.appendingPathComponent(".git")
        let hook = git.appendingPathComponent("hooks/pre-push")
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nwhile read local_ref local_sha remote_ref remote_sha; do\n  [ \"$remote_ref\" = \"refs/heads/\(branch)\" ] || { echo \"Bean: only \(branch) can be pushed from this folder\" >&2; exit 1; }\ndone\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try ignore(".claude/settings.local.json", in: git)
    }

    static func ignore(_ pattern: String, in git: URL) throws {
        let file = git.appendingPathComponent("info/exclude")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        guard !text.split(separator: "\n").contains(Substring(pattern)) else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + pattern + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}

final class CodingSessions {
    static let budgetUSD = "1"
    static let timeout: TimeInterval = 600
    private static let stripped: Set<String> = ["MODEL_API_KEY", "OPENROUTER_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GH_TOKEN", "GITHUB_TOKEN"]

    private static let saving = NSLock()
    private static let creating = NSLock()

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

    func save(_ session: CodingSession) {
        Self.saving.withLock {
            var sessions = all.filter { $0.id != session.id }
            sessions.append(session)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? JSONEncoder().encode(sessions).write(to: file, options: .atomic)
        }
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

    func prepareWorkspace(repo: String, cloneURL: String) -> Result<CodingSession, ToolFailure> {
        Self.creating.lock()
        defer { Self.creating.unlock() }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let branch = "bean/\(id)"
        let checkout = Self.trustedCheckout(of: repo)
        let folder = checkout.map { URL(fileURLWithPath: $0).appendingPathComponent(".claude/worktrees/bean-\(id)") } ?? root.appendingPathComponent(id)
        try? FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cloned = Self.run("/usr/bin/git", ["clone", "--quiet", cloneURL, folder.path], in: folder.deletingLastPathComponent())
        guard cloned.exit == 0 else { return .failure(ToolFailure("clone failed: \(cloned.output.prefix(300))")) }
        let mainAt = Self.remoteHead(in: folder)
        for command in [["checkout", "--quiet", "-b", branch], ["config", "core.hooksPath", ".git/hooks"]] {
            let done = Self.run("/usr/bin/git", command, in: folder)
            guard done.exit == 0 else { return .failure(ToolFailure("preparing the folder failed: \(done.output.prefix(300))")) }
        }
        do {
            try SessionGuards.install(in: folder, branch: branch)
            if let checkout { try SessionGuards.ignore(".claude/worktrees/", in: URL(fileURLWithPath: checkout).appendingPathComponent(".git")) }
        } catch {
            return .failure(ToolFailure("preparing the folder failed: \(error.localizedDescription)"))
        }
        var session = CodingSession(id: id, repo: repo, branch: branch, worktree: folder.path)
        session.workspace = true
        session.startedAt = Date()
        session.mainAt = mainAt
        save(session)
        return .success(session)
    }

    static func trustedCheckout(of repo: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
              let projects = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["projects"] as? [String: [String: Any]] else { return nil }
        let trusted = projects.filter { $0.value["hasTrustDialogAccepted"] as? Bool == true && !$0.key.contains("/.claude/worktrees/") && OffLimits.match($0.key) == nil }.keys.sorted { $0.count < $1.count }
        return trusted.first { path in
            let config = (try? String(contentsOfFile: "\(path)/.git/config", encoding: .utf8)) ?? ""
            return config.lowercased().contains("/\(repo.lowercased())") || config.lowercased().contains(":\(repo.lowercased())")
        }
    }

    private static func remoteHead(in folder: URL) -> String? {
        run("/usr/bin/git", ["ls-remote", "origin", "HEAD"], in: folder).output.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    func mainMoved(_ session: CodingSession) -> String? {
        guard session.workspace == true, let before = session.mainAt, FileManager.default.fileExists(atPath: session.worktree),
              let now = Self.remoteHead(in: URL(fileURLWithPath: session.worktree)), now != before else { return nil }
        return "the main branch of \(session.repo) moved from \(before.prefix(7)) to \(now.prefix(7)) while session \(session.id) ran. Nothing here should touch it: say so plainly and let the user look."
    }

    func appState(_ session: CodingSession) -> AppSessionState {
        let encoded = session.worktree.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects/\(encoded)")
        let files = ((try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter { $0.pathExtension == "jsonl" }
        let dated = files.map { (file: $0, at: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        guard let newest = dated.max(by: { $0.at < $1.at }), let text = try? String(contentsOf: newest.file, encoding: .utf8) else { return .notStarted }
        let turns = text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }.filter { ["user", "assistant"].contains($0["type"] as? String) }
        guard let last = turns.last, let message = last["message"] as? [String: Any] else { return .notStarted }
        let idle = Date().timeIntervalSince(newest.at)
        let blocks = message["content"] as? [[String: Any]] ?? []
        if last["type"] as? String == "assistant" {
            if let tool = blocks.last(where: { $0["type"] as? String == "tool_use" }) {
                guard idle >= Self.stalledAfter else { return .running }
                let input = (try? JSONSerialization.data(withJSONObject: tool["input"] ?? [:])).map { String(decoding: $0, as: UTF8.self) } ?? ""
                return .stalled("\(tool["name"] as? String ?? "a tool"): \(input.prefix(200))")
            }
            guard idle >= 5 else { return .running }
            return .finished(blocks.compactMap { $0["text"] as? String }.joined(separator: "\n"))
        }
        return idle >= Self.stalledAfter ? .stalled("no reply from the session") : .running
    }

    private static let stalledAfter: TimeInterval = 60

    func changes(_ session: CodingSession) -> String {
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
        let worktree = URL(fileURLWithPath: session.worktree)
        return Self.run("/usr/bin/git", ["status", "--short"], in: worktree).output.isEmpty
            && Self.run("/usr/bin/git", ["log", "--oneline", "HEAD", "--not", "--remotes"], in: worktree).output.isEmpty
    }

    func close(_ session: CodingSession) {
        var session = session
        if session.workspace == true {
            try? FileManager.default.removeItem(atPath: session.worktree)
            session.open = false
            return save(session)
        }
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
        var drive = BrainTool(name: "session_drive", description: "Get code written in the background, where nobody sees it, when no window of an app that runs coding sessions is open: start a coding session (Claude Code, installed on this Mac) in a fresh worktree of a repo in your targets or listed for you, or continue one, and stand in as its user. One piece of work gets one session: to fix or check what a session did, continue it with its id instead of starting another. It answers the session's questions and permission requests on the user's behalf until the task is done, then returns the outcome and the changes.", parameters: [
            "repo": ["type": "string", "description": "The repo's owner/name exactly as listed: \(CodeRepos.described)."],
            "clone_url": ["type": "string", "description": "The repo's https git URL, if it is not on GitHub."],
            "branch": ["type": "string", "description": "To work on a branch that already exists, such as the one of an open pull request. Leave empty for a new branch."],
            "task": ["type": "string", "description": "The full task, as you would write it to a colleague who knows nothing yet. Tell it to leave its changes uncommitted: once it returns, you commit, push and open the pull request yourself with session_act. Never ask a session to do those."],
            "session": ["type": "string", "description": "To continue an open session: its id. Leave empty to start one."],
            "why": ["type": "string", "description": "Why, in one sentence."],
        ], required: ["task", "why"], effect: .read) { [weak self] args in
            guard let self, let task = args.string("task") else { return ToolOutput(text: "task is needed", ok: false) }
            if await MainActor.run(body: { self.isOverBudget(agent) }) { return ToolOutput(text: "your budget for today is spent: call finish now", ok: false) }
            let why = args.string("why") ?? ""
            let session: CodingSession
            if let id = args.string("session") {
                guard let open = sessions.session(id), open.open else { return ToolOutput(text: "no open session with that id", ok: false) }
                session = open
            } else {
                if let window = await Task.detached(operation: { WindowChannels.open().first { Skills.forApp($0.bundleId)?.runsSessions == true } }).value {
                    let mine = window.bundleId == agent.attachment?.bundleId
                    await MainActor.run {
                        self.note(.session, "Left the session to \(window.app)", why, "", agent)
                        if !mine { self.ownedSteps = self.ownedSteps.filter { $0.value != agent.name } }
                    }
                    return ToolOutput(text: mine ? "Not started: sessions run in your window here, as your know-how for this app says." : "Not started: \(window.app) is open and \(Skills.forApp(window.bundleId)?.does ?? "runs coding sessions"), so this work belongs in that window \"\(window.title ?? window.app)\". Finish now and say so: Bean gives it to an agent there.", ok: false)
                }
                guard let repo = args.string("repo") else { return ToolOutput(text: "repo is needed to start a session: name it exactly as listed", ok: false) }
                let url = args.string("clone_url") ?? "https://github.com/\(repo).git"
                let words = { (text: String) in Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 3 }) }
                if let same = sessions.all.last(where: { other in
                    guard let earlier = other.task, other.startedAt.map({ Date().timeIntervalSince($0) < 3600 }) == true else { return false }
                    return Double(words(earlier).intersection(words(task)).count) / Double(max(1, words(earlier).union(words(task)).count)) >= 0.5
                }) {
                    return ToolOutput(text: "Not started: session \(same.id) on branch \(same.branch) already has this piece. \(same.open ? "Continue it with its id." : "It is finished: do not do it again.")", ok: false)
                }
                if let refusal = refusal(repo: repo, url: url) {
                    await MainActor.run { self.note(.refused, "Start a session on \(repo): \(task.prefix(240))", why, refusal, agent) }
                    return ToolOutput(text: "refused: \(refusal)", ok: false)
                }
                switch await Task.detached(operation: { sessions.create(repo: repo, cloneURL: url, onBranch: args.string("branch")) }).value {
                case var .success(created):
                    created.task = task
                    created.startedAt = Date()
                    sessions.save(created)
                    session = created
                case let .failure(failure):
                    await MainActor.run { self.note(.failed, "Start a session on \(repo)", why, failure.message, agent) }
                    return ToolOutput(text: failure.message, ok: false)
                }
            }
            await MainActor.run {
                self.note(.session, "Started a session on \(session.repo): \(task.prefix(120))", why, "", agent)
                self.markUsed("claude", by: agent)
            }
            let asked = await MainActor.run { self.doing[agent.id] }
            let report = await ClaudeStandIn(agent: agent, mission: mission.reaching(session.repo), folder: folder, worker: self, session: session, asked: asked).drive(task: task)
            var updated = sessions.session(session.id) ?? session
            updated.claudeSession = report.claudeSession ?? updated.claudeSession
            updated.costUSD += report.costUSD
            sessions.save(updated)
            let current = updated
            let changes = await Task.detached { sessions.changes(current) }.value
            let verdict = report.outcome == "accept" ? "accepted its work" : report.outcome == "refuse" ? "refused its work" : report.outcome == "waiting" ? "waiting for your decision" : "stopped: \(report.outcome)"
            let summary = String(format: "%d turns, $%.3f. Commands allowed: %@", report.turns, report.costUSD, report.allowed.prefix(12).joined(separator: "; "))
            await MainActor.run { self.note(.session, "Session on \(session.repo): \(verdict)", why, summary, agent, claudeUSD: report.costUSD) }
            if let need = report.need { return ToolOutput(text: "session \(session.id) is waiting for the user's decision: \(need.question). Leave it open and do not touch this task. Move to another task, or finish.") }
            return ToolOutput(text: "session \(session.id), branch \(session.branch), outcome \(report.outcome), \(report.turns) turns\nrefused in the session: \(report.denied.prefix(5).joined(separator: "; "))\nlast message:\n\(report.lastMessage.prefix(1500))\n\n\(changes)\n\nIf this is right, accept it now yourself with session_act. Do not ask the session to commit.")
        }
        drive.runsAtOnce = true
        let workspace = BrainTool(name: "session_workspace", description: "Get a fresh copy of a repo on a new branch, in a folder of its own, to point a coding app at. It returns the folder and a session id. Follow it with session_wait, then accept the work with session_act on that id, or end it with session_close.", parameters: [
            "repo": ["type": "string", "description": "The repo's owner/name exactly as listed: \(CodeRepos.described)."],
            "task": ["type": "string", "description": "What the session will do, in one sentence."],
            "why": ["type": "string", "description": "Why, in one sentence."],
        ], required: ["repo", "why"], effect: .read) { [weak self] args in
            guard let self, let repo = args.string("repo") else { return ToolOutput(text: "repo is needed", ok: false) }
            let url = "https://github.com/\(repo).git"
            if let refusal = refusal(repo: repo, url: url) { return ToolOutput(text: "refused: \(refusal)", ok: false) }
            switch await Task.detached(operation: { sessions.prepareWorkspace(repo: repo, cloneURL: url) }).value {
            case var .success(created):
                created.task = args.string("task")
                sessions.save(created)
                let session = created
                await MainActor.run { self.note(.session, "Prepared a copy of \(repo) on branch \(session.branch)", args.string("why") ?? "", session.worktree, agent) }
                return ToolOutput(text: "session \(session.id), branch \(session.branch), folder \(session.worktree). The session there can read and edit, but cannot commit or push: you do that with session_act afterwards.")
            case let .failure(failure):
                return ToolOutput(text: failure.message, ok: false)
            }
        }
        var wait = BrainTool(name: "session_wait", description: "Wait for the session a coding app is running in the folder of session_workspace, and get its result and the changes. It returns when the session finishes or stops moving, after 10 minutes at most.", parameters: [
            "session": ["type": "string"],
        ], required: ["session"], effect: .read) { [weak self] args in
            guard let id = args.string("session"), let session = sessions.session(id), session.open else { return ToolOutput(text: "no open session with that id", ok: false) }
            let started = Date()
            var state = AppSessionState.notStarted
            waiting: while Date().timeIntervalSince(started) < CodingSessions.timeout {
                if BeanSettings.shared.effectivePaused { return ToolOutput(text: "all agents are paused", ok: false) }
                state = await Task.detached { sessions.appState(session) }.value
                switch state {
                case .finished, .stalled: break waiting
                case .notStarted where Date().timeIntervalSince(started) > 90: break waiting
                default: try? await Task.sleep(for: .seconds(3))
                }
            }
            let moved = await Task.detached { sessions.mainMoved(session) }.value
            let warning = moved.map { "\nWARNING: \($0)" } ?? ""
            if moved != nil { await MainActor.run { self?.note(.failed, "Main moved during a session on \(session.repo)", "", moved ?? "", agent) } }
            switch state {
            case .notStarted:
                return ToolOutput(text: "No session has started in that folder. Check window_controls: your text may still wait to be sent, or the app may be asking something.\(warning)", ok: false)
            case .running:
                return ToolOutput(text: "Still running after 10 minutes. Call session_wait again, or finish and say it is still running.\(warning)")
            case let .stalled(on):
                return ToolOutput(text: "The session has stopped moving on \(on). It may be waiting for a permission or an answer in the app, and you cannot give those. Call session_wait once more if it may still be working, otherwise ask_user and stop.\(warning)")
            case let .finished(last):
                let changes = await Task.detached { sessions.changes(session) }.value
                return ToolOutput(text: "Finished. Its last message:\n\(last.prefix(1500))\n\n\(changes)\n\nIf this is right, accept it now with session_act.\(warning)")
            }
        }
        wait.runsAtOnce = true
        let act = BrainTool(name: "session_act", description: "Accept a session's work: run one plain command inside its worktree. In order: `git add -A`, then `git commit -F \"$\(ActionGuard.bodyVariable)\"` with the message in body, then `git push -u origin HEAD`, then `gh pr create --draft --repo <owner/name> --title \"<title>\" --body-file \"$\(ActionGuard.bodyVariable)\"`. Long text goes in body, read from the file \"$\(ActionGuard.bodyVariable)\". Quote any argument with spaces.", parameters: [
            "session": ["type": "string"],
            "command": ["type": "string"],
            "body": ["type": "string"],
            "did": ["type": "string", "description": "What this does, in plain words, for the journal."],
            "why": ["type": "string", "description": "Why, in one sentence."],
            "undo": ["type": "string", "description": "How to undo it, in plain words, if it can be undone."],
            "undo_command": ["type": "string", "description": "The one command that undoes it, if there is one."],
        ], required: ["session", "command", "did", "why"], effect: .read) { [weak self] args in
            guard let self, let id = args.string("session"), let command = args.string("command"), let session = sessions.session(id), session.open else { return ToolOutput(text: "no open session with that id", ok: false) }
            let worktree = URL(fileURLWithPath: session.worktree)
            let reach = mission.reaching(session.repo)
            if ActionGuard(mission: reach, worktree: worktree, abilities: folder.abilities).isUnknown(command) { await self.learn(command, agent: agent, mission: reach, folder: folder) }
            let check = ActionGuard(mission: reach, worktree: worktree, abilities: folder.abilities)
            return await self.act(command, args: args, cwd: session.worktree, guardBy: check, agent: agent, folder: folder)
        }
        let close = BrainTool(name: "session_close", description: "End a session and remove its worktree: after its work is pushed, or to refuse it for good.", parameters: [
            "session": ["type": "string"],
            "why": ["type": "string", "description": "Why, in one sentence."],
        ], effect: .read) { [weak self] args in
            guard let id = args.string("session"), let session = sessions.session(id), session.open else { return ToolOutput(text: "no open session with that id", ok: false) }
            await Task.detached { sessions.close(session) }.value
            await MainActor.run { self?.note(.session, "Closed the session on \(session.repo)", args.string("why") ?? "", String(format: "$%.3f in all", session.costUSD), agent) }
            return ToolOutput(text: "closed")
        }
        return [drive, workspace, wait, act, close]
    }
}
