import Foundation

struct BrainAnswer: Codable {
    let at: Date
    let trigger: Trigger.Kind
    let attempt: Int
    let gateScore: Double?
    let sawScreen: Bool
    let tool: String?
    let message: String?
    let steps: [PlanStep]?
    let latencyMs: Int
    let model: String
    let promptTokens: Int?
    let completionTokens: Int?
    let failure: String?
}

final class Brain {
    static let system = """
    You are Bean, a discreet butler that lives in the notch of the user's Mac. A local model noticed that the user may need help. You get what triggered it and a screenshot of the screen.
    Always answer by calling exactly one tool:
    - propose_plan when shell commands, run one after the other in the terminal the user is using, would fix the problem. End the plan with the command that proves the fix (rerun the build or the tests) when there is one. Bean shows the plan and runs it only after the user confirms, and stops at the first step that fails.
    - show_message when you can name the cause and the fix but it is not something safe to run in the terminal.
    - stay_quiet when you cannot tell what is wrong, or interrupting would not be worth it.
    Messages: at most two sentences and 200 characters, naming the concrete cause and fix like a senior colleague leaning over the desk. Quote the exact file, command or line. No greetings, no generic advice.
    Step titles: two to four words, like "Install requests" or "Rerun the build".
    Never propose sudo, rm -rf, force pushes, or anything that deletes data or touches the system.
    """
    static let tools: [[String: Any]] = [
        tool("propose_plan", "Propose shell commands to run in the user's terminal, in order, after they confirm.", [
            "message": ["type": "string", "description": "The cause and what the plan does, for the notch. At most 200 characters."],
            "steps": ["type": "array", "minItems": 1, "maxItems": 4, "items": [
                "type": "object",
                "properties": ["title": ["type": "string"], "command": ["type": "string", "description": "One single-line shell command."]],
                "required": ["title", "command"],
            ]],
        ]),
        tool("show_message", "Show a short message in the notch.", [
            "message": ["type": "string", "description": "At most 200 characters."],
        ]),
        tool("stay_quiet", "Do not interrupt the user.", [:]),
    ]
    static let dismissAfter: TimeInterval = 30
    static let maxAttempts = 2

    private let spark: MuseSpark
    private let notch: NotchController
    private let actions: ActionRunner
    private let log: JSONLog
    private var busy = false
    private var dismissal: DispatchWorkItem?

    init(spark: MuseSpark, notch: NotchController, actions: ActionRunner, log: JSONLog) {
        self.spark = spark
        self.notch = notch
        self.actions = actions
        self.log = log
    }

