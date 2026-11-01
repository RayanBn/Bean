import SwiftUI

struct RosterItem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let look: Agent.Look
    let mood: AgentActivity.Mood
    let line: String
    var place: String?
    var app: pid_t?
}

struct CrewMember: Identifiable, Equatable {
    let id: UUID
    let name: String
    let look: Agent.Look
    let mood: AgentActivity.Mood
}

struct Birth: Equatable {
    let id: UUID
    let hue: Double
    let start: Date
    static let delay = 0.3
    static let duration = 0.9
}

struct NotchPip: Identifiable, Equatable {
    let id: UUID
    let look: Agent.Look
    let working: Bool
}

struct NotchCard: Identifiable, Equatable {
    struct Choice: Identifiable, Equatable {
        let title: String
        let answer: String
        var detail: String?
        var id: String { answer }
    }

    enum Source: Equatable {
        case need(agent: UUID, need: UUID)
        case offer(UUID)
    }

    let id: UUID
    let source: Source
    let name: String
    let look: Agent.Look
    let title: String
    let saw: String?
    let choices: [Choice]
    var urgent = false
    var replies = false
    var offersOther = false
    var settings: URL?
    var connector: String?

    var agent: UUID? {
        if case .need(let agent, _) = source { return agent }
        return nil
    }

    var truncates: Bool { choices.contains { $0.title.count > 100 } || choices.count > 4 }

    var stacked: Bool {
        let titles = choices.map { $0.title.count }
        return choices.count > 3 || titles.reduce(0, +) > 34 || titles.contains { $0 > 22 } || choices.contains { $0.detail != nil }
    }
}

enum NotchSurface: Equatable {
    case rest
    case list
    case compose
    case making(String)
    case ready(RosterItem)
    case card(NotchCard, more: Int)
    case line(NotchReport)
    case report(NotchReport)

    var isOpen: Bool { self != .rest }
    var takesKeys: Bool { self == .compose }
}

final class NotchModel: ObservableObject {
    @Published var crew: [CrewMember] = []
    @Published var bean: CrewMember?
    @Published var lifted: UUID?
    @Published var shape = NotchShape.Metrics()
    @Published var hasNotch = true
    @Published var notchSize: CGSize = .zero
    @Published var surface = NotchSurface.rest
    @Published var roster: [RosterItem] = []
    @Published var gaze: CGSize?
    @Published var calling: Color?
    @Published var birth: Birth?
    @Published var newborn: UUID?
    @Published var pips: [NotchPip] = []
    @Published var waiting = 0
    @Published var doneMark = false
    @Published var draft = ""
    @Published var composeError: String?
    @Published var contentHeight: CGFloat = 0

    var topInset: CGFloat { notchSize.height }
    var showsPlus: Bool { true }
    var shownCount: Int { min(crew.count, CrewLayout.shown) }
}
