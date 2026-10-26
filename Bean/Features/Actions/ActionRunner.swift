import AppKit

final class ActionRunner {
    static let stepTimeout: TimeInterval = 120

    private let log: JSONLog

    init(log: JSONLog) {
        self.log = log
    }

    func record(_ outcome: ActionRecord.Outcome, _ plan: Plan, steps: [StepResult]? = nil, failure: String? = nil) {
        log.append(ActionRecord(at: Date(), outcome: outcome, commands: plan.steps.map(\.command), appBundleId: plan.appBundleId, steps: steps, failure: failure))
    }

    func terminalFrame(of plan: Plan) -> CGRect? {
        app(for: plan).flatMap { Accessibility.focusedWindowFrame(of: $0.processIdentifier) }
    }

    @MainActor
    func run(_ plan: Plan, onStep: @escaping (Int, Bool) -> Void) async -> PlanResult {
        var results: [StepResult] = []
        var failure: String?
        if let blocked = plan.blockedCommand {
            failure = "blocked command: \(blocked)"
        } else if let app = app(for: plan) {
            for (index, step) in plan.steps.enumerated() {
                let started = Date()
                if let problem = await type(step.command, into: app) {
                    failure = problem
                    onStep(index, false)
                    break
                }
                let output = await waitForOutput(of: step.command, in: app, since: started)
                let errorLine = output.flatMap(TerminalText.lastError)
                let result = StepResult(command: step.command, ok: output != nil && errorLine == nil, errorLine: errorLine, seconds: Date().timeIntervalSince(started).rounded())
                results.append(result)
                onStep(index, result.ok)
                if output == nil { failure = "\(step.command) did not finish within \(Int(Self.stepTimeout)) s" }
                if !result.ok { break }
            }
        } else {
            failure = "\(plan.appBundleId) is not running"
        }
        let tail = app(for: plan).flatMap { Accessibility.focusedText(of: $0.processIdentifier) }.map { TerminalText($0).tail(20) }
        let result = PlanResult(steps: results, failure: failure, terminalTail: tail)
        record(result.succeeded ? .ran : .failed, plan, steps: results, failure: failure ?? result.failedStep?.errorLine)
        return result
    }

    private func app(for plan: Plan) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: plan.appBundleId).first
    }

    @MainActor
    private func type(_ command: String, into app: NSRunningApplication) async -> String? {
        app.activate()
        for _ in 0..<30 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            return "\(app.localizedName ?? "the terminal") did not come to the front"
        }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(command.utf16)
        for start in stride(from: 0, to: units.count, by: 16) {
            let chunk = Array(units[start..<min(start + 16, units.count)])
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event?.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            return "focus moved away while typing, Return not pressed"
        }
        for keyDown in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: keyDown)?.post(tap: .cghidEventTap)
        }
        return nil
    }

    @MainActor
    private func waitForOutput(of command: String, in app: NSRunningApplication, since started: Date) async -> ArraySlice<String>? {
        while Date().timeIntervalSince(started) < Self.stepTimeout {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if let output = Accessibility.focusedText(of: app.processIdentifier).flatMap({ TerminalText($0).finishedOutput(of: command) }) {
                return output
            }
        }
        return nil
    }
}
