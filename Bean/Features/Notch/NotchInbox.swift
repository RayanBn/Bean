import Foundation

struct NotchAnswer: Equatable {
    enum Kind { case yes, notNow, never, other }
    let title: String
    var kind = Kind.other

    static let yes = NotchAnswer(title: "Yes", kind: .yes)
    static let notNow = NotchAnswer(title: "Not now", kind: .notNow)
}

struct NotchOffer: Identifiable, Equatable {
    enum Urgency { case atPause, now }
    var id = UUID()
    var agent: UUID?
    let result: String
    let saw: String
    var answers = [NotchAnswer.yes, .notNow]
    var urgency = Urgency.atPause
    var expires: Date?
}

struct NotchReport: Identifiable, Equatable {
    struct Item: Identifiable, Equatable {
        var id = UUID()
        let text: String
        var undo: (() -> Void)?

        static func == (a: Item, b: Item) -> Bool { a.id == b.id }
    }

    struct Action: Identifiable, Equatable {
        var id = UUID()
        let title: String
        let run: () -> Void

        static func == (a: Action, b: Action) -> Bool { a.id == b.id }
    }

    enum Tone { case plain, working, done }

    var id = UUID()
    let line: String
    var link: URL?
    var items: [Item] = []
    var actions: [Action] = []
    var tone = Tone.plain
    var isReturn = false

    static func == (a: NotchReport, b: NotchReport) -> Bool { a.id == b.id }
}

@MainActor
final class NotchInbox: ObservableObject {
    static let shared = NotchInbox()

    @Published private(set) var offers: [NotchOffer] = []
    var onReport: ((NotchReport) -> Void)?
    private var replies: [UUID: (NotchAnswer?) -> Void] = [:]

    func offer(_ offer: NotchOffer, onAnswer: @escaping (NotchAnswer?) -> Void) {
        guard !offers.contains(where: { $0.id == offer.id }) else { return }
        offers.append(offer)
        replies[offer.id] = onAnswer
    }

    func report(_ report: NotchReport) {
        onReport?(report)
    }

    func withdraw(_ id: UUID) {
        offers.removeAll { $0.id == id }
        replies[id] = nil
    }

    func settle(_ id: UUID, with answer: NotchAnswer?) {
        let reply = replies[id]
        withdraw(id)
        reply?(answer)
    }

    func expire(at now: Date) {
        for offer in offers where offer.expires.map({ $0 <= now }) == true { settle(offer.id, with: nil) }
    }
}
