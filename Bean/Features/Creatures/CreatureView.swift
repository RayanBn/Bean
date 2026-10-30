import SwiftUI

enum CreaturePose: Equatable {
    case peek
    case perch
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

    init(hue: Double) {
        let h = hue - floor(hue)
        body = Color(hue: h, saturation: 0.6, brightness: 0.97)
        top = Color(hue: h, saturation: 0.28, brightness: 1)
        deep = Color(hue: h, saturation: 0.82, brightness: 0.74)
        stub = Color(hue: h, saturation: 0.72, brightness: 0.8)
        eye = Color(hue: h, saturation: 0.6, brightness: 0.12)
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

    var body: some View {
        if let motion {
            CreatureBody(look: look, mood: mood, size: size, pose: pose, limbs: limbs, motion: motion, shineOverride: shine)
        } else if mood == .working || mood == .needsYou {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                CreatureBody(look: look, mood: mood, size: size, pose: pose, limbs: limbs,
                             motion: CreatureMotion(time: context.date.timeIntervalSinceReferenceDate), shineOverride: shine)
            }
        } else {
            CreatureBody(look: look, mood: mood, size: size, pose: pose, limbs: limbs, motion: CreatureMotion(), shineOverride: shine)
        }
    }
}

private struct CreatureBody: View {
    let look: Agent.Look
    let mood: AgentActivity.Mood
    let size: CGFloat
    let pose: CreaturePose
    let limbs: CGFloat
    let motion: CreatureMotion
    let shineOverride: CGFloat?

    @State private var blink = false
    @State private var gaze = CGSize.zero
    @State private var kick = 0.0
    @State private var shine: CGFloat = -1.6
    @State private var snooze = false

    private var palette: CreaturePalette { CreaturePalette(hue: look.hue) }
    private var t: Double { motion.time }

    var body: some View {
        let d = size
        let c = CreatureView.center
        ZStack {
            if limbs > 0.01 { feet }
            arms
            drop
                .shadow(color: .black.opacity(0.28), radius: d * 0.06, y: d * 0.04)
                .position(x: c.x * d, y: (CreatureView.tip + 0.58) * d + bob)
            if mood == .sleeping { Snore(d: d, on: snooze).position(x: (c.x + 0.45) * d, y: (CreatureView.tip + 0.2) * d) }
            if mood == .needsYou && pose == .peek { Alert(d: d).position(x: (c.x + 0.5) * d, y: (CreatureView.tip + 0.3) * d) }
        }
        .frame(width: d * CreatureView.widthRatio, height: d * CreatureView.heightRatio)
        .task(id: mood) { await idleLoop() }
    }

    private var bob: CGFloat {
        guard mood == .working, pose != .dangle else { return 0 }
        return -abs(sin(t * 7)) * (pose == .peek ? 0.05 : 0.07) * size
    }

