import AppKit
import SwiftUI

final class DragStageModel: ObservableObject {
    @Published var look = Agent.Look(hue: 0.3, accessory: "none")
    @Published var mood: AgentActivity.Mood = .idle
    @Published var visible = false
    @Published var grip = CGPoint.zero
    @Published var size: CGFloat = 20
    @Published var limbs: CGFloat = 0
    @Published var angle: Double = 0
    @Published var motion = CreatureMotion()
    @Published var pose: CreaturePose = .dangle
    @Published var highlight: CGRect?
    @Published var home: CGRect?
    @Published var tether: CGPoint?
    @Published var stretch: CGFloat = 0
}

struct DragStageView: View {
    @ObservedObject var model: DragStageModel

    var body: some View {
        let tint = CreaturePalette(look: model.look).body
        let frame = CreatureView.frame(model.size)
        ZStack(alignment: .topLeading) {
            if let rect = model.highlight {
                ZStack {
                    Capsule().fill(tint).frame(width: rect.width * 0.86, height: 4).blur(radius: 5)
                    Capsule().fill(LinearGradient(colors: [.clear, tint, .white, tint, .clear], startPoint: .leading, endPoint: .trailing))
                        .frame(width: rect.width * 0.8, height: 2)
                }
                .position(x: rect.midX, y: rect.minY + 1)
                .transition(.opacity)
            }
            if let tether = model.tether, model.visible {
                Thread(from: tether, to: CGPoint(x: model.grip.x, y: model.grip.y + model.size * 0.12), width: model.size * 0.32)
                    .fill(LinearGradient(colors: [CreaturePalette(look: model.look).top, tint], startPoint: .top, endPoint: .bottom))
            }
            if let rect = model.home {
                ZStack {
                    Capsule().fill(tint).frame(width: rect.width * 0.8, height: 4).blur(radius: 5)
                    Capsule().fill(LinearGradient(colors: [.clear, tint, .white, tint, .clear], startPoint: .leading, endPoint: .trailing))
                        .frame(width: rect.width * 0.7, height: 2)
                }
                .position(x: rect.midX, y: rect.maxY + 1)
                .transition(.opacity)
            }
            if model.visible {
                CreatureView(look: model.look, mood: model.mood, size: model.size, pose: model.pose, limbs: model.limbs, motion: model.motion)
                    .scaleEffect(x: 1 - model.stretch * 0.45, y: 1 + model.stretch, anchor: CreatureView.gripAnchor)
                    .rotationEffect(.radians(model.angle), anchor: CreatureView.gripAnchor)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 4)
                    .position(x: model.grip.x, y: model.grip.y - frame.height * CreatureView.gripAnchor.y + frame.height / 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: model.highlight)
        .animation(.easeOut(duration: 0.15), value: model.home)
    }
}

private struct Thread: Shape {
    let from: CGPoint
    let to: CGPoint
    let width: CGFloat

    func path(in rect: CGRect) -> Path {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = max(hypot(dx, dy), 1)
        let n = CGPoint(x: -dy / length, y: dx / length)
        let pinch = max(0.08, 1 - length / DragStage.snapLength)
        let ends = width / 2, waist = width / 2 * pinch * 0.5
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        func side(_ p: CGPoint, _ r: CGFloat) -> CGPoint { CGPoint(x: p.x + n.x * r, y: p.y + n.y * r) }
        var p = Path()
        p.move(to: side(from, ends))
        p.addQuadCurve(to: side(to, ends), control: side(mid, waist))
        p.addLine(to: side(to, -ends))
        p.addQuadCurve(to: side(from, -ends), control: side(mid, -waist))
        p.closeSubpath()
        p.addEllipse(in: CGRect(x: from.x - ends, y: from.y - ends, width: 2 * ends, height: 2 * ends))
        return p
    }
}

final class DragStage: NSObject {
    enum Drop {
        case window(ForeignWindow)
        case home
    }

    struct Flight {
        let from: CGPoint
        let to: CGPoint
        let fromSize: CGFloat
        let toSize: CGFloat
        let fromLimbs: CGFloat
        let toLimbs: CGFloat
        let pose: CreaturePose
        let duration: Double
        let lift: CGFloat
        var elapsed: Double = 0
        let done: () -> Void
    }

    static let heldSize: CGFloat = 46
    static let snapLength: CGFloat = 90
    static let cursorOffset = CGPoint(x: 5, y: -17)

    let model = DragStageModel()
    var homeZone: () -> NSRect = { .zero }
    private let panel: NSPanel
    private var link: CADisplayLink?
    private var held = false
    private var flight: Flight?
    private var anchor = CGPoint.zero
    private var velocity = CGVector.zero
    private var accel = CGVector.zero
    private var spin = 0.0
    private var targets: [ForeignWindow] = []
    private var target: Drop?
    private var lastTime: CFTimeInterval = 0
    private var onRelease: ((Drop?) -> Void)?

