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
        let gone = held.session == "starting" ? Date().timeIntervalSince(held.at) > 120 : session == nil || session?.open == false
        if gone {
            await MainActor.run { note(.session, "Released work \(workId), which \(held.agent) no longer holds", "", "", agent) }
            SessionClaims.release(workId, in: root)
            return await claim(workId, agent: agent)
        }
        await MainActor.run { note(.refused, "Work \(workId) is already held", "", "\(held.agent), session \(held.session)", agent) }
        let result = session?.pullRequest.map { " Its pull request: \($0)." } ?? ""
        return "Not started: work id \(workId) is held by \(held.agent), session \(held.session), since \(held.at.formatted(date: .omitted, time: .shortened)).\(result) Do not do it again. If you judge this is really different work, give it its own id."
    }

    @MainActor
    func releaseClaim(of session: CodingSession, agent: Agent, why: String) {
        guard let workId = session.workId, SessionClaims.holder(workId, in: storeForBrain.root)?.session == session.id else { return }
        SessionClaims.release(workId, in: storeForBrain.root)
        note(.session, "Released work \(workId)", why, "", agent)
    }

    // The agent's run is over by now. Nothing calls a model for this session's agent until the stream's end wakes it.
    @MainActor
    func startDriving(_ session: CodingSession, task: String, why: String, agent: Agent, mission: AgentMission, folder: AgentFolder) {
        drivingSessions.insert(session.id)
        let asked = doing[agent.id]
        if let workId = session.workId { SessionClaims.set(SessionClaim(key: workId, session: session.id, agent: agent.name, at: Date()), in: storeForBrain.root) }
        note(.session, "Started a session on \(session.repo): \(task.prefix(120))", why, "", agent)
        markUsed(SessionDriver.installed.binary, by: agent)
        let standIn = ClaudeStandIn(agent: agent, mission: mission.reaching(session.repo), folder: folder, worker: self, session: session, asked: asked)
        Task { @MainActor in
            let report = await standIn.drive(task: task)
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
        if report.need != nil { return await planMayBeSettled() }
        let sessions = CodingSessions(folder: folder)
        let current = sessions.session(session.id) ?? session
        let changes = await Task.detached { sessions.changes(current) }.value
        let next = report.outcome == "accept" ? "If this is right, accept it now yourself with session_act: add, commit, push the branch, open a draft pull request. Do not ask the session to commit." : "It stopped before it was done. Continue it with session_drive and its id, the same session on the same branch, or say plainly what could not be done."
        let text = "What you asked session \(session.id) on \(session.repo): \(task.prefix(1500))\n\nOutcome: \(report.outcome), on branch \(current.branch).\nRefused in the session: \(report.denied.prefix(5).joined(separator: "; "))\nIts last message:\n\(report.lastMessage.prefix(1500))\n\n\(changes)\n\n\(next)"
        let result = await runHandedOff(agent, task: text, trigger: "Your coding session ended")
        Self.log.append(Entry(agent: agent.name, event: "sessionAnswered", detail: "\(session.id) \(result.prefix(200))"))
        if !drivingSessions.contains(session.id), sessions.session(session.id)?.status == .stopped {
            sessions.finish(current)
            releaseClaim(of: current, agent: agent, why: "it stopped and was not continued")
        }
        teamResults.append("\(agent.name), session \(session.id): \(result.prefix(600))")
        heardFromSession = "\(agent.name), session \(session.id): \(result.prefix(600))"
        await planMayBeSettled()
    }

    var sessionsStillMoving: Bool { heldPlan != nil || settlingPlan || movingSessions > 0 || !drivingSessions.isEmpty || storeForBrain.agents.contains { isBusy($0.id) } }

    @MainActor
    func planMayBeSettled() async {
        guard movingSessions == 1, drivingSessions.isEmpty, !settlingPlan else { return }
        guard let bean = storeForBrain.agents.first(where: \.isBean) else { return }
        guard let held = heldPlan else {
            if !isBusy(bean.id), let heard = heardFromSession { wake(heard) }
            heardFromSession = nil
            return
        }
        settlingPlan = true
        defer { settlingPlan = false }
        while isBusy(bean.id) { try? await Task.sleep(for: .seconds(1)) }
        heldPlan = nil
        heardFromSession = nil
        await reportHeldPlan(held, bean: bean)
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
