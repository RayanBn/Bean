import AppKit

final class TriggerDetector {
    static let tailLines = 20

    private var stuckAfter: TimeInterval { BeanSettings.shared.effectiveStuckSeconds }
    private var idleAfter: TimeInterval { BeanSettings.shared.effectiveIdleSeconds }
    private var inMeeting = false
    private var searchFired = false
    private var lastBundleId: String?
    private var error: (line: String, tail: String, since: Date, origin: Snapshot)?
    private var stuckCheck: DispatchWorkItem?
    private var waitingCheck: DispatchWorkItem?
    private var lastSnapshot: Snapshot?
    private let idle: IdleClock
    private let repeatAfter: Int
    private let waitAfter: TimeInterval
    private let breakAfter: TimeInterval
    private var waitingFired: Set<String> = []
    private var activities: [Activity] = []
    static let waitingWindow: TimeInterval = 3600
    private var failures: [String: [Date]] = [:]
    private var repeatFired: Set<String> = []
    static let failureWindow: TimeInterval = 600
    static let ignoredExitCodes: Set<Int> = [0, 130, 148]

    init(idle: IdleClock, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.idle = idle
        repeatAfter = environment["BEAN_REPEAT_FAILURES"].flatMap(Int.init) ?? 3
        waitAfter = environment["BEAN_WAIT_SECONDS"].flatMap(Double.init) ?? 120
        breakAfter = environment["BEAN_BREAK_SECONDS"].flatMap(Double.init) ?? 600
    }

    func start() {
        idle.every(idleFor: { [weak self] in self?.idleAfter ?? 300 }) { [weak self] seconds in
            guard let self, let snapshot = lastSnapshot else { return }
            emit(.idle, snapshot.with(idleSeconds: seconds))
        }
        idle.onReturn { [weak self] away in
            guard let self, away >= breakAfter else { return }
            backFromBreak(away: away)
        }
    }

