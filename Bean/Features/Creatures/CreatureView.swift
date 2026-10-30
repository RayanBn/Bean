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
    let shade: Color
    let light: Color
    let limb: Color
    let accent: Color

    init(hue: Double) {
        var h = hue - floor(hue)
        // Keeps a round creature clear of Minion yellow.
        if (0.1...0.19).contains(h) { h = h < 0.145 ? 0.08 : 0.22 }
        body = Color(hue: h, saturation: 0.56, brightness: 0.97)
        shade = Color(hue: h, saturation: 0.72, brightness: 0.70)
        light = Color(hue: h, saturation: 0.22, brightness: 1)
        limb = Color(hue: h, saturation: 0.66, brightness: 0.78)
        let c = h + 0.5
        accent = Color(hue: c - floor(c), saturation: 0.65, brightness: 0.92)
    }
}

struct CreatureView: View {
    static let widthRatio: CGFloat = 1.7
    static let heightRatio: CGFloat = 2.0
    static let center = CGPoint(x: 0.85, y: 0.95)
    static let gripAnchor = UnitPoint(x: 0.5, y: 0.26 / heightRatio)
    static let seatAnchor = UnitPoint(x: 0.5, y: 1.36 / heightRatio)

    static func frame(_ size: CGFloat) -> CGSize {
        CGSize(width: size * widthRatio, height: size * heightRatio)
    }

    let look: Agent.Look
    var mood: AgentActivity.Mood = .idle
    var size: CGFloat
    var pose: CreaturePose = .perch
    var limbs: CGFloat = 1
    var motion: CreatureMotion?

