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
    func firstWork(agent: UUID, result: String) async
    func delegate(moment: Moment, result: String) async
    func undo(agent: UUID)
    func leave(window: Int)
    func holdsWindow(_ number: Int) -> Bool
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
                let filtered = ProcessInfo.processInfo.environment["BEAN_WINDOW_FILTER"] != nil
                let idle = filtered ? 0 : CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
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
        guard !BeanSettings.shared.effectivePaused else { return }
        if idle >= rules.awayAfterSeconds { awayNow = true } else if awayNow {
            awayNow = false
            cameBack = true
        }
        await take(former.advance(to: now, active: idle < rules.awayAfterSeconds))
        expire(now: now)
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
        let knows = Goals.text ?? "nothing yet"
        let verdict = await look(moment, knows)
        var seen = moment
        var score: Double?
        switch verdict {
        case .keptPrivate: return log(moment, "keptPrivate", by: "Strands")
        case .dropped(let value): return log(moment, "filtered", by: "Strands", score: value)
        case .pass(let value): score = value
        }
        if score == nil, !MomentFilter.canCheckTitles { seen.title = nil }
        asked += 1
        dose.questions.append(now)
        saveDose(now: now)
        guard let answer = await brain(Self.text(for: seen, knows: knows, jobs: jobs.forCard)) else { return log(moment, "noAnswer", by: "Muse Spark", score: score) }
        apply(MomentDecision.decide(moment, answer: answer, job: job, readingYes: readingYes), moment: moment, answer: answer, job: job, score: score, now: now)
    }

    static func text(for moment: Moment, knows: String, jobs: String) -> String {
        "What the person wants: \(knows)\nWhat Bean noticed before:\n\(MomentHandsLive.seenLately)\nWhat they answered before:\n\(jobs)\n\n\(moment.card)\nAgent on this window: none."
    }

    private func apply(_ outcome: MomentOutcome, moment: Moment, answer: MomentAnswer, job: MomentJob?, score: Double?, now: Date) {
        switch outcome {
        case .quiet(let why):
            jobs.move(.modelIgnored, moment: moment, words: MomentKey.words(modelKey: answer.key, moment: moment), now: now)
            log(moment, "ignore", by: "Muse Spark", score: score, detail: why)
        case let .remember(why, words):
            hands?.remember("seen: \(moment.because) \(why)")
            jobs.move(.modelIgnored, moment: moment, words: words, now: now)
            log(moment, "remember", by: "Muse Spark", score: score, detail: why)
        case .rejected(let why):
            log(moment, "rejected", by: "code", score: score, detail: why)
        case .ask(let offer):
            jobs.move(.asked, moment: moment, words: offer.words, now: now)
            waiting.append(offer)
            log(moment, "offer", by: "Muse Spark", score: score, detail: offer.result)
        case let .act(result, words, needs, sayIt):
            log(moment, "act", by: "code", score: score, detail: result)
            Task { await self.act(moment, result: result, words: words, needs: needs, sayIt: sayIt, job: job, now: now) }
        }
    }

    private func act(_ moment: Moment, result: String, words: [String], needs: MomentAnswer.Needs, sayIt: Bool, job: MomentJob?, now: Date) async {
        if moment.kind == .service {
            await hands?.delegate(moment: moment, result: result)
            jobs.move(job == nil ? .yes : .cleanRun, moment: moment, words: words, now: now)
            if sayIt { hands?.say(result, undoAgent: nil) }
            return
        }
        guard let agent = await hands?.place(moment: moment, result: result, needs: needs, agent: job?.agent) else { return }
        let moved = jobs.move(job == nil ? .yes : .cleanRun, moment: moment, words: words, agent: agent, now: now)
        if sayIt { hands?.say(AgentStrings.shown("On %@: %@", moment.title ?? moment.app ?? "", result), undoAgent: agent) }
        await hands?.firstWork(agent: agent, result: result)
        if moved.step == .keepDoing { askToKeep(moment, result: result, words: words) }
    }

    private func askToKeep(_ moment: Moment, result: String, words: [String]) {
        waiting.append(MomentOffer(id: UUID(), kind: .keepDoing, moment: moment, result: result, saw: moment.because, because: moment.because,
                                   answers: [MomentOffer.keepDoing, MomentOffer.notNow], words: words, needs: .nothing, when: .nextPause))
    }

    private func deliver(now: Date, atPause: Bool) {
        guard shown == nil, !inCall, let index = waiting.firstIndex(where: { $0.when == .whenBack ? cameBack : atPause }) else { return }
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
            if offer.needs != .hearCall { ReadingYes.add(MomentJob.bundle(of: offer.moment)) }
            let job = jobs.move(.yes, moment: offer.moment, words: offer.words, now: now)
            log(offer.moment, "saidYes", by: "person")
            await act(offer.moment, result: offer.result, words: offer.words, needs: offer.needs, sayIt: true, job: job, now: now)
        case MomentOffer.keepDoing:
            jobs.move(.keepDoing, moment: offer.moment, words: offer.words, now: now)
            log(offer.moment, "keepDoing", by: "person")
        case MomentOffer.never:
            jobs.never(moment: offer.moment)
            log(offer.moment, "never", by: "person")
        default:
            jobs.move(.notNow, moment: offer.moment, words: offer.words, now: now)
            log(offer.moment, "notNow", by: "person")
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