    func observe(_ activities: [Activity]) {
        self.activities = activities
        let now = Date()
        let next = activities.filter { $0.unseen && !waitingFired.contains(Self.key($0)) && now.timeIntervalSince($0.changedAt) < Self.waitingWindow }
            .map { $0.changedAt.addingTimeInterval(waitAfter + 0.5) }
            .min()
        waitingCheck?.cancel()
        guard let next else { return }
        let work = DispatchWorkItem { [weak self] in self?.unseenWaited() }
        waitingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(next.timeIntervalSinceNow, 0), execute: work)
    }

    private func unseenWaited() {
        idle.once(idleFor: 2) { [weak self] _ in
            guard let self else { return }
            let waiting = unseen(olderThan: waitAfter).filter { !self.waitingFired.contains(Self.key($0)) }
            guard !waiting.isEmpty else { return self.observe(self.activities) }
            if Presence.current().inMeeting {
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.unseenWaited() }
                return
            }
            waiting.forEach { self.waitingFired.insert(Self.key($0)) }
            let front = NSWorkspace.shared.frontmostApplication
            var trigger = Trigger(at: Date(), kind: .unseenChange, app: front?.localizedName, bundleId: front?.bundleIdentifier, windowTitle: lastSnapshot?.windowTitle, idleSeconds: IdleClock.seconds().rounded(), errorLine: nil, errorSeconds: nil, terminalTail: nil)
            trigger.waiting = waiting.map(\.line)
            trigger.waitingIds = waiting.map(\.id)
            emit(trigger)
            observe(activities)
        }
    }

    private func unseen(olderThan age: TimeInterval) -> [Activity] {
        activities.filter { item in
            let waited = Date().timeIntervalSince(item.changedAt)
            return item.unseen && waited >= age && waited < Self.waitingWindow
        }
    }

    private static func key(_ item: Activity) -> String { "\(item.bundleId)/\(item.id)@\(item.changedAt.timeIntervalSince1970)" }

    private func backFromBreak(away: TimeInterval) {
        let front = NSWorkspace.shared.frontmostApplication
        var trigger = Trigger(at: Date(), kind: .backFromBreak, app: front?.localizedName, bundleId: front?.bundleIdentifier, windowTitle: lastSnapshot?.windowTitle, idleSeconds: IdleClock.seconds().rounded(), errorLine: nil, errorSeconds: nil, terminalTail: nil)
        trigger.awayMinutes = (away / 6).rounded() / 10
        let waiting = unseen(olderThan: 0).filter { !waitingFired.contains(Self.key($0)) }
        waiting.forEach { waitingFired.insert(Self.key($0)) }
        trigger.waiting = waiting.map(\.line)
        trigger.waitingIds = waiting.map(\.id)
        emit(trigger)
    }

    func observe(_ snapshot: Snapshot) {
        inMeeting = snapshot.presence?.inMeeting ?? false
        if let last = lastBundleId, last != snapshot.bundleId {
            emit(.appChanged, snapshot)
        }
        lastBundleId = snapshot.bundleId
        lastSnapshot = snapshot

        if let bundleId = snapshot.bundleId, TerminalText.terminals.contains(bundleId), let text = snapshot.focusedText {
            readTerminal(text, snapshot)
        }

        if let current = error, !searchFired, let page = snapshot.browser, page.isSearch, let query = page.searchQuery, Self.overlaps(query, current.line) {
            searchFired = true
            let terminal = Snapshot(at: snapshot.at, app: current.origin.app, bundleId: current.origin.bundleId, windowTitle: current.origin.windowTitle, idleSeconds: snapshot.idleSeconds, focusedText: nil)
            emit(.searchingError, terminal, errorLine: current.line, errorSeconds: snapshot.at.timeIntervalSince(current.since).rounded(), terminalTail: current.tail, searchQuery: query, url: page.url.absoluteString)
        }
    }

    func observe(_ command: ShellCommand) {
        let key = command.cmd.trimmingCharacters(in: .whitespaces)
        let now = Date(timeIntervalSince1970: command.end)
        guard !Self.ignoredExitCodes.contains(command.exit) else {
            if command.exit == 0 {
                failures[key] = nil
                repeatFired.remove(key)
            }
            return
        }
        let recent = (failures[key] ?? []).filter { now.timeIntervalSince($0) < Self.failureWindow } + [now]
        failures[key] = recent
        let base = Trigger(at: now, kind: .commandFailed, app: command.appName, bundleId: command.bundleId, windowTitle: nil, idleSeconds: 0, errorLine: nil, errorSeconds: nil, terminalTail: nil, command: key, exitCode: command.exit, cwd: command.cwd)
        emit(base)
        guard recent.count >= repeatAfter, !repeatFired.contains(key) else { return }
        repeatFired.insert(key)
        var repeated = Trigger(at: now, kind: .repeatedFailure, app: command.appName, bundleId: command.bundleId, windowTitle: nil, idleSeconds: 0, errorLine: nil, errorSeconds: nil, terminalTail: nil, command: key, exitCode: command.exit, cwd: command.cwd)
        repeated.failures = recent.count
        repeated.failureMinutes = (now.timeIntervalSince(recent[0]) / 60 * 10).rounded() / 10
        emit(repeated)
    }

    private func readTerminal(_ text: String, _ snapshot: Snapshot) {
        let terminal = TerminalText(text)
        guard let line = terminal.lastError else {
            error = nil
            stuckCheck?.cancel()
            return
        }
        guard error?.line != line else { return }
        let tail = terminal.tail(Self.tailLines)
        error = (line, tail, snapshot.at, snapshot)
        searchFired = false
        emit(.terminalError, snapshot, errorLine: line, terminalTail: tail)
        stuckCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stuck(on: line) }
        stuckCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + stuckAfter, execute: work)
    }

    private func stuck(on line: String) {
        guard let current = error, current.line == line else { return }
        let origin = current.origin
        let terminal = Snapshot(at: Date(), app: origin.app, bundleId: origin.bundleId, windowTitle: origin.windowTitle, idleSeconds: IdleClock.seconds(), focusedText: nil)
        emit(.stuckOnError, terminal, errorLine: line, errorSeconds: Date().timeIntervalSince(current.since).rounded(), terminalTail: current.tail)
    }

    private func emit(_ kind: Trigger.Kind, _ snapshot: Snapshot, errorLine: String? = nil, errorSeconds: Double? = nil, terminalTail: String? = nil, searchQuery: String? = nil, url: String? = nil) {
        var trigger = Trigger(at: snapshot.at, kind: kind, app: snapshot.app, bundleId: snapshot.bundleId, windowTitle: snapshot.windowTitle, idleSeconds: snapshot.idleSeconds.rounded(), errorLine: errorLine, errorSeconds: errorSeconds, terminalTail: terminalTail)
        trigger.searchQuery = searchQuery
        trigger.url = url
        emit(trigger)
    }

    private func emit(_ trigger: Trigger) {
        var trigger = trigger
        trigger.inMeeting = inMeeting
        trigger.source = "triggers"
        trigger.gate = Self.policies[trigger.kind]
        trigger.notice = Self.notices[trigger.kind]
        Events.post(trigger)
    }

    static let policies: [Trigger.Kind: Trigger.GatePolicy] = [.repeatedFailure: .always, .searchingError: .always, .appChanged: .never]
    static let notices: [Trigger.Kind: String] = [
        .stuckOnError: "Stuck?", .terminalError: "Error", .idle: "Still there?", .appChanged: "Hmm",
        .commandFailed: "Failed", .repeatedFailure: "Again?", .searchingError: "Found it?",
    ]

    static func overlaps(_ query: String, _ errorLine: String) -> Bool {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init).filter { $0.count >= 4 })
        }
        let shared = words(query).intersection(words(errorLine))
        return shared.count >= 2 || (shared.count == 1 && words(query).count <= 2)
    }
}
