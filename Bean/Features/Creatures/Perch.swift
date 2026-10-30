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
}

struct PerchView: View {
    @ObservedObject var model: PerchModel
    let onDragStart: () -> Void
    let onRelease: (Bool) -> Void
    @State private var dragging = false
    @State private var squash = false

    var body: some View {
        let frame = CreatureView.frame(Perch.size)
        let panel = Perch.panelSize
        let seatY = panel.height - Perch.seatDepth
        let reach = Perch.size * 0.5 + 8
        ZStack(alignment: .topLeading) {
            if let text = model.bubble, !text.isEmpty {
                CreatureBubble(name: model.name, text: text, mood: model.mood, hue: model.look.hue, tailOnLeft: !model.bubbleOnLeft)
                    .frame(width: Perch.bubbleWidth, height: seatY, alignment: model.bubbleOnLeft ? .bottomTrailing : .bottomLeading)
                    .position(x: panel.width / 2 + (model.bubbleOnLeft ? -1 : 1) * (reach + Perch.bubbleWidth / 2), y: seatY / 2 - 2)
                    .transition(.scale(scale: 0.5, anchor: model.bubbleOnLeft ? .bottomTrailing : .bottomLeading).combined(with: .opacity))
                    .id(text)
            }
            CreatureView(look: model.look, mood: model.mood, size: Perch.size, pose: .perch)
                .scaleEffect(x: squash ? 1.18 : 1, y: squash ? 0.8 : 1, anchor: CreatureView.seatAnchor)
                .rotationEffect(.radians(model.sway), anchor: CreatureView.seatAnchor)
                .animation(.spring(response: 0.45, dampingFraction: 0.32), value: model.sway)
                .frame(width: frame.width, height: frame.height)
                .contentShape(Ellipse().scale(x: 0.7, y: 0.6).offset(y: frame.height * 0.08))
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
                .position(x: panel.width / 2, y: panel.height - frame.height / 2)
        }
        .frame(width: panel.width, height: panel.height)
        .animation(.spring(response: 0.4, dampingFraction: 0.72), value: model.bubble)
        .onChange(of: model.landings) {
            squash = true
            withAnimation(.spring(response: 0.32, dampingFraction: 0.45)) { squash = false }
        }
    }
}

final class Perch {
    static let size: CGFloat = 38
    static let bubbleWidth: CGFloat = 250
    static let panelSize = CGSize(width: 2 * (bubbleWidth + size), height: 128)
    static let seatDepth = CreatureView.frame(size).height * (1 - CreatureView.seatAnchor.y)
    static let headroom: CGFloat = 58

    let id: UUID
    let model = PerchModel()
    let panel: NSPanel
    private(set) var window: ForeignWindow?
    var fraction: CGFloat
    var lifted = false { didSet { refresh() } }
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

    var shown: Bool { window?.onScreen == true && !lifted }

    var seat: NSPoint? {
        guard let window else { return nil }
        let f = window.appKitFrame
        let margin = Self.size * 0.7
        let x = min(max(f.minX + fraction * f.width, f.minX + margin), f.maxX - margin)
        let screen = NSScreen.screens.first { $0.frame.intersects(f) && $0.frame.contains(NSPoint(x: x, y: min(f.maxY, $0.frame.maxY) - 1)) }
        let ceiling = (screen?.visibleFrame.maxY ?? f.maxY) - Self.headroom
        return NSPoint(x: x, y: min(f.maxY, ceiling))
    }

    var grip: NSPoint? {
        seat.map { NSPoint(x: $0.x, y: $0.y + Self.size * (CreatureView.seatAnchor.y - CreatureView.gripAnchor.y) * CreatureView.heightRatio) }
    }

    var hitRect: NSRect? {
        guard shown, let seat else { return nil }
        return NSRect(x: seat.x - Self.size * 0.55, y: seat.y - Self.size * 0.35, width: Self.size * 1.1, height: Self.size * 1.35)
    }

    func update(_ window: ForeignWindow?) {
        self.window = window
        refresh()
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

    private func refresh() {
        guard let window, window.onScreen, let seat else {
            if !lifted { panel.orderOut(nil) }
            return
        }
        let left = seat.x + Self.panelSize.width / 2 > (Screens.containing(seat)?.visibleFrame.maxX ?? .infinity)
        if model.bubbleOnLeft != left { model.bubbleOnLeft = left }
        let origin = NSPoint(x: (seat.x - Self.panelSize.width / 2).rounded(), y: (seat.y - Self.seatDepth).rounded())
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
