import SwiftUI

struct RosterItem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let look: Agent.Look
    let mood: AgentActivity.Mood
    let line: String
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

final class NotchModel: ObservableObject {
    @Published var crew: [CrewMember] = []
    @Published var bean: CrewMember?
    @Published var lifted: UUID?
    @Published var shape = NotchShape.Metrics()
    @Published var hasNotch = true
    @Published var notchSize: CGSize = .zero
    @Published var listOpen = false
    @Published var roster: [RosterItem] = []
    @Published var gaze: CGSize?
    @Published var calling: Color?
    @Published var birth: Birth?
    @Published var newborn: UUID?

    var topInset: CGFloat { notchSize.height }
    var showsPlus: Bool { crew.isEmpty }
    var shownCount: Int { min(crew.count, CrewLayout.shown) }
}