    override init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NotchController.level.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: DragStageView(model: model))
    }

    var isActive: Bool { held || flight != nil }

    func begin(look: Agent.Look, mood: AgentActivity.Mood, from point: NSPoint, size: CGFloat, limbs: CGFloat, tethered: Bool = false,
               release: @escaping (Drop?) -> Void) {
        show(look: look, mood: mood, at: point, size: size, limbs: limbs)
        onRelease = release
        targets = ForeignWindow.pickable()
        held = true
        model.tether = tethered ? local(point) : nil
        start()
    }

    func launch(look: Agent.Look, mood: AgentActivity.Mood, from point: NSPoint, size: CGFloat, limbs: CGFloat) {
        show(look: look, mood: mood, at: point, size: size, limbs: limbs)
    }

    private func show(look: Agent.Look, mood: AgentActivity.Mood, at point: NSPoint, size: CGFloat, limbs: CGFloat) {
        anchor = point
        velocity = .zero
        accel = .zero
        spin = 0
        flight = nil
        cover(screen: Screens.containing(point))
        model.look = look
        model.mood = mood
        model.size = size
        model.limbs = limbs
        model.angle = 0
        model.stretch = 0
        model.pose = .dangle
        model.grip = local(point)
        model.visible = true
        panel.orderFrontRegardless()
    }

    func release() {
        guard held else { return }
        held = false
        model.highlight = nil
        model.home = nil
        model.tether = nil
        let drop = target
        target = nil
        onRelease?(drop)
        onRelease = nil
    }

    func fly(to point: NSPoint, size: CGFloat, limbs: CGFloat, pose: CreaturePose, duration: Double, lift: CGFloat, done: @escaping () -> Void) {
        flight = Flight(from: anchor, to: point, fromSize: model.size, toSize: size, fromLimbs: model.limbs, toLimbs: limbs,
                        pose: pose, duration: duration, lift: lift, done: done)
        start()
    }

    func hide() {
        flight = nil
        held = false
        model.visible = false
        model.highlight = nil
        model.home = nil
        model.tether = nil
        link?.invalidate()
        link = nil
        panel.orderOut(nil)
    }

    private func start() {
        guard link == nil, let view = panel.contentView else { return }
        lastTime = 0
        let link = view.displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func cover(screen: NSScreen?) {
        guard let screen, panel.frame != screen.frame else { return }
        panel.setFrame(screen.frame, display: false)
    }

    private func local(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x - panel.frame.minX, y: panel.frame.maxY - p.y)
    }

    private func local(_ r: NSRect) -> CGRect {
        CGRect(x: r.minX - panel.frame.minX, y: panel.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTime == 0 ? 1.0 / 60 : min(max(now - lastTime, 1.0 / 240), 1.0 / 20)
        lastTime = now
        if held {
            if NSEvent.pressedMouseButtons & 1 == 0 { release() }
            holdStep(dt)
        }
        if flight != nil { flightStep(dt) }
        guard held || flight != nil else { return }
        model.grip = local(anchor)
        model.motion = CreatureMotion(time: now, swing: spin * 0.06 + model.angle * 0.5,
                                      flail: min(1, hypot(velocity.dx, velocity.dy) / 700))
    }

    private func holdStep(_ dt: Double) {
        let mouse = NSEvent.mouseLocation
        cover(screen: Screens.containing(mouse))
        let goal = CGPoint(x: mouse.x + Self.cursorOffset.x, y: mouse.y + Self.cursorOffset.y)
        let k = 700.0, c = 2 * sqrt(k) * 0.72
        let ax = k * (goal.x - anchor.x) - c * velocity.dx
        let ay = k * (goal.y - anchor.y) - c * velocity.dy
        velocity.dx += ax * dt
        velocity.dy += ay * dt
        anchor.x += velocity.dx * dt
        anchor.y += velocity.dy * dt
        accel = CGVector(dx: accel.dx * 0.6 + ax * 0.4, dy: accel.dy * 0.6 + ay * 0.4)
        swingStep(dt, ax: accel.dx, ay: -accel.dy)

        if let tether = model.tether, hypot(model.grip.x - tether.x, model.grip.y - tether.y) > Self.snapLength {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { model.tether = nil }
        }
        let stretch = min(0.2, hypot(velocity.dx, velocity.dy) / 4200)
        model.stretch += (stretch - model.stretch) * min(1, dt * 14)
        model.size += (Self.heldSize - model.size) * min(1, dt * 10)
        model.limbs += (1 - model.limbs) * min(1, dt * 9)

        if homeZone().insetBy(dx: -24, dy: -24).contains(mouse) {
            target = .home
            model.highlight = nil
            model.home = local(homeZone().insetBy(dx: -4, dy: -4))
        } else if let window = ForeignWindow.under(mouse, in: targets) {
            target = .window(window)
            model.highlight = local(window.appKitFrame).insetBy(dx: -2, dy: -2)
            model.home = nil
        } else {
            target = nil
            model.highlight = nil
            model.home = nil
        }
    }

    private func swingStep(_ dt: Double, ax: Double, ay: Double) {
        let length = 34.0, g = 1900.0
        let theta = model.angle
        let torque = (ax * cos(theta) - (g - ay) * sin(theta)) / length
        spin += (torque - 3.2 * spin) * dt
        model.angle = max(-1.25, min(1.25, theta + spin * dt))
    }

    private func flightStep(_ dt: Double) {
        guard var f = flight else { return }
        f.elapsed += dt
        let p = min(1, f.elapsed / f.duration)
        let e = 1 - pow(1 - p, 3)
        let mid = CGPoint(x: (f.from.x + f.to.x) / 2, y: max(f.from.y, f.to.y) + f.lift)
        let u = 1 - e
        anchor = CGPoint(x: u * u * f.from.x + 2 * u * e * mid.x + e * e * f.to.x,
                         y: u * u * f.from.y + 2 * u * e * mid.y + e * e * f.to.y)
        model.size = f.fromSize + (f.toSize - f.fromSize) * e
        model.limbs = f.fromLimbs + (f.toLimbs - f.fromLimbs) * e
        model.angle *= max(0, 1 - dt * 10)
        model.stretch *= max(0, 1 - dt * 12)
        if p > 0.55, model.pose != f.pose { model.pose = f.pose }
        spin = 0
        velocity = .zero
        if p >= 1 {
            model.stretch = 0
            flight = nil
            f.done()
        } else {
            flight = f
        }
    }
}
