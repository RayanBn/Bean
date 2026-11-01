import AppKit
import SwiftUI

// Bean is never the active app, and macOS ignores a background app's cursor without this. There is no public way.
@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSSetConnectionProperty") private func CGSSetConnectionProperty(_ connection: Int32, _ target: Int32, _ key: CFString, _ value: CFBoolean) -> Int32

final class NotchPanel: NSPanel {
    var takesKeys = false
    override var canBecomeKey: Bool { takesKeys }
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
    static let rosterRow: CGFloat = 40
    static let hoverDelay: TimeInterval = 0.35
    static let canvas = CGSize(width: 640, height: 520)
    static let level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

    static func panelWidth(_ surface: NotchSurface) -> CGFloat {
        switch surface {
        case .line: 400
        case .list: 420
        default: 400
        }
    }

    let model = NotchModel()
    var onSecondaryClick: ((NSView, NSRect) -> Void)?
    private var pressAnswered = true

    var onHover: (() -> Void)?
    var onPlus: (() -> Void)?
    var onOpenPage: ((UUID?) -> Void)?
    var onRow: ((UUID) -> Void)?
    var onSubmit: ((String) -> Void)?
    var onAnswer: ((NotchCard, String) -> Void)?
    var onHide: ((NotchCard) -> Void)?
    var onConnect: ((NotchCard, String) -> Void)?
    var onExpandLine: ((NotchReport) -> Void)?
    var rosterProvider: () -> [RosterItem] = { [] }
    var onCrewGesture: ((UUID, CrewGesture) -> Void)?
    private(set) var liftedFromPanel = false
    private let panel: NotchPanel
    private var geometry = NotchGeometry.current()
    private var mouseMonitors: [Any] = []
    private var hoverTimer: DispatchWorkItem?

