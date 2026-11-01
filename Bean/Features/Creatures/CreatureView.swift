import SwiftUI

enum CreaturePose: Equatable {
    case peek
    case perch
    case hang
    case dangle
}

struct CreatureMotion: Equatable {
    var time: Double = 0
    var swing: Double = 0
    var flail: Double = 0
}

struct CreaturePalette {
    let body: Color
    let top: Color
    let deep: Color
    let stub: Color
    let eye: Color
    let ink: Color

    static let pearl = CreaturePalette(body: Color(red: 0.9, green: 0.91, blue: 0.96), top: .white,
                                       deep: Color(red: 0.62, green: 0.65, blue: 0.78), stub: Color(red: 0.7, green: 0.72, blue: 0.82),
                                       eye: Color(white: 0.1), ink: Color(white: 0.82))

    init(look: Agent.Look) {
        self = look.isPearl ? .pearl : CreaturePalette(hue: look.hue)
    }

    init(hue: Double) {
        let h = hue - floor(hue)
        body = Color(hue: h, saturation: 0.6, brightness: 0.97)
        top = Color(hue: h, saturation: 0.28, brightness: 1)
        deep = Color(hue: h, saturation: 0.82, brightness: 0.74)
        stub = Color(hue: h, saturation: 0.72, brightness: 0.8)
        eye = Color(hue: h, saturation: 0.6, brightness: 0.12)
        ink = Color(hue: h, saturation: 0.34, brightness: 0.86)
    }

    private init(body: Color, top: Color, deep: Color, stub: Color, eye: Color, ink: Color) {
        self.body = body
        self.top = top
        self.deep = deep
        self.stub = stub
        self.eye = eye
        self.ink = ink
    }
}

struct CreatureView: View {
    static let widthRatio: CGFloat = 1.5
    static let heightRatio: CGFloat = 1.75
    static let tip: CGFloat = 0.2
    static let bottom: CGFloat = 1.36
    static let center = CGPoint(x: 0.75, y: 0.8)
    static let gripAnchor = UnitPoint(x: 0.5, y: tip / heightRatio)
    static let seatAnchor = UnitPoint(x: 0.5, y: (bottom - 0.03) / heightRatio)

    static func frame(_ size: CGFloat) -> CGSize {
        CGSize(width: size * widthRatio, height: size * heightRatio)
    }

    let look: Agent.Look
    var mood: AgentActivity.Mood = .idle
    var size: CGFloat
    var pose: CreaturePose = .perch
    var limbs: CGFloat = 1
    var motion: CreatureMotion?
    var shine: CGFloat?
    var pearl = false
    var lookAt: CGSize?
    var flat = false
    var ink: Color?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let motion {
            body(motion)
        } else if !reduceMotion, mood == .working || mood == .needsYou || mood.isForming {
            TimelineView(.animation(minimumInterval: mood == .needsYou ? 1.0 / 8 : 1.0 / 15)) { context in
                body(CreatureMotion(time: context.date.timeIntervalSinceReferenceDate))
            }
        } else {
            body(CreatureMotion())
        }
    }

    private func body(_ motion: CreatureMotion) -> some View {
        let pearl = pearl || look.isPearl
        return CreatureBody(palette: pearl ? .pearl : CreaturePalette(hue: look.hue), pearl: pearl, mark: Agent.Look.symbol(for: look.accessory), mood: mood, size: size, pose: pose,
                     limbs: limbs, motion: motion, shineOverride: shine, lookAt: lookAt, flat: flat, ink: ink)
    }
}

private struct CreatureBody: View {
    let palette: CreaturePalette
    let pearl: Bool
    let mark: String?
    let mood: AgentActivity.Mood
    let size: CGFloat
    let pose: CreaturePose
    let limbs: CGFloat
    let motion: CreatureMotion
    let shineOverride: CGFloat?
    let lookAt: CGSize?
    let flat: Bool
    let ink: Color?

    @State private var blink = false
    @State private var gaze = CGSize.zero
    @State private var kick = 0.0
    @State private var shine: CGFloat = -1.6
    @State private var snooze = false

    private var t: Double { motion.time }

    private var fill: CGFloat {
        guard case .forming(let since) = mood else { return 1 }
        return 1 - 0.82 * exp(-max(0, t - since.timeIntervalSinceReferenceDate) / 4.5)
    }

    var body: some View {
        let d = size
        let c = CreatureView.center
        ZStack {
            if mood == .needsYou, !flat {
                Circle().fill(palette.body.opacity(0.42 + 0.22 * sin(t * 2.4)))
                    .frame(width: d * 1.9, height: d * 1.9)
                    .blur(radius: d * 0.38)
                    .position(x: c.x * d, y: (CreatureView.tip + 0.66) * d)
            }
            if limbs > 0.01 { feet }
            arms
            Group {
                if flat { glyph } else { drop }
            }
                .shadow(color: flat ? .clear : .black.opacity(0.28), radius: d * 0.06, y: d * 0.04)
                .position(x: c.x * d, y: (CreatureView.tip + 0.58) * d + bob)
            if mood == .sleeping { Snore(d: d, on: snooze).position(x: (c.x + 0.45) * d, y: (CreatureView.tip + 0.2) * d) }
        }
        .frame(width: d * CreatureView.widthRatio, height: d * CreatureView.heightRatio)
        .task(id: mood) { await idleLoop() }
    }

