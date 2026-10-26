import Foundation

final class TriggerDetector {
    static let tailLines = 20

    var onTrigger: ((Trigger) -> Void)?

    private let log: JSONLog
    private let stuckAfter: TimeInterval
    private let idleAfter: TimeInterval
    private var lastBundleId: String?
    private var error: (line: String, tail: String, since: Date, stuckFired: Bool, origin: Snapshot)?
    private var idleFired = false
    private let repeatAfter: Int
    private var failures: [String: [Date]] = [:]
    private var repeatFired: Set<String> = []
    static let failureWindow: TimeInterval = 600
    static let ignoredExitCodes: Set<Int> = [0, 130, 148]

    init(log: JSONLog, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.log = log
        stuckAfter = environment["BEAN_STUCK_SECONDS"].flatMap(Double.init) ?? 180
        idleAfter = environment["BEAN_IDLE_SECONDS"].flatMap(Double.init) ?? 300
        repeatAfter = environment["BEAN_REPEAT_FAILURES"].flatMap(Int.init) ?? 3
    }

    func observe(_ snapshot: Snapshot) {
        if let last = lastBundleId, last != snapshot.bundleId {
            emit(.appChanged, snapshot)
        }
        lastBundleId = snapshot.bundleId

        if snapshot.idleSeconds >= idleAfter, !idleFired {
            idleFired = true
            emit(.idle, snapshot)
        } else if snapshot.idleSeconds < idleAfter {
            idleFired = false
        }

        if let bundleId = snapshot.bundleId, TerminalText.terminals.contains(bundleId), let text = snapshot.focusedText {
            readTerminal(text, snapshot)
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
        log.append(base)
        onTrigger?(base)
        guard recent.count >= repeatAfter, !repeatFired.contains(key) else { return }
        repeatFired.insert(key)
        var repeated = Trigger(at: now, kind: .repeatedFailure, app: command.appName, bundleId: command.bundleId, windowTitle: nil, idleSeconds: 0, errorLine: nil, errorSeconds: nil, terminalTail: nil, command: key, exitCode: command.exit, cwd: command.cwd)
        repeated.failures = recent.count
        repeated.failureMinutes = (now.timeIntervalSince(recent[0]) / 60 * 10).rounded() / 10
        log.append(repeated)
        onTrigger?(repeated)
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
        emit(.terminalError, snapshot, errorLine: line, terminalTail: tail)
    }

    private func emit(_ kind: Trigger.Kind, _ snapshot: Snapshot, errorLine: String? = nil, errorSeconds: Double? = nil, terminalTail: String? = nil) {
        let trigger = Trigger(at: snapshot.at, kind: kind, app: snapshot.app, bundleId: snapshot.bundleId, windowTitle: snapshot.windowTitle, idleSeconds: snapshot.idleSeconds.rounded(), errorLine: errorLine, errorSeconds: errorSeconds, terminalTail: terminalTail)
        log.append(trigger)
        onTrigger?(trigger)
    }
}