    init() {
        _ = CGSSetConnectionProperty(CGSMainConnectionID(), CGSMainConnectionID(), "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NotchController.level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true

        let actions = NotchActions(
            plus: { [weak self] in self?.plusPressed() },
            openPage: { [weak self] id in self?.select { $0.onOpenPage?(id) } },
            row: { [weak self] id in self?.select { $0.onRow?(id) } },
            crew: { [weak self] id, gesture in self?.crewGesture(id, gesture) },
            submit: { [weak self] text in self?.answered { $0.onSubmit?(text) } },
            closeCompose: { [weak self] in self?.closeCompose() },
            answer: { [weak self] card, text in self?.answered { $0.onAnswer?(card, text) } },
            hide: { [weak self] card in self?.answered { $0.onHide?(card) } },
            connect: { [weak self] card, connector in self?.answered { $0.onConnect?(card, connector) } },
            takeKeys: { [weak self] in self?.takeKeys() },
            expandLine: { [weak self] report in self?.answered { $0.onExpandLine?(report) } },
            undo: { [weak self] item in self?.answered { _ in item.undo?() } })
        let host = NotchHostingView(rootView: NotchView(model: model,
                                                        onTap: { [weak self] in self?.tapped() },
                                                        onCrew: { [weak self] id, gesture in self?.crewGesture(id, gesture) },
                                                        onPlus: { [weak self] in self?.plusPressed() },
                                                        actions: actions,
                                                        onHeight: { [weak self] height in DispatchQueue.main.async { self?.measured(height) } }))
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
                if let self, event.window === self.panel, !self.model.surface.isOpen { self.watchPress() }
                return event
            },
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.pressedElsewhere() },
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
        show(.rest)
        action(self)
    }

    private func answered(_ action: (NotchController) -> Void) {
        pressAnswered = true
        action(self)
    }

    private func plusPressed() {
        pressAnswered = true
        onPlus?()
    }

    func show(_ surface: NotchSurface) {
        hoverTimer?.cancel()
        hoverTimer = nil
        guard model.surface != surface else { return }
        if !surface.takesKeys, !cardHasReply(surface) { releaseKeys() }
        model.contentHeight = Self.height(of: surface, like: model)
        withAnimation(.easeOut(duration: 0.15)) { model.surface = surface }
        apply(animated: true)
    }

    static func height(of surface: NotchSurface, like model: NotchModel) -> CGFloat {
        let probe = NotchModel()
        probe.surface = surface
        probe.roster = model.roster
        probe.composeError = model.composeError
        let host = NSHostingView(rootView: NotchSurfaceView(model: probe, actions: NotchActions()))
        return min(host.fittingSize.height, canvas.height - model.notchSize.height)
    }

    func refit() {
        measured(Self.height(of: model.surface, like: model))
    }

    private func cardHasReply(_ surface: NotchSurface) -> Bool {
        if case .card(let card, _) = surface, case .card(let current, _) = model.surface { return card.id == current.id }
        return false
    }

    func showList() {
        model.roster = rosterProvider()
        show(.list)
    }

    func openCompose() {
        show(.compose)
        takeKeys()
    }

    private func takeKeys() {
        panel.takesKeys = true
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
    }

    func releaseKeys() {
        guard panel.takesKeys else { return }
        panel.takesKeys = false
        panel.resignKey()
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    private func closeCompose() {
        model.composeError = nil
        model.composeQuestion = nil
        show(.rest)
    }

    func closeReady() {
        if case .ready = model.surface { show(.rest) }
    }

    private func pressedElsewhere() {
        switch model.surface {
        case .compose: closeCompose()
        case .ready: show(.rest)
        default: break
        }
    }

    private func measured(_ height: CGFloat) {
        guard abs(model.contentHeight - height) > 0.5 else { return }
        model.contentHeight = height
        if model.surface.isOpen { apply(animated: true) }
    }

    var mouseInside: Bool { islandFrame.contains(NSEvent.mouseLocation) }
    var hasKeys: Bool { panel.takesKeys }

    func setPips(_ pips: [NotchPip]) {
        guard pips != model.pips else { return }
        let resize = pips.count != model.pips.count
        withAnimation(.easeOut(duration: 0.2)) { model.pips = pips }
        if resize { apply(animated: true) }
    }

    func setWaiting(_ count: Int, attention: Bool) {
        let shown = attention ? count : 0
        if model.waiting != shown {
            withAnimation(.easeOut(duration: 0.2)) { model.waiting = shown }
            apply(animated: true)
        }
        call(attention ? .orange : nil)
    }

    func setDoneMark(_ on: Bool) {
        guard model.doneMark != on else { return }
        withAnimation(.easeOut(duration: 0.2)) { model.doneMark = on }
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
        if case .lift = gesture {
            liftedFromPanel = model.surface.isOpen
            show(.rest)
        }
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
        if model.surface.isOpen {
            if case .list = model.surface { show(.rest) }
        } else {
            onHover?()
        }
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
        if model.lifted == nil, !panel.takesKeys, panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        switch model.surface {
        case .rest:
            if !inside || model.lifted != nil {
                hoverTimer?.cancel()
                hoverTimer = nil
            } else if hoverTimer == nil {
                let item = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.hoverTimer = nil
                    guard NSEvent.pressedMouseButtons == 0, self.model.lifted == nil, self.reachContainsMouse else { return }
                    self.onHover?()
                }
                hoverTimer = item
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: item)
            }
        case .list, .report:
            if !inside { show(.rest) }
        default:
            break
        }
        let dx = mouse.x - island.midX, dy = island.minY - mouse.y
        let gaze: CGSize? = hypot(dx, max(dy, 0)) < 420
            ? CGSize(width: (max(-1, min(1, dx / 160)) * 10).rounded() / 10, height: (max(-0.6, min(1, dy / 120)) * 10).rounded() / 10)
            : nil
        if model.gaze != gaze { model.gaze = gaze }
    }

    private var reachContainsMouse: Bool {
        islandFrame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
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
        let right = CrewLayout.beanEar(g.notchSize) + CrewLayout.signals(pips: model.pips.count, waiting: model.waiting, done: model.doneMark)
        let rest = compact(left: max(crew, 8), right: right)
        guard model.surface.isOpen else { return rest }
        let width = max(rest.width + 2 * abs(rest.offset), Self.panelWidth(model.surface))
        return .init(width: width, height: compactHeight + model.contentHeight, radius: 18, flare: rest.flare)
    }
}
