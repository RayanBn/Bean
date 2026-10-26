import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class NotchController {
    static let restEar: CGFloat = 22
    static let compactFlare: CGFloat = 6
    static let expandedFlare: CGFloat = 14
    static let growSpring = Animation.spring(response: 0.45, dampingFraction: 0.72)
    static let shrinkSpring = Animation.spring(response: 0.34, dampingFraction: 0.86)
    static let overshoot = CGSize(width: 24, height: 16)

    let model = NotchModel()
    private let overlay = ScreenOverlay()
    private let panel: NotchPanel
    private var geometry = NotchGeometry.current()
    private var generation = 0

    init() {
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false

        let host = NotchHostingView(rootView: NotchView(model: model) { [weak self] in self?.tapped() })
        host.sizingOptions = []
        panel.contentView = host
        adopt(geometry)
        apply(animated: false)
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.adopt(NotchGeometry.current())
            self.apply(animated: false)
        }
    }

    func think(_ text: String? = nil) {
        go(.thinking(text))
    }

    func show(_ message: NotchMessage) {
        go(.message) {
            self.model.message = message
            self.model.messageID = UUID()
        }
    }

    func rest() {
        go(.rest)
    }

    func notice(_ word: String) {
        go(.notice(word))
    }

    func act(steps: [String]) {
        overlay.takeControl(below: panel)
        go(.acting) {
            self.model.steps = steps.enumerated().map { NotchStep(title: $1, status: $0 == 0 ? .running : .pending) }
        }
    }

    func advance() {
        guard let i = model.steps.firstIndex(where: { $0.status == .running }) else { return }
        step(i, .done)
        if i + 1 < model.steps.count { step(i + 1, .running) }
    }

    func step(_ index: Int, _ status: NotchStep.Status) {
        guard model.steps.indices.contains(index) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { model.steps[index].status = status }
    }

    func highlight(_ globalRect: CGRect?) {
        overlay.highlight(globalRect)
    }

    func done(_ text: String) {
        go(.done(text))
    }

    func stayedQuiet() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { model.quietCount += 1 }
    }

    private func tapped() {
        model.phase == .rest ? go(.message) : rest()
    }

    private func adopt(_ geometry: NotchGeometry) {
        self.geometry = geometry
        overlay.place(on: geometry.screen)
        model.hasNotch = geometry.hasNotch
        model.notchSize = geometry.notchSize
    }

    private func go(_ phase: NotchPhase, update: () -> Void = {}) {
        if phase != .acting { overlay.release() }
        withAnimation(.default) {
            update()
            model.phase = phase
        }
        apply(animated: true)
    }

    private func apply(animated: Bool) {
        let target = targetMetrics()
        let size = CGSize(width: target.width, height: target.height)
        let grows = size.width >= model.shape.width && size.height >= model.shape.height
        generation += 1
        let current = panel.frame.size
        let window = animated
            ? CGSize(width: max(current.width, size.width + Self.overshoot.width), height: max(current.height, size.height + Self.overshoot.height))
            : size
        panel.setFrame(geometry.frame(for: window), display: true)
        model.contentSize = size
        withAnimation(animated ? (grows ? Self.growSpring : Self.shrinkSpring) : nil) {
            model.shape = target
        }
        guard animated else { return }
        let settled = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.generation == settled else { return }
            self.panel.setFrame(self.geometry.frame(for: size), display: true)
        }
    }

    private func targetMetrics() -> NotchShape.Metrics {
        let g = geometry
        let top = model.topInset
        let compactHeight = g.notchSize.height
        func compact(ear: CGFloat) -> NotchShape.Metrics {
            let f = g.hasNotch ? Self.compactFlare : 0
            return .init(width: g.notchSize.width + 2 * ear + 2 * f, height: compactHeight,
                         radius: g.hasNotch ? 10 : compactHeight / 2, flare: f)
        }
        func expanded(_ width: CGFloat, _ height: CGFloat) -> NotchShape.Metrics {
            let f = g.hasNotch ? Self.expandedFlare : 0
            return .init(width: width + 2 * f, height: height, radius: 24, flare: f)
        }
        func ear(for text: String) -> CGFloat {
            max(NotchStyle.width(of: text, size: 13, weight: .semibold) + 26, 44)
        }
        let contentTop = top + (g.hasNotch ? 8 : 14)
        switch model.phase {
        case .rest:
            return compact(ear: Self.restEar)
        case .notice(let word):
            return compact(ear: ear(for: word))
        case .done(let text):
            return compact(ear: ear(for: text))
        case .thinking:
            return expanded(380, contentTop + 22 + 14)
        case .message:
            let textWidth: CGFloat = 520 - 40
            let text = NotchStyle.height(of: model.message.text, size: MessageBody.textSize, width: textWidth)
            let buttons: CGFloat = model.message.choices.isEmpty ? 0 : 8 + 6 + 28
            return expanded(520, contentTop + 16 + 8 + text + buttons + 16)
        case .acting:
            return expanded(440, contentTop + 26 + CGFloat(model.steps.count) * 26 + 14)
        }
    }
}
