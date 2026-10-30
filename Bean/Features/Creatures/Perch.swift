import AppKit
import SwiftUI

final class PerchModel: ObservableObject {
    @Published var name = ""
    @Published var look = Agent.Look(hue: 0.3, accessory: "none")
    @Published var mood: AgentActivity.Mood = .idle
    @Published var bubble: String?
    @Published var bubbleOnLeft = false
    @Published var landings = 0
    @Published var sway = 0.0
    @Published var hovered = false
    @Published var popping = false
}

struct PerchView: View {
    @ObservedObject var model: PerchModel
    var alwaysTalking = false
    let onDragStart: () -> Void
    let onRelease: (Bool) -> Void
    @State private var dragging = false
    @State private var squash = false
    @State private var peeking = false
    @State private var announcing = false

    private var talking: Bool {
        alwaysTalking || peeking || announcing || model.mood == .needsYou
    }

    var body: some View {
        let d = Perch.badge
        let frame = CreatureView.frame(d)
        let panel = Perch.panelSize
        let seat = CGPoint(x: panel.width / 2, y: Perch.seatInset)
        ZStack(alignment: .topLeading) {
            if talking, let text = model.bubble, !text.isEmpty, !model.popping {
                CreatureBubble(text: text, tailOnLeft: !model.bubbleOnLeft, below: true)
                    .frame(width: Perch.bubbleWidth, height: panel.height - seat.y - 14, alignment: model.bubbleOnLeft ? .topTrailing : .topLeading)
                    .position(x: seat.x + (model.bubbleOnLeft ? 12 - Perch.bubbleWidth / 2 : Perch.bubbleWidth / 2 - 12),
                              y: seat.y + 14 + (panel.height - seat.y - 14) / 2)
                    .transition(.scale(scale: 0.6, anchor: model.bubbleOnLeft ? .topTrailing : .topLeading).combined(with: .opacity))
                    .id(text)
            }
            Droplets(color: CreaturePalette(look: model.look).body, count: 7, spread: d * 1.4, trigger: model.popping ? 1 : 0)
                .position(seat)
            CreatureView(look: model.look, mood: model.mood, size: d, pose: .peek, limbs: 0)
                .frame(width: frame.width, height: frame.height)
                .scaleEffect(model.popping ? 0.01 : 1)
                .opacity(model.popping ? 0 : 1)
                .animation(.easeIn(duration: 0.18), value: model.popping)
                .scaleEffect(x: squash ? 1.25 : 1, y: squash ? 0.8 : 1)
                .rotationEffect(.radians(model.sway * 0.4))
                .animation(.spring(response: 0.45, dampingFraction: 0.4), value: model.sway)
                .position(seat)
                .overlay {
                    Circle().fill(.clear).contentShape(Circle())
                        .frame(width: Perch.hit, height: Perch.hit)
                        .position(seat)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                guard !dragging, hypot(value.translation.width, value.translation.height) > 3 else { return }
                                dragging = true
                                onDragStart()
                            }
                            .onEnded { _ in
                                onRelease(dragging)
                                dragging = false
                            })
                        .accessibilityElement()
                        .accessibilityLabel(model.name)
                        .accessibilityIdentifier("agent-perch-\(model.name)")
                }
        }
        .frame(width: panel.width, height: panel.height)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: talking)
        .task(id: model.hovered) {
            guard model.hovered else { return peeking = false }
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled, !dragging { peeking = true }
        }
        .task(id: model.landings) {
            guard model.landings > 0 else { return }
            announcing = true
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { announcing = false }
        }
        .onChange(of: model.landings) {
            squash = true
            withAnimation(.spring(response: 0.3, dampingFraction: 0.45)) { squash = false }
        }
    }
}

final class Perch {
    static let badge: CGFloat = 14
    static let hit: CGFloat = 24
    static let gap: CGFloat = 8
    static let bubbleWidth: CGFloat = 250
    static let seatInset: CGFloat = 24
    static let panelSize = CGSize(width: 2 * bubbleWidth + 40, height: 150)
    static let fallback = TitleSlot(center: CGPoint(x: 86, y: 17), pitch: 23)

    let id: UUID
    let model = PerchModel()
    let panel: NSPanel
    private(set) var window: ForeignWindow?
    var slot = 0 { didSet { if slot != oldValue { refresh() } } }
    var lifted = false { didSet { refresh() } }
    private var layout: (size: CGSize, slot: TitleSlot?)?
    var onSeated: (() -> Void)?
    private var measuring: CGSize?
    private var settle: DispatchWorkItem?

    init(id: UUID, onDragStart: @escaping () -> Void, onRelease: @escaping (Bool) -> Void) {
        self.id = id
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

    var shown: Bool { window?.onScreen == true && !lifted && seated }

    var seated: Bool { layout?.slot != nil }

    var seat: NSPoint? {
        guard let window, let place = layout?.slot else { return nil }
        let x = window.frame.minX + place.center.x - CGFloat(slot) * place.pitch
        return NSPoint(x: max(x, window.frame.minX + Self.badge), y: Screens.primaryHeight - (window.frame.minY + place.center.y))
    }

    var grip: NSPoint? {
        seat.map { NSPoint(x: $0.x, y: $0.y + Self.badge * (CreatureView.heightRatio / 2 - CreatureView.tip)) }
    }

    var hitRect: NSRect? {
        guard shown, let seat else { return nil }
        return NSRect(x: seat.x - Self.hit / 2, y: seat.y - Self.hit / 2, width: Self.hit, height: Self.hit)
    }

    func update(_ window: ForeignWindow?) {
        self.window = window
        if let window, layout?.size != window.frame.size { measure(window) }
        refresh()
    }

    func measureNow() {
        guard let window else { return }
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
                    let wasSeated = self.seated
                    self.layout = (current.frame.size, measured?.slot)
                    if self.seated != wasSeated { self.onSeated?() }
                    self.refresh()
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
        let screen = Screens.containing(seat)?.visibleFrame ?? .infinite
        let left = seat.x + Self.bubbleWidth > screen.maxX
        if model.bubbleOnLeft != left { model.bubbleOnLeft = left }
        let origin = NSPoint(x: (seat.x - Self.panelSize.width / 2).rounded(), y: (seat.y - Self.panelSize.height + Self.seatInset).rounded())
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
