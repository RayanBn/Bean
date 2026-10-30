import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class NotchHostingView<Content: View>: NSHostingView<Content> {
    var onSecondaryClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) { onSecondaryClick?() }
}

final class NotchController {
    static let compactFlare: CGFloat = 6
    static let expandedFlare: CGFloat = 14
    static let growSpring = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let shrinkSpring = Animation.spring(response: 0.34, dampingFraction: 0.9)
    static let canvas = CGSize(width: 640, height: 520)
    static let createWidth: CGFloat = 460
    static let level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

    let model = NotchModel()
    var onSecondaryClick: ((NSView, NSRect) -> Void)?
    var onCreate: ((String) -> Void)?
    var onCrewGesture: ((UUID, CrewGesture) -> Void)?
    private let panel: NotchPanel
    private var geometry = NotchGeometry.current()
    private var mouseMonitors: [Any] = []
    private var outsideClicks: Any?
    private var hintTimer: DispatchWorkItem?

    init() {
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NotchController.level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true

        let host = NotchHostingView(rootView: NotchView(model: model,
                                                        onTap: { [weak self] in self?.tapped() },
                                                        onCrew: { [weak self] id, gesture in self?.crewGesture(id, gesture) },
                                                        onPlus: { [weak self] in self?.beginCreate() },
                                                        onSubmit: { [weak self] text in self?.submit(text) },
                                                        onCancel: { [weak self] in self?.endCreate() }))
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

    var islandFrame: NSRect {
        geometry.frame(for: CGSize(width: model.shape.width, height: model.shape.height))
    }

    func setCrew(_ crew: [CrewMember]) {
        guard crew != model.crew else { return }
        let resize = crew.count != model.crew.count
        model.crew = crew
        if model.newborn.map({ id in !crew.contains { $0.id == id } }) == true { clearNewborn() }
        if resize && model.phase == .rest { apply(animated: true) }
    }

    func setBean(_ bean: CrewMember?) {
        guard bean != model.bean else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { model.bean = bean }
    }

    func setIdeas(_ ideas: [AgentIdea]) {
        guard ideas != model.ideas else { return }
        model.ideas = ideas
        if model.phase == .create { apply(animated: true) }
    }

    func say(_ text: String, for seconds: Double) {
        model.say = text
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.model.say == text { self?.model.say = nil }
        }
    }

    func call(_ color: Color?) {
        if model.calling != color { model.calling = color }
    }

    func hatch(_ id: UUID, hue: Double) {
        let birth = Birth(id: id, hue: hue, start: Date().addingTimeInterval(Birth.delay))
        model.birth = birth
        model.newborn = id
        model.hint = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + Birth.delay + Birth.duration) { [weak self] in
            if self?.model.birth == birth { self?.model.birth = nil }
        }
    }

    func greet(_ id: UUID, _ text: String) {
        guard model.newborn == id else { return }
        model.hint = text
        hintTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            if self?.model.newborn == id { self?.clearNewborn() }
        }
        hintTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: item)
    }

    func lift(_ id: UUID?) {
        if let id, id == model.newborn { clearNewborn() }
        model.lifted = id
        trackMouse()
    }

    func headPoint(for id: UUID) -> NSPoint {
        let index = min(model.crew.firstIndex { $0.id == id } ?? 0, max(model.shownCount - 1, 0))
        let c = id == Agent.beanID ? CrewLayout.beanCenter(model.notchSize) : CrewLayout.center(index: index, notch: model.notchSize)
        let top = geometry.frame(for: CGSize(width: 0, height: model.notchSize.height)).maxY
        return NSPoint(x: geometry.screen.frame.midX + c.x, y: top - c.y - (model.newborn == id ? CrewLayout.hang : 0))
    }

    var headSize: CGFloat { CrewLayout.headSize(model.notchSize) }

    func beginCreate() {
        guard model.phase != .create else { return }
        model.say = nil
        model.draft = ""
        panel.allowsKey = true
        go(.create)
        panel.makeKey()
        if outsideClicks == nil {
            outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.endCreate() }
        }
    }

    func endCreate() {
        guard model.phase == .create else { return }
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        go(.rest)
        panel.allowsKey = false
        panel.resignKey()
        NSWorkspace.shared.frontmostApplication?.activate()
    }

    private func submit(_ text: String) {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        endCreate()
        onCreate?(request)
    }

    private func clearNewborn() {
        hintTimer?.cancel()
        model.newborn = nil
        model.hint = nil
    }

    private func crewGesture(_ id: UUID, _ gesture: CrewGesture) {
        onCrewGesture?(id, gesture)
    }

    private func tapped() {
        switch model.phase {
        case .rest: beginCreate()
        case .message: rest()
        case .create: break
        }
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
        let mouse = NSEvent.mouseLocation
        let island = islandFrame
        let reach = island.insetBy(dx: -2, dy: model.newborn == nil ? -2 : -(CrewLayout.hang + 2))
        let inside = reach.contains(mouse)
        if model.lifted == nil, panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if model.phase == .rest, model.hovering != inside {
            model.hovering = inside
            apply(animated: true)
        }
        let dx = mouse.x - island.midX, dy = island.minY - mouse.y
        let gaze: CGSize? = hypot(dx, max(dy, 0)) < 420
            ? CGSize(width: (max(-1, min(1, dx / 160)) * 10).rounded() / 10, height: (max(-0.6, min(1, dy / 120)) * 10).rounded() / 10)
            : nil
        if model.gaze != gaze { model.gaze = gaze }
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
        let contentTop = top + (g.hasNotch ? 8 : 4)
        switch model.phase {
        case .rest:
            let crew = CrewLayout.ear(count: model.crew.count, shown: model.shownCount, plus: model.showsPlus, notch: g.notchSize)
            return compact(ear: max(CrewLayout.beanEar(g.notchSize), crew))
        case .create:
            let chips = model.ideas.reduce(CGFloat(0)) { $0 + NotchStyle.width(of: $1.label, size: 12, weight: .medium) + 33 + 6 }
            return expanded(max(Self.createWidth, chips + 34), contentTop + 26 + (model.ideas.isEmpty ? 0 : 11 + 24) + 16)
        case .message:
            let textWidth: CGFloat = 520 - 40
            let text = NotchStyle.height(of: model.message.text, size: MessageBody.textSize, width: textWidth)
            let buttons: CGFloat = model.message.choices.isEmpty ? 0 : 8 + 6 + 28
            return expanded(520, contentTop + 16 + 8 + text + buttons + 16)
        }
    }
}
