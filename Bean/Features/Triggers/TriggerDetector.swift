import Foundation

final class TriggerDetector {
    static let tailLines = 20

    var onTrigger: ((Trigger) -> Void)?

    private let log: JSONLog
    private var stuckAfter: TimeInterval { BeanSettings.shared.effectiveStuckSeconds }
    private var idleAfter: TimeInterval { BeanSettings.shared.effectiveIdleSeconds }
    private var inMeeting = false
    private var searchFired = false
    private var lastBundleId: String?
    private var error: (line: String, tail: String, since: Date, stuckFired: Bool, origin: Snapshot)?
    private var idleFired = false
    private let repeatAfter: Int
    private let agentWaitAfter: TimeInterval
    private let breakAfter: TimeInterval
    private var agentsFired: Set<String> = []
    private var away: Double = 0
    private var context: MacContext?
    static let agentWindow: TimeInterval = 3600
    private var failures: [String: [Date]] = [:]
    private var repeatFired: Set<String> = []
    static let failureWindow: TimeInterval = 600
    static let ignoredExitCodes: Set<Int> = [0, 130, 148]

    init(log: JSONLog, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.log = log
        repeatAfter = environment["BEAN_REPEAT_FAILURES"].flatMap(Int.init) ?? 3
        agentWaitAfter = environment["BEAN_AGENT_WAIT_SECONDS"].flatMap(Double.init) ?? 120
        breakAfter = environment["BEAN_BREAK_SECONDS"].flatMap(Double.init) ?? 600
    }

    func observe(_ context: MacContext) {
        self.context = context
        let waiting = waitingAgents(in: context, olderThan: agentWaitAfter).filter { !agentsFired.contains(Self.key($0)) }
        guard !waiting.isEmpty, context.idleSeconds >= 2, context.presence?.inMeeting != true else { return }
        waiting.forEach { agentsFired.insert(Self.key($0)) }
        var trigger = Trigger(at: context.at, kind: .agentWaiting, app: context.frontmost?.name, bundleId: context.frontmost?.bundleId, windowTitle: context.focusedWindow?.title, idleSeconds: context.idleSeconds, errorLine: nil, errorSeconds: nil, terminalTail: nil)
        trigger.agents = waiting.map(\.line)
        trigger.agentIds = waiting.map(\.id)
        emit(trigger)
    }

    private func waitingAgents(in context: MacContext, olderThan age: TimeInterval) -> [AgentSession] {
        context.agents.filter { agent in
            let waited = context.at.timeIntervalSince(agent.lastActivity)
            return agent.needsUser && agent.unseen && waited >= age && waited < Self.agentWindow
        }
    }

    private static func key(_ agent: AgentSession) -> String { "\(agent.id)@\(agent.lastActivity.timeIntervalSince1970)" }

    private func backFromBreak(_ snapshot: Snapshot) {
        if snapshot.idleSeconds >= breakAfter { away = max(away, snapshot.idleSeconds) }
        guard away > 0, snapshot.idleSeconds < 5 else { return }
        var trigger = Trigger(at: snapshot.at, kind: .backFromBreak, app: snapshot.app, bundleId: snapshot.bundleId, windowTitle: snapshot.windowTitle, idleSeconds: snapshot.idleSeconds.rounded(), errorLine: nil, errorSeconds: nil, terminalTail: nil)
        trigger.awayMinutes = (away / 6).rounded() / 10
        away = 0
        if let context {
            let waiting = waitingAgents(in: context, olderThan: 0)
            waiting.forEach { agentsFired.insert(Self.key($0)) }
            trigger.agents = waiting.map(\.line)
            trigger.agentIds = waiting.map(\.id)
        }
        emit(trigger)
    }

    func observe(_ snapshot: Snapshot) {
        inMeeting = snapshot.presence?.inMeeting ?? false
        if let last = lastBundleId, last != snapshot.bundleId {
            emit(.appChanged, snapshot)
        }
        lastBundleId = snapshot.bundleId
        backFromBreak(snapshot)

        if snapshot.idleSeconds >= idleAfter, !idleFired {
            idleFired = true
            emit(.idle, snapshot)
        } else if snapshot.idleSeconds < idleAfter {
            idleFired = false
        }

        if let bundleId = snapshot.bundleId, TerminalText.terminals.contains(bundleId), let text = snapshot.focusedText {
            readTerminal(text, snapshot)
        }

        if let current = error, !searchFired, let page = snapshot.browser, page.isSearch, let query = page.searchQuery, Self.overlaps(query, current.line) {
            searchFired = true
            let terminal = Snapshot(at: snapshot.at, app: current.origin.app, bundleId: current.origin.bundleId, windowTitle: current.origin.windowTitle, idleSeconds: snapshot.idleSeconds, focusedText: nil)
            emit(.searchingError, terminal, errorLine: current.line, errorSeconds: snapshot.at.timeIntervalSince(current.since).rounded(), terminalTail: current.tail, searchQuery: query, url: page.url.absoluteString)
        }

        if let current = error, !current.stuckFired, snapshot.at.timeIntervalSince(current.since) >= stuckAfter {
            error?.stuckFired = true
            let terminal = Snapshot(at: snapshot.at, app: current.origin.app, bundleId: current.origin.bundleId, windowTitle: current.origin.windowTitle, idleSeconds: snapshot.idleSeconds, focusedText: nil)
            emit(.stuckOnError, terminal, errorLine: current.line, errorSeconds: snapshot.at.timeIntervalSince(current.since).rounded(), terminalTail: current.tail)
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
            return
        }
        guard error?.line != line else { return }
        let tail = terminal.tail(Self.tailLines)
        error = (line, tail, snapshot.at, false, snapshot)
        searchFired = false
        emit(.terminalError, snapshot, errorLine: line, terminalTail: tail)
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
        log.append(trigger)
        onTrigger?(trigger)
    }

    static func overlaps(_ query: String, _ errorLine: String) -> Bool {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init).filter { $0.count >= 4 })
        }
        let shared = words(query).intersection(words(errorLine))
        return shared.count >= 2 || (shared.count == 1 && words(query).count <= 2)
    }
}
