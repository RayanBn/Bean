import SwiftUI

struct NotchChoice: Identifiable {
    let id = UUID()
    let label: String
    let isPrimary: Bool
    let action: () -> Void
}

struct NotchMessage {
    let text: String
    let choices: [NotchChoice]
}

enum NotchPhase: Equatable {
    case rest
    case message
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
    @Published var phase: NotchPhase = .rest
    @Published var message = NotchMessage(text: "", choices: [])
    @Published var messageID = UUID()
    @Published var shape = NotchShape.Metrics()
    @Published var contentSize: CGSize = .zero
    @Published var hasNotch = true
    @Published var notchSize: CGSize = .zero
    @Published var hovering = false
    @Published var gaze: CGSize?
    @Published var calling: Color?
    @Published var birth: Birth?
    @Published var newborn: UUID?

    var topInset: CGFloat { notchSize.height }
    var showsPlus: Bool { crew.isEmpty || hovering }
    var shownCount: Int { min(crew.count, hovering ? CrewLayout.most : CrewLayout.shown) }
}
