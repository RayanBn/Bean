import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class NotchModel: ObservableObject {
    enum State { case rest, expanded }
    @Published var state: State = .rest
    @Published var message = "Bean is here. I'll speak up only when I can help."
}

final class NotchController {
    static let earWidth: CGFloat = 14
    static let expandedSize = CGSize(width: 520, height: 170)

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

    func toggle() {
        model.state = model.state == .rest ? .expanded : .rest
        layout(animated: true)
    }

    private func layout(animated: Bool) {
        let size = model.state == .rest ? restSize : Self.expandedSize
        panel.setFrame(geometry.frame(for: size), display: true, animate: animated)
    }

    private var restSize: CGSize {
        geometry.hasNotch
            ? CGSize(width: geometry.notchSize.width + 2 * Self.earWidth, height: geometry.notchSize.height)
            : geometry.notchSize
    }
}
