import AppKit
import SwiftUI

final class PerchModel: ObservableObject {
    @Published var name = ""
    @Published var look = Agent.Look(hue: 0.3, accessory: "none")
    @Published var mood: AgentActivity.Mood = .idle
    @Published var bubble: String?
    @Published var bubbleBelow = false
    @Published var landings = 0
}

struct PerchView: View {
    @ObservedObject var model: PerchModel
    let onDragStart: () -> Void
    let onRelease: (Bool) -> Void
    @State private var dragging = false
    @State private var squash = false

    var body: some View {
        let frame = CreatureView.frame(Perch.size)
        VStack(spacing: 0) {
            if !model.bubbleBelow { bubble.frame(height: Perch.bubbleSpace, alignment: .bottom) }
            CreatureView(look: model.look, mood: model.mood, size: Perch.size, pose: .perch)
                .scaleEffect(x: squash ? 1.18 : 1, y: squash ? 0.8 : 1, anchor: CreatureView.seatAnchor)
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
            if model.bubbleBelow { bubble.frame(height: Perch.bubbleSpace, alignment: .top) }
        }
        .frame(width: Perch.panelSize.width, height: Perch.panelSize.height)
        .onChange(of: model.landings) {
            squash = true
            withAnimation(.spring(response: 0.32, dampingFraction: 0.45)) { squash = false }
        }
    }

    @ViewBuilder private var bubble: some View {
        if let text = model.bubble, !text.isEmpty {
            CreatureBubble(text: text, tint: CreaturePalette(hue: model.look.hue).body)
                .padding(.horizontal, 8)
                .transition(.scale(scale: 0.6, anchor: model.bubbleBelow ? .top : .bottom).combined(with: .opacity))
        } else {
            Color.clear
        }
    }
}

final class Perch {
    static let size: CGFloat = 38
    static let bubbleSpace: CGFloat = 76
    static let panelSize = CGSize(width: 240, height: bubbleSpace + CreatureView.frame(size).height)
    static let seatDepth = CreatureView.frame(size).height * (1 - CreatureView.seatAnchor.y)
    static let headroom = size * 1.05

    let id: UUID
    let model = PerchModel()
    let panel: NSPanel
    private(set) var window: ForeignWindow?
    var fraction: CGFloat
    var lifted = false { didSet { refresh() } }

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

    func dismiss() {
        panel.orderOut(nil)
    }

    private func refresh() {
        guard let window, window.onScreen, let seat else {
            if !lifted { panel.orderOut(nil) }
            return
        }
        let below = seat.y - Self.seatDepth + Self.panelSize.height > (Screens.containing(seat)?.visibleFrame.maxY ?? .infinity)
        if model.bubbleBelow != below { model.bubbleBelow = below }
        let seatFromBottom = below ? Self.panelSize.height - CreatureView.frame(Self.size).height * CreatureView.seatAnchor.y : Self.seatDepth
        let origin = NSPoint(x: (seat.x - Self.panelSize.width / 2).rounded(), y: (seat.y - seatFromBottom).rounded())
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        panel.alphaValue = lifted ? 0 : 1
        if !panel.isVisible {
            panel.order(.above, relativeTo: window.number)
        }
    }
}
