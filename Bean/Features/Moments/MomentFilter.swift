import Foundation

// Strands removes the obvious and keeps private titles on the Mac. It never decides to interrupt: that takes a model's result and code's three questions.
enum MomentFilter {
    enum Verdict: Equatable {
        case pass(Double?)
        case dropped(Double)
        case keptPrivate
        case noCheck
    }

    static let question = "Is this person in the middle of work where an assistant could finish a concrete part for them now?"

    static func card(_ moment: Moment, knows: String) -> String {
        "\(moment.card)\nWhat Bean knows about this person: \(knows)\nAgent on this window: none."
    }

    static func look(at moment: Moment, knows: String, rules: MomentRules = .starting) async -> Verdict {
        if PrivateCheck.filterIsOff { return .pass(nil) }
        let unchecked: Verdict = moment.kind == .service ? .pass(nil) : .noCheck
        switch await PrivateCheck.titleVerdict(moment.title) {
        case .privateTitle: return .keptPrivate
        case .noCheck: return unchecked
        case .open: break
        }
        guard moment.kind != .call else { return .pass(nil) }
        guard PrivateCheck.canCheckTitles, let score = await StrandsDecider.score(state: card(moment, knows: knows), question: question) else { return unchecked }
        return score >= rules.filterAtLeast ? .pass(score) : .dropped(score)
    }
}
