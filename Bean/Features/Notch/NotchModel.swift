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
    case create
    case message
}

struct CrewMember: Identifiable, Equatable {
    let id: UUID
    let name: String
    let look: Agent.Look
    let mood: AgentActivity.Mood
    var ring = false
}

struct AgentIdea: Identifiable, Equatable {
    var id: String { label }
    let label: String
    let request: String

    var hue: Double { AgentIdea.hue(for: request) }

    static func hue(for text: String) -> Double {
        let sum = text.lowercased().unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }
        return Double(sum % 1000) / 1000
    }
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
    @Published var draft = ""
    @Published var ideas: [AgentIdea] = []
    @Published var birth: Birth?
    @Published var newborn: UUID?
    @Published var hint: String?
    @Published var say: String?

    var topInset: CGFloat { notchSize.height }
    var showsPlus: Bool { crew.isEmpty || hovering }
    var shownCount: Int { min(crew.count, hovering ? CrewLayout.most : CrewLayout.shown) }
}
