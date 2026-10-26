import AppKit
import SwiftUI

final class ScreenOverlayModel: ObservableObject {
    @Published var glow: CGFloat = 0
    @Published var target: CGRect?
}

final class ScreenOverlay {
    let model = ScreenOverlayModel()
    private let window: NSPanel
    private var screen: NSScreen?
    private var hideWork: DispatchWorkItem?

    init() {
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = NSHostingView(rootView: ScreenOverlayView(model: model))
    }

    var isVisible: Bool { window.isVisible }

    func place(on screen: NSScreen) {
        self.screen = screen
        window.setFrame(screen.frame, display: false)
    }

    func takeControl(below panel: NSWindow) {
        hideWork?.cancel()
        window.order(.below, relativeTo: panel.windowNumber)
        withAnimation(.easeOut(duration: 1.1)) { model.glow = 1 }
    }

    func release() {
        guard window.isVisible else { return }
        withAnimation(.easeInOut(duration: 0.3)) { model.target = nil }
        withAnimation(.easeIn(duration: 0.8)) { model.glow = 0 }
        let work = DispatchWorkItem { [weak self] in self?.window.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    func highlight(_ globalRect: CGRect?) {
        guard let screen, let primary = NSScreen.screens.first else { return }
        let local = globalRect.map {
            CGRect(x: $0.minX - screen.frame.minX,
                   y: $0.minY - (primary.frame.maxY - screen.frame.maxY),
                   width: $0.width, height: $0.height)
        }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { model.target = local }
    }
}

struct ScreenOverlayView: View {
    @ObservedObject var model: ScreenOverlayModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            TimelineView(.animation(paused: model.glow == 0)) { context in
                let angle = Angle.degrees(context.date.timeIntervalSinceReferenceDate * 50)
                ZStack {
                    edge(width: 36, blur: 28, opacity: 0.55, angle: angle)
                    edge(width: 14, blur: 8, opacity: 0.8, angle: angle)
                    edge(width: 3, blur: 0.6, opacity: 0.95, angle: angle)
                }
            }
            if let target = model.target {
                TargetHalo()
                    .frame(width: target.width + 14, height: target.height + 14)
                    .position(x: target.midX, y: target.midY)
                    .transition(.scale(scale: 1.6).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private func edge(width: CGFloat, blur: CGFloat, opacity: Double, angle: Angle) -> some View {
        GlowEdge(progress: model.glow, radius: 12)
            .stroke(AngularGradient(colors: ScreenOverlayView.palette, center: .center, angle: angle),
                    style: StrokeStyle(lineWidth: width, lineCap: .round))
            .blur(radius: blur)
            .opacity(opacity)
    }

    static let palette: [Color] = [
        Color(red: 0.30, green: 0.98, blue: 0.56),
        Color(red: 0.20, green: 0.84, blue: 1.00),
        Color(red: 0.50, green: 0.52, blue: 1.00),
        Color(red: 0.78, green: 1.00, blue: 0.32),
        Color(red: 0.30, green: 0.98, blue: 0.56),
    ]
}

struct GlowEdge: Shape {
    var progress: CGFloat
    let radius: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in r: CGRect) -> Path {
        guard progress > 0 else { return Path() }
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: radius)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.midX, y: r.minY), radius: radius)
        p.closeSubpath()
        let half = min(progress, 1) / 2
        var out = p.trimmedPath(from: 0, to: half)
        out.addPath(p.trimmedPath(from: 1 - half, to: 1))
        return out
    }
}

struct TargetHalo: View {
    @State private var pulse = false

    var body: some View {
        let green = ScreenOverlayView.palette[0]
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(green.opacity(0.10))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(green, lineWidth: 2))
            .shadow(color: green.opacity(0.9), radius: pulse ? 14 : 6)
            .scaleEffect(pulse ? 1.04 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
            }
    }
}
