import Foundation

// A coding session the user started in their own app. Bean reads one record to name it, and only the file's date before a yes.
enum ReopenPlace: String, Codable { case app, terminal }

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

    private static func listedRows() -> [[String: Any]] {
        let driver = SessionDriver.installed
        let binary = HiddenShell.run("command -v \(driver.binary)", timeout: 10).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = CodingSessions.run("/bin/zsh", ["-lc", "exec \"$0\" \"$@\"", binary] + driver.liveSessionsArguments, in: FileManager.default.homeDirectoryForCurrentUser, timeout: 20)
        return (try? JSONSerialization.jsonObject(with: Data(result.output.utf8))) as? [[String: Any]] ?? []
    }

    static func listedRow(of id: String) -> [String: Any]? {
        listedRows().first { $0["sessionId"] as? String == id }
    }

    // Read after the yes. The transcript's first entry point says where the user had the session, and both are offered if it does not say.
    static func reopenPlaces(of id: String, driver: SessionDriver = .installed) -> [ReopenPlace] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil)) ?? []
        guard let file = folders.lazy.map({ $0.appendingPathComponent("\(id).jsonl") }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let handle = try? FileHandle(forReadingFrom: file), let data = try? handle.read(upToCount: 400_000) else { return [.app, .terminal] }
        try? handle.close()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let point = entry["entrypoint"] as? String else { continue }
            if driver.appEntrypoints.contains(point) { return [.app] }
            if driver.terminalEntrypoints.contains(point) { return [.terminal] }
            return [.app, .terminal]
        }
        return [.app, .terminal]
    }

    // The live session running under this app's process, whichever app it is. Only the newest one is named.
    static func live(underApp pid: Int32) -> UserSession? {
        let table = CodingSessions.run("/bin/ps", ["-axo", "pid=,ppid="], in: FileManager.default.homeDirectoryForCurrentUser).output
        var parents: [Int32: Int32] = [:]
        for line in table.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
            if parts.count == 2 { parents[parts[0]] = parts[1] }
        }
        func runs(under app: Int32, _ start: Int32) -> Bool {
            var current = start
            for _ in 0..<32 {
                if current == app { return true }
                guard let next = parents[current], next > 1 else { return false }
                current = next
            }
            return false
        }
        let found = listedRows().filter { ($0["pid"] as? Int).map { runs(under: pid, Int32($0)) } == true }.compactMap { row -> UserSession? in
            guard let id = row["sessionId"] as? String, let folder = row["cwd"] as? String, FileManager.default.fileExists(atPath: folder) else { return nil }
            let title = row["name"] as? String ?? (folder as NSString).lastPathComponent
            return OffLimits.match("\(title) \(folder)") == nil ? UserSession(id: id, title: title, folder: folder, branch: nil, lastActivity: nil) : nil
        }
        return found.max { (transcriptDate(of: $0.id) ?? .distantPast) < (transcriptDate(of: $1.id) ?? .distantPast) }
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

enum UserSessionLook: Equatable {
    case offer(UserSessionOffer)
    case active, held, never, nothing
}

struct UserSessionOffer: Equatable {
    let session: UserSession
    let words: String
}

extension AgentWorker {

    // Asks nothing of any model. The moment path decides when, and shows the offer's fixed words.
    // `pid` looks for the session running under that app. `alsoClosed` falls back to the newest session the app has a record of.
    func userSessionLook(inApp pid: Int32? = nil, alsoClosed: Bool = true) async -> UserSessionLook {
        let found = await Task.detached { () -> UserSession? in
            if let pid, let live = UserSessions.live(underApp: pid) { return live }
            return alsoClosed ? UserSessions.latest() : nil
        }.value
        guard let session = found else { return .nothing }
        if SessionConsents.load(in: storeForBrain.root).never.contains(session.id) { return .never }
        if heldUserSession(session) { return .held }
        let row = await Task.detached { UserSessions.listedRow(of: session.id) }.value
        if case .active = UserSessions.state(of: session, listed: row) { return .active }
        return .offer(UserSessionOffer(session: session, words: "I'll take over your session “\(session.title.prefix(60))” while you're away from it?"))
    }

    func userSessionOffer(inApp pid: Int32? = nil, alsoClosed: Bool = true) async -> UserSessionOffer? {
        if case let .offer(offer) = await userSessionLook(inApp: pid, alsoClosed: alsoClosed) { return offer }
        return nil
    }

    private func heldUserSession(_ session: UserSession) -> Bool {
        SessionClaims.holder("session-\(session.id)", in: storeForBrain.root) != nil
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
        if BeanSettings.shared.effectivePaused { return AgentStrings.paused }
        let row = await Task.detached { UserSessions.listedRow(of: session.id) }.value
        let state = UserSessions.state(of: session, listed: row)
        if case let .active(why) = state { return "You look active in that session: \(why). I left it alone." }
        guard let repo = await Task.detached(operation: { UserSessions.repo(in: session.folder) }).value else { return "That session's folder is not a repo with a remote, so there would be no pull request to give you." }
        guard OffLimits.match(repo) == nil else { return "That repo is off limits." }
        guard let agent = await agentFor("Carry on the person's own coding session \"\(session.title)\" in \(repo) while they are away from it, up to a draft pull request or a real question. They said yes.", bornFrom: { .person($0) })?.agent else { return "I could not find or make an agent for this." }
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
        record.reopensIn = await Task.detached { UserSessions.reopenPlaces(of: session.id) }.value
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

    // Only for the user's click: it brings that place forward. Nil means it opened, otherwise a sentence to show.
    func reopenSession(_ agentID: UUID, session id: String, in place: ReopenPlace) async -> String? {
        guard place == .app else { return openInTerminal(agentID, session: id) }
        guard let agent = storeForBrain.agents.first(where: { $0.id == agentID }) else { return "That agent no longer exists." }
        let sessions = CodingSessions(folder: AgentFolder(agent, in: storeForBrain))
        guard let session = sessions.session(id), let resumeId = session.claudeSession else { return "This session has no id to open yet." }
        if drivingSessions.contains(id) { return "It is still running. It can reopen once it has stopped." }
        let driver = SessionDriver.installed
        let folder = FileManager.default.fileExists(atPath: session.worktree) ? URL(fileURLWithPath: session.worktree) : FileManager.default.homeDirectoryForCurrentUser
        let result = await Task.detached { () -> (exit: Int32, output: String) in
            let binary = HiddenShell.run("command -v \(driver.binary)", timeout: 10).output.trimmingCharacters(in: .whitespacesAndNewlines)
            return CodingSessions.run("/bin/zsh", ["-lc", "exec \"$0\" \"$@\"", binary] + driver.showInAppArguments(resumeId), in: folder, timeout: 30)
        }.value
        guard result.exit == 0 else { return result.output.isEmpty ? "It could not reopen there." : String(result.output.prefix(200)) }
        note(.session, "Reopened session \(id), as the user asked", "", "", agent)
        return nil
    }
}
