import Foundation

struct CodingSession: Codable {
    let id: String
    let repo: String
    var branch: String
    var worktree: String
    var claudeSession: String?
    var costUSD: Double = 0
    var open = true
    var inApp: Bool?
    var task: String?
    var startedAt: Date?
    var mainAt: String?
    var localMainAt: String?
    var checkout: String?
    var folderName: String?
    var transcript: String?
}

enum AppSessionState {
    case notStarted, running, stalled(String), finished(String)
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

    var startedLately: String {
        let lines = all.filter { $0.task != nil && Date().timeIntervalSince($0.startedAt ?? .distantPast) < 43200 }.suffix(5).map { "- \($0.id)\($0.inApp == true ? ", sent in the app" : ""), \($0.open ? "open" : "finished"): \(($0.task ?? "").prefix(160))" }
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

    func recordAppSession(task: String, folderName: String?) -> CodingSession {
        let checkout = folderName.flatMap(Self.checkout(named:))
        let origin = checkout.map { Self.run("/usr/bin/git", ["remote", "get-url", "origin"], in: URL(fileURLWithPath: $0)).output } ?? ""
        let repo = origin.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ".git", with: "").split(whereSeparator: { "/:".contains($0) }).suffix(2).joined(separator: "/")
        var session = CodingSession(id: String(UUID().uuidString.prefix(8)).lowercased(), repo: repo.isEmpty ? folderName ?? "" : repo, branch: "", worktree: "")
        session.inApp = true
        session.task = task
        session.startedAt = Date()
        session.folderName = folderName
        session.checkout = checkout
        if let checkout {
            let folder = URL(fileURLWithPath: checkout)
            session.mainAt = Self.remoteHead(in: folder)
            session.localMainAt = Self.localMain(in: folder)
        }
        save(session)
        return session
    }

    private static func checkout(named name: String) -> String? {
        guard ProcessInfo.processInfo.environment["BEAN_NO_TRUSTED_CHECKOUT"] == nil else { return nil }
        guard let data = try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")),
              let projects = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["projects"] as? [String: Any] else { return nil }
        return projects.keys.filter { !$0.contains("/.claude/worktrees/") && ($0 as NSString).lastPathComponent == name && FileManager.default.fileExists(atPath: "\($0)/.git") }.min { $0.count < $1.count }
    }

    private static func remoteHead(in folder: URL) -> String? {
        run("/usr/bin/git", ["ls-remote", "origin", "HEAD"], in: folder).output.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    private static func localMain(in folder: URL) -> String? {
        let name = run("/usr/bin/git", ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: folder).output.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "origin/", with: "")
        let head = run("/usr/bin/git", ["rev-parse", "--verify", "-q", "refs/heads/\(name.isEmpty ? "main" : name)"], in: folder).output.trimmingCharacters(in: .whitespacesAndNewlines)
        return head.isEmpty ? nil : head
    }

    func mainMoved(_ session: CodingSession) -> String? {
        guard session.inApp == true, let checkout = session.checkout else { return nil }
        let folder = URL(fileURLWithPath: checkout)
        var moved: [String] = []
        if let before = session.mainAt, let now = Self.remoteHead(in: folder), now != before { moved.append("on the remote from \(before.prefix(7)) to \(now.prefix(7))") }
        if let before = session.localMainAt, let now = Self.localMain(in: folder), now != before { moved.append("locally from \(before.prefix(7)) to \(now.prefix(7))") }
        return moved.isEmpty ? nil : "main of \(session.repo) moved \(moved.joined(separator: " and ")) while session \(session.id) ran. Say so plainly and let the user look."
    }

