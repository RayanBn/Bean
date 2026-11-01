import AppKit

// What code may do once it has decided. Only this side can change anything, and the watching side reaches it only through a decided outcome.
@MainActor
protocol MomentHands: AnyObject {
    func show(_ offer: MomentOffer)
    func withdraw(_ offer: MomentOffer)
    func say(_ line: String, undoAgent: UUID?)
    func note(_ text: String)
    func remember(_ text: String)
    func place(moment: Moment, result: String, needs: MomentAnswer.Needs, agent: UUID?) async -> UUID?
    func firstWork(agent: UUID, result: String) async -> Bool
    func agentName(_ id: UUID) -> String?
    func delegate(moment: Moment, result: String) async
    func undo(agent: UUID)
    func leave(window: Int)
    func holdsWindow(_ number: Int) -> Bool
    func holdsApp(_ bundleId: String?) -> Bool
    func sessionLook(window: Int?, alsoClosed: Bool) async -> UserSessionLook
    func sessionAllowed(_ session: UserSession) -> Bool
    func takeOver(_ session: UserSession) async -> String?
    func decline(_ session: UserSession, forGood: Bool)
    func wantsToLeave(rules: MomentRules, now: Date)
    func record(_ entry: GateEntry)
}

@MainActor
final class MomentDesk {
    typealias Brain = (String) async -> MomentAnswer?
    typealias Look = (Moment, String) async -> MomentFilter.Verdict

    let jobs: MomentJobs
    private let rules: MomentRules
    private weak var hands: MomentHands?
    private let brain: Brain
    private let look: Look
    private var former: MomentFormer
    private var dose: MomentDose
    private let doseFile: URL
    private var waiting: [MomentOffer] = []
    private var shown: MomentOffer?
    private var inCall = false
    private var awayNow = false
    private var cameBack = false
    private var justMoved = false
    private var thinking = false
    private var queue: [Moment] = []
    private var heartbeat: Timer?
    private var lastDay: Date?
    private var focusWindow: Int?
    private var leftAt: Date?
    private var lastSessionCheck: Date?
    private(set) var asked = 0

