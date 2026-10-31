import CryptoKit
import Foundation

// What is particular to the coding tool that runs sessions. Only this value and the stand-in's stream name it.
struct SessionDriver {
    let binary: String
    let terminal: String

    static let installed = SessionDriver(binary: "claude", terminal: "Terminal")

    func openArguments(resuming id: String) -> [String] { ["--resume", id] }
}

struct SessionClaim: Codable {
    let key: String
    let session: String
    let agent: String
    let at: Date
}

// A claim is an exact id and nothing else. Whether two tasks are the same work is the model's call.
enum SessionClaims {
    private static func file(_ key: String, in root: URL) -> URL {
        let name = SHA256.hash(data: Data(key.lowercased().utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("claims").appendingPathComponent("\(name).json")
    }

    static func take(_ claim: SessionClaim, in root: URL) -> SessionClaim? {
        let target = file(claim.key, in: root)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(claim) else { return nil }
        let handle = open(target.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard handle >= 0 else { return holder(claim.key, in: root) }
        _ = data.withUnsafeBytes { write(handle, $0.baseAddress, $0.count) }
        close(handle)
        return nil
    }

    static func holder(_ key: String, in root: URL) -> SessionClaim? {
        (try? Data(contentsOf: file(key, in: root))).flatMap { try? JSONDecoder().decode(SessionClaim.self, from: $0) }
    }

    static func set(_ claim: SessionClaim, in root: URL) {
        try? JSONEncoder().encode(claim).write(to: file(claim.key, in: root), options: .atomic)
    }

    static func release(_ key: String, in root: URL) {
        try? FileManager.default.removeItem(at: file(key, in: root))
    }
}

extension AgentWorker {
    func claim(_ workId: String, agent: Agent) async -> String? {
        let root = await MainActor.run { storeForBrain.root }
        let mine = SessionClaim(key: workId, session: "starting", agent: agent.name, at: Date())
        guard let held = SessionClaims.take(mine, in: root) else {
            await MainActor.run { note(.session, "Took work \(workId)", "", "", agent) }
            return nil
        }
        let session = await MainActor.run { () -> CodingSession? in
            storeForBrain.agents.first { $0.name == held.agent }.flatMap { CodingSessions(folder: AgentFolder($0, in: storeForBrain)).session(held.session) }
        }
        let delivered = session?.pullRequest != nil
        let gone = held.session == "starting" ? Date().timeIntervalSince(held.at) > 120 : session == nil || (session?.open == false && !delivered) || Date().timeIntervalSince(held.at) > 86400
        if gone {
            await MainActor.run { note(.session, "Released work \(workId), which \(held.agent) no longer holds", "", "", agent) }
            SessionClaims.release(workId, in: root)
            return await claim(workId, agent: agent)
        }
        await MainActor.run { note(.refused, "Work \(workId) is already held", "", "\(held.agent), session \(held.session)", agent) }
        let result = session?.pullRequest.map { " It is done, with this pull request: \($0)." } ?? ""
        return "Not started: work id \(workId) is held by \(held.agent), session \(held.session), since \(held.at.formatted(date: .omitted, time: .shortened)).\(result) Do not do it again. If you judge this is really different work, give it its own id."
    }

    @MainActor
    func releaseClaim(of session: CodingSession, agent: Agent, why: String) {
        guard let workId = session.workId, SessionClaims.holder(workId, in: storeForBrain.root)?.session == session.id else { return }
        // Delivered work stays held, so the same id never does it twice. The hold lapses after a day.
        if let folder = storeForBrain.agents.first(where: { $0.id == agent.id }).map({ AgentFolder($0, in: storeForBrain) }), CodingSessions(folder: folder).session(session.id)?.pullRequest != nil { return }
        SessionClaims.release(workId, in: storeForBrain.root)
        note(.session, "Released work \(workId)", why, "", agent)
    }

    // The agent's run is over by now. Nothing calls a model for this session's agent until the stream's end wakes it.
    @MainActor
    func startDriving(_ session: CodingSession, task: String, why: String, agent: Agent, mission: AgentMission, folder: AgentFolder, saidByUser: Bool = false) {
        drivingSessions.insert(session.id)
        let asked = doing[agent.id]
        if let workId = session.workId { SessionClaims.set(SessionClaim(key: workId, session: session.id, agent: agent.name, at: Date()), in: storeForBrain.root) }
        note(.session, "Started a session on \(session.repo): \(task.prefix(120))", why, "", agent)
        markUsed(SessionDriver.installed.binary, by: agent)
        let standIn = ClaudeStandIn(agent: agent, mission: mission.reaching(session.repo), folder: folder, worker: self, session: session, asked: asked)
        Task { @MainActor in
            let report = await standIn.drive(task: task, saidByUser: saidByUser)
            let sessions = CodingSessions(folder: folder)
            sessions.update(session.id) { $0.claudeSession = report.claudeSession ?? $0.claudeSession }
            let verdict = report.outcome == "accept" ? "accepted its work" : report.outcome == "refuse" ? "refused its work" : report.outcome == "waiting" ? "waiting for your decision" : "stopped: \(report.outcome)"
            note(.session, "Session on \(session.repo): \(verdict)", why, String(format: "%d turns, $%.3f. Commands allowed: %@", report.turns, report.costUSD, report.allowed.prefix(12).joined(separator: "; ")), agent, claudeUSD: report.costUSD)
            await sessionEnded(session, report: report, task: task, agent: agent, folder: folder)
        }
    }

    @MainActor
    private func sessionEnded(_ session: CodingSession, report: StandInReport, task: String, agent: Agent, folder: AgentFolder) async {
        movingSessions += 1
        defer { movingSessions -= 1 }
        drivingSessions.remove(session.id)
        Self.log.append(Entry(agent: agent.name, event: "sessionEnded", detail: "\(session.id) \(report.outcome)"))
        if stoppedByUser.remove(session.id) != nil {
            releaseClaim(of: session, agent: agent, why: "the user stopped it")
            return await planMayBeSettled()
        }
        if let words = ClaudeStandIn.takeInbox(session.id), !isOverBudget(agent), let mission = folder.mission {
            CodingSessions(folder: folder).update(session.id) { $0.open = true }
            startDriving(session, task: words, why: "The user told it", agent: agent, mission: mission, folder: folder, saidByUser: true)
            return
        }
        if report.need != nil { return await planMayBeSettled() }
        if budgetStopped.remove(session.id) != nil || report.outcome == "budget" {
            CodingSessions(folder: folder).update(session.id) { $0.step = "Stopped: its budget is spent" }
            sayBudgetSpent(agent)
            releaseClaim(of: session, agent: agent, why: "its agent's budget is spent")
            teamResults.append("\(agent.name), session \(session.id): stopped, because its budget for today is spent.")
            refresh()
            return await planMayBeSettled()
        }
        let sessions = CodingSessions(folder: folder)
        let current = sessions.session(session.id) ?? session
        stopsInARow[session.id] = report.outcome == "accept" ? 0 : (stopsInARow[session.id] ?? 0) + 1
        if stopsInARow[session.id, default: 0] > Self.stopsBeforeAsking {
            stopsInARow[session.id] = 0
            raise(AgentNeed(kind: .stuck, question: "Session \(session.id) on \(session.repo) stopped \(Self.stopsBeforeAsking + 1) times in a row, last with: \(report.outcome). It waits for you.", session: session.id), agent: agent)
            sessions.update(session.id) { $0.status = .waiting; $0.question = "It keeps stopping: \(report.outcome)" }
            refresh()
            return await planMayBeSettled()
        }
        let changes = await Task.detached { sessions.changes(current) }.value
        let next = report.outcome == "accept" ? "If this is right, accept it now yourself with session_act: add, commit, push the branch, open a draft pull request. Do not ask the session to commit." : "It stopped before it was done. Continue it with session_drive and its id, the same session on the same branch, or say plainly what could not be done."
        let text = "What you asked session \(session.id) on \(session.repo): \(task.prefix(1500))\n\nOutcome: \(report.outcome), on branch \(current.branch).\nRefused in the session: \(report.denied.prefix(5).joined(separator: "; "))\nIts last message:\n\(report.lastMessage.prefix(1500))\n\n\(changes)\n\n\(next)"
        let result = await runHandedOff(agent, task: text, trigger: "Your coding session ended")
        Self.log.append(Entry(agent: agent.name, event: "sessionAnswered", detail: "\(session.id) \(result.prefix(200))"))
        if !drivingSessions.contains(session.id), sessions.session(session.id)?.status == .stopped {
            sessions.finish(current)
            releaseClaim(of: current, agent: agent, why: "it stopped and was not continued")
        }
        closeSettledNeeds(agent, folder: folder, session: sessions.session(session.id) ?? current)
        refresh()
        teamResults.append("\(agent.name), session \(session.id): \(result.prefix(600))")
        // With no plan of Bean's waiting on it, this was the agent's own work for the user, so the agent says how it ended.
        if heldPlan == nil, !settlingPlan, let bean = storeForBrain.agents.first(where: \.isBean), !isBusy(bean.id), !result.isEmpty {
            record(JournalEntry(kind: .replied, did: result, why: ""), agent)
        }
        await planMayBeSettled()
    }

    private static let stopsBeforeAsking = 2

    func isReplying(_ id: UUID) -> Bool { replying.contains(id) }

    var sessionsInMotion: Bool { !drivingSessions.isEmpty || movingSessions > 0 }

    var sessionsStillMoving: Bool { heldPlan != nil || settlingPlan || movingSessions > 0 || !drivingSessions.isEmpty || storeForBrain.agents.contains { isBusy($0.id) } }

    @MainActor
    func planMayBeSettled() async {
        guard movingSessions <= 1, drivingSessions.isEmpty, !settlingPlan else { return }
        guard let bean = storeForBrain.agents.first(where: \.isBean) else { return }
        // A run in progress speaks for the plan when it ends, so one report goes out.
        guard let held = heldPlan, !isBusy(bean.id) else { return }
        settlingPlan = true
        heldPlan = nil
        // Not awaited here: the session whose end led here must stop counting as in motion, or the report would wait for itself.
        Task { @MainActor in
            while isBusy(bean.id) { try? await Task.sleep(for: .seconds(1)) }
            await reportHeldPlan(held, bean: bean)
            settlingPlan = false
            if heldPlan != nil, !sessionsInMotion { await planMayBeSettled() }
        }
    }

    // For the page: stop a running session on the user's word. Nothing wakes for it, and it can resume later.
    @MainActor
    func stopSession(_ agentID: UUID, session id: String) {
        guard drivingSessions.contains(id) else { return }
        stoppedByUser.insert(id)
        ClaudeStandIn.stop(id)
        if let agent = storeForBrain.agents.first(where: { $0.id == agentID }) { note(.session, "The user stopped session \(id)", "", "", agent) }
    }

    // For the page: continue a stopped session by its id, in its own folder, under Bean's limits again.
    @MainActor
    func resumeSession(_ agentID: UUID, session id: String, saying text: String = "Carry on from where you stopped.") {
        guard let agent = storeForBrain.agents.first(where: { $0.id == agentID }), !drivingSessions.contains(id) else { return }
        let folder = AgentFolder(agent, in: storeForBrain)
        guard let mission = folder.mission, let session = CodingSessions(folder: folder).session(id), FileManager.default.fileExists(atPath: session.worktree) else { return }
        startDriving(session, task: text, why: "The user asked to resume it", agent: agent, mission: mission, folder: folder)
    }

    // For the page: let the user take over a session in a terminal. A running stand-in lets go of it first, so one session has one driver.
    @MainActor
    func openInTerminal(_ agentID: UUID, session id: String) -> String? {
        guard let agent = storeForBrain.agents.first(where: { $0.id == agentID }) else { return "That agent no longer exists." }
        let folder = AgentFolder(agent, in: storeForBrain)
        guard let session = CodingSessions(folder: folder).session(id), let resumeId = session.claudeSession else { return "This session has no id to open yet." }
        guard FileManager.default.fileExists(atPath: session.worktree) else { return "Its folder \(session.worktree) is gone." }
        stopSession(agentID, session: id)
        let driver = SessionDriver.installed
        let binary = HiddenShell.run("command -v \(driver.binary)", timeout: 10).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let script = folder.url.appendingPathComponent("sessions").appendingPathComponent("open-\(id).command")
        let arguments = driver.openArguments(resuming: resumeId).map { "\"\($0)\"" }.joined(separator: " ")
        let text = "#!/bin/zsh -l\ncd \"\(session.worktree)\"\nexec \"\(binary)\" \(arguments)\n"
        guard (try? text.write(to: script, atomically: true, encoding: .utf8)) != nil else { return "Could not write the file that opens it." }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let opened = Process()
        opened.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opened.arguments = ["-a", driver.terminal, script.path]
        guard (try? opened.run()) != nil else { return "Could not open \(driver.terminal)." }
        note(.session, "Opened session \(id) in \(driver.terminal)", "", "", agent)
        return nil
    }
}

struct SessionTakeOver: Equatable {
    let folder: String
    let command: [String]
}

struct SessionChanges: Equatable {
    struct File: Equatable, Identifiable {
        var id: String { path }
        let path: String
        let status: String
        let added: Int
        let removed: Int
        let diff: String
    }
    struct PullRequest: Equatable {
        let url: String
        let state: String
        let isDraft: Bool
    }
    let files: [File]
    let diff: String
    let pullRequest: PullRequest?

    var added: Int { files.reduce(0) { $0 + $1.added } }
    var removed: Int { files.reduce(0) { $0 + $1.removed } }
}

extension CodingSessions {
    static let diffLimit = 200_000
    private static let pullRequestSeconds: TimeInterval = 30
    private static let pullRequests = NSLock()
    private static var seenPullRequests: [String: (at: Date, pull: SessionChanges.PullRequest?)] = [:]

    // The page asks every couple of seconds, and gh is slow, so its answer is kept for a while.
    private func pullRequestState(_ session: CodingSession) -> SessionChanges.PullRequest? {
        if let seen = Self.pullRequests.withLock({ Self.seenPullRequests[session.id] }), Date().timeIntervalSince(seen.at) < Self.pullRequestSeconds { return seen.pull }
        var pull: SessionChanges.PullRequest?
        let view = HiddenShell.run("gh pr view --json url,state,isDraft", in: session.worktree, timeout: 15)
        if view.exit == 0, let row = (try? JSONSerialization.jsonObject(with: Data(view.output.utf8))) as? [String: Any], let url = row["url"] as? String {
            pull = SessionChanges.PullRequest(url: url, state: row["state"] as? String ?? "", isDraft: row["isDraft"] as? Bool ?? false)
        }
        Self.pullRequests.withLock { Self.seenPullRequests[session.id] = (Date(), pull) }
        return pull
    }

    private static func diffs(in text: String) -> [String: String] {
        var found: [String: String] = [:]
        for part in text.components(separatedBy: "\ndiff --git ").enumerated() {
            let body = part.offset == 0 ? part.element : "diff --git " + part.element
            guard let head = body.split(separator: "\n").first, let path = head.components(separatedBy: " b/").last else { continue }
            found[path] = body
        }
        return found
    }

    func fullChanges(_ session: CodingSession) -> SessionChanges? {
        guard FileManager.default.fileExists(atPath: session.worktree) else { return nil }
        let place = URL(fileURLWithPath: session.worktree)
        let git = { (arguments: [String]) in Self.run("/usr/bin/git", arguments, in: place).output }
        _ = git(["add", "--intent-to-add", "."])
        let found = git(["merge-base", "HEAD", "origin/HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let base = found.isEmpty ? "HEAD" : found
        var counts: [String: (Int, Int)] = [:]
        for line in git(["diff", "--numstat", base]).split(separator: "\n") {
            let parts = line.split(separator: "\t").map(String.init)
            if parts.count == 3 { counts[parts[2]] = (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0) }
        }
        let whole = git(["diff", base])
        let perFile = Self.diffs(in: whole)
        let files = git(["diff", "--name-status", base]).split(separator: "\n").compactMap { line -> SessionChanges.File? in
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count >= 2, let path = parts.last else { return nil }
            return SessionChanges.File(path: path, status: String(parts[0].prefix(1)), added: counts[path]?.0 ?? 0, removed: counts[path]?.1 ?? 0, diff: String((perFile[path] ?? "").prefix(Self.diffLimit)))
        }
        return SessionChanges(files: files, diff: String(whole.prefix(Self.diffLimit)), pullRequest: pullRequestState(session))
    }
}

extension AgentWorker {
    func sessionChanges(_ agentID: UUID, session id: String) async -> SessionChanges? {
        guard let folder = await MainActor.run(body: { storeForBrain.agents.first { $0.id == agentID }.map { AgentFolder($0, in: storeForBrain) } }) else { return nil }
        return await Task.detached {
            let sessions = CodingSessions(folder: folder)
            return sessions.session(id).flatMap { sessions.fullChanges($0) }
        }.value
    }

    // The user's words reach the session itself: they outrank the stand-in's next answer, and an ended session resumes for them. Nil means they went through.
    @MainActor
    func sendToSession(_ agentID: UUID, session id: String, text: String) -> String? {
        guard let agent = storeForBrain.agents.first(where: { $0.id == agentID }) else { return "That agent no longer exists." }
        let folder = AgentFolder(agent, in: storeForBrain)
        let sessions = CodingSessions(folder: folder)
        guard let session = sessions.session(id) else { return "That session no longer exists." }
        if BeanSettings.shared.effectivePaused { return AgentStrings.local(AgentStrings.paused) }
        if isOverBudget(agent) { return "\(agent.name)'s budget for today is spent. Raise it to go on." }
        if session.status == .takenOver { return "You have this session in the terminal." }
        for need in folder.needs where need.session == id { close(need, agent: agent, answer: text) }
        if drivingSessions.contains(id) {
            ClaudeStandIn.tell(id, text)
            return nil
        }
        guard let mission = folder.mission, FileManager.default.fileExists(atPath: session.worktree) else { return "Its folder \(session.worktree) is gone." }
        sessions.update(id) { $0.open = true }
        startDriving(session, task: text, why: "The user told it", agent: agent, mission: mission, folder: folder, saidByUser: true)
        return nil
    }

    // Stops the stand-in first, so one session has one driver. The caller runs the command and calls endTakeOver when it exits.
    @MainActor
    func takeOver(_ agentID: UUID, session id: String) async -> SessionTakeOver? {
        guard let agent = storeForBrain.agents.first(where: { $0.id == agentID }) else { return nil }
        let folder = AgentFolder(agent, in: storeForBrain)
        let sessions = CodingSessions(folder: folder)
        guard sessions.session(id)?.claudeSession != nil else { return nil }
        stopSession(agentID, session: id)
        for _ in 0..<50 where drivingSessions.contains(id) || movingSessions > 0 { try? await Task.sleep(for: .milliseconds(100)) }
        guard let session = sessions.session(id), let resumeId = session.claudeSession, !drivingSessions.contains(id), FileManager.default.fileExists(atPath: session.worktree) else { return nil }
        for need in folder.needs where need.session == id { close(need, agent: agent, answer: "The user took over the session") }
        sessions.update(id) {
            $0.status = .takenOver
            $0.step = "The user has it in the terminal"
        }
        note(.session, "The user took over session \(id)", "", "", agent)
        refresh()
        let driver = SessionDriver.installed
        let binary = HiddenShell.run("command -v \(driver.binary)", timeout: 10).output.trimmingCharacters(in: .whitespacesAndNewlines)
        return SessionTakeOver(folder: session.worktree, command: [binary] + driver.openArguments(resuming: resumeId))
    }

    @MainActor
    func endTakeOver(_ agentID: UUID, session id: String) {
        guard let agent = storeForBrain.agents.first(where: { $0.id == agentID }) else { return }
        let folder = AgentFolder(agent, in: storeForBrain)
        let sessions = CodingSessions(folder: folder)
        guard let session = sessions.session(id), session.status == .takenOver else { return }
        Task { @MainActor in
            let seen = await Task.detached { (sessions.currentBranch(of: session), sessions.pullRequestLink(of: session)) }.value
            sessions.update(id) {
                $0.status = .handedBack
                $0.step = "Handed back"
                $0.branch = seen.0 ?? $0.branch
                $0.pullRequest = seen.1 ?? $0.pullRequest
            }
            SessionEventLog(sessions: sessions, session: id, worker: self).addSoon(.ended, "Handed back")
            note(.session, "The user handed session \(id) back", "", seen.1 ?? "", agent)
            refresh()
        }
    }

    // Plan usage counts too: an agent's budget covers what its sessions cost as well as its own thinking.
    func spent(by agent: Agent) -> Double {
        let sessions = CodingSessions(folder: AgentFolder(agent, in: storeForBrain)).all.filter { Calendar.current.isDateInToday($0.startedAt ?? .distantPast) }
        return CostLedger.spentToday(agent: agent.id.uuidString) + sessions.reduce(0) { $0 + $1.costUSD }
    }

    @MainActor
    func budgetLeft(for agent: Agent) -> Double {
        max(0, (AgentFolder(agent, in: storeForBrain).mission?.dailyBudgetUSD ?? 1) - spent(by: agent))
    }

    // Like a hard stop in a budget policy: work that is running ends now, the reason shows, and raising the budget clears it.
    @MainActor
    func stopSessionsOverBudget(_ agent: Agent) {
        guard isOverBudget(agent) else { return }
        let running = CodingSessions(folder: AgentFolder(agent, in: storeForBrain)).all.filter { drivingSessions.contains($0.id) && !budgetStopped.contains($0.id) }
        for session in running {
            budgetStopped.insert(session.id)
            ClaudeStandIn.stop(session.id)
        }
    }

    @MainActor
    func sayBudgetSpent(_ agent: Agent) {
        let folder = AgentFolder(agent, in: storeForBrain)
        guard !folder.needs.contains(where: { $0.kind == .budget }), let mission = folder.mission else { return }
        raise(AgentNeed(kind: .budget, question: String(format: AgentStrings.local("Today's budget of $%.2f is spent, so I stopped. Raise it or I resume tomorrow."), mission.dailyBudgetUSD)), agent: agent)
    }

    // Once the work is pushed, a question raised on the way to it asks about nothing.
    @MainActor
    func closeSettledNeeds(_ agent: Agent, folder: AgentFolder, session: CodingSession) {
        guard session.pullRequest != nil, !CodingSessions(folder: folder).all.contains(where: { drivingSessions.contains($0.id) }), let started = session.startedAt else { return }
        let since = folder.journal.last { $0.kind == .handoff && $0.at <= started }?.at ?? started
        let settled = folder.needs.filter { ($0.kind == .decision || $0.kind == .stuck) && $0.session == nil && $0.ability == nil && $0.permission == nil && $0.connector == nil && $0.consent == nil && $0.at >= since }
        for need in settled {
            folder.save(folder.needs.filter { $0.id != need.id })
            record(JournalEntry(kind: .replied, did: "No longer needed: \(need.question)", why: ""), agent)
        }
        if !settled.isEmpty { refresh() }
    }
}
