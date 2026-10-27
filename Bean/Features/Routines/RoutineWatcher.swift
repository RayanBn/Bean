import AppKit

extension Trigger.Kind {
    static let repeatSeen: Self = "repeatSeen"
}

@MainActor
final class RoutineWatcher {
    static let history: TimeInterval = 14 * 24 * 3600
    static let offerOdds = 0.7

    private let recorder = ActionRecorder()
    private let log: JSONLog
    private let actionsLog: JSONLog
    private var actions: [RecordedAction] = []
    private var routines: [Routine] = []
    private var snoozed: [String: Date] = [:]
    private var announced: (routine: Routine, at: Date)?
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(log: JSONLog, actionsLog: JSONLog) {
        self.log = log
        self.actionsLog = actionsLog
    }

    func start() {
        let since = Date().addingTimeInterval(-Self.history)
        actions = ((try? String(contentsOf: actionsLog.url, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .compactMap { try? decoder.decode(RecordedAction.self, from: Data($0.utf8)) }
            .filter { $0.at > since }
        recorder.onAction = { [weak self] action in self?.recorded(action) }
        recorder.isPaused = { Channels.shared.isActing }
        Events.onOutcome { [weak self] outcome in
            guard outcome.trigger.source == "routines", let id = outcome.trigger.ref else { return }
            self?.log.append(RoutineEvent(at: Date(), event: outcome.outcome.rawValue, routine: id, detail: outcome.action))
            if outcome.outcome == .declined { self?.snoozed[id] = Date().addingTimeInterval(24 * 3600) }
            if outcome.outcome != .proposed { self?.announced = nil }
        }
        recorder.start()
        remine()
        log.append(RoutineEvent(at: Date(), event: "started", detail: "\(actions.count) actions, \(routines.count) routines"))
    }

    func observe(_ command: ShellCommand) {
        recorder.observe(command)
    }

    func observe(_ event: InventoryEvent) {
        guard ["windowFocused", "titleChanged", "tabChanged", "textChanged"].contains(event.event) else { return }
        recorder.windowChanged(pid: event.pid)
    }

    private func recorded(_ action: RecordedAction) {
        actionsLog.append(action)
        actions.append(action)
        remine()
        if let announced, Date().timeIntervalSince(announced.at) < 180 {
            follow(announced.routine)
        } else {
            considerOffer()
        }
    }

    private func follow(_ routine: Routine) {
        let miner = RoutineMiner(actions: routine.scope.map { scope in actions.filter { $0.app == scope } } ?? actions)
        guard let session = miner.currentSession, var recipe = RecipeBook.shared.recipe("routine-\(routine.id)") else { return }
        let recent = Array(miner.tokens[session])
        let length = routine.tokens.count
        let done = (1...length).reversed().first { recent.count >= $0 && Array(recent.suffix($0)) == Array(routine.tokens.prefix($0)) }
            ?? recent.last.flatMap { routine.tokens.lastIndex(of: $0) }.map { $0 + 1 }
        guard let done else { return }
        recipe.steps = Self.plan(routine, from: done % length, used: Self.labels(of: routine, in: Array(miner.actions[session])))
        RecipeBook.shared.save(recipe)
        log.append(RoutineEvent(at: Date(), event: "followed", routine: routine.id, detail: "\(done % length)/\(length)", steps: recipe.steps.map(\.intent)))
    }

    private func remine() {
        let known = Set(routines.map(\.id))
        routines = RoutineMiner.all(actions)
        for routine in routines where !known.contains(routine.id) {
            log.append(RoutineEvent(at: Date(), event: "learned", routine: routine.id, name: routine.name, detail: "\(routine.instances) times on \(routine.days) days\(routine.loops ? ", in a loop" : "")\(routine.scope.map { " in \($0)" } ?? "")", steps: routine.tokens))
        }
    }

    private func considerOffer() {
        var views: [String: RoutineMiner] = [:]
        for routine in routines where routine.instances >= 2 && (snoozed[routine.id] ?? .distantPast) < Date() {
            let key = routine.scope ?? ""
            let miner = views[key] ?? RoutineMiner(actions: routine.scope.map { scope in actions.filter { $0.app == scope } } ?? actions)
            views[key] = miner
            guard let session = miner.currentSession, routine.scope == nil || actions.last?.app == routine.scope else { continue }
            let recent = Array(miner.tokens[session])
            let length = routine.tokens.count
            let matched = (2..<length).reversed().first { recent.count >= $0 && Array(recent.suffix($0)) == Array(routine.tokens.prefix($0)) }
            let finishedOne = routine.loops && routine.steps.contains(where: \.variable) && recent.count >= length && Array(recent.suffix(length)) == routine.tokens
            guard let done = matched ?? (finishedOne ? length : nil) else { continue }
            let odds = miner.completionOdds(of: routine.tokens, prefixLength: min(done, length - 1))
            log.append(RoutineEvent(at: Date(), event: "matched", routine: routine.id, name: routine.name, detail: "\(done)/\(length) steps, odds \(String(format: "%.2f", odds))\(routine.scope.map { " in \($0)" } ?? "")"))
            guard odds >= Self.offerOdds else { continue }
            announce(routine, done: done, used: Self.labels(of: routine, in: Array(miner.actions[session])))
            return
        }
    }

    private func announce(_ routine: Routine, done: Int, used: [String]) {
        let length = routine.tokens.count
        let remaining = Self.plan(routine, from: done % length, used: used)
        let bundleId = routine.scope ?? remaining.compactMap(\.app).first
        var recipe = RecipeBook.shared.recipe("routine-\(routine.id)")
            ?? Recipe(id: "routine-\(routine.id)", kind: .act, bundleId: bundleId, goal: routine.name, source: .demonstrated)
        recipe.goal = routine.name
        recipe.whenToUse = "The user has started this routine again; these are the steps left to finish this run."
        recipe.steps = remaining
        RecipeBook.shared.save(recipe)
        snoozed[routine.id] = Date().addingTimeInterval(600)
        announced = (routine, Date())

        var trigger = Trigger(at: Date(), kind: .repeatSeen, app: NSWorkspace.shared.frontmostApplication?.localizedName, bundleId: bundleId,
                              windowTitle: actions.last?.window, idleSeconds: 0, errorLine: nil, errorSeconds: nil, terminalTail: nil)
        trigger.details = """
        Bean watched the user do the same \(length) steps \(routine.instances) times\(routine.days > 1 ? " over \(routine.days) days" : "")\(routine.loops ? ", one after another, as a loop over similar items" : ""): \(routine.steps.map(\.step.intent).joined(separator: " → ")).
        The user has just started it again (\(done % length == 0 ? "finished one more run" : "\(done) of \(length) steps done")).
        Recipe \(recipe.id) holds what is left: \(remaining.map(\.intent).joined(separator: " → ")). Each step is checked by what it did when the user did it. To offer it, propose achieve with recipe \(recipe.id).
        """
        trigger.notice = "Again?"
        trigger.gate = .always
        trigger.source = "routines"
        trigger.ref = routine.id
        log.append(RoutineEvent(at: Date(), event: "announced", routine: routine.id, name: routine.name, detail: recipe.id, steps: remaining.map(\.intent)))
        Events.post(trigger)
    }

    static func plan(_ routine: Routine, from start: Int, used: [String]) -> [Step] {
        let length = routine.steps.count
        guard routine.loops, let item = routine.steps.firstIndex(where: \.variable) else { return routine.steps[start...].map(\.step) }
        var finish: [Step] = []
        var index = start
        while index != item {
            finish.append(routine.steps[index].step)
            index = (index + 1) % length
        }
        let round = (0..<length).map { routine.steps[(item + $0) % length] }
        let pick = round[0]
        var target = pick.step.target ?? Locator()
        target.title = nil
        target.ancestors = pick.path.isEmpty ? nil : pick.path.reversed()
        target.urlPattern = pick.href.map(Vocabulary.anchored)
        var first = pick.step
        first.target = target
        first.target?.title = "{item}"
        first.intent = pick.step.intent.replacingOccurrences(of: "the next", with: "“{item}”")
        let each = Step(intent: "Do the same for each other \(Vocabulary.roleName(target.role)) like it", kind: .each, target: target, bundleId: pick.step.app,
                        excluding: used, steps: [first] + round.dropFirst().map(\.step))
        return finish + [each]
    }

    static func labels(of routine: Routine, in session: [RecordedAction]) -> [String] {
        guard let pick = routine.steps.first(where: \.variable)?.step.target else { return [] }
        return session.compactMap { action in
            guard let element = action.element, element.bundleId == pick.bundleId, element.role == pick.role else { return nil }
            return element.label
        }
    }
}