    // New transcripts are matched by the text the agent sent, so another session's content is never used.
    private static func findTranscript(of session: CodingSession) -> (file: URL, cwd: String, branch: String)? {
        guard let task = session.task, let started = session.startedAt else { return nil }
        let flat = { (text: String) in text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let wanted = String(flat(task).prefix(200))
        let since = started.addingTimeInterval(-5)
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let folders = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >= since
        }
        let files = folders.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.creationDateKey])) ?? [] }.filter {
            $0.pathExtension == "jsonl" && ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) >= since
        }
        for file in files {
            guard let head = try? FileHandle(forReadingFrom: file), let data = try? head.read(upToCount: 200_000) else { continue }
            try? head.close()
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                guard let entry = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], entry["type"] as? String == "user", let message = entry["message"] as? [String: Any] else { continue }
                let content = message["content"]
                let typed = content as? String ?? (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: " ")
                if flat(typed).contains(wanted) { return (file, entry["cwd"] as? String ?? "", entry["gitBranch"] as? String ?? "") }
                break
            }
        }
        return nil
    }

    func appState(_ session: CodingSession) -> AppSessionState {
        var session = self.session(session.id) ?? session
        if session.transcript == nil, let found = Self.findTranscript(of: session) {
            session.transcript = found.file.path
            session.worktree = found.cwd
            session.branch = found.branch
            save(session)
        }
        guard let path = session.transcript, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return .notStarted }
        let at = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
        let turns = text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }.filter { ["user", "assistant"].contains($0["type"] as? String) }
        guard let last = turns.last, let message = last["message"] as? [String: Any] else { return .notStarted }
        let idle = Date().timeIntervalSince(at)
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

    private static let stalledAfter: TimeInterval = 120

    func pullRequest(_ session: CodingSession) -> (link: String, facts: String)? {
        guard !session.worktree.isEmpty, FileManager.default.fileExists(atPath: session.worktree) else { return nil }
        let view = HiddenShell.run("gh pr view --json url,isDraft,state --jq '.url + \" \" + (.isDraft|tostring) + \" \" + .state'", in: session.worktree, timeout: 15)
        let facts = view.output.split(whereSeparator: \.isWhitespace).map(String.init)
        guard view.exit == 0, facts.count == 3, facts[0].hasPrefix("https://") else { return nil }
        return (facts[0], "\(facts[0]), draft \(facts[1]), \(facts[2].lowercased())")
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

    func close(_ session: CodingSession) {
        var session = session
        if session.inApp == true {
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
        let watchable = WindowChannels.open().first { Skills.forApp($0.bundleId)?.runsSessions == true }.map { " \($0.app) is open: it \(Skills.forApp($0.bundleId)?.does ?? "runs coding sessions"), through an agent on its window. Choose what fits: the background suits work the user asked to run there, or a folder that app cannot use." } ?? ""
        var drive = BrainTool(name: "session_drive", description: "Get code written in the background, where nobody sees it: start a coding session (Claude Code, installed on this Mac) in a fresh worktree of a repo in your targets or listed for you, or continue one, and stand in as its user.\(watchable) One piece of work gets one session: to fix or check what a session did, continue it with its id instead of starting another. It answers the session's questions and permission requests on the user's behalf until the task is done, then returns the outcome and the changes.", parameters: [
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
                guard let repo = args.string("repo") else { return ToolOutput(text: "repo is needed to start a session: name it exactly as listed", ok: false) }
                let url = args.string("clone_url") ?? "https://github.com/\(repo).git"
                if let same = sessions.all.last(where: { other in
                    guard let earlier = other.task, other.startedAt.map({ Date().timeIntervalSince($0) < 3600 }) == true else { return false }
                    return AgentWorker.readsAlike(earlier, task)
                }), let earlier = same.task, await MainActor.run(body: { self.firstTimeAlike(task) }) {
                    return ToolOutput(text: "Not started yet, so you can compare. Session \(same.id) on branch \(same.branch) has this task: \(earlier.prefix(300)). If this is the same work, \(same.open ? "continue it with its id" : "it is finished, so do not do it again"). If it is different work, call this again with the same task and it starts.")
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
        var wait = BrainTool(name: "session_wait", description: "Wait for a session you sent in a coding app, and get its result, its branch and its pull request. It returns when the session finishes or stops moving, after 10 minutes at most.", parameters: [
            "session": ["type": "string"],
        ], required: ["session"], effect: .read) { [weak self] args in
            guard let id = args.string("session"), let first = sessions.session(id), first.inApp == true else { return ToolOutput(text: "no session sent in an app with that id", ok: false) }
            let started = Date()
            var state = AppSessionState.notStarted
            waiting: while Date().timeIntervalSince(started) < CodingSessions.timeout {
                if BeanSettings.shared.effectivePaused { return ToolOutput(text: "all agents are paused", ok: false) }
                state = await Task.detached { sessions.appState(first) }.value
                switch state {
                case .finished, .stalled: break waiting
                case .notStarted where Date().timeIntervalSince(started) > 90: break waiting
                default: try? await Task.sleep(for: .seconds(3))
                }
            }
            let session = sessions.session(id) ?? first
            let moved = await Task.detached { sessions.mainMoved(session) }.value
            let warning = moved.map { "\nWARNING: \($0)" } ?? ""
            if let moved { await MainActor.run { self?.note(.failed, "Main moved during a session on \(session.repo)", "", moved, agent) } }
            switch state {
            case .notStarted:
                return ToolOutput(text: "No session with your text has started. Check window_controls: the app may be asking something, or the task did not go out.\(warning)", ok: false)
            case .running:
                return ToolOutput(text: "Still running after 10 minutes. Call session_wait again, or finish and say it is still running.\(warning)")
            case let .stalled(on):
                return ToolOutput(text: "The session has stopped moving on \(on). It may be waiting for a permission or an answer in the app, and you cannot give those. Call session_wait once more if it may still be working, otherwise ask_user once and stop.\(warning)")
            case let .finished(last):
                let name = session.folderName ?? ""
                let place = name.isEmpty || session.worktree.contains(name) ? "It ran in \(session.worktree), on branch \(session.branch)." : "WARNING: it ran in \(session.worktree), not in \(name), so the work did not reach the project."
                let (pull, changes) = await Task.detached { (sessions.pullRequest(session), sessions.changes(session)) }.value
                if let pull { await MainActor.run { self?.record(JournalEntry(kind: .session, did: "The session opened a pull request", why: "", result: pull.facts, link: pull.link), agent) } }
                return ToolOutput(text: "Finished. Its last message:\n\(last.prefix(1500))\n\n\(place)\nPull request: \(pull?.facts ?? "none on that branch").\n\(changes)\(warning)")
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
            guard let self, let id = args.string("session"), let command = args.string("command"), let session = sessions.session(id), session.open, !session.worktree.isEmpty else { return ToolOutput(text: "no open session with that id", ok: false) }
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
        let onItsWindow = Skills.forApp(agent.attachment?.bundleId)?.runsSessions == true
        return onItsWindow ? [wait, act, close] : [drive, wait, act, close]
    }
}