    func consider(_ decision: GateDecision, _ trigger: Trigger) {
        guard decision.stepIn else {
            if trigger.kind != .appChanged, !busy { notch.stayedQuiet() }
            return
        }
        guard !busy else { return }
        busy = true
        notch.notice(Self.noticeWord(for: trigger))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.ask(about: trigger, gateScore: decision.score, attempt: 1)
        }
    }

    private func ask(about trigger: Trigger, gateScore: Double?, attempt: Int) {
        notch.think(attempt == 1 ? "Looking at your screen" : "Looking again")
        Task {
            let answer = await think(about: trigger, gateScore: gateScore, attempt: attempt)
            await MainActor.run { self.present(answer, for: trigger, gateScore: gateScore) }
        }
    }

    private func think(about trigger: Trigger, gateScore: Double?, attempt: Int) async -> BrainAnswer {
        let started = Date()
        var failures: [String] = []
        var jpeg: Data?
        do {
            jpeg = try await ScreenCapture.mainDisplayJPEG()
        } catch {
            failures.append("capture: \(error.localizedDescription)")
        }

        struct Arguments: Decodable { let message: String?; let steps: [PlanStep]? }
        var reply: MuseSpark.Reply?
        var arguments: Arguments?
        do {
            let response = try await spark.complete(system: Self.system, text: trigger.summary, jpeg: jpeg, tools: Self.tools)
            reply = response
            if let call = response.toolCall {
                arguments = try? JSONDecoder().decode(Arguments.self, from: call.arguments)
            } else {
                failures.append("spark: no tool call")
            }
        } catch {
            failures.append("spark: \(error.localizedDescription)")
        }

        let answer = BrainAnswer(
            at: started, trigger: trigger.kind, attempt: attempt, gateScore: gateScore, sawScreen: jpeg != nil,
            tool: reply?.toolCall?.name, message: arguments?.message.flatMap { $0.isEmpty ? nil : $0 }, steps: arguments?.steps,
            latencyMs: Int(Date().timeIntervalSince(started) * 1000), model: spark.model,
            promptTokens: reply?.promptTokens, completionTokens: reply?.completionTokens,
            failure: failures.isEmpty ? nil : failures.joined(separator: "; ")
        )
        log.append(answer)
        return answer
    }

    private func present(_ answer: BrainAnswer, for trigger: Trigger, gateScore: Double?) {
        guard answer.tool != "stay_quiet", let text = answer.message else {
            finish()
            if answer.tool == "stay_quiet" { notch.stayedQuiet() }
            return
        }
        let gotIt = NotchChoice(label: "Got it", isPrimary: true) { [weak self] in self?.finish() }

        guard let steps = answer.steps, !steps.isEmpty, let bundleId = trigger.bundleId, TerminalText.terminals.contains(bundleId) else {
            show(NotchMessage(text: text, choices: [gotIt]))
            return
        }
        let plan = Plan(steps: steps, appBundleId: bundleId)
        let commands = steps.map { "`\($0.command)`" }.joined(separator: " → ")
        if let blocked = plan.blockedCommand {
            actions.record(.blocked, plan)
            show(NotchMessage(text: "\(text)\nRun `\(blocked)` yourself if you are sure.", choices: [gotIt]))
            return
        }
        actions.record(.proposed, plan)
        show(NotchMessage(text: "\(text)\n\(commands)", choices: [
            NotchChoice(label: "Not now", isPrimary: false) { [weak self] in
                self?.actions.record(.declined, plan)
                self?.finish()
            },
            NotchChoice(label: steps.count == 1 ? "Run it" : "Run \(steps.count) steps", isPrimary: true) { [weak self] in
                self?.run(plan, for: trigger, gateScore: gateScore, attempt: answer.attempt)
            },
        ]))
    }

    private func run(_ plan: Plan, for trigger: Trigger, gateScore: Double?, attempt: Int) {
        dismissal?.cancel()
        notch.act(steps: plan.steps.map(\.title))
        notch.highlight(actions.terminalFrame(of: plan))
        Task { @MainActor in
            let result = await actions.run(plan) { [weak self] index, ok in
                if ok { self?.notch.advance() } else { self?.notch.step(index, .failed) }
            }
            notch.highlight(nil)
            if result.succeeded {
                notch.done("Fixed")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.finish() }
            } else if let failed = result.failedStep, attempt < Self.maxAttempts {
                let retry = Trigger(
                    at: Date(), kind: .stuckOnError, app: trigger.app, bundleId: trigger.bundleId, windowTitle: trigger.windowTitle,
                    idleSeconds: 0, errorLine: failed.errorLine, errorSeconds: trigger.errorSeconds, terminalTail: result.terminalTail
                )
                try? await Task.sleep(nanoseconds: 900_000_000)
                ask(about: retry, gateScore: gateScore, attempt: attempt + 1)
            } else {
                show(NotchMessage(text: "Stopped: \(result.failure ?? result.failedStep?.errorLine ?? "a step failed").", choices: [
                    NotchChoice(label: "Got it", isPrimary: true) { [weak self] in self?.finish() },
                ]))
            }
        }
    }

    private func show(_ message: NotchMessage) {
        notch.show(message)
        dismissal?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finish() }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dismissAfter, execute: work)
    }

    private func finish() {
        dismissal?.cancel()
        busy = false
        notch.rest()
    }

    private static func noticeWord(for trigger: Trigger) -> String {
        switch trigger.kind {
        case .stuckOnError: return "Stuck?"
        case .terminalError: return "Error"
        case .idle: return "Still there?"
        case .appChanged: return "Hmm"
        }
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any]) -> [String: Any] {
        ["type": "function", "function": [
            "name": name, "description": description,
            "parameters": ["type": "object", "properties": properties, "required": Array(properties.keys)],
        ]]
    }
}
