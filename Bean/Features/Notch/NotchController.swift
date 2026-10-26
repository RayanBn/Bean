import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

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

final class NotchModel: ObservableObject {
    enum State { case rest, thinking, message }
    @Published var state: State = .rest
    @Published var message = NotchMessage(text: "Bean is here. I'll speak up only when I can help.", choices: [])
}

final class NotchController {
    static let earWidth: CGFloat = 14
    static let thinkingSize = CGSize(width: 300, height: 44)
    static let messageSize = CGSize(width: 520, height: 170)

    let model = NotchModel()
    private let panel: NotchPanel
    private var geometry = NotchGeometry.current()

    init() {
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false

        let view = NotchView(model: model, notchSize: geometry.notchSize, hasNotch: geometry.hasNotch) { [weak self] in
            self?.toggle()
        }
        panel.contentView = NSHostingView(rootView: view)
        layout(animated: false)
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.geometry = NotchGeometry.current()
            self.layout(animated: false)
        }
    }

    func think() {
        set(.thinking)
    }

    func show(_ message: NotchMessage) {
        model.message = message
        set(.message)
    }

    func rest() {
        set(.rest)
    }

    private func toggle() {
        set(model.state == .rest ? .message : .rest)
    }

    private func set(_ state: NotchModel.State) {
        model.state = state
        layout(animated: true)
    }

    private func layout(animated: Bool) {
        let size: CGSize
        switch model.state {
        case .rest: size = restSize
        case .thinking: size = Self.thinkingSize
        case .message: size = Self.messageSize
        }
        panel.setFrame(geometry.frame(for: size), display: true, animate: animated)
    }

    private var restSize: CGSize {
        geometry.hasNotch
            ? CGSize(width: geometry.notchSize.width + 2 * Self.earWidth, height: geometry.notchSize.height)
            : geometry.notchSize
    }
}
