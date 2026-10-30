import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class NotchHostingView<Content: View>: NSHostingView<Content> {
    var onSecondaryClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) { onSecondaryClick?() }
}

final class NotchController {
    static let compactFlare: CGFloat = 6
    static let expandedFlare: CGFloat = 14
    static let growSpring = Animation.spring(response: 0.45, dampingFraction: 0.72)
    static let shrinkSpring = Animation.spring(response: 0.34, dampingFraction: 0.86)
    static let canvas = CGSize(width: 640, height: 520)

    let model = NotchModel()
    var onSecondaryClick: ((NSView, NSRect) -> Void)?
    var onRestClick: (() -> Void)?
    var onCrewGesture: ((UUID, CrewGesture) -> Void)?
    private let panel: NotchPanel
    private var geometry = NotchGeometry.current()
    private var mouseMonitors: [Any] = []

    init() {
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true

        let host = NotchHostingView(rootView: NotchView(model: model, onTap: { [weak self] in self?.tapped() },
                                                    onCrew: { [weak self] id, gesture in self?.crewGesture(id, gesture) }))
        host.sizingOptions = []
        host.onSecondaryClick = { [weak self, weak host] in
            guard let self, let host, let open = self.onSecondaryClick else { return }
            let w = self.model.shape.width, h = self.model.shape.height
            let island = NSRect(x: (host.bounds.width - w) / 2, y: host.isFlipped ? 0 : host.bounds.height - h, width: w, height: h)
            open(host, island)
        }
        panel.contentView = host
        adopt(geometry)
        apply(animated: false)
        panel.orderFrontRegardless()

        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        mouseMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in self?.trackMouse() },
            NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in self?.trackMouse(); return event },
        ].compactMap { $0 }

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

    func hideFromCapture(_ hidden: Bool) {
        panel.sharingType = hidden ? .none : .readOnly
    }

    func notice(_ word: String) {
        go(.notice(word))
    }

    func done(_ text: String) {
        go(.done(text))
    }

    var islandFrame: NSRect {
        geometry.frame(for: CGSize(width: model.shape.width, height: model.shape.height))
    }

    func setCrew(_ crew: [CrewMember]) {
        guard crew != model.crew else { return }
        let resize = crew.count != model.crew.count
        model.crew = crew
        if resize && model.phase == .rest { apply(animated: true) }
    }

    func lift(_ id: UUID?) {
        model.lifted = id
        trackMouse()
    }

    func headPoint(for id: UUID) -> NSPoint {
        let index = min(model.crew.firstIndex { $0.id == id } ?? model.crew.count, CrewLayout.shown - 1)
        let c = CrewLayout.center(index: index, notch: model.notchSize)
        let top = geometry.frame(for: CGSize(width: 0, height: model.notchSize.height)).maxY
        return NSPoint(x: geometry.screen.frame.midX + c.x, y: top - c.y)
    }

    var headSize: CGFloat { CrewLayout.headSize(model.notchSize) }

    private func crewGesture(_ id: UUID, _ gesture: CrewGesture) {
        onCrewGesture?(id, gesture)
    }

    private func tapped() {
        guard model.phase == .rest else { return rest() }
        model.pokes += 1
        onRestClick?()
    }

    private func adopt(_ geometry: NotchGeometry) {
        self.geometry = geometry
        panel.setFrame(geometry.frame(for: Self.canvas), display: false)
        model.hasNotch = geometry.hasNotch
        model.notchSize = geometry.notchSize
    }

    private func go(_ phase: NotchPhase, update: () -> Void = {}) {
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
        model.contentSize = size
        withAnimation(animated ? (grows ? Self.growSpring : Self.shrinkSpring) : nil) {
            model.shape = target
        }
        trackMouse()
    }

    private func trackMouse() {
        if model.lifted != nil { return }
        let island = geometry.frame(for: CGSize(width: model.shape.width, height: model.shape.height))
        let outside = !island.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents != outside { panel.ignoresMouseEvents = outside }
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
        func ear(for text: String, icon: CGFloat = 0) -> CGFloat {
            max(NotchStyle.width(of: text, size: 13, weight: .semibold) + icon + 22, BeanEyes.ear)
        }
        let contentTop = top + (g.hasNotch ? 8 : 4)
        switch model.phase {
        case .rest:
            return compact(ear: max(BeanEyes.ear, CrewLayout.ear(count: model.crew.count, notch: g.notchSize)))
        case .notice(let word):
            return compact(ear: ear(for: word))
        case .done(let text):
            return compact(ear: ear(for: text, icon: 21))
        case .thinking:
            return expanded(380, contentTop + 22 + 14)
        case .message:
            let textWidth: CGFloat = 520 - 40
            let text = NotchStyle.height(of: model.message.text, size: MessageBody.textSize, width: textWidth)
            let buttons: CGFloat = model.message.choices.isEmpty ? 0 : 8 + 6 + 28
            return expanded(520, contentTop + 16 + 8 + text + buttons + 16)
        }
    }
}