    private var drop: some View {
        let d = size
        let shape = DropShape()
        return ZStack {
            shape.fill(LinearGradient(stops: [.init(color: palette.top, location: 0),
                                              .init(color: palette.body, location: 0.45),
                                              .init(color: palette.deep, location: 1)],
                                      startPoint: .top, endPoint: .bottom))
            ZStack {
                Rectangle().fill(LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(width: d * 0.32, height: d * 1.6)
                    .rotationEffect(.degrees(24))
                    .offset(x: (shineOverride ?? shine) * d)
                Ellipse().fill(.white.opacity(0.55))
                    .frame(width: d * 0.15, height: d * 0.28)
                    .rotationEffect(.degrees(30))
                    .blur(radius: d * 0.02)
                    .offset(x: -d * 0.22, y: -d * 0.04)
            }
            .frame(width: d, height: d * 1.16)
            .mask(shape)
            eyes.offset(y: d * 0.15)
        }
        .frame(width: d, height: d * 1.16)
    }

    private var eyes: some View {
        let d = size
        let lookAt = currentGaze
        return HStack(spacing: d * 0.11) {
            eye(lookAt)
            eye(lookAt)
        }
        .scaleEffect(mood == .needsYou ? 1.12 : 1)
    }

    private func eye(_ lookAt: CGSize) -> some View {
        let d = size
        let w = d * 0.23
        return ZStack {
            if mood == .sleeping {
                ClosedEye().stroke(palette.eye, style: StrokeStyle(lineWidth: max(1, d * 0.045), lineCap: .round))
                    .frame(width: w * 0.85, height: w * 0.35)
            } else {
                Circle().fill(palette.eye)
                Circle().fill(.white).frame(width: w * 0.4).offset(x: w * 0.17, y: -w * 0.17)
            }
        }
        .frame(width: w, height: w)
        .offset(x: lookAt.width * d * 0.035, y: lookAt.height * d * 0.03)
        .scaleEffect(x: 1, y: blink && mood != .sleeping ? 0.1 : 1)
        .animation(.easeInOut(duration: 0.07), value: blink)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: gaze)
    }

    private var currentGaze: CGSize {
        switch (pose, mood) {
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
        case .perch:
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
            case .working, .needsYou:
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

private struct Alert: View {
    let d: CGFloat

    var body: some View {
        Text("!")
            .font(.system(size: max(8, d * 0.45), weight: .black, design: .rounded))
            .foregroundStyle(Color(red: 1, green: 0.8, blue: 0.2))
    }
}

struct CreatureBubble: View {
    let name: String
    let text: String
    let mood: AgentActivity.Mood
    let hue: Double
    let tailOnLeft: Bool

    var body: some View {
        let palette = CreaturePalette(hue: hue)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(palette.body).frame(width: 5, height: 5).shadow(color: palette.body, radius: 3)
                Text(name).font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(palette.top)
                if mood == .reading { ReadingDots(color: palette.top) }
                if mood == .needsYou {
                    Text("needs you").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundStyle(.black.opacity(0.8))
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Capsule().fill(palette.top))
                }
            }
            Text(text)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(LinearGradient(colors: [.black.opacity(0.5), .black.opacity(0.72)], startPoint: .top, endPoint: .bottom))
                shape.fill(RadialGradient(colors: [palette.body.opacity(0.28), .clear], center: .topLeading, startRadius: 0, endRadius: 140))
            }
            .environment(\.colorScheme, .dark)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.3), palette.body.opacity(mood == .needsYou ? 0.95 : 0.45)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
        .overlay(alignment: tailOnLeft ? .bottomLeading : .bottomTrailing) {
            BubbleTail(pointsLeft: tailOnLeft)
                .fill(.black.opacity(0.7))
                .frame(width: 8, height: 10)
                .offset(x: tailOnLeft ? -7 : 7, y: -7)
        }
        .shadow(color: palette.body.opacity(0.35), radius: 12)
        .shadow(color: .black.opacity(0.3), radius: 5, y: 3)
        .frame(maxWidth: 250, alignment: tailOnLeft ? .leading : .trailing)
    }
}

private struct BubbleTail: Shape {
    let pointsLeft: Bool

    func path(in r: CGRect) -> Path {
        var p = Path()
        let tip = pointsLeft ? r.minX : r.maxX
        let base = pointsLeft ? r.maxX : r.minX
        p.move(to: CGPoint(x: base, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: tip, y: r.maxY), control: CGPoint(x: (base + tip) / 2, y: r.midY))
        p.addLine(to: CGPoint(x: base, y: r.maxY - 2))
        p.closeSubpath()
        return p
    }
}

private struct ReadingDots: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<3) { i in
                    Circle().fill(color).frame(width: 3.5, height: 3.5)
                        .opacity(0.3 + 0.7 * (0.5 + 0.5 * sin(t * 6 - Double(i) * 0.9)))
                }
            }
        }
    }
}