    var body: some View {
        if let motion {
            CreatureBody(look: look, mood: mood, size: size, pose: pose, limbs: limbs, motion: motion)
        } else if mood == .working || mood == .needsYou {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                CreatureBody(look: look, mood: mood, size: size, pose: pose, limbs: limbs,
                             motion: CreatureMotion(time: context.date.timeIntervalSinceReferenceDate))
            }
        } else {
            CreatureBody(look: look, mood: mood, size: size, pose: pose, limbs: limbs, motion: CreatureMotion())
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

    @State private var blink = false
    @State private var gaze = CGSize.zero
    @State private var kick = 0.0
    @State private var snooze = false

    private var palette: CreaturePalette { CreaturePalette(hue: look.hue) }
    private var t: Double { motion.time }

    var body: some View {
        let d = size
        let c = CreatureView.center
        ZStack {
            if limbs > 0.01 { legs }
            if pose == .dangle || mood == .needsYou { arms.zIndex(0) }
            if look.accessory == "antenna" { Antenna(palette: palette, d: d, bob: kick).position(x: c.x * d, y: (c.y - 0.47) * d) }
            torso
            if limbs > 0.01 && pose != .dangle && mood != .needsYou { arms }
            if mood == .sleeping { Snore(d: d, on: snooze).position(x: (c.x + 0.5) * d, y: (c.y - 0.55) * d) }
            if mood == .needsYou && pose == .peek { Alert(d: d).position(x: (c.x + 0.52) * d, y: (c.y - 0.3) * d) }
        }
        .frame(width: d * CreatureView.widthRatio, height: d * CreatureView.heightRatio)
        .task(id: mood) { await idleLoop() }
    }

    private var bodyOffset: CGFloat {
        switch (pose, mood) {
        case (.perch, .working): -abs(sin(t * 7)) * 0.07 * size
        case (.peek, .working): -abs(sin(t * 7)) * 0.05 * size
        default: 0
        }
    }

    private var torso: some View {
        let d = size
        let c = CreatureView.center
        return ZStack {
            Ellipse()
                .fill(RadialGradient(colors: [palette.light, palette.body, palette.shade],
                                     center: UnitPoint(x: 0.35, y: 0.28), startRadius: 0, endRadius: d * 0.72))
                .overlay(Ellipse().strokeBorder(palette.shade.opacity(0.55), lineWidth: max(0.7, d * 0.025)))
                .frame(width: d, height: d * 0.94)
            Ellipse().fill(palette.light.opacity(0.55)).frame(width: d * 0.46, height: d * 0.26).offset(y: d * 0.26)
            if look.accessory == "scarf" { Scarf(palette: palette, d: d) }
            face
            accessory
        }
        .scaleEffect(x: mood == .sleeping ? 1.04 : 1, y: mood == .sleeping ? 0.95 : 1, anchor: .bottom)
        .position(x: c.x * d, y: c.y * d + bodyOffset)
    }

    private var face: some View {
        let d = size
        let lookAt = currentGaze
        return ZStack {
            HStack(spacing: d * 0.04) {
                eye(lookAt)
                eye(lookAt)
            }
            .offset(y: -d * 0.06)
            HStack(spacing: d * 0.5) {
                Ellipse().fill(Color.pink.opacity(0.35)).frame(width: d * 0.13, height: d * 0.07)
                Ellipse().fill(Color.pink.opacity(0.35)).frame(width: d * 0.13, height: d * 0.07)
            }
            .offset(y: d * 0.15)
            Mouth(kind: mouth).stroke(Color(white: 0.15), style: StrokeStyle(lineWidth: max(0.8, d * 0.035), lineCap: .round))
                .frame(width: d * 0.14, height: d * 0.08)
                .offset(y: d * 0.2)
        }
    }

    private var mouth: Mouth.Kind {
        if pose == .dangle { return .open }
        switch mood {
        case .needsYou, .sleeping: return .open
        case .working, .reading: return .flat
        case .idle: return .smile
        }
    }

    private func eye(_ lookAt: CGSize) -> some View {
        let d = size
        let w = d * 0.34
        return ZStack {
            if mood == .sleeping {
                Mouth(kind: .closedEye).stroke(Color(white: 0.15), style: StrokeStyle(lineWidth: max(0.8, d * 0.04), lineCap: .round))
                    .frame(width: w * 0.7, height: w * 0.3)
            } else {
                Circle().fill(.white)
                    .overlay(Circle().strokeBorder(Color(white: 0.15).opacity(0.35), lineWidth: max(0.5, d * 0.015)))
                ZStack {
                    Circle().fill(Color(white: 0.1)).frame(width: w * 0.56)
                    Circle().fill(.white).frame(width: w * 0.18).offset(x: w * 0.1, y: -w * 0.1)
                }
                .offset(x: lookAt.width * w * 0.2, y: lookAt.height * w * 0.2)
                if mood == .reading || mood == .working {
                    Rectangle().fill(palette.body).frame(height: w * 0.38).frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .frame(width: w, height: w)
        .clipShape(Circle())
        .scaleEffect(x: 1, y: blink && mood != .sleeping ? 0.1 : 1)
        .animation(.easeInOut(duration: 0.07), value: blink)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: gaze)
    }

    private var currentGaze: CGSize {
        switch (pose, mood) {
        case (.dangle, _): CGSize(width: max(-1, min(1, -motion.swing * 2)), height: 0.7)
        case (_, .working): CGSize(width: sin(t * 2.2) * 0.6, height: 0.8)
        case (_, .needsYou): CGSize(width: 0, height: -0.2)
        default: gaze
        }
    }

    @ViewBuilder private var accessory: some View {
        let d = size
        switch look.accessory {
        case "glasses": Glasses(d: d).offset(y: -d * 0.06)
        case "headset": Headset(palette: palette, d: d)
        case "cap": Cap(palette: palette, d: d)
        case "bow": Bow(palette: palette, d: d).offset(x: d * 0.26, y: -d * 0.4)
        default: EmptyView()
        }
    }

    private var legs: some View {
        let d = size
        let c = CreatureView.center
        let len = d * 0.36 * limbs
        let base: (Double, Double)
        switch pose {
        case .dangle:
            let wiggle = sin(t * 11) * 0.35 * motion.flail
            base = (-motion.swing * 0.7 + 0.12 + wiggle, -motion.swing * 0.7 - 0.12 - wiggle)
        case .perch:
            let kickL = mood == .working ? sin(t * 5) * 0.25 : kick * 0.3
            base = (0.08 + kickL, -0.08 - (mood == .working ? sin(t * 5 + 1.6) * 0.25 : kick * -0.2))
        case .peek:
            base = (0.1, -0.1)
        }
        return ZStack {
            Limb(color: palette.limb, width: d * 0.12, length: len, angle: base.0, end: d * 0.17)
                .position(x: (c.x - 0.17) * d, y: (c.y + 0.32) * d + len / 2)
            Limb(color: palette.limb, width: d * 0.12, length: len, angle: base.1, end: d * 0.17)
                .position(x: (c.x + 0.17) * d, y: (c.y + 0.32) * d + len / 2)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.5), value: kick)
    }

    private var arms: some View {
        let d = size
        let c = CreatureView.center
        let shoulderY = (c.y + 0.02) * d + bodyOffset
        let left = CGPoint(x: (c.x - 0.42) * d, y: shoulderY)
        let right = CGPoint(x: (c.x + 0.42) * d, y: shoulderY)
        let rest = d * 0.3 * limbs
        func toward(_ from: CGPoint, _ to: CGPoint) -> (Double, CGFloat) {
            let dx = to.x - from.x, dy = to.y - from.y
            return (atan2(-dx, dy), max(rest, hypot(dx, dy)))
        }
        let l: (Double, CGFloat), r: (Double, CGFloat)
        switch (pose, mood) {
        case (.dangle, _):
            let grip = CGPoint(x: c.x * d, y: 0.26 * d)
            let a = toward(left, CGPoint(x: grip.x - d * 0.04, y: grip.y)), b = toward(right, CGPoint(x: grip.x + d * 0.04, y: grip.y))
            l = (a.0, a.1 * limbs + rest * (1 - limbs)); r = (b.0, b.1 * limbs + rest * (1 - limbs))
        case (_, .needsYou):
            l = (0.35, rest); r = (-2.65 + sin(t * 9) * 0.3, rest * 1.1)
        case (_, .working):
            l = (0.2 + sin(t * 16) * 0.3, rest); r = (-0.2 - sin(t * 16 + 2) * 0.3, rest)
        default:
            l = (0.32, rest); r = (-0.32, rest)
        }
        return ZStack {
            Limb(color: palette.limb, width: d * 0.11, length: l.1, angle: l.0, end: d * 0.15)
                .position(x: left.x, y: left.y + l.1 / 2)
            Limb(color: palette.limb, width: d * 0.11, length: r.1, angle: r.0, end: d * 0.15)
                .position(x: right.x, y: right.y + r.1 / 2)
        }
        .opacity(limbs > 0.01 || pose == .dangle ? 1 : 0)
    }

    private func idleLoop() async {
        gaze = .zero
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 1.6...3.4)))
            if Task.isCancelled { return }
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
                for x in stride(from: -0.8, through: 0.8, by: 0.4) {
                    gaze = CGSize(width: x, height: 0.7)
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

private struct Limb: View {
    let color: Color
    let width: CGFloat
    let length: CGFloat
    let angle: Double
    let end: CGFloat

    var body: some View {
        ZStack(alignment: .bottom) {
            Capsule().fill(color).frame(width: width, height: max(length, width))
            Circle().fill(color).frame(width: end, height: end).offset(y: end * 0.25)
        }
        .frame(width: end, height: max(length, width))
        .rotationEffect(.radians(angle), anchor: .top)
    }
}

private struct Mouth: Shape {
    enum Kind { case smile, flat, open, closedEye }
    let kind: Kind

    func path(in r: CGRect) -> Path {
        var p = Path()
        switch kind {
        case .smile:
            p.move(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.2))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.2), control: CGPoint(x: r.midX, y: r.maxY * 1.1))
        case .flat:
            p.move(to: CGPoint(x: r.minX + r.width * 0.2, y: r.midY))
            p.addLine(to: CGPoint(x: r.maxX - r.width * 0.2, y: r.midY))
        case .open:
            p.addEllipse(in: CGRect(x: r.midX - r.height * 0.45, y: r.minY, width: r.height * 0.9, height: r.height))
        case .closedEye:
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY * 1.6))
        }
        return p
    }
}

