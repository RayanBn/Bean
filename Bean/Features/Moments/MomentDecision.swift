import Foundation

// Code, not the model, decides whether a yes is needed. Any yes: ask. All no: do it, say so in one line, offer undo.
struct ThreeQuestions: Equatable {
    var newSource = false
    var someoneElse = false
    var cannotUndo = false

    var anyYes: Bool { newSource || someoneElse || cannotUndo }

    static func ask(about moment: Moment, answer: MomentAnswer, readingYes: Bool) -> ThreeQuestions {
        var questions = ThreeQuestions()
        questions.newSource = moment.kind != .service && !readingYes
        if answer.needs == .hearCall {
            questions.newSource = true
            questions.someoneElse = true
        }
        switch AppGuard.risk(in: answer.result) {
        case .send?: questions.someoneElse = true
        case .delete?, .buy?, .consent?: questions.cannotUndo = true
        case nil: break
        }
        return questions
    }
}

struct MomentOffer: Equatable, Identifiable {
    enum Kind: Equatable { case proposal, keepDoing }

    let id: UUID
    let kind: Kind
    let moment: Moment
    let result: String
    let saw: String
    let because: String
    let answers: [String]
    let words: [String]
    let needs: MomentAnswer.Needs
    let when: MomentAnswer.When
    var startsWork = true
    var shownAt: Date?

    static let yes = "Yes"
    static let notNow = "Not now"
    static let never = "Never here"
    static let keepDoing = "Keep doing it"
}

enum MomentOutcome: Equatable {
    case quiet(String)
    case remember(String, words: [String])
    case rejected(String)
    case ask(MomentOffer)
    case act(result: String, words: [String], needs: MomentAnswer.Needs, sayIt: Bool)
}

enum MomentDecision {
    private static func words(for moment: Moment, job: MomentJob?, answer: MomentAnswer) -> [String] {
        job?.words ?? MomentKey.words(modelKey: answer.key, moment: moment)
    }

    // A pure function of the moment, the proposal and what is known. It holds no tool, so a proposal cannot do anything by itself.
    static func decide(_ moment: Moment, answer: MomentAnswer, job: MomentJob?, readingYes: Bool, sealed: Skill? = nil, id: UUID = UUID()) -> MomentOutcome {
        let words = words(for: moment, job: job, answer: answer)
        switch answer.verdict {
        case .ignore: return .quiet(answer.saw)
        case .remember: return .remember(answer.saw, words: words)
        case .offer, .place: break
        }
        guard answer.isUsable else { return .rejected("no result or nothing seen") }
        if let sealed {
            guard let fixed = sealed.offer else { return .rejected("an agent cannot do this on this window") }
            return .ask(MomentOffer(id: id, kind: .proposal, moment: moment, result: fixed, saw: answer.saw, because: moment.because,
                                    answers: [MomentOffer.yes, MomentOffer.notNow, MomentOffer.never], words: words, needs: .actInWindow,
                                    when: answer.when == .whenBack ? .whenBack : .nextPause, startsWork: false))
        }
        let questions = ThreeQuestions.ask(about: moment, answer: answer, readingYes: readingYes)
        if questions.anyYes || (job.map { $0.step <= .offer } ?? false) {
            return .ask(MomentOffer(id: id, kind: .proposal, moment: moment, result: answer.result, saw: answer.saw, because: moment.because,
                                    answers: [MomentOffer.yes, MomentOffer.notNow, MomentOffer.never], words: words, needs: answer.needs,
                                    when: answer.when == .whenBack ? .whenBack : .nextPause))
        }
        return .act(result: answer.result, words: words, needs: answer.needs, sayIt: job?.step != .aloneQuiet)
    }
}

// How much Bean may say. Internal, never shown, and it never holds back a call or an answer to the person's own question.
struct MomentDose: Codable, Equatable {
    var offers: [Date] = []
    var questions: [Date] = []
    var ignoredInARow = 0

    private var factor: Double { ignoredInARow >= 2 ? 2 : 1 }

    func mayOffer(now: Date, rules: MomentRules) -> Bool {
        let today = offers.filter { Calendar.current.isDate($0, inSameDayAs: now) }
        if Double(today.count) * factor >= Double(rules.offersPerDay) { return false }
        guard let last = offers.last else { return true }
        return now.timeIntervalSince(last) >= rules.offerEveryMinutes * 60 * factor
    }

    func mayAsk(now: Date, rules: MomentRules) -> Bool {
        questions.filter { Calendar.current.isDate($0, inSameDayAs: now) }.count < rules.questionsPerDay
    }

    mutating func keepRecent(now: Date) {
        let day = now.addingTimeInterval(-86400 * 2)
        offers.removeAll { $0 < day }
        questions.removeAll { $0 < day }
    }
}