    private var bob: CGFloat {
        guard mood == .working, pose != .dangle, pose != .hang else { return 0 }
        return pose == .peek ? -(0.5 + 0.5 * sin(t * 2.6)) * 0.06 * size : -abs(sin(t * 7)) * 0.07 * size
    }

    private var drop: some View {
        let d = size
        let shape = DropShape()
        return ZStack {
            shape.fill(LinearGradient(stops: [.init(color: palette.top, location: 0),
                                              .init(color: palette.body, location: 0.45),
                                              .init(color: palette.deep, location: 1)],
                                      startPoint: .top, endPoint: .bottom))
            if fill < 1 { unformed }
            if pearl {
                shape.fill(AngularGradient(colors: [.pink.opacity(0.2), .cyan.opacity(0.2), .yellow.opacity(0.14), .purple.opacity(0.2), .pink.opacity(0.2)],
                                           center: UnitPoint(x: 0.4, y: 0.7)))
            }
            ZStack {
                Rectangle().fill(LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(width: d * 0.32, height: d * 1.6)
                    .rotationEffect(.degrees(24))
                    .offset(x: (shineOverride ?? shine) * d)
                RadialGradient(colors: [.white.opacity(0.5), .white.opacity(0)], center: UnitPoint(x: 0.5, y: 0.08), startRadius: 0, endRadius: d * 0.36)
                RadialGradient(colors: [palette.top.opacity(0.55), .clear], center: UnitPoint(x: 0.5, y: 1.08), startRadius: 0, endRadius: d * 0.4)
            }
            .frame(width: d, height: d * 1.16)
            .mask(shape)
            if let mark {
                Image(systemName: mark)
                    .font(.system(size: d * 0.22, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
                    .offset(y: -d * 0.12)
            }
            eyes.offset(y: d * 0.15)
        }
        .frame(width: d, height: d * 1.16)
    }

    // A row's icons are one flat ink, with what is behind them showing through their holes.
    private var glyph: some View {
        let d = size
        return ZStack {
            if mood == .needsYou {
                DropShape().fill(palette.body).opacity(0.8 + 0.2 * sin(t * 2.4))
            } else {
                DropShape().fill(ink ?? palette.ink)
            }
            eyes.offset(y: d * 0.15).blendMode(.destinationOut)
        }
        .compositingGroup()
        .frame(width: d, height: d * 1.16)
    }

    private var unformed: some View {
        let d = size
        let level = d * 1.16 * (1 - fill)
        return ZStack(alignment: .top) {
            Rectangle().fill(LinearGradient(colors: [.white, CreaturePalette.pearl.body], startPoint: .top, endPoint: .bottom))
                .frame(height: level)
            Capsule().fill(.white.opacity(0.75)).frame(height: max(1, d * 0.04)).blur(radius: 0.5).offset(y: level - d * 0.02)
        }
        .frame(width: d, height: d * 1.16, alignment: .top)
        .mask(DropShape())
    }

    private var eyes: some View {
        let d = size
        let at = currentGaze
        return HStack(spacing: d * 0.11) {
            eye(at)
            eye(at)
        }
        .scaleEffect(mood == .needsYou ? 1.12 : 1)
    }

    private func eye(_ at: CGSize) -> some View {
        let d = size
        let w = d * 0.23
        return ZStack {
            if mood == .sleeping || mood.isForming {
                ClosedEye().stroke(palette.eye, style: StrokeStyle(lineWidth: max(1, d * 0.045), lineCap: .round))
                    .frame(width: w * 0.85, height: w * 0.35)
            } else {
                Circle().fill(palette.eye)
                if !flat { Circle().fill(.white).frame(width: w * 0.4).offset(x: w * 0.17, y: -w * 0.17) }
            }
        }
        .frame(width: w, height: w)
        .offset(x: at.width * d * 0.035, y: at.height * d * 0.03)
        .scaleEffect(x: 1, y: blink && mood != .sleeping && !mood.isForming ? 0.1 : 1)
        .animation(.easeInOut(duration: 0.07), value: blink)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: gaze)
    }

    private var currentGaze: CGSize {
        if let lookAt, pose != .dangle, mood == .idle || mood == .needsYou { return lookAt }
        return switch (pose, mood) {
        case (.dangle, _): CGSize(width: max(-1, min(1, -motion.swing * 2)), height: 0.8)
        case (_, .working): CGSize(width: sin(t * 2.2) * 0.6, height: 0.9)
        case (_, .needsYou): CGSize(width: 0, height: -0.4)
        default: gaze
        }
    }

    private func stub(_ length: CGFloat, _ angle: Double, at point: CGPoint) -> some View {
        Capsule()
            .fill(LinearGradient(colors: [palette.deep, palette.stub], startPoint: .top, endPoint: .bottom))
            .frame(width: size * 0.15, height: max(length, size * 0.15))
            .rotationEffect(.radians(angle), anchor: .top)
            .position(x: point.x, y: point.y + max(length, size * 0.15) / 2)
    }

    private var feet: some View {
        let d = size
        let len = d * 0.26 * limbs
        let hipY = (CreatureView.bottom - 0.1) * d + bob
        let angles: (Double, Double)
        switch pose {
        case .dangle:
            let wiggle = sin(t * 11) * 0.4 * motion.flail
            angles = (-motion.swing * 0.7 + 0.12 + wiggle, -motion.swing * 0.7 - 0.12 - wiggle)
        case .perch, .hang:
            let a = mood == .working ? sin(t * 5) * 0.3 : kick * 0.35
            let b = mood == .working ? sin(t * 5 + 1.6) * 0.3 : -kick * 0.2
            angles = (0.06 + a, -0.06 + b)
        case .peek:
            angles = (0.08, -0.08)
        }
        return ZStack {
            stub(len, angles.0, at: CGPoint(x: (CreatureView.center.x - 0.15) * d, y: hipY))
            stub(len, angles.1, at: CGPoint(x: (CreatureView.center.x + 0.15) * d, y: hipY))
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.45), value: kick)
    }

    @ViewBuilder private var arms: some View {
        let d = size
        let shoulderY = (CreatureView.tip + 0.62) * d + bob
        let left = CGPoint(x: (CreatureView.center.x - 0.43) * d, y: shoulderY)
        let right = CGPoint(x: (CreatureView.center.x + 0.43) * d, y: shoulderY)
        let len = d * 0.24 * limbs
        switch (pose, mood) {
        case (.hang, _):
            stub(d * 0.66 * limbs, .pi - 0.35, at: left)
            stub(d * 0.66 * limbs, -.pi + 0.35, at: right)
        case (.dangle, _):
            let wave = sin(t * 9) * 0.25 * motion.flail
            stub(len, 2.55 + wave, at: left)
            stub(len, -2.55 - wave, at: right)
        case (.perch, .needsYou):
            stub(len, -2.7 + sin(t * 9) * 0.35, at: right)
        case (.perch, .working):
            stub(len * 0.8, 0.5 + sin(t * 16) * 0.35, at: left)
            stub(len * 0.8, -0.5 - sin(t * 16 + 2) * 0.35, at: right)
        default:
            EmptyView()
        }
    }

    private func idleLoop() async {
        gaze = .zero
        var beat = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 1.8...3.4)))
            if Task.isCancelled { return }
            beat += 1
            if pose != .peek && mood != .sleeping && beat % 3 == 0 {
                shine = -1.6
                withAnimation(.easeInOut(duration: 1.1)) { shine = 1.6 }
            }
            switch mood {
            case .idle:
                if Bool.random() {
                    blink = true
                    try? await Task.sleep(for: .milliseconds(120))
                    blink = false
                }
                gaze = Double.random(in: 0...1) < 0.35 ? .zero : CGSize(width: .random(in: -1...1), height: .random(in: -0.6...0.6))
                if Double.random(in: 0...1) < 0.3 { kick = kick == 0 ? 1 : 0 }
            case .reading:
                for x in stride(from: -0.9, through: 0.9, by: 0.45) {
                    gaze = CGSize(width: x, height: 0.8)
                    try? await Task.sleep(for: .milliseconds(380))
                }
            case .sleeping:
                withAnimation(.easeOut(duration: 1.6)) { snooze.toggle() }
            case .working, .needsYou, .forming:
                blink = true
                try? await Task.sleep(for: .milliseconds(110))
                blink = false
            }
        }
    }
}

