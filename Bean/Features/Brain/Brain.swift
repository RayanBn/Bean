import Foundation

struct BrainAnswer: Codable {
    let at: Date
    let trigger: Trigger.Kind
    let gateScore: Double?
    let sawScreen: Bool
    let tool: String?
    let message: String?
    let command: String?
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
    - propose_command when one shell command, run in the terminal the user is using, would fix the problem or move it forward. Bean shows it and runs it only after the user confirms.
    - show_message when you can name the cause and the fix but it is not a single safe command.
    - stay_quiet when you cannot tell what is wrong, or interrupting would not be worth it.
    Messages: at most two sentences and 220 characters, naming the concrete cause and fix like a senior colleague leaning over the desk. Quote the exact file, command or line. No greetings, no generic advice.
    Never propose sudo, rm -rf, force pushes, or anything that deletes data or touches the system.
    """
    static let tools: [[String: Any]] = [
        tool("propose_command", "Propose one shell command to run in the user's terminal after they confirm.", [
            "message": ["type": "string", "description": "Why this fixes it, for the notch. At most 220 characters."],
            "command": ["type": "string", "description": "One single-line shell command."],
        ]),
        tool("show_message", "Show a short message in the notch.", [
            "message": ["type": "string", "description": "At most 220 characters."],
        ]),
        tool("stay_quiet", "Do not interrupt the user.", [:]),
    ]
    static let dismissAfter: TimeInterval = 30

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
        guard decision.stepIn, !busy else { return }
        busy = true
        notch.think()
        Task {
            let answer = await think(about: trigger, gateScore: decision.score)
            await MainActor.run { self.present(answer, for: trigger) }
        }
    }

    private func think(about trigger: Trigger, gateScore: Double?) async -> BrainAnswer {
        let started = Date()
        var failures: [String] = []
        var jpeg: Data?
        do {
            jpeg = try await ScreenCapture.mainDisplayJPEG()
        } catch {
            failures.append("capture: \(error.localizedDescription)")
        }

        var reply: MuseSpark.Reply?
        var arguments: [String: String] = [:]
        do {
            let response = try await spark.complete(system: Self.system, text: trigger.summary, jpeg: jpeg, tools: Self.tools)
            reply = response
            if let call = response.toolCall {
                arguments = (try? JSONDecoder().decode([String: String].self, from: call.arguments)) ?? [:]
            } else {
                failures.append("spark: no tool call")
            }
        } catch {
            failures.append("spark: \(error.localizedDescription)")
        }

        let answer = BrainAnswer(
            at: started, trigger: trigger.kind, gateScore: gateScore, sawScreen: jpeg != nil,
            tool: reply?.toolCall?.name, message: arguments["message"].flatMap { $0.isEmpty ? nil : $0 }, command: arguments["command"],
            latencyMs: Int(Date().timeIntervalSince(started) * 1000), model: spark.model,
            promptTokens: reply?.promptTokens, completionTokens: reply?.completionTokens,
            failure: failures.isEmpty ? nil : failures.joined(separator: "; ")
        )
        log.append(answer)
        return answer
    }

    private func present(_ answer: BrainAnswer, for trigger: Trigger) {
        busy = false
        guard answer.tool != "stay_quiet", let text = answer.message else {
            notch.rest()
            return
        }
        let gotIt = NotchChoice(label: "Got it", isPrimary: answer.command == nil) { [weak self] in self?.dismiss() }

        guard let command = answer.command, let bundleId = trigger.bundleId, TriggerDetector.terminals.contains(bundleId) else {
            show(NotchMessage(text: text, choices: [gotIt]))
            return
        }
        let action = TerminalCommand(command: command, appBundleId: bundleId)
        if action.isBlocked {
            actions.record(.blocked, action)
            show(NotchMessage(text: "\(text)\n`\(command)` — run it yourself if you are sure.", choices: [gotIt]))
            return
        }
        actions.record(.proposed, action)
        show(NotchMessage(text: text.contains(command) ? text : "\(text)\n`\(command)`", choices: [
            NotchChoice(label: "Not now", isPrimary: false) { [weak self] in
                self?.actions.record(.declined, action)
                self?.dismiss()
            },
            NotchChoice(label: "Run it", isPrimary: true) { [weak self] in self?.run(action) },
        ]))
    }

    private func run(_ action: TerminalCommand) {
        dismissal?.cancel()
        notch.think()
        Task {
            let failure = await actions.run(action)
            await MainActor.run {
                if let failure {
                    self.show(NotchMessage(text: "Could not run it: \(failure).", choices: []), for: 6)
                } else {
                    self.notch.rest()
                }
            }
        }
    }

    private func show(_ message: NotchMessage, for seconds: TimeInterval = Brain.dismissAfter) {
        notch.show(message)
        dismissal?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.notch.rest() }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func dismiss() {
        dismissal?.cancel()
        notch.rest()
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any]) -> [String: Any] {
        ["type": "function", "function": [
            "name": name, "description": description,
            "parameters": ["type": "object", "properties": properties, "required": Array(properties.keys)],
        ]]
    }
}