    init(hands: MomentHands, jobs: MomentJobs? = nil, rules: MomentRules = .starting, doseFile: URL = JSONLog.directory.appendingPathComponent("moment-dose.json"),
         brain: @escaping Brain = { await MomentAnswer.ask(about: $0) }, look: @escaping Look = { await MomentFilter.look(at: $0, knows: $1) }) {
        self.hands = hands
        self.jobs = jobs ?? MomentJobs(rules: rules)
        self.rules = rules
        self.brain = brain
        self.look = look
        self.doseFile = doseFile
        former = MomentFormer(rules: rules)
        dose = (try? Data(contentsOf: doseFile)).flatMap { try? Self.decoder.decode(MomentDose.self, from: $0) } ?? MomentDose()
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func start() {
        heartbeat = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
                Task { await self.tick(now: Date(), idle: idle) }
            }
        }
    }

    func sensed(_ signal: SenseSignal) async {
        guard !BeanSettings.shared.effectivePaused else { return }
        if signal.type == "call.started" { inCall = true }
        if signal.type == "call.ended" {
            inCall = false
            justMoved = true
        }
        if signal.type == "window.focused" { focusWindow = signal.window }
        if signal.type == "window.unfocused" { focusWindow = nil }
        if signal.type == "window.closed", let number = signal.window, hands?.holdsWindow(number) == true { hands?.leave(window: number) }
        let place = "\(signal.app ?? "") \(signal.bundleId ?? "") \(signal.title ?? "")"
        guard OffLimits.match(place) == nil, !SealedApps.contains(bundleId: signal.bundleId, app: signal.app, rules: rules) else {
            if signal.type == "window.focused" { _ = former.observe(LoggedEvent(at: signal.at, type: "window.unfocused")) }
            return
        }
        if signal.type == "window.focused" || signal.type == "window.unfocused" { justMoved = true }
        let event = LoggedEvent(at: signal.at, type: signal.type, app: signal.app, bundleId: signal.bundleId, window: signal.window, title: signal.title)
        await take(former.observe(event, detail: signal.detail))
    }

    func tick(now: Date, idle: TimeInterval) async {
        guard !BeanSettings.shared.effectivePaused, !Onboarding.holding else { return }
        if idle >= rules.awayAfterSeconds { awayNow = true } else if awayNow {
            awayNow = false
            cameBack = true
        }
        let filtered = ProcessInfo.processInfo.environment["BEAN_WINDOW_FILTER"] != nil
        await take(former.advance(to: now, active: filtered || idle < rules.awayAfterSeconds))
        expire(now: now)
        await lookForSession(now: now, idle: idle)
        deliver(now: now, atPause: justMoved || idle >= rules.pauseIdleSeconds)
        justMoved = false
        cameBack = false
        if lastDay.map({ !Calendar.current.isDate($0, inSameDayAs: now) }) ?? true {
            lastDay = now
            hands?.wantsToLeave(rules: rules, now: now)
        }
    }

    private func take(_ moments: [Moment]) async {
        queue += moments
        guard !thinking else { return }
        thinking = true
        while !queue.isEmpty { await think(queue.removeFirst()) }
        thinking = false
    }

    private func log(_ moment: Moment, _ decision: String, by: String = "code", score: Double? = nil, detail: String? = nil) {
        hands?.record(GateEntry(at: moment.at, event: moment.kind.rawValue, app: moment.app, title: moment.title, decision: decision, by: by, score: score, detail: detail))
    }

    private func think(_ moment: Moment) async {
        if moment.kind == .call { return log(moment, "fixedWords") }
        if let number = moment.window, hands?.holdsWindow(number) == true { return log(moment, "hasAgent") }
        if hands?.holdsApp(moment.bundleId) == true { return log(moment, "hasAgent") }
        let now = moment.at
        let job: MomentJob?
        switch jobs.standing(for: moment, now: now) {
        case .stop(let why): return log(moment, why == "never here" ? "standingNever" : "standingQuiet")
        case .goOn(let found): job = found
        }
        let bundle = MomentJob.bundle(of: moment)
        let readingYes = ReadingYes.covers(bundle)
        if !readingYes, moment.kind != .service, shown != nil || !waiting.isEmpty || !dose.mayOffer(now: now, rules: rules) { return log(moment, "dose") }
        guard dose.mayAsk(now: now, rules: rules) else { return log(moment, "dayCap") }
        let verdict = await look(moment, Goals.text ?? "nothing yet")
        var score: Double?
        switch verdict {
        case .keptPrivate: return log(moment, "keptPrivate", by: "Strands")
        case .noCheck: return log(moment, "noLocalCheck")
        case .dropped(let value): return log(moment, "filtered", by: "Strands", score: value)
        case .pass(let value): score = value
        }
        asked += 1
        dose.questions.append(now)
        saveDose(now: now)
        let sealed = Skills.forApp(moment.bundleId).flatMap { $0.sealed ? $0 : nil }
        guard let answer = await brain(Self.text(for: moment, goals: Goals.text, noticed: MomentHandsLive.seenLately, jobs: jobs.forCard, limit: sealed?.body)) else { return log(moment, "noAnswer", by: "Muse Spark", score: score) }
        let decided = MomentDecision.decide(moment, answer: answer, job: job, readingYes: readingYes, sealed: sealed)
        apply(await withSession(decided, moment: moment, answer: answer, sealed: sealed != nil), moment: moment, answer: answer, job: job, score: score, now: now)
    }

    // Slowest to fastest. A sealed window says what an agent really can do there, so an offer does not promise more.
    // A coding session under this window's app is worth more than an agent on the window, so the offer waits for the person to leave it.
    private func withSession(_ outcome: MomentOutcome, moment: Moment, answer: MomentAnswer, sealed: Bool) async -> MomentOutcome {
        var offer: MomentOffer
        switch outcome {
        case .ask(let asked): offer = asked
        case let .act(result, words, needs, _):
            offer = MomentOffer(id: UUID(), kind: .proposal, moment: moment, result: result, saw: answer.saw, because: moment.because,
                                answers: [MomentOffer.yes, MomentOffer.notNow, MomentOffer.never], words: words, needs: needs, when: .nextPause)
        default: return outcome
        }
        guard moment.kind != .service, let look = await hands?.sessionLook(window: moment.window, alsoClosed: sealed) else { return outcome }
        switch look {
        case .held: return .rejected("this session is already taken over")
        case .offer, .active:
            offer.waitsUntilLeft = true
            return .ask(offer)
        case .never, .nothing:
            return outcome
        }
    }

    static func text(for moment: Moment, goals: String?, noticed: String, jobs: String, limit: String? = nil) -> String {
        var parts: [String] = []
        if let goals { parts.append("What the person wants: \(goals)") }
        if !noticed.isEmpty { parts.append("What Bean noticed before:\n\(noticed)") }
        if !jobs.isEmpty { parts.append("What they answered before:\n\(jobs)") }
        parts.append("\(moment.card)\nAgent on this window: none.\(limit.map { "\nWhat an agent can do on this window, and nothing more: \($0)" } ?? "")")
        return parts.joined(separator: "\n\n")
    }

    private func apply(_ outcome: MomentOutcome, moment: Moment, answer: MomentAnswer, job: MomentJob?, score: Double?, now: Date) {
        switch outcome {
        case .quiet(let why):
            jobs.move(.modelIgnored, moment: moment, words: MomentKey.words(modelKey: answer.key, moment: moment), now: now)
            log(moment, "ignore", by: "Muse Spark", score: score, detail: why)
        case let .remember(why, words):
            hands?.remember("seen: \(moment.because) \(why)")
            jobs.move(.remembered, moment: moment, words: words, now: now)
            log(moment, "remember", by: "Muse Spark", score: score, detail: why)
        case .rejected(let why):
            log(moment, "rejected", by: "code", score: score, detail: why)
        case .ask(let offer):
            jobs.move(.asked, moment: moment, words: offer.words, now: now)
            waiting.append(offer)
            log(moment, "offer", by: "Muse Spark", score: score, detail: offer.result)
        case let .act(result, words, needs, sayIt):
            log(moment, "act", by: "code", score: score, detail: result)
            Task { await self.act(moment, result: result, words: words, needs: needs, sayIt: sayIt, startsWork: true, job: job, now: now) }
        }
    }

    private func act(_ moment: Moment, result: String, words: [String], needs: MomentAnswer.Needs, sayIt: Bool, startsWork: Bool, job: MomentJob?, now: Date) async {
        if moment.kind == .service {
            await hands?.delegate(moment: moment, result: result)
            jobs.move(job == nil ? .yes : .cleanRun, moment: moment, words: words, now: now)
            if sayIt { hands?.say(result, undoAgent: nil) }
            return
        }
        guard let agent = await hands?.place(moment: moment, result: result, needs: needs, agent: job?.agent) else { return }
        let moved = jobs.move(job == nil ? .yes : .cleanRun, moment: moment, words: words, agent: agent, now: now)
        if sayIt { hands?.say(String(format: "%@ is on %@. Nothing has changed yet.", hands?.agentName(agent) ?? "An agent", moment.app ?? moment.title ?? ""), undoAgent: agent) }
        guard startsWork, await hands?.firstWork(agent: agent, result: result) == true else { return }
        if moved.step == .keepDoing { askToKeep(moment, result: result, words: words) }
    }

    private func askToKeep(_ moment: Moment, result: String, words: [String]) {
        waiting.append(MomentOffer(id: UUID(), kind: .keepDoing, moment: moment, result: result, saw: moment.because, because: moment.because,
                                   answers: [MomentOffer.keepDoing, MomentOffer.notNow], words: words, needs: .nothing, when: .nextPause))
    }

    // A sealed window waits until the person has left it. A session of theirs that has gone idle then replaces the fixed words.
    private func lookForSession(now: Date, idle: TimeInterval) async {
        guard let held = waiting.first(where: \.waitsUntilLeft) else { return }
        let id = held.id
        guard focusWindow != held.moment.window || idle >= rules.awayAfterSeconds else {
            leftAt = nil
            return
        }
        let left = leftAt ?? now
        leftAt = left
        guard lastSessionCheck.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return }
        lastSessionCheck = now
        let look = await hands?.sessionLook(window: held.moment.window, alsoClosed: !held.startsWork) ?? .nothing
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        switch look {
        case .offer(let found) where hands?.sessionAllowed(found.session) == true:
            let offer = waiting.remove(at: index)
            leftAt = nil
            jobs.move(.cleanRun, moment: offer.moment, words: offer.words, now: now)
            log(offer.moment, "act", detail: found.words)
            if await hands?.takeOver(found.session) == nil { hands?.say(String(format: "Carrying on “%@” while you're away.", found.session.title), undoAgent: nil) }
        case .offer(let found):
            waiting[index].result = found.words
            waiting[index].session = found.session
            waiting[index].waitsUntilLeft = false
            leftAt = nil
            justMoved = true
        case .held:
            let offer = waiting.remove(at: index)
            leftAt = nil
            log(offer.moment, "hasAgent")
        case .active where now.timeIntervalSince(left) < rules.sessionWaitMinutes * 60:
            break
        case .active, .never, .nothing:
            waiting[index].waitsUntilLeft = false
            leftAt = nil
            justMoved = true
        }
    }

    private func deliver(now: Date, atPause: Bool) {
        guard shown == nil, !inCall, let index = waiting.firstIndex(where: { !$0.waitsUntilLeft && ($0.when == .whenBack ? cameBack : atPause) }) else { return }
        var offer = waiting.remove(at: index)
        if offer.kind == .proposal, !dose.mayOffer(now: now, rules: rules) { return log(offer.moment, "dose") }
        offer.shownAt = now
        shown = offer
        if offer.kind == .proposal {
            dose.offers.append(now)
            saveDose(now: now)
        }
        hands?.show(offer)
    }

    private func expire(now: Date) {
        guard let offer = shown, let at = offer.shownAt, now.timeIntervalSince(at) >= rules.offerExpiresMinutes * 60 else { return }
        hands?.withdraw(offer)
        shown = nil
        guard offer.kind == .proposal else { return }
        jobs.move(.ignored, moment: offer.moment, words: offer.words, now: now)
        dose.ignoredInARow += 1
        saveDose(now: now)
        log(offer.moment, "offerExpired")
    }

    func answered(_ id: UUID, _ text: String, now: Date = Date()) async {
        guard let offer = shown, offer.id == id else { return }
        shown = nil
        switch text {
        case MomentOffer.yes:
            dose.ignoredInARow = 0
            saveDose(now: now)
            if offer.session == nil, offer.startsWork, offer.needs != .hearCall { ReadingYes.add(MomentJob.bundle(of: offer.moment)) }
            let job = jobs.move(.yes, moment: offer.moment, words: offer.words, now: now)
            log(offer.moment, "saidYes", by: "person")
            if let session = offer.session {
                let refused = await hands?.takeOver(session)
                hands?.say(refused ?? String(format: "Carrying on “%@” while you're away.", session.title), undoAgent: nil)
                return
            }
            await act(offer.moment, result: offer.result, words: offer.words, needs: offer.needs, sayIt: true, startsWork: offer.startsWork, job: job, now: now)
        case MomentOffer.keepDoing:
            jobs.move(.keepDoing, moment: offer.moment, words: offer.words, now: now)
            log(offer.moment, "keepDoing", by: "person")
        case MomentOffer.never:
            if let session = offer.session { hands?.decline(session, forGood: true) }
            jobs.never(moment: offer.moment)
            log(offer.moment, "never", by: "person")
        case AgentWorker.skipAnswer:
            jobs.move(.ignored, moment: offer.moment, words: offer.words, now: now)
            log(offer.moment, "offerExpired", by: "person")
        case MomentOffer.notNow:
            if let session = offer.session { hands?.decline(session, forGood: false) }
            jobs.move(.notNow, moment: offer.moment, words: offer.words, now: now)
            log(offer.moment, "notNow", by: "person")
        default:
            jobs.move(.undone(text), moment: offer.moment, words: offer.words, now: now)
            jobs.move(.notNow, moment: offer.moment, words: offer.words, now: now)
            log(offer.moment, "notNow", by: "person", detail: text)
        }
    }

    func tell(_ line: String) { hands?.say(line, undoAgent: nil) }

    func undo(agent id: UUID, words: String? = nil) {
        jobs.undone(agent: id, words: words)
        hands?.undo(agent: id)
    }

    private func saveDose(now: Date) {
        dose.keepRecent(now: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(dose).write(to: doseFile, options: .atomic)
    }
}
