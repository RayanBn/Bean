import AppKit
import SwiftUI

final class PerchModel: ObservableObject {
    @Published var name = ""
    @Published var look = Agent.Look(hue: 0.3, accessory: "none")
    @Published var mood: AgentActivity.Mood = .idle
    @Published var landings = 0
    @Published var popping = false
    @Published var size = Perch.size
    @Published var control = CGSize(width: Perch.hit, height: Perch.hit)
    @Published var ink: Color?
    @Published var hovering = false
    @Published var unseen = true
}

struct PerchView: View {
    @ObservedObject var model: PerchModel
    let onDragStart: () -> Void
    let onRelease: (Bool) -> Void
    @State private var dragging = false
    @State private var squash = false

    var body: some View {
        let d = model.size
        let frame = CreatureView.frame(d)
        let panel = Perch.panelSize
        let seat = CGPoint(x: panel.width / 2, y: panel.height / 2)
        ZStack(alignment: .topLeading) {
            Droplets(color: CreaturePalette(look: model.look).body, count: 7, spread: d * 1.4, trigger: model.popping ? 1 : 0)
                .position(seat)
            if !model.unseen {
                CreatureView(look: model.look, mood: model.mood, size: d, pose: .peek, limbs: 0, flat: true, ink: model.ink)
                    .frame(width: frame.width, height: frame.height)
                    .scaleEffect(model.popping ? 0.01 : 1)
                    .opacity(model.popping ? 0 : 1)
                    .animation(.easeIn(duration: 0.18), value: model.popping)
                    .scaleEffect(x: squash ? 1.25 : 1, y: squash ? 0.8 : 1)
                    .position(x: seat.x, y: seat.y + Perch.lowered(d))
            }
            RoundedRectangle(cornerRadius: min(model.control.height / 4, 8), style: .continuous)
                .fill((model.ink ?? .primary).opacity(model.hovering ? 0.14 : 0))
                .frame(width: model.control.width, height: model.control.height)
                .position(seat)
            Rectangle().fill(.clear).contentShape(Rectangle())
                .frame(width: model.control.width, height: model.control.height)
                .position(seat)
                .gesture(drag)
                .help(model.name)
                .accessibilityElement()
                .accessibilityLabel(model.name)
                .accessibilityIdentifier("agent-perch-\(model.name)")
        }
        .frame(width: panel.width, height: panel.height)
        .onChange(of: model.landings) {
            squash = true
            withAnimation(.spring(response: 0.32, dampingFraction: 0.45)) { squash = false }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard !dragging, hypot(value.translation.width, value.translation.height) > 3 else { return }
                dragging = true
                onDragStart()
            }
            .onEnded { _ in
                onRelease(dragging)
                dragging = false
            }
    }
}

final class Perch {
    static let size: CGFloat = 14
    static let hit: CGFloat = 24
    static let panelSize = CGSize(width: 96, height: 72)
    // The body sits above the middle of its frame. Lowered by this, it is centered on the row like the icons next to it.
    static func lowered(_ d: CGFloat) -> CGFloat { d * (CreatureView.heightRatio - CreatureView.tip - CreatureView.bottom) / 2 }

    let id: UUID
    let model = PerchModel()
    let panel: NSPanel
    private(set) var window: ForeignWindow?
    var app: Int32?
    var slot = 0 {
        didSet {
            guard slot != oldValue else { return }
            let was = oldValue < layout?.slot?.room ?? 0
            refresh()
            if seated != was { onSeated?() }
        }
    }
    var lifted = false { didSet { refresh() } }
    var onSeated: (() -> Void)?
    private var layout: (window: Int, size: CGSize, slot: TitleSlot?)?
    private var measuring: (window: Int, size: CGSize)?
    private var remeasures = 0
    private var settling: Timer?
    private var settleUntil = Date.distantPast
    private var barCheck: Timer?
    private var scanningBar = false
    private var barScanned = Date.distantPast
    private var marks: [CGRect]?

    init(id: UUID, onDragStart: @escaping () -> Void, onRelease: @escaping (Bool) -> Void) {
        self.id = id
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .normal
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        let host = NotchHostingView(rootView: PerchView(model: model, onDragStart: onDragStart, onRelease: onRelease))
        host.sizingOptions = []
        panel.contentView = host
    }

