import Foundation

// A coding session the user started in their own app. Bean reads one record to name it, and only the file's date before a yes.
struct UserSession: Equatable {
    let id: String
    let title: String
    let folder: String
    let branch: String?
    let lastActivity: Date?
}

enum UserSessionState: Equatable {
    case active(String)
    case openButIdle
    case closed
}

// The rule is plain facts, and it can be wrong one way: a user reading the session without typing looks idle.
enum UserSessions {
    private static let environment = ProcessInfo.processInfo.environment
    static let awayAfter: TimeInterval = environment["BEAN_AWAY_SECONDS"].flatMap(TimeInterval.init) ?? 600
    private static var records: URL {
        environment["BEAN_APP_SESSIONS"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }
    private static var transcripts: URL {
        environment["BEAN_SESSION_TRANSCRIPTS"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    // Newest first by file date alone, and it stops at the first record it can name, so no other session's record is read.
    static func latest() -> UserSession? {
        let files = FileManager.default.enumerator(at: records, includingPropertiesForKeys: [.contentModificationDateKey])?.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" } ?? []
        let newest = files.sorted { date(of: $0) > date(of: $1) }
        for file in newest.prefix(5) {
            guard let row = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any] else { continue }
            guard row["isArchived"] as? Bool != true, let session = session(from: row) else { continue }
            return session
        }
        return nil
    }

    private static func session(from row: [String: Any]) -> UserSession? {
        guard let id = row["cliSessionId"] as? String, let folder = row["cwd"] as? String, FileManager.default.fileExists(atPath: folder) else { return nil }
        let title = row["title"] as? String ?? (folder as NSString).lastPathComponent
        guard OffLimits.match("\(title) \(folder)") == nil else { return nil }
        let at = (row["lastActivityAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return UserSession(id: id, title: title, folder: folder, branch: row["branch"] as? String, lastActivity: at)
    }

    private static func date(of file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    static func transcriptDate(of id: String) -> Date? {
        let folders = (try? FileManager.default.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil)) ?? []
        return folders.lazy.map { $0.appendingPathComponent("\(id).jsonl") }.first { FileManager.default.fileExists(atPath: $0.path) }.map(date(of:))
    }

    // `listed` holds the tool's row for this session alone, if it has one: it lists only sessions with a live process.
    static func state(of session: UserSession, listed: [String: Any]?, now: Date = Date()) -> UserSessionState {
        if let status = listed?["status"] as? String, status != "idle" { return .active("it is \(status)") }
        let last = [transcriptDate(of: session.id), session.lastActivity].compactMap { $0 }.max()
        if let last, now.timeIntervalSince(last) < awayAfter { return .active("it moved in the last \(Int(awayAfter / 60)) minutes") }
        return listed == nil ? .closed : .openButIdle
    }

    static func listedRow(of id: String) -> [String: Any]? {
        let driver = SessionDriver.installed
        let binary = HiddenShell.run("command -v \(driver.binary)", timeout: 10).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = CodingSessions.run("/bin/zsh", ["-lc", "exec \"$0\" \"$@\"", binary] + driver.liveSessionsArguments, in: FileManager.default.homeDirectoryForCurrentUser, timeout: 20)
        let rows = (try? JSONSerialization.jsonObject(with: Data(result.output.utf8))) as? [[String: Any]] ?? []
        return rows.first { $0["sessionId"] as? String == id }
    }

    static func repo(in folder: String) -> String? {
        let origin = CodingSessions.run("/usr/bin/git", ["remote", "get-url", "origin"], in: URL(fileURLWithPath: folder)).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = origin.replacingOccurrences(of: ".git", with: "").split(whereSeparator: { "/:".contains($0) }).suffix(2)
        return parts.count == 2 ? parts.joined(separator: "/") : nil
    }
}

struct SessionConsents: Codable {
    var sessions: [String] = []
    var folders: [String] = []
    var never: [String] = []

    static func file(in root: URL) -> URL { root.appendingPathComponent("session-consents.json") }
    static func load(in root: URL) -> SessionConsents { (try? Data(contentsOf: file(in: root))).flatMap { try? JSONDecoder().decode(SessionConsents.self, from: $0) } ?? SessionConsents() }
    func save(in root: URL) { try? JSONEncoder().encode(self).write(to: Self.file(in: root), options: .atomic) }
    func allows(_ session: UserSession) -> Bool { sessions.contains(session.id) || folders.contains(session.folder) }
}

struct UserSessionOffer: Equatable {
    let session: UserSession
    let words: String
}

extension AgentWorker {
    private static let keeperRole = "Carries on your coding sessions while you are away from them, up to a draft pull request or a real question."

    // Asks nothing of any model. The moment path decides when, and shows these fixed words.
    func userSessionOffer() async -> UserSessionOffer? {
        guard let session = await Task.detached(operation: { UserSessions.latest() }).value else { return nil }
        guard !SessionConsents.load(in: storeForBrain.root).never.contains(session.id) else { return nil }
        let row = await Task.detached { UserSessions.listedRow(of: session.id) }.value
        if case .active = UserSessions.state(of: session, listed: row) { return nil }
        return UserSessionOffer(session: session, words: "I'll take over your session “\(session.title.prefix(60))” while you're away from it?")
    }

    func declineUserSession(_ session: UserSession, forGood: Bool) {
        guard forGood else { return }
        var consents = SessionConsents.load(in: storeForBrain.root)
        consents.never.append(session.id)
        consents.save(in: storeForBrain.root)
    }

    // The yes covers this session, or its folder. Nil means it started, otherwise a sentence to show.
    func takeOverUserSession(_ session: UserSession, wholeFolder: Bool = false) async -> String? {
        var consents = SessionConsents.load(in: storeForBrain.root)
        if wholeFolder { consents.folders.append(session.folder) } else { consents.sessions.append(session.id) }
        consents.save(in: storeForBrain.root)
        if BeanSettings.shared.effectivePaused { return AgentStrings.local(AgentStrings.paused) }
        let row = await Task.detached { UserSessions.listedRow(of: session.id) }.value
        let state = UserSessions.state(of: session, listed: row)
        if case let .active(why) = state { return "You look active in that session: \(why). I left it alone." }
        guard let repo = await Task.detached(operation: { UserSessions.repo(in: session.folder) }).value else { return "That session's folder is not a repo with a remote, so there would be no pull request to give you." }
        guard OffLimits.match(repo) == nil else { return "That repo is off limits." }
        let agent = sessionKeeper()
        if isOverBudget(agent) { return "\(agent.name)'s budget for today is spent. Raise it to go on." }
        let folder = AgentFolder(agent, in: storeForBrain)
        guard let mission = folder.mission else { return "Could not set up the agent for this." }
        let workId = "session-\(session.id)"
        if let held = await claim(workId, agent: agent) { return held }
        let sessions = CodingSessions(folder: folder)
        var record = CodingSession(id: String(UUID().uuidString.prefix(8)).lowercased(), repo: repo, branch: session.branch ?? "", worktree: session.folder)
        record.claudeSession = session.id
        record.userOwned = true
        record.forkOnResume = state == .openButIdle
        record.workId = workId
        record.title = session.title
        record.startedAt = Date()
        let task = "The user stepped away and asked you to carry on. Carry on the work of this session up to the point it can be reviewed. If this folder is on the main branch, make your own branch first. Leave your changes uncommitted and say what you did. If only the user can decide something, ask with your question tool."
        record.task = task
        sessions.save(record)
        SessionClaims.set(SessionClaim(key: workId, session: record.id, agent: agent.name, at: Date()), in: storeForBrain.root)
        startDriving(record, task: task, why: "The user said yes to \(session.title)", agent: agent, mission: mission.reaching(repo), folder: folder)
        return nil
    }

    // Only for the user's click: it brings the app forward. Nil means it opened, otherwise a sentence to show.
    func seeInClaude(_ agentID: UUID, session id: String) async -> String? {
        guard let agent = storeForBrain.agents.first(where: { $0.id == agentID }) else { return "That agent no longer exists." }
        let sessions = CodingSessions(folder: AgentFolder(agent, in: storeForBrain))
        guard let session = sessions.session(id), session.userOwned == true, let resumeId = session.claudeSession else { return "Only a session of yours that an agent took over opens there." }
        if drivingSessions.contains(id) { return "It is still running. It can open there once it has stopped." }
        let driver = SessionDriver.installed
        let folder = FileManager.default.fileExists(atPath: session.worktree) ? URL(fileURLWithPath: session.worktree) : FileManager.default.homeDirectoryForCurrentUser
        let result = await Task.detached { () -> (exit: Int32, output: String) in
            let binary = HiddenShell.run("command -v \(driver.binary)", timeout: 10).output.trimmingCharacters(in: .whitespacesAndNewlines)
            return CodingSessions.run("/bin/zsh", ["-lc", "exec \"$0\" \"$@\"", binary] + driver.showInAppArguments(resumeId), in: folder, timeout: 30)
        }.value
        guard result.exit == 0 else { return result.output.isEmpty ? "It could not open there." : String(result.output.prefix(200)) }
        note(.session, "Opened session \(id) in the app, as the user asked", "", "", agent)
        return nil
    }

    private func sessionKeeper() -> Agent {
        if let found = storeForBrain.agents.first(where: { $0.role == Self.keeperRole }) { return found }
        let agent = Agent(id: UUID(), name: "Relay", role: Self.keeperRole, look: .init(hue: Agent.Look.nextHue(taken: storeForBrain.agents.filter { !$0.isBean }.map(\.look.hue)), accessory: "none"), attachment: nil, createdAt: Date())
        let folder = AgentFolder(agent, in: storeForBrain)
        folder.create(agent: agent, bornFrom: .person("Take over my session while I am away from it."))
        folder.save(AgentMission(mission: Self.keeperRole))
        storeForBrain.save(agent)
        return agent
    }
}
