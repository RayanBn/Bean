import Foundation

struct BrainAnswer: Codable {
    let at: Date
    let trigger: Trigger.Kind
    let gateScore: Double?
    let sawScreen: Bool
    let stayQuiet: Bool?
    let message: String?
    let latencyMs: Int
    let model: String
    let promptTokens: Int?
    let completionTokens: Int?
    let failure: String?
}

final class Brain {
    static let system = """
    You are Bean, a discreet butler that lives in the notch of the user's Mac. A local model noticed that the user may need help. You get what triggered it and a screenshot of the screen.
    If you can genuinely help right now, write one short message for the notch: at most two sentences and 220 characters, naming the concrete cause and the concrete fix, like a senior colleague leaning over the desk. Quote the exact file, command or line when you can. No greetings, no generic advice.
    If you cannot tell what is wrong, or interrupting would not be worth it, set stayQuiet to true and leave message empty.
    """
    static let schema: [String: Any] = [
        "type": "object",
        "properties": ["stayQuiet": ["type": "boolean"], "message": ["type": "string"]],
        "required": ["stayQuiet", "message"],
        "additionalProperties": false,
    ]
    static let dismissAfter: TimeInterval = 30

    private let spark: MuseSpark
    private let notch: NotchController
    private let log: JSONLog
    private var busy = false
    private var dismissal: DispatchWorkItem?

    init(spark: MuseSpark, notch: NotchController, log: JSONLog) {
        self.spark = spark
        self.notch = notch
        self.log = log
    }

    func consider(_ decision: GateDecision, _ trigger: Trigger) {
        guard decision.stepIn, !busy else { return }
        busy = true
        notch.think()
        Task {
            let answer = await think(about: trigger, gateScore: decision.score)
            await MainActor.run { self.present(answer) }
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
        var parsed: (stayQuiet: Bool, message: String)?
        do {
            let response = try await spark.complete(system: Self.system, text: trigger.summary, jpeg: jpeg, schema: Self.schema)
            reply = response
            struct Output: Decodable { let stayQuiet: Bool; let message: String }
            let output = try JSONDecoder().decode(Output.self, from: response.json)
            parsed = (output.stayQuiet, output.message)
        } catch {
            failures.append("spark: \(error.localizedDescription)")
        }

        let answer = BrainAnswer(
            at: started, trigger: trigger.kind, gateScore: gateScore, sawScreen: jpeg != nil,
            stayQuiet: parsed?.stayQuiet, message: parsed?.message.isEmpty == false ? parsed?.message : nil,
            latencyMs: Int(Date().timeIntervalSince(started) * 1000), model: spark.model,
            promptTokens: reply?.promptTokens, completionTokens: reply?.completionTokens,
            failure: failures.isEmpty ? nil : failures.joined(separator: "; ")
        )
        log.append(answer)
        return answer
    }

    private func present(_ answer: BrainAnswer) {
        busy = false
        guard answer.stayQuiet == false, let text = answer.message else {
            notch.rest()
            return
        }
        notch.show(NotchMessage(text: text, choices: [NotchChoice(label: "Got it", isPrimary: true) { [weak self] in self?.dismiss() }]))
        dismissal?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.notch.rest() }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dismissAfter, execute: work)
    }

    private func dismiss() {
        dismissal?.cancel()
        notch.rest()
    }
}