    private var place: TitleSlot? { layout?.slot.flatMap { window != nil && slot < $0.room ? $0 : nil } }

    var seated: Bool { place != nil }

    var shown: Bool { window?.onScreen == true && !lifted && seated }

    var seat: NSPoint? {
        guard let window, let place else { return nil }
        return NSPoint(x: window.frame.minX + place.center.x - CGFloat(slot) * place.pitch, y: Screens.primaryHeight - (window.frame.minY + place.center.y))
    }

    var landingSize: CGFloat { place?.size ?? Self.size }

    var grip: NSPoint? {
        guard let seat else { return nil }
        return NSPoint(x: seat.x, y: seat.y + landingSize * (CreatureView.heightRatio / 2 - CreatureView.tip) - Self.lowered(landingSize))
    }

    var hitRect: NSRect? {
        guard shown, let seat, let control = place?.control else { return nil }
        return NSRect(x: seat.x - control.width / 2, y: seat.y - control.height / 2, width: control.width, height: control.height)
    }

    func update(_ window: ForeignWindow?) {
        let before = seated
        let moved = window?.number != self.window?.number
        if moved { remeasures = 0; marks = nil }
        self.window = window
        if barCheck == nil, window != nil { watchBar() }
        if let window, layout?.window != window.number || layout?.size != window.frame.size { measure(window, after: moved ? 0 : 0.35) }
        refresh()
        if moved { raise() }
        if seated != before { onSeated?() }
    }

    // An app can open a sidebar or hide its bar with its window at the same size, so the bar itself is watched, lightly.
    private func watchBar() {
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, let window = self.window, window.onScreen, !self.lifted else { return }
            if self.shown, !self.panel.isOnActiveSpace { self.raise() }
            // A slow app can take longer to answer than this timer's beat. One in the background rearranges its bar rarely, and being brought forward checks it again.
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid
            guard !self.scanningBar, front || Date().timeIntervalSince(self.barScanned) >= 6 else { return }
            self.scanningBar = true
            self.barScanned = Date()
            Task.detached(priority: .utility) {
                let now = ForeignWindow.barMarks(of: window)
                await MainActor.run {
                    self.scanningBar = false
                    guard self.window?.number == window.number else { return }
                    // An app can stop answering for a moment, as its Space changes, and a measure then finds no seat. Its answer coming back counts as a change.
                    if let now, self.marks != now {
                        self.remeasures = 0
                        self.measure(window, after: 0)
                    }
                    self.marks = now
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        barCheck = timer
    }

    // A drop waits for a picture of the window, for a moment only, so the agent flies to its real place.
    func measureNow(then done: @escaping () -> Void) {
        guard let window else { return done() }
        var finished = false
        let finish = { [weak self] (picture: BarPicture?) in
            guard !finished else { return }
            finished = true
            self?.layout = (window.number, window.frame.size, ForeignWindow.titleSlot(of: window, picture: picture))
            self?.refresh()
            done()
            if picture == nil { self?.measure(window, after: 0.2) }
        }
        Task { let picture = await BarPicture.capture(window); await MainActor.run { finish(picture) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { finish(nil) }
    }

    private func measure(_ window: ForeignWindow, after delay: TimeInterval) {
        guard measuring?.window != window.number || measuring?.size != window.frame.size else { return }
        measuring = (window.number, window.frame.size)
        let same = { (other: ForeignWindow?) in other?.number == window.number && other?.frame.size == window.frame.size }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, same(self.window) else { self?.measuring = nil; return }
            Task.detached(priority: .userInitiated) {
                let measured = ForeignWindow.titleSlot(of: window, picture: await BarPicture.capture(window))
                await MainActor.run {
                    self.measuring = nil
                    guard same(self.window) else { return }
                    let before = self.seated
                    self.layout = (window.number, window.frame.size, measured)
                    self.refresh()
                    if self.seated != before { self.onSeated?() }
                    if measured?.alone != false || measured?.ink == nil, self.remeasures < 5 {
                        self.remeasures += 1
                        self.measure(window, after: 1)
                    } else if measured?.alone == false, measured?.ink != nil {
                        self.remeasures = 0
                    }
                }
            }
        }
    }

    // An app raises its window some 40 ms after it says it is active, so one reorder at the notification loses the race.
    func raise() {
        guard shown else { return }
        settleUntil = Date().addingTimeInterval(0.3)
        keepOrder()
        guard settling == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self, Date() < self.settleUntil, self.shown else {
                timer.invalidate()
                self?.settling = nil
                return
            }
            self.keepOrder()
        }
        RunLoop.main.add(timer, forMode: .common)
        settling = timer
    }

    private func keepOrder() {
        guard let window else { return }
        let base = window.barWindow ?? window.number
        guard !panel.isOnActiveSpace || !inOrder(above: base, of: window.pid) else { return }
        show(above: base)
    }

    // Ordered from another Space, a panel stays there until it is ordered out. A window that just went full screen is on a new Space.
    private func show(above number: Int) {
        if !panel.isOnActiveSpace { panel.orderOut(nil) }
        panel.order(.above, relativeTo: number)
        noteSeen()
    }

    // Only another app's window between this panel and its base is wrong. The app's own popovers and bars may sit there.
    private func inOrder(above base: Int, of pid: Int32) -> Bool {
        let above = CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow, CGWindowID(base)) as? [[String: Any]] ?? []
        for info in above.reversed() {
            if (info[kCGWindowNumber as String] as? Int) == panel.windowNumber { return true }
            if (info[kCGWindowLayer as String] as? Int) == 0, (info[kCGWindowOwnerPID as String] as? Int32) != pid { return false }
        }
        return false
    }

    func dismiss() {
        barCheck?.invalidate()
        barCheck = nil
        panel.orderOut(nil)
        noteSeen()
    }

    // A creature with its panel ordered out stops animating. One on another Space stays drawn, as it slides in with its window.
    private func noteSeen() {
        let unseen = !panel.isVisible || panel.alphaValue == 0
        if model.unseen != unseen { model.unseen = unseen }
    }

    func pop() {
        guard shown else { return dismiss() }
        model.popping = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.dismiss() }
    }

