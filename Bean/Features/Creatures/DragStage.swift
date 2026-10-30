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
}

struct DragStageView: View {
    @ObservedObject var model: DragStageModel

    var body: some View {
        let tint = CreaturePalette(hue: model.look.hue).body
        let frame = CreatureView.frame(model.size)
        ZStack(alignment: .topLeading) {
            if let rect = model.highlight {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint, lineWidth: 3))
                    .shadow(color: tint.opacity(0.9), radius: 10)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .transition(.opacity)
            }
            if let rect = model.home {
                Capsule().strokeBorder(tint, lineWidth: 2.5)
                    .shadow(color: tint, radius: 8)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .transition(.opacity)
            }
            if model.visible {
                CreatureView(look: model.look, mood: model.mood, size: model.size, pose: model.pose, limbs: model.limbs, motion: model.motion)
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
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: DragStageView(model: model))
    }

    var isActive: Bool { held || flight != nil }

    func begin(look: Agent.Look, mood: AgentActivity.Mood, from point: NSPoint, size: CGFloat, limbs: CGFloat, release: @escaping (Drop?) -> Void) {
        onRelease = release
        targets = ForeignWindow.pickable()
        anchor = point
        velocity = .zero
        accel = .zero
        spin = 0
        flight = nil
        held = true
        cover(screen: Screens.containing(NSEvent.mouseLocation))
        model.look = look
        model.mood = mood
        model.size = size
        model.limbs = limbs
        model.angle = 0
        model.pose = .dangle
        model.grip = local(point)
        model.visible = true
        panel.orderFrontRegardless()
        start()
    }

    func release() {
        guard held else { return }
        held = false
        model.highlight = nil
        model.home = nil
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
        spin = 0
        velocity = .zero
        if p >= 1 {
            model.pose = f.pose
            flight = nil
            f.done()
        } else {
            flight = f
        }
    }
}
