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
    private let overlay = ScreenOverlay()
    private let panel: NotchPanel
    private var geometry = NotchGeometry.current()
    private var mouseMonitors: [Any] = []

    init() {
        let defaults = UserDefaults.standard
        if defaults.double(forKey: "statsDay") == Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 {
            model.quietCount = defaults.integer(forKey: "statsQuiet")
            model.steppedInToday = defaults.integer(forKey: "statsSteppedIn")
        }
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true

        let host = NotchHostingView(rootView: NotchView(model: model, onTap: { [weak self] in self?.tapped() }, toggle: { [weak self] in self?.toggleCard($0) }))
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
        if ["notice", "thinking"].contains(model.phase.key) { count(\.steppedInToday) }
        go(.message) {
            self.model.message = message
            self.model.messageID = UUID()
        }
    }

    func rest() {
        go(.rest)
    }

    func review(_ review: NotchReview) {
        if ["notice", "thinking"].contains(model.phase.key) { count(\.steppedInToday) }
        go(.review) {
            self.model.review = review
            self.model.reviewID = UUID()
        }
    }

    func recording(_ on: Bool) {
        guard model.recording != on else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { model.recording = on }
        if model.phase == .rest { apply(animated: true) }
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
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { count(\.quietCount) }
        if model.phase == .rest { apply(animated: true) }
    }

    private func toggleCard(_ id: UUID) {
        guard let i = model.review?.cards.firstIndex(where: { $0.id == id }) else { return }
        model.review?.cards[i].isOn.toggle()
    }

    private func tapped() {
        model.phase == .rest ? model.pokes += 1 : rest()
    }

    private func count(_ counter: ReferenceWritableKeyPath<NotchModel, Int>) {
        let defaults = UserDefaults.standard
        let today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        if defaults.double(forKey: "statsDay") != today {
            defaults.set(today, forKey: "statsDay")
            model.quietCount = 0
            model.steppedInToday = 0
        }
        model[keyPath: counter] += 1
        defaults.set(model.quietCount, forKey: "statsQuiet")
        defaults.set(model.steppedInToday, forKey: "statsSteppedIn")
    }

    private func adopt(_ geometry: NotchGeometry) {
        self.geometry = geometry
        panel.setFrame(geometry.frame(for: Self.canvas), display: false)
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
        model.contentSize = size
        withAnimation(animated ? (grows ? Self.growSpring : Self.shrinkSpring) : nil) {
            model.shape = target
        }
        trackMouse()
    }

    private func trackMouse() {
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
        var restEar: CGFloat {
            let count = model.quietCount > 0 ? NotchStyle.width(of: "\(model.quietCount)", size: 11, weight: .semibold) + 16 : 0
            return max(count + (model.recording ? 11 : 0), BeanEyes.ear)
        }
        let contentTop = top + (g.hasNotch ? 8 : 4)
        switch model.phase {
        case .rest:
            return compact(ear: restEar)
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
        case .review:
            return expanded(ReviewBody.width, contentTop + (model.review.map(ReviewBody.height) ?? 0) + 6)
        case .acting:
            return expanded(440, contentTop + 26 + CGFloat(model.steps.count) * 26 + 14)
        }
    }
}