    private func refresh() {
        defer { noteSeen() }
        // A window on another Space keeps its panel there, so the two slide together when the Space changes.
        if let window, !window.onScreen, !panel.isOnActiveSpace { return }
        guard let window, window.onScreen, let seat, let place else {
            if !lifted { panel.orderOut(nil) }
            return
        }
        if model.size != place.size { model.size = place.size }
        if model.control != place.control { model.control = place.control }
        let ink = place.ink.map { Self.blend($0, hue: model.look.hue) }
        if model.ink != ink { model.ink = ink }
        let origin = NSPoint(x: (seat.x - Self.panelSize.width / 2).rounded(), y: (seat.y - Self.panelSize.height / 2).rounded())
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        panel.alphaValue = lifted ? 0 : 1
        if !panel.isVisible || !panel.isOnActiveSpace { show(above: window.barWindow ?? window.number) }
    }
}

private extension Perch {
    // The row's ink, leaning toward the agent's own color so two agents stay two.
    static func blend(_ ink: NSColor, hue: Double) -> Color {
        let tint = NSColor(hue: hue - floor(hue), saturation: 0.7, brightness: max(ink.brightnessComponent, 0.45), alpha: 1)
        return Color(nsColor: ink.blended(withFraction: 0.32, of: tint) ?? ink)
    }
}

struct Droplets: View {
    let color: Color
    let count: Int
    let spread: CGFloat
    let trigger: Int
    @State private var out: Bool?

    var body: some View {
        ZStack {
            if let out {
                ForEach(0..<count, id: \.self) { i in
                    let a = count == 2 ? (i == 0 ? Double.pi * 1.12 : -Double.pi * 0.12) : Double(i) / Double(count) * 2 * .pi
                    let r = spread * (count == 2 ? 1 : 0.8 + 0.25 * CGFloat(i % 3))
                    Circle().fill(color)
                        .frame(width: 4 + CGFloat(i % 3), height: 4 + CGFloat(i % 3))
                        .offset(x: out ? cos(a) * r : 0, y: out ? sin(a) * r * (count == 2 ? 0.6 : 1) : 0)
                        .opacity(out ? 0 : 1)
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) {
            out = false
            withAnimation(.easeOut(duration: 0.45)) { out = true } completion: { out = nil }
        }
    }
}
