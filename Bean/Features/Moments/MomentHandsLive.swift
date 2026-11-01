import AppKit

struct MomentLine: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let undoAgent: UUID?
}

// The acting side: an agent on a window, a line in the notch, a question through Bean. Every action the placed agent then takes goes through its Perimeter.
@MainActor
final class MomentHandsLive: MomentHands {
    private unowned let worker: AgentWorker
    private var store: AgentStore { worker.storeForBrain }
    private var bean: Agent? { store.agents.first(where: \.isBean) }
    static let seen = MemoryFile(url: JSONLog.directory.appendingPathComponent("seen.md"), limit: 1500)
    static var seenLately: String { ((try? seen.entries()) ?? []).suffix(5).joined(separator: "\n") }

    init(worker: AgentWorker) {
        self.worker = worker
        if let bean { Self.dropOffers(bean, in: store) }
    }

    private static func dropOffers(_ bean: Agent, in store: AgentStore) {
        let folder = AgentFolder(bean, in: store)
        folder.save(folder.needs.filter { $0.moment == nil })
    }

    func show(_ offer: MomentOffer) {
        guard let bean else { return }
        let place = offer.moment.title ?? offer.moment.app ?? ""
        let question = offer.kind == .keepDoing ? String(format: "Keep doing this on %@?", String(place.prefix(40))) : String(format: "On %@: %@", place, offer.result)
        worker.raise(AgentNeed(kind: .decision, question: question, options: offer.answers.map { $0 }, recommended: offer.answers.first.map { $0 },
                               detail: offer.because, moment: offer.id), agent: bean, why: offer.because)
    }

    func withdraw(_ offer: MomentOffer) {
        guard let bean else { return }
        let folder = AgentFolder(bean, in: store)
        folder.save(folder.needs.filter { $0.moment != offer.id })
        worker.refresh()
    }

    func say(_ line: String, undoAgent: UUID?) {
        worker.momentLine = MomentLine(text: line, undoAgent: undoAgent)
        guard let bean else { return }
        worker.record(JournalEntry(kind: .notice, did: line, why: ""), bean)
        store.activity[bean.id] = AgentActivity(mood: .idle, bubble: line)
    }

    func note(_ text: String) {
        if let bean { worker.record(JournalEntry(kind: .action, did: text, why: ""), bean) }
    }

    func remember(_ text: String) {
        Self.seen.append(text, dated: true)
    }

    func holdsWindow(_ number: Int) -> Bool {
        store.agents.contains { $0.attachment?.windowNumber == number }
    }

    func sessionLook(window number: Int?, alsoClosed: Bool) async -> UserSessionLook {
        let pid = WindowChannels.open().first { $0.number == number }?.pid
        guard pid != nil || alsoClosed else { return .nothing }
        return await worker.userSessionLook(inApp: pid, alsoClosed: alsoClosed)
    }

    func sessionAllowed(_ session: UserSession) -> Bool { SessionConsents.load(in: store.root).allows(session) }
    func takeOver(_ session: UserSession) async -> String? { await worker.takeOverUserSession(session) }
    func decline(_ session: UserSession, forGood: Bool) { worker.declineUserSession(session, forGood: forGood) }

    func place(moment: Moment, result: String, needs: MomentAnswer.Needs, agent: UUID?) async -> UUID? {
        let open = WindowChannels.open().filter { OffLimits.match("\($0.app) \($0.bundleId) \($0.title ?? "")") == nil }
        guard let window = open.first(where: { $0.number == moment.window }) ?? open.first(where: { $0.bundleId == moment.bundleId && $0.title == moment.title }), !holdsWindow(window.number) else {
            note(String(format: "%@ is gone, so I did nothing.", moment.title ?? moment.app ?? ""))
            return nil
        }
        if let id = agent, let waiting = store.agents.first(where: { $0.id == id && $0.attachment == nil }) {
            AgentFolder(waiting, in: store).updateCard { $0.readOnly = needs != .actInWindow }
            worker.place(waiting, on: window)
            await landed(id, on: window)
            return id
        }
        guard let made = try? await worker.createAgent(from: result, bornFrom: .moment(moment.because), on: window, stayQuiet: "Nothing here moves this forward: " + result,
                                                       leaveWhen: "the window closes, or \(Int(MomentRules.starting.quietDaysToLeave)) quiet days") else {
            note(String(format: "I could not make an agent for %@.", moment.title ?? moment.app ?? ""))
            return nil
        }
        AgentFolder(made, in: store).updateCard { $0.readOnly = needs != .actInWindow }
        await landed(made.id, on: window)
        return made.id
    }

    // The creature flies to the window first, and a run started before it lands has no window to read.
    private func landed(_ id: UUID, on window: OpenWindow) async {
        for _ in 0..<40 where store.agents.first(where: { $0.id == id })?.attachment?.windowNumber != window.number {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if store.agents.first(where: { $0.id == id })?.attachment?.windowNumber != window.number {
            store.attach(id, to: WindowChannels.attachment(for: window))
        }
    }

    func agentName(_ id: UUID) -> String? { store.agents.first { $0.id == id }?.name }

    func firstWork(agent: UUID, result: String) async -> Bool {
        guard let current = store.agents.first(where: { $0.id == agent }) else { return false }
        let began = Date()
        let worked = await worker.handOff(current, task: result, trigger: "You were placed on this window because of what the person was doing. Read your window first. Your job is")
        guard store.agents.contains(where: { $0.id == agent }) else { return false }
        let checked = worked.ok ? await worker.checkedResult(current, task: result, claim: worked.text, since: began, windowBefore: nil) { _ in worked.text } : worked.text
        worker.record(JournalEntry(kind: .replied, did: checked, why: ""), current)
        return worked.ok
    }

    func delegate(moment: Moment, result: String) async {
        _ = await worker.inform(source: moment.title ?? moment.app ?? "a connected service", text: "\(moment.card)\nProposed: \(result)")
    }

    func undo(agent id: UUID) {
        guard let current = store.agents.first(where: { $0.id == id }) else { return }
        worker.stopWork(id)
        worker.forget(current)
        worker.momentLine = nil
    }

    func leave(window number: Int) {
        for agent in store.agents where agent.attachment?.windowNumber == number {
            let folder = AgentFolder(agent, in: store)
            guard folder.card?.bornFrom.kind == "moment" else { continue }
            store.attach(agent.id, to: nil)
            worker.record(JournalEntry(kind: .action, did: String(format: "Its window closed, so %@ left it.", agent.name), why: ""), agent)
        }
    }

    func wantsToLeave(rules: MomentRules, now: Date) {
        for agent in store.agents where !agent.isBean {
            let folder = AgentFolder(agent, in: store)
            guard folder.card?.bornFrom.kind == "moment", !worker.isBusy(agent.id) else { continue }
            let last = folder.journal.last?.at ?? agent.createdAt
            if now.timeIntervalSince(last) >= rules.quietDaysToLeave * 86400 { worker.forget(agent) }
        }
    }

    func record(_ entry: GateEntry) {
        EventGate.log.append(entry)
        worker.noteGate(entry)
    }
}

extension AgentWorker {
    func answerMoment(_ need: AgentNeed, agent: Agent, text: String) {
        close(need, agent: agent, answer: text)
        record(JournalEntry(kind: .said, did: text, why: ""), agent)
        guard let id = need.moment else { return }
        Task { @MainActor in await moments?.answered(id, text) }
    }
}
