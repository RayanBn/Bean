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

struct NotchStep: Identifiable {
    enum Status { case pending, running, done, failed }
    let id = UUID()
    let title: String
    var status: Status
}

enum NotchPhase: Equatable {
    case rest
    case notice(String)
    case thinking(String?)
    case message
    case review
    case acting
    case done(String)

    var key: String {
        switch self {
        case .rest: "rest"
        case .notice: "notice"
        case .thinking: "thinking"
        case .message: "message"
        case .review: "review"
        case .acting: "acting"
        case .done: "done"
        }
    }
}

final class NotchModel: ObservableObject {
    @Published var phase: NotchPhase = .rest
    @Published var message = NotchMessage(text: "Bean is here. I'll speak up only when I can help.", choices: [])
    @Published var messageID = UUID()
    @Published var steps: [NotchStep] = []
    @Published var review: NotchReview?
    @Published var reviewID = UUID()
    @Published var recording = false
    @Published var quietCount = 0
    @Published var steppedInToday = 0
    @Published var pokes = 0
    @Published var shape = NotchShape.Metrics()
    @Published var contentSize: CGSize = .zero
    @Published var hasNotch = true
    @Published var notchSize: CGSize = .zero

    var topInset: CGFloat { notchSize.height }
}