private struct Glasses: View {
    let d: CGFloat

    var body: some View {
        let w = d * 0.4
        let line = max(0.8, d * 0.04)
        ZStack {
            HStack(spacing: d * 0.0) {
                Circle().strokeBorder(Color(white: 0.12), lineWidth: line).frame(width: w, height: w)
                Rectangle().fill(Color(white: 0.12)).frame(width: d * 0.05, height: line)
                Circle().strokeBorder(Color(white: 0.12), lineWidth: line).frame(width: w, height: w)
            }
            HStack(spacing: w * 1.95 + d * 0.05) {
                Rectangle().fill(Color(white: 0.12)).frame(width: d * 0.08, height: line)
                Rectangle().fill(Color(white: 0.12)).frame(width: d * 0.08, height: line)
            }
            .offset(y: -w * 0.2)
        }
    }
}

private struct Headset: View {
    let palette: CreaturePalette
    let d: CGFloat

    var body: some View {
        let line = max(1, d * 0.06)
        ZStack {
            Circle().trim(from: 0.55, to: 0.95)
                .stroke(Color(white: 0.2), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .frame(width: d * 1.04, height: d * 1.04)
                .offset(y: d * 0.02)
            HStack(spacing: d * 0.9) {
                RoundedRectangle(cornerRadius: d * 0.06).fill(Color(white: 0.2)).frame(width: d * 0.14, height: d * 0.26)
                RoundedRectangle(cornerRadius: d * 0.06).fill(Color(white: 0.2)).frame(width: d * 0.14, height: d * 0.26)
            }
            .offset(y: -d * 0.04)
            Path { p in
                p.move(to: CGPoint(x: d * 0.04, y: d * 0.5))
                p.addQuadCurve(to: CGPoint(x: d * 0.36, y: d * 0.78), control: CGPoint(x: d * 0.02, y: d * 0.8))
            }
            .stroke(Color(white: 0.2), style: StrokeStyle(lineWidth: line * 0.6, lineCap: .round))
            .frame(width: d, height: d)
            Circle().fill(palette.accent).frame(width: d * 0.09).offset(x: -d * 0.14, y: d * 0.28)
        }
    }
}

private struct Cap: View {
    let palette: CreaturePalette
    let d: CGFloat

