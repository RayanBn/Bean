import Foundation

final class TriggerDetector {
    static let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty"]
    static let errorPattern = try! NSRegularExpression(pattern: #"\w*(Error|Exception)\b|(?i:\b(error|traceback|fatal|panic|failed)\b)"#)
    static let promptPattern = try! NSRegularExpression(pattern: #"^(\S+@\S+ .*[%$#] |\$ )"#)
    static let scannedLines = 30
    static let tailLines = 20

    var onTrigger: ((Trigger) -> Void)?

    private let log: JSONLog
    private let stuckAfter: TimeInterval
    private let idleAfter: TimeInterval
    private var lastBundleId: String?
    private var error: (line: String, tail: String, since: Date, stuckFired: Bool, origin: Snapshot)?
    private var idleFired = false

    init(log: JSONLog, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.log = log
        stuckAfter = environment["BEAN_STUCK_SECONDS"].flatMap(Double.init) ?? 180
        idleAfter = environment["BEAN_IDLE_SECONDS"].flatMap(Double.init) ?? 300
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

        if let bundleId = snapshot.bundleId, Self.terminals.contains(bundleId), let text = snapshot.focusedText {
            readTerminal(text, snapshot)
        }

        if let current = error, !current.stuckFired, snapshot.at.timeIntervalSince(current.since) >= stuckAfter {
            error?.stuckFired = true
            let terminal = Snapshot(at: snapshot.at, app: current.origin.app, bundleId: current.origin.bundleId, windowTitle: current.origin.windowTitle, idleSeconds: snapshot.idleSeconds, focusedText: nil)
            emit(.stuckOnError, terminal, errorLine: current.line, errorSeconds: snapshot.at.timeIntervalSince(current.since).rounded(), terminalTail: current.tail)
        }
    }

    private func readTerminal(_ text: String, _ snapshot: Snapshot) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let line = lines.suffix(Self.scannedLines).last(where: Self.isError) else {
            error = nil
            return
        }
        guard error?.line != line else { return }
        let tail = lines.suffix(Self.tailLines).joined(separator: "\n")
        error = (line, tail, snapshot.at, false, snapshot)
        emit(.terminalError, snapshot, errorLine: line, terminalTail: tail)
    }

    private static func isError(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        return errorPattern.firstMatch(in: line, range: range) != nil && promptPattern.firstMatch(in: line, range: range) == nil
    }

    private func emit(_ kind: Trigger.Kind, _ snapshot: Snapshot, errorLine: String? = nil, errorSeconds: Double? = nil, terminalTail: String? = nil) {
        let trigger = Trigger(at: snapshot.at, kind: kind, app: snapshot.app, bundleId: snapshot.bundleId, windowTitle: snapshot.windowTitle, idleSeconds: snapshot.idleSeconds.rounded(), errorLine: errorLine, errorSeconds: errorSeconds, terminalTail: terminalTail)
        log.append(trigger)
        onTrigger?(trigger)
    }
}
