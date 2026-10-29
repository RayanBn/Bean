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
    case notice(String)
    case thinking(String?)
    case message
    case done(String)

    var key: String {
        switch self {
        case .rest: "rest"
        case .notice: "notice"
        case .thinking: "thinking"
        case .message: "message"
        case .done: "done"
        }
    }
}

final class NotchModel: ObservableObject {
    @Published var phase: NotchPhase = .rest
    @Published var message = NotchMessage(text: "Bean is here. I'll speak up only when I can help.", choices: [])
    @Published var messageID = UUID()
    @Published var pokes = 0
    @Published var shape = NotchShape.Metrics()
    @Published var contentSize: CGSize = .zero
    @Published var hasNotch = true
    @Published var notchSize: CGSize = .zero

    var topInset: CGFloat { notchSize.height }
}