struct DropShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + h * 0.62),
                   control1: CGPoint(x: r.midX + w * 0.2, y: r.minY + h * 0.2),
                   control2: CGPoint(x: r.maxX, y: r.minY + h * 0.36))
        p.addCurve(to: CGPoint(x: r.minX, y: r.minY + h * 0.62),
                   control1: CGPoint(x: r.maxX, y: r.maxY + h * 0.06),
                   control2: CGPoint(x: r.minX, y: r.maxY + h * 0.06))
        p.addCurve(to: CGPoint(x: r.midX, y: r.minY),
                   control1: CGPoint(x: r.minX, y: r.minY + h * 0.36),
                   control2: CGPoint(x: r.midX - w * 0.2, y: r.minY + h * 0.2))
        return p
    }
}

private struct ClosedEye: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY * 1.6))
        return p
    }
}

private struct Snore: View {
    let d: CGFloat
    let on: Bool

    var body: some View {
        Text("z")
            .font(.system(size: max(7, d * 0.3), weight: .heavy, design: .rounded))
            .foregroundStyle(.white.opacity(on ? 0 : 0.9))
            .offset(x: on ? d * 0.15 : 0, y: on ? -d * 0.3 : 0)
            .scaleEffect(on ? 1.3 : 0.8)
    }
}