    var body: some View {
        ZStack {
            Ellipse().fill(palette.accent).frame(width: d * 0.84, height: d * 0.5)
                .mask(Rectangle().frame(height: d * 0.25).offset(y: -d * 0.125))
                .offset(y: -d * 0.2)
            Capsule().fill(palette.accent.opacity(0.85)).frame(width: d * 0.5, height: d * 0.08)
                .offset(x: d * 0.34, y: -d * 0.2)
            Circle().fill(palette.accent).frame(width: d * 0.08).offset(y: -d * 0.46)
        }
    }
}

private struct Bow: View {
    let palette: CreaturePalette
    let d: CGFloat

    var body: some View {
        let color = Color(hue: 0.95, saturation: 0.6, brightness: 0.95)
        ZStack {
            Ellipse().fill(color).frame(width: d * 0.2, height: d * 0.14).offset(x: -d * 0.1).rotationEffect(.degrees(-15))
            Ellipse().fill(color).frame(width: d * 0.2, height: d * 0.14).offset(x: d * 0.1).rotationEffect(.degrees(15))
            Circle().fill(color.opacity(0.8)).frame(width: d * 0.08)
        }
        .rotationEffect(.degrees(20))
    }
}

private struct Scarf: View {
    let palette: CreaturePalette
    let d: CGFloat

    var body: some View {
        ZStack {
            Rectangle().fill(palette.accent).frame(width: d, height: d * 0.11).offset(y: d * 0.3)
                .mask(Ellipse().frame(width: d, height: d * 0.94))
            RoundedRectangle(cornerRadius: d * 0.03).fill(palette.accent).frame(width: d * 0.1, height: d * 0.2)
                .rotationEffect(.degrees(-14)).offset(x: d * 0.3, y: d * 0.38)
        }
    }
}

private struct Antenna: View {
    let palette: CreaturePalette
    let d: CGFloat
    let bob: Double

    var body: some View {
        ZStack(alignment: .top) {
            Path { p in
                p.move(to: CGPoint(x: d * 0.15, y: d * 0.3))
                p.addQuadCurve(to: CGPoint(x: d * 0.15, y: d * 0.04), control: CGPoint(x: d * 0.22, y: d * 0.16))
            }
            .stroke(palette.shade, style: StrokeStyle(lineWidth: max(1, d * 0.04), lineCap: .round))
            Circle().fill(palette.accent).frame(width: d * 0.12).offset(x: 0, y: -d * 0.02)
                .shadow(color: palette.accent.opacity(0.8), radius: d * 0.05)
        }
        .frame(width: d * 0.3, height: d * 0.32)
        .rotationEffect(.degrees(bob * 10 - 5), anchor: .bottom)
        .animation(.spring(response: 0.4, dampingFraction: 0.35), value: bob)
        .offset(y: -d * 0.12)
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
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.86)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.6), lineWidth: 1))
            .frame(maxWidth: 220, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
