import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
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
    static let growSpring = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let shrinkSpring = Animation.spring(response: 0.34, dampingFraction: 0.9)
    static let rosterRow: CGFloat = 36
    static let rosterWidth: CGFloat = 340
    static let hoverDelay: TimeInterval = 0.6
    static let canvas = CGSize(width: 640, height: 520)
    static let level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

    let model = NotchModel()
    var onSecondaryClick: ((NSView, NSRect) -> Void)?
    var hasAgents: () -> Bool = { false }
    private var pressAnswered = true

    var onNew: (() -> Void)?
    var onOpen: (() -> Void)?
    var onRoster: ((UUID) -> Void)?
    var rosterProvider: () -> [RosterItem] = { [] }
    var onCrewGesture: ((UUID, CrewGesture) -> Void)?
    private let panel: NotchPanel
    private var geometry = NotchGeometry.current()
    private var mouseMonitors: [Any] = []
    private var hoverTimer: DispatchWorkItem?

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

        let host = NotchHostingView(rootView: NotchView(model: model,
                                                        onTap: { [weak self] in self?.tapped() },
                                                        onCrew: { [weak self] id, gesture in self?.crewGesture(id, gesture) },
                                                        onPlus: { [weak self] in self?.select { $0.onNew?() } },
                                                        onRoster: { [weak self] id in self?.select { $0.onRoster?(id) } }))
        host.sizingOptions = []
        let openMenu = { [weak self, weak host] in
            guard let self, let host, let open = self.onSecondaryClick else { return }
            let w = self.model.shape.width, h = self.model.shape.height
            let island = NSRect(x: (host.bounds.width - w) / 2, y: host.isFlipped ? 0 : host.bounds.height - h, width: w, height: h)
            open(host, island)
        }
        host.onSecondaryClick = openMenu
        panel.contentView = host
        adopt(geometry)
        apply(animated: false)
        panel.orderFrontRegardless()

        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        mouseMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in self?.trackMouse() },
            NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in self?.trackMouse(); return event },
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                if let self, event.window === self.panel, !self.model.listOpen { self.watchPress() }
                return event
            },
        ].compactMap { $0 }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.adopt(NotchGeometry.current())
            self.apply(animated: false)
        }
    }

    func hideFromCapture(_ hidden: Bool) {
        panel.sharingType = hidden ? .none : .readOnly
    }

    var islandFrame: NSRect {
        geometry.frame(for: CGSize(width: model.shape.width, height: model.shape.height)).offsetBy(dx: model.shape.offset, dy: 0)
    }

    private func select(_ action: (NotchController) -> Void) {
        pressAnswered = true
        setList(false)
        action(self)
    }

    private func setList(_ open: Bool) {
        hoverTimer?.cancel()
        hoverTimer = nil
        guard model.listOpen != open else { return }
        if open { model.roster = rosterProvider() }
        withAnimation(.easeOut(duration: 0.15)) { model.listOpen = open }
        apply(animated: true)
    }

    func setCrew(_ crew: [CrewMember]) {
        guard crew != model.crew else { return }
        let resize = crew.count != model.crew.count
        model.crew = crew
        if model.newborn.map({ id in !crew.contains { $0.id == id } }) == true { clearNewborn() }
        if resize { apply(animated: true) }
    }

    func setBean(_ bean: CrewMember?) {
        guard bean != model.bean else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { model.bean = bean }
    }

    func call(_ color: Color?) {
        if model.calling != color { model.calling = color }
    }

    func hatch(_ id: UUID, hue: Double) {
        let birth = Birth(id: id, hue: hue, start: Date().addingTimeInterval(Birth.delay))
        model.birth = birth
        model.newborn = id
        DispatchQueue.main.asyncAfter(deadline: .now() + Birth.delay + Birth.duration) { [weak self] in
            if self?.model.birth == birth { self?.model.birth = nil }
        }
    }

    func settle(_ id: UUID) {
        if model.newborn == id { model.newborn = nil }
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

    private func clearNewborn() {
        model.newborn = nil
    }

    private func crewGesture(_ id: UUID, _ gesture: CrewGesture) {
        pressAnswered = true
        onCrewGesture?(id, gesture)
    }

    // A press on this inactive panel sometimes never gets its mouse-up, so the gesture never ends.
    private func watchPress() {
        pressAnswered = false
        let at = NSEvent.mouseLocation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.pressAnswered, NSEvent.pressedMouseButtons == 0, self.model.lifted == nil else { return }
            let heads = self.model.crew.map(\.id) + [Agent.beanID]
            let radius = self.headSize
            if let head = heads.first(where: { hypot(self.headPoint(for: $0).x - at.x, self.headPoint(for: $0).y - at.y) < radius }) {
                self.onCrewGesture?(head, .release(dragged: false))
            } else {
                self.tapped()
            }
        }
    }

    private func tapped() {
        pressAnswered = true
        onOpen?()
    }

    private func adopt(_ geometry: NotchGeometry) {
        self.geometry = geometry
        panel.setFrame(geometry.frame(for: Self.canvas), display: false)
        model.hasNotch = geometry.hasNotch
        model.notchSize = geometry.notchSize
    }

    private func apply(animated: Bool) {
        let target = targetMetrics()
        let size = CGSize(width: target.width, height: target.height)
        let grows = size.width >= model.shape.width && size.height >= model.shape.height
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
        if !inside || model.lifted != nil {
            setList(false)
        } else if !model.listOpen, hoverTimer == nil, hasAgents() {
            let item = DispatchWorkItem { [weak self] in
                self?.hoverTimer = nil
                guard NSEvent.pressedMouseButtons == 0 else { return }
                self?.setList(true)
            }
            hoverTimer = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: item)
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
        func compact(left: CGFloat, right: CGFloat) -> NotchShape.Metrics {
            let f = g.hasNotch ? Self.compactFlare : 0
            return .init(width: g.notchSize.width + left + right + 2 * f, height: compactHeight,
                         radius: g.hasNotch ? 10 : compactHeight / 2, flare: f, offset: (right - left) / 2)
        }
        let crew = CrewLayout.ear(count: model.crew.count, shown: model.shownCount, plus: model.showsPlus, notch: g.notchSize)
        let right = CrewLayout.beanEar(g.notchSize)
        let rest = compact(left: max(crew, 8), right: right)
        guard model.listOpen else { return rest }
        let rows = CGFloat(model.roster.count + 1) * Self.rosterRow
        let width = max(rest.width + 2 * abs(rest.offset), Self.rosterWidth)
        return .init(width: width, height: compactHeight + rows + 10, radius: 18, flare: rest.flare)
    }
}
