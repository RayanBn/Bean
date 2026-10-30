import AppKit
import SwiftUI

final class PerchModel: ObservableObject {
    @Published var name = ""
    @Published var look = Agent.Look(hue: 0.3, accessory: "none")
    @Published var mood: AgentActivity.Mood = .idle
    @Published var landings = 0
    @Published var sway = 0.0
    @Published var popping = false
    @Published var badge = false
}

struct PerchView: View {
    @ObservedObject var model: PerchModel
    let onDragStart: () -> Void
    let onRelease: (Bool) -> Void
    @State private var dragging = false
    @State private var squash = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.badge { badge } else { sitting }
        }
        .frame(width: Perch.panelSize.width, height: Perch.panelSize.height)
        .onChange(of: model.landings) {
            squash = true
            withAnimation(.spring(response: 0.32, dampingFraction: 0.45)) { squash = false }
        }
    }

    @ViewBuilder private var sitting: some View {
        let frame = CreatureView.frame(Perch.size)
        let panel = Perch.panelSize
        let seatY = Perch.seatRow
        Droplets(color: CreaturePalette(look: model.look).body, count: 2, spread: Perch.size * 0.8, trigger: model.landings)
            .position(x: panel.width / 2, y: seatY - 3)
        Droplets(color: CreaturePalette(look: model.look).body, count: 9, spread: Perch.size * 1.1, trigger: model.popping ? 1 : 0)
            .position(x: panel.width / 2, y: seatY - Perch.size * 0.5)
        CreatureView(look: model.look, mood: model.mood, size: Perch.size, pose: .perch)
            .scaleEffect(model.popping ? 0.01 : 1, anchor: .center)
            .opacity(model.popping ? 0 : 1)
            .animation(.easeIn(duration: 0.18), value: model.popping)
            .scaleEffect(x: squash ? 1.18 : 1, y: squash ? 0.8 : 1, anchor: CreatureView.seatAnchor)
            .rotationEffect(.radians(model.sway), anchor: CreatureView.seatAnchor)
            .animation(.spring(response: 0.45, dampingFraction: 0.32), value: model.sway)
            .frame(width: frame.width, height: frame.height)
            .contentShape(Ellipse().scale(x: 0.7, y: 0.6).offset(y: frame.height * 0.08))
            .gesture(drag)
            .accessibilityElement()
            .accessibilityLabel(model.name)
            .accessibilityIdentifier("agent-perch-\(model.name)")
            .help(model.name)
            .position(x: panel.width / 2, y: seatY + Perch.seatDepth - frame.height / 2)
    }

    @ViewBuilder private var badge: some View {
        let d = Perch.badge
        let frame = CreatureView.frame(d)
        let panel = Perch.panelSize
        let seat = CGPoint(x: panel.width / 2, y: Perch.seatRow)
        Droplets(color: CreaturePalette(look: model.look).body, count: 7, spread: d * 1.4, trigger: model.popping ? 1 : 0)
            .position(seat)
        CreatureView(look: model.look, mood: model.mood, size: d, pose: .peek, limbs: 0)
            .frame(width: frame.width, height: frame.height)
            .scaleEffect(model.popping ? 0.01 : 1)
            .opacity(model.popping ? 0 : 1)
            .animation(.easeIn(duration: 0.18), value: model.popping)
            .scaleEffect(x: squash ? 1.25 : 1, y: squash ? 0.8 : 1)
            .position(seat)
        Circle().fill(.clear).contentShape(Circle())
            .frame(width: Perch.hit, height: Perch.hit)
            .position(seat)
            .gesture(drag)
            .accessibilityElement()
            .accessibilityLabel(model.name)
            .accessibilityIdentifier("agent-perch-\(model.name)")
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
    enum Seat { case sit, badge, none }

    static let size: CGFloat = 38
    static let badge: CGFloat = 14
    static let hit: CGFloat = 24
    static let seatRow: CGFloat = 96
    static let panelSize = CGSize(width: 160, height: seatRow + 50)
    static let seatDepth = CreatureView.frame(size).height * (1 - CreatureView.seatAnchor.y)
    static let headroom: CGFloat = size * 1.15

    let id: UUID
    let model = PerchModel()
    let panel: NSPanel
    private(set) var window: ForeignWindow?
    var fraction: CGFloat
    var slot = 0 { didSet { if slot != oldValue { refresh() } } }
    var lifted = false { didSet { refresh() } }
    var onSeated: (() -> Void)?
    private var layout: (size: CGSize, slot: TitleSlot?)?
    private var measuring: CGSize?
    private var settle: DispatchWorkItem?

    init(id: UUID, fraction: CGFloat, onDragStart: @escaping () -> Void, onRelease: @escaping (Bool) -> Void) {
        self.id = id
        self.fraction = fraction
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        let host = NotchHostingView(rootView: PerchView(model: model, onDragStart: onDragStart, onRelease: onRelease))
        host.sizingOptions = []
        panel.contentView = host
    }

    var mode: Seat {
        guard let window else { return .none }
        if roomAbove(window) { return .sit }
        return layout?.slot == nil ? .none : .badge
    }

    var seated: Bool { mode != .none }

    var shown: Bool { window?.onScreen == true && !lifted && seated }

    private func roomAbove(_ window: ForeignWindow) -> Bool {
        let f = window.appKitFrame
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(f) }) else { return true }
        return screen.visibleFrame.maxY - f.maxY >= Self.headroom
    }

    var seat: NSPoint? {
        guard let window else { return nil }
        switch mode {
        case .sit:
            let f = window.appKitFrame
            let margin = Self.size * 0.7
            return NSPoint(x: min(max(f.minX + fraction * f.width, f.minX + margin), f.maxX - margin), y: f.maxY)
        case .badge:
            guard let place = layout?.slot else { return nil }
            let x = window.frame.minX + place.center.x - CGFloat(slot) * place.pitch
            return NSPoint(x: max(x, window.frame.minX + Self.badge), y: Screens.primaryHeight - (window.frame.minY + place.center.y))
        case .none:
            return nil
        }
    }

    var landingSize: CGFloat { mode == .sit ? Self.size : Self.badge }

    var grip: NSPoint? {
        guard let seat else { return nil }
        let lift = mode == .sit
            ? Self.size * (CreatureView.seatAnchor.y - CreatureView.gripAnchor.y) * CreatureView.heightRatio
            : Self.badge * (CreatureView.heightRatio / 2 - CreatureView.tip)
        return NSPoint(x: seat.x, y: seat.y + lift)
    }

    var hitRect: NSRect? {
        guard shown, let seat else { return nil }
        if mode == .badge { return NSRect(x: seat.x - Self.hit / 2, y: seat.y - Self.hit / 2, width: Self.hit, height: Self.hit) }
        return NSRect(x: seat.x - Self.size * 0.55, y: seat.y - Self.size * 0.35, width: Self.size * 1.1, height: Self.size * 1.35)
    }

    func update(_ window: ForeignWindow?) {
        let before = seated
        self.window = window
        if let window, layout?.size != window.frame.size { measure(window) }
        refresh()
        if seated != before { onSeated?() }
    }

    func measureNow() {
        guard let window, !roomAbove(window) else { return }
        layout = (window.frame.size, ForeignWindow.titleLayout(of: window)?.slot)
        refresh()
    }

    private func measure(_ window: ForeignWindow) {
        guard measuring != window.frame.size else { return }
        measuring = window.frame.size
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let current = self.window, current.frame.size == window.frame.size else { self?.measuring = nil; return }
            DispatchQueue.global(qos: .userInitiated).async {
                let measured = ForeignWindow.titleLayout(of: current)
                DispatchQueue.main.async {
                    self.measuring = nil
                    guard self.window?.frame.size == current.frame.size else { return }
                    let before = self.seated
                    self.layout = (current.frame.size, measured?.slot)
                    self.refresh()
                    if self.seated != before { self.onSeated?() }
                }
            }
        }
    }

    func raise() {
        guard shown, let window else { return }
        panel.order(.above, relativeTo: window.number)
    }

    private func swing(by dx: CGFloat) {
        let sway = max(-0.6, min(0.6, -Double(dx) * 0.025))
        if abs(sway - model.sway) > 0.02 { model.sway = sway }
        settle?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.model.sway = 0 }
        settle = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
    }

    func dismiss() {
        panel.orderOut(nil)
    }

    func pop() {
        guard shown else { return dismiss() }
        model.popping = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.dismiss() }
    }

    private func refresh() {
        guard let window, window.onScreen, let seat else {
            if !lifted { panel.orderOut(nil) }
            return
        }
        let badge = mode == .badge
        if model.badge != badge { model.badge = badge }
        let origin = NSPoint(x: (seat.x - Self.panelSize.width / 2).rounded(), y: (seat.y - Self.panelSize.height + Self.seatRow).rounded())
        if panel.frame.origin != origin {
            if panel.isVisible && !lifted { swing(by: origin.x - panel.frame.origin.x) }
            panel.setFrameOrigin(origin)
        }
        panel.alphaValue = lifted ? 0 : 1
        if !panel.isVisible {
            panel.order(.above, relativeTo: window.number)
        }
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
