import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchDesk {
    private let store: AgentStore
    private let worker: AgentWorker
    private let notch: NotchController
    private let agents: Agents
    private let inbox = NotchInbox.shared
    private var subscriptions: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    private var cards: [NotchCard] = []
    private var folded: Set<UUID> = []
    private var reasserted: Set<UUID> = []
    private var hidden: Set<UUID> = []
    private var holdUntil = Date.distantPast
    private var pacer = NotchPacer()
    private var focusedSince = Date()
    private var switchedAt = Date.distantPast
    private var lines: [NotchReport] = []
    private var lastReceived = Date.distantPast
    private var lastReport: NotchReport?
    private var journalSeen: [UUID: Set<UUID>] = [:]
    private var doneSinceReply: [UUID: [JournalEntry]] = [:]
    private var failedSinceReply: Set<UUID> = []
    private var awaySince: Date?
    private var returned: Date?
    private let started = Date()
    private var readyTimer: DispatchWorkItem?

    init(store: AgentStore, worker: AgentWorker, notch: NotchController, agents: Agents, connect: @escaping (String) -> Void) {
        self.store = store
        self.worker = worker
        self.notch = notch
        self.agents = agents
        self.connect = connect
        notch.onHover = { [weak self] in self?.openFromRest() }
        notch.onPlus = { [weak self] in self?.startCompose() }
        notch.onOpenPage = { [weak agents] id in agents?.open(id) }
        notch.onRow = { [weak self] id in self?.openRow(id) }
        notch.onSubmit = { [weak self] sentence in self?.make(sentence) }
        notch.onAnswer = { [weak self] card, text in self?.answer(card, text) }
        notch.onHide = { [weak self] card in self?.hide(card) }
        notch.onConnect = { [weak self] card, connector in self?.connectCard(card, connector) }
        notch.onExpandLine = { [weak self] report in self?.expand(report) }
        notch.rosterProvider = { [weak agents] in agents?.roster ?? [] }
        inbox.onReport = { [weak self] report in self?.receive(report) }

        for agent in store.agents { journalSeen[agent.id] = Set(worker.journal[agent.id]?.map(\.id) ?? AgentFolder(agent, in: store).journal.map(\.id)) }

        worker.$needs.combineLatest(inbox.$offers, store.$agents)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] needs, offers, agents in self?.rebuild(needs, offers, agents) }
            .store(in: &subscriptions)
        store.$agents.combineLatest(store.$activity)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] agents, activity in self?.showPips(agents, activity) }
            .store(in: &subscriptions)
        worker.$journal
            .receive(on: DispatchQueue.main)
            .sink { [weak self] journal in self?.readJournal(journal) }
            .store(in: &subscriptions)

        worker.$liveSteps
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.notch.model.surface == .list { self.notch.showList() }
                self.pace()
            }
            .store(in: &subscriptions)

        worker.$momentLine
            .receive(on: DispatchQueue.main)
            .sink { [weak self] line in self?.say(line) }
            .store(in: &subscriptions)

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.appSwitched(to: bundle) }
        })
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.awaySince = self?.awaySince ?? Date() }
        })
        observers.append(center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameBack() }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat() }
        }
        readFakes()
    }

    private let connect: (String) -> Void
    var opensFromRest: (() -> Bool)?

    private func rebuild(_ needs: [UUID: [AgentNeed]], _ offers: [NotchOffer], _ agents: [Agent]) {
        var next: [NotchCard] = offers.map { offer in
            let agent = offer.agent.flatMap { id in agents.first { $0.id == id } }
            return NotchCard(id: offer.id, source: .offer(offer.id), name: agent?.name ?? "Bean", look: agent?.look ?? .pearl, title: offer.result, saw: offer.saw,
                             choices: offer.answers.map { NotchCard.Choice(title: $0.title, answer: $0.title) }, urgent: offer.urgency == .now)
        }
        for agent in agents {
            let folder = AgentFolder(agent, in: store)
            for need in needs[agent.id] ?? [] where !self.agents.shows(agent.id) {
                next.append(Self.card(need, agent: agent, perimeter: Perimeter(folder: folder, window: agent.attachment)))
            }
        }
        next.sort { $0.urgent && !$1.urgent }
        let ids = Set(next.map(\.id))
        folded.formIntersection(ids)
        reasserted.formIntersection(ids)
        hidden.formIntersection(ids)
        cards = next
        pace()
    }

    // Bean never sends words to people unless this agent's Perimeter allows it, so a choice that would is not offered. A full draft is not a label: the person sends that one.
    private static func offerable(_ option: String, _ perimeter: Perimeter) -> Bool {
        guard option.count <= 40, AppGuard.risk(in: option) == .send else { return true }
        return perimeter.refusal(.press(AppControl(role: "AXButton", label: option, secure: false))) == nil
    }

    private static func card(_ need: AgentNeed, agent: Agent, perimeter: Perimeter) -> NotchCard {
        var isCall = false
        if #available(macOS 14.2, *) { isCall = need.consent == CallSense.id }
        let preferred = need.recommended ?? need.options.first
        let ordered = (need.options.filter { $0 == preferred } + need.options.filter { $0 != preferred }).filter { offerable($0, perimeter) }
        var choices = ordered.map { NotchCard.Choice(title: $0, answer: $0, detail: need.consequences?[$0]) }
        if isCall, need.options.count >= 2 {
            choices = [.init(title: "Yes", answer: need.options[0]), .init(title: "Not now", answer: need.options[1])]
        }
        let saw = need.detail ?? need.senseWhy
        return NotchCard(id: need.id, source: .need(agent: agent.id, need: need.id), name: agent.name, look: agent.look,
                         title: need.question, saw: saw, choices: choices, urgent: isCall,
                         replies: need.options.isEmpty && need.connector == nil && need.consent == nil,
                         offersOther: (need.consent == nil && need.permission == nil && need.moment == nil && ordered.count >= 3),
                         settings: SettingsPane(need)?.url, connector: need.connector)
    }

    private func showPips(_ agents: [Agent], _ activity: [UUID: AgentActivity]) {
        let placed = agents.filter { $0.attachment != nil && !$0.isBean }
        notch.setPips(placed.map { agent in
            let mood = activity[agent.id]?.mood ?? .idle
            return NotchPip(id: agent.id, look: agent.look, working: mood == .working || mood == .reading)
        })
        if case .list = notch.model.surface {
            notch.model.roster = self.agents.roster
            notch.refit()
        }
    }

    private func beat() {
        inbox.expire(at: Date())
        readFakes()
        let idle = NotchPacer.sinceInput
        if idle >= NotchPacer.away, awaySince == nil, idle < Date().timeIntervalSince(started) { awaySince = Date().addingTimeInterval(-idle) }
        if idle < 3, awaySince != nil { cameBack() }
        pace()
    }

    private func appSwitched(to bundle: String?) {
        pacer.focusedBefore = Date().timeIntervalSince(focusedSince)
        focusedSince = Date()
        switchedAt = Date()
        if let bundle, let card = cards.first(where: { folded.contains($0.id) && attachedBundle($0) == bundle }) { reassert(card.id) }
        pace()
    }

    private func attachedBundle(_ card: NotchCard) -> String? {
        guard case .need(let id, _) = card.source else { return nil }
        return store.agents.first { $0.id == id }?.attachments.first { $0.bundleId == NSWorkspace.shared.frontmostApplication?.bundleIdentifier }?.bundleId ?? store.agents.first { $0.id == id }?.attachment?.bundleId
    }

    private func reassert(_ id: UUID) {
        guard reasserted.insert(id).inserted else { return }
        folded.remove(id)
    }

    private func pace() {
        let surface = notch.model.surface
        notch.setWaiting(cards.count, attention: !cards.isEmpty && !isShowingCard(surface))
        guard notch.model.lifted == nil else { return }
        switch surface {
        case .card(let card, _):
            guard let current = cards.first(where: { $0.id == card.id }) else {
                notch.show(.rest)
                return pace()
            }
            let more = cards.count - 1
            if surface != .card(current, more: more) { notch.show(.card(current, more: more)) }
            if !current.urgent, let urgent = cards.first(where: { $0.urgent && !folded.contains($0.id) }) { return open(urgent) }
            if notch.mouseInside || notch.hasKeys { holdUntil = Date().addingTimeInterval(NotchPacer.hold / 2) }
            if Date() > holdUntil {
                folded.insert(current.id)
                notch.show(.rest)
            }
        case .line(let shown):
            if let urgent = cards.first(where: { $0.urgent && !folded.contains($0.id) }) {
                open(urgent)
            } else if shown.tone == .working, let next = lines.first {
                lines.removeFirst()
                showLine(next)
            }
        case .rest:
            if let urgent = cards.first(where: { $0.urgent && !folded.contains($0.id) }) { return open(urgent) }
            if let since = returned {
                returned = nil
                if let line = returnLine(since: since) { return showLine(line) }
            }
            if let next = cards.first(where: { !folded.contains($0.id) }) {
                pacer.sinceSwitch = Date().timeIntervalSince(switchedAt)
                pacer.fullScreen = Self.frontIsFullScreen
                pacer.onCall = !worker.listening.isEmpty
                if pacer.mayOpen(urgent: next.urgent) { return open(next) }
            }
            if let line = lines.first {
                lines.removeFirst()
                return showLine(line)
            }
            if let live = liveLine(alreadyOpen: false) { notch.show(.live(live)) }
        case .live:
            if let urgent = cards.first(where: { $0.urgent && !folded.contains($0.id) }) { return open(urgent) }
            if let next = cards.first(where: { !folded.contains($0.id) }) {
                pacer.sinceSwitch = Date().timeIntervalSince(switchedAt)
                pacer.fullScreen = Self.frontIsFullScreen
                pacer.onCall = !worker.listening.isEmpty
                if pacer.mayOpen(urgent: false) { return open(next) }
            }
            if let line = lines.first {
                lines.removeFirst()
                return showLine(line)
            }
            notch.show(liveLine(alreadyOpen: true).map(NotchSurface.live) ?? .rest)
        default:
            break
        }
    }

    // The same quiet rules as any line: not while typing, in full screen or on a call. It opens for a real step, and holds through the thinking between steps.
    private func liveLine(alreadyOpen: Bool) -> NotchLive? {
        guard NotchPacer.sinceKey >= NotchPacer.typing, !Self.frontIsFullScreen, worker.listening.isEmpty else { return nil }
        let working = store.agents.compactMap { agent in worker.liveSteps[agent.id].map { (agent, $0) } }.filter { !agents.shows($0.0.id) }
        // Bean waiting for an agent says less than the agent it waits for.
        let doers = working.contains { !$0.0.isBean } ? working.filter { !$0.0.isBean } : working
        guard let (agent, step) = doers.filter({ !$0.1.thinking }).max(by: { $0.1.since < $1.1.since }) ?? (alreadyOpen || doers.count < working.count ? doers.first : nil) else { return nil }
        return NotchLive(agent: agent.id, name: agent.name, look: agent.look, words: step.words, since: step.since, others: working.count - 1)
    }

    private func isShowingCard(_ surface: NotchSurface) -> Bool {
        if case .card = surface { return true }
        return false
    }

    private func open(_ card: NotchCard) {
        holdUntil = Date().addingTimeInterval(card.urgent ? 4 * NotchPacer.hold : NotchPacer.hold)
        notch.show(.card(card, more: cards.count - 1))
    }

    private func openRow(_ id: UUID) {
        if let card = cards.first(where: { $0.agent == id }) {
            folded.remove(card.id)
            hidden.remove(card.id)
            open(card)
        } else {
            agents.open(id)
        }
    }

    private func openFromRest() {
        if opensFromRest?() == true { return }
        if let card = cards.first(where: { !hidden.contains($0.id) }) {
            folded.remove(card.id)
            open(card)
        } else if notch.model.doneMark, let report = lastReport {
            notch.setDoneMark(false)
            notch.show(.report(report))
        } else {
            notch.showList()
        }
    }

    private func answer(_ card: NotchCard, _ text: String) {
        cards.removeAll { $0.id == card.id }
        switch card.source {
        case .offer(let id):
            let answer = inbox.offers.first { $0.id == id }?.answers.first { $0.title == text }
            inbox.settle(id, with: answer ?? NotchAnswer(title: text))
        case .need(let agent, let need):
            worker.answer(agent, need: need, text)
        }
        afterCard()
    }

    private func hide(_ card: NotchCard) {
        folded.insert(card.id)
        reasserted.insert(card.id)
        hidden.insert(card.id)
        if case .offer(let id) = card.source { inbox.settle(id, with: nil) }
        afterCard()
    }

    private func connectCard(_ card: NotchCard, _ connector: String) {
        connect(connector)
        hide(card)
    }

    private func afterCard() {
        notch.releaseKeys()
        if notch.mouseInside, let next = cards.first(where: { !folded.contains($0.id) }) {
            open(next)
        } else {
            notch.show(.rest)
            pace()
        }
    }

    private func startCompose() {
        notch.model.composeError = nil
        notch.model.composeQuestion = nil
        notch.openCompose()
    }

    private func make(_ sentence: String) {
        let sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else { return }
        guard ModelClient().isReady else {
            notch.model.composeError = BeanSettings.shared.effectiveProvider == .local ? "Bean needs a model first. Open Bean to pick one." : "Bean needs a key first. Open Bean to add one."
            notch.refit()
            return
        }
        let request = notch.model.composeQuestion?.answered(sentence) ?? AgentMaker.Request(sentence)
        notch.model.composeQuestion = nil
        notch.releaseKeys()
        notch.model.draft = ""
        notch.show(.making(sentence))
        agents.hatchFromNotch(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let agent):
                self.showReady(agent)
            case .failure(let question as AgentMaker.Question):
                self.notch.model.composeQuestion = question
                self.notch.openCompose()
            case .failure(let error):
                self.notch.model.draft = sentence
                self.notch.model.composeError = ModelClient.plain(error)
                self.notch.openCompose()
            }
        }
    }

    func showReady(_ agent: Agent) {
        let job = AgentFolder(agent, in: store).card?.job.goal ?? agent.role
        notch.show(.ready(RosterItem(id: agent.id, name: agent.name, look: agent.look, mood: .idle, line: job)))
        readyTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.notch.closeReady() }
        readyTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: item)
    }

    private func receive(_ report: NotchReport) {
        // The same line from two sources at launch is said once.
        if lastReport?.line == report.line, Date().timeIntervalSince(lastReceived) < 5 { return }
        lastReceived = Date()
        lastReport = report
        lines.append(report)
        pace()
    }

    private func showLine(_ report: NotchReport) {
        notch.show(.line(report))
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchPacer.line) { [weak self] in
            self?.foldLine(report)
        }
    }

    private func foldLine(_ report: NotchReport) {
        guard notch.model.surface == .line(report) else { return }
        if notch.mouseInside {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.foldLine(report) }
            return
        }
        notch.show(.rest)
        notch.setDoneMark(report.tone == .done)
        pace()
    }

    private func expand(_ report: NotchReport) {
        if report.isReturn, let card = cards.first {
            folded.remove(card.id)
            return open(card)
        }
        notch.setDoneMark(false)
        if report.items.isEmpty, report.link == nil {
            notch.showList()
        } else {
            notch.show(.report(report))
        }
    }

    private func readJournal(_ journal: [UUID: [JournalEntry]]) {
        for (id, entries) in journal {
            guard let agent = store.agents.first(where: { $0.id == id }) else { continue }
            let seen = journalSeen[id] ?? []
            let fresh = entries.filter { !seen.contains($0.id) }
            journalSeen[id] = Set(entries.map(\.id))
            doneSinceReply[id, default: []] += fresh.filter { $0.kind == .action }
            if fresh.contains(where: { [.failed, .refused, .stuck].contains($0.kind) }) { failedSinceReply.insert(id) }
            guard let reply = fresh.last(where: { $0.kind == .replied }) else { continue }
            let done = doneSinceReply.removeValue(forKey: id) ?? []
            let failed = failedSinceReply.remove(id) != nil
            guard !agents.shows(id) else { continue }
            receive(NotchReport(line: Self.firstLine(reply.did), link: (reply.link ?? done.compactMap(\.link).last ?? Self.firstLink(reply.did)).flatMap(URL.init(string:)),
                                items: done.map { item($0, of: agent) }, tone: !done.isEmpty && !failed ? .done : .plain))
        }
    }

    private func say(_ line: MomentLine?) {
        guard let line else { return }
        let undo: (() -> Void)? = line.undoAgent.map { id in { [weak self] in self?.worker.moments?.undo(agent: id) } }
        receive(NotchReport(line: line.text, items: undo == nil ? [] : [.init(text: line.text, undo: undo)], tone: undo == nil ? .plain : .working))
    }

    private func item(_ entry: JournalEntry, of agent: Agent) -> NotchReport.Item {
        let undoable = entry.undoCommand != nil || entry.undoText != nil
        return NotchReport.Item(text: entry.did, undo: undoable ? { [weak self] in self?.worker.undo(agent.id, entry: entry.id) } : nil)
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        guard line.count > 90 else { return line }
        if let end = line.range(of: ". "), line.distance(from: line.startIndex, to: end.lowerBound) > 20 { return String(line[..<end.lowerBound]) }
        return line
    }

    private static func firstLink(_ text: String) -> String? {
        text.split(whereSeparator: \.isWhitespace).first { $0.hasPrefix("https://") }.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".,)")) }
    }

    private func cameBack() {
        guard let since = awaySince else { return }
        awaySince = nil
        returned = since
        for card in cards { reassert(card.id) }
    }

    private func returnLine(since: Date) -> NotchReport? {
        var done = 0, items: [NotchReport.Item] = []
        for agent in store.agents {
            guard let summary = worker.away(agent.id, since: since) else { continue }
            done += summary.done.count + summary.decided.count
            items += summary.done.map { item($0, of: agent) }
        }
        guard done > 0 || !cards.isEmpty else { return nil }
        var parts: [String] = []
        if done > 0 { parts.append(String(format: "%d done", done)) }
        if !cards.isEmpty { parts.append(cards.count == 1 ? "1 question" : String(format: "%d questions", cards.count)) }
        return NotchReport(line: String(format: "While you were away: %@.", parts.joined(separator: ", ")), items: items, isReturn: true)
    }

    private static var frontIsFullScreen: Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { info in
            guard info[kCGWindowOwnerPID as String] as? Int32 == front, info[kCGWindowLayer as String] as? Int == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: bounds) else { return false }
            return NSScreen.screens.contains { $0.frame.size == frame.size }
        }
    }

    private static let fakeFile = ProcessInfo.processInfo.environment["BEAN_NOTCH_FAKE_FILE"].map(URL.init(fileURLWithPath:))
    private var fakesRead = 0

    private struct Fake: Decodable {
        struct Offer: Decodable {
            let result: String
            let saw: String
            let answers: [String]?
            let now: Bool?
        }
        struct Report: Decodable {
            let line: String
            let link: String?
            let items: [String]?
            let undoable: Bool?
            let working: Bool?
        }
        struct Say: Decodable {
            let agent: String
            let text: String
        }
        let say: Say?
        let offer: Offer?
        let report: Report?
    }

    private func readFakes() {
        guard let file = Self.fakeFile, let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n")
        guard lines.count > fakesRead else { return }
        for line in lines[fakesRead...] {
            guard let fake = try? JSONDecoder().decode(Fake.self, from: Data(line.utf8)) else { continue }
            if let say = fake.say, let agent = store.agents.first(where: { $0.name == say.agent }) { worker.send(agent.id, say.text) }
            if let offer = fake.offer {
                let answers = offer.answers.map { $0.map { NotchAnswer(title: $0) } } ?? [.yes, .notNow]
                inbox.offer(NotchOffer(result: offer.result, saw: offer.saw, answers: answers, urgency: offer.now == true ? .now : .atPause)) { answer in
                    print("fake offer \(offer.result): \(answer?.title ?? "ignored")")
                }
            }
            if let report = fake.report {
                inbox.report(NotchReport(line: report.line, link: report.link.flatMap(URL.init(string:)),
                                         items: (report.items ?? []).map { text in NotchReport.Item(text: text, undo: report.undoable == true ? { print("fake undo \(text)") } : nil) },
                                         tone: report.working == true ? .working : report.items == nil ? .plain : .done))
            }
        }
        fakesRead = lines.count
    }
}
