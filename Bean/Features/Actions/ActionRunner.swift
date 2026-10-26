import AppKit

final class ActionRunner {
    private let log: JSONLog

    init(log: JSONLog) {
        self.log = log
    }

    func record(_ outcome: ActionRecord.Outcome, _ command: TerminalCommand, failure: String? = nil) {
        log.append(ActionRecord(at: Date(), outcome: outcome, command: command.command, appBundleId: command.appBundleId, failure: failure))
    }

    func run(_ command: TerminalCommand) async -> String? {
        let failure = await type(command)
        record(failure == nil ? .ran : .failed, command, failure: failure)
        return failure
    }

    @MainActor
    private func type(_ command: TerminalCommand) async -> String? {
        guard !command.isBlocked else { return "blocked command" }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: command.appBundleId).first else {
            return "\(command.appBundleId) is not running"
        }
        app.activate()
        for _ in 0..<30 where NSWorkspace.shared.frontmostApplication?.bundleIdentifier != command.appBundleId {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == command.appBundleId else {
            return "\(command.appBundleId) did not come to the front"
        }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(command.command.utf16)
        for start in stride(from: 0, to: units.count, by: 16) {
            let chunk = Array(units[start..<min(start + 16, units.count)])
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event?.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == command.appBundleId else {
            return "focus moved away while typing, Return not pressed"
        }
        for keyDown in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: keyDown)?.post(tap: .cghidEventTap)
        }
        return nil
    }
}
