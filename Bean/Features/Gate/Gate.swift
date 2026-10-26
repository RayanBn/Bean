import Foundation

struct GateDecision: Codable {
    let at: Date
    let trigger: Trigger.Kind
    let app: String?
    let errorLine: String?
    let score: Double?
    let stepIn: Bool
    let threshold: Double
    let rule: String?
    let latencyMs: Int
    let model: String
    let failure: String?
}

final class Gate {
    static let alwaysStepIn: Set<Trigger.Kind> = [.repeatedFailure, .searchingError]
    static let neverStepIn: Set<Trigger.Kind> = [.appChanged]

    static let system = """
    You are the gate of Bean, a discreet assistant that lives in the Mac notch. You get one event about what the user is doing. Decide whether Bean should interrupt the user right now to help.
    Say yes only when the user is likely stuck and Bean can clearly help: the same error has stayed on screen for minutes, tests keep failing for minutes, or the user is searching the web for an error message.
    Say no for normal work: switching apps, reading, browsing, writing code, chatting, a meeting, time away from the Mac, an error that just appeared (give the user time to read it), and output that mentions errors without anything failing.
    An unneeded interruption is worse than a missed one.
    """

    var onDecision: ((GateDecision, Trigger) -> Void)?

    private let models: [BeanSettings.GateProvider: GateModel]
    private let log: JSONLog

    init(cloud: GateModel, local: GateModel, log: JSONLog) {
        models = [.cloud: cloud, .local: local]
        self.log = log
    }

    var threshold: Double { BeanSettings.shared.effectiveThreshold }

    func judge(_ trigger: Trigger) {
        Task {
            let decision = await decide(trigger)
            await MainActor.run { self.onDecision?(decision, trigger) }
        }
    }

    func decide(_ trigger: Trigger) async -> GateDecision {
        let started = Date()
        let model = models[BeanSettings.shared.effectiveGateProvider]!
        let threshold = threshold
        var score: Double?
        var failure: String?
        let quietRule = Self.neverStepIn.contains(trigger.kind) ? trigger.kind.rawValue
            : trigger.inMeeting == true && BeanSettings.shared.quietInMeetings ? "inMeeting" : nil
        if let quietRule {
            let decision = GateDecision(at: started, trigger: trigger.kind, app: trigger.app, errorLine: trigger.errorLine, score: nil, stepIn: false, threshold: threshold, rule: quietRule, latencyMs: 0, model: model.name, failure: nil)
            log.append(decision)
            return decision
        }
        do {
            score = try await model.score(trigger)
            if score == nil { failure = "no usable answer from the gate model" }
        } catch {
            failure = error.localizedDescription
        }
        let rule = Self.alwaysStepIn.contains(trigger.kind) ? trigger.kind.rawValue : nil
        let decision = GateDecision(
            at: started, trigger: trigger.kind, app: trigger.app, errorLine: trigger.errorLine,
            score: score.map { ($0 * 1000).rounded() / 1000 }, stepIn: (score ?? 0) >= threshold || rule != nil, threshold: threshold,
            rule: rule, latencyMs: Int(Date().timeIntervalSince(started) * 1000), model: model.name, failure: failure
        )
        log.append(decision)
        return decision
    }
}
