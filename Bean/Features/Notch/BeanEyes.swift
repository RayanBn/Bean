import AppKit
import SwiftUI

enum EyeMood: Equatable {
    case calm, alert, pondering, attentive, focused, worried, happy

    init(_ phase: NotchPhase, failed: Bool) {
        switch phase {
        case .rest: self = .calm
        case .notice: self = .alert
        case .thinking: self = .pondering
        case .message: self = .attentive
        case .acting: self = failed ? .worried : .focused
        case .done: self = .happy
        }
    }

    var size: CGSize {
        switch self {
        case .calm: CGSize(width: 9, height: 11)
        case .alert: CGSize(width: 10, height: 17)
        case .pondering: CGSize(width: 8, height: 11)
        case .attentive: CGSize(width: 9, height: 15)
        case .focused: CGSize(width: 11, height: 5)
        case .worried: CGSize(width: 12, height: 7)
        case .happy: CGSize(width: 12, height: 11)
        }
    }

    var tilt: Double { self == .worried ? -22 : 0 }

    var blinks: Bool { self == .calm || self == .attentive || self == .pondering }
    var followsCursor: Bool { self == .calm || self == .attentive }
}

struct BeanEyes: View {
    static let slot: CGFloat = 13
    static let spacing: CGFloat = 3
    static let inset: CGFloat = 5
    static let pairWidth = 2 * slot + spacing
    static let ear = inset + pairWidth + 7

    let mood: EyeMood
    let quietCount: Int
    @State private var lidClosed = false
    @State private var shushing = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let look = gaze(at: context.date.timeIntervalSinceReferenceDate)
            HStack(spacing: Self.spacing) {
                eye.rotationEffect(.degrees(mood.tilt)).animation(.spring(response: 0.32, dampingFraction: 0.55), value: mood).offset(x: look.width, y: look.height)
                eye.rotationEffect(.degrees(-mood.tilt)).animation(.spring(response: 0.32, dampingFraction: 0.55), value: mood).offset(x: look.width, y: look.height)
            }
        }
        .task(id: mood) { await blinkLoop() }
        .onChange(of: quietCount) { shush() }
    }

    private var eye: some View {
        let size = mood.size
        let closed = lidClosed || shushing
        return EyeShape(width: size.width, height: closed ? 1.6 : size.height, happy: mood == .happy && !shushing ? 1 : 0)
            .fill(NotchStyle.accent)
            .shadow(color: NotchStyle.accent.opacity(0.75), radius: 3)
            .frame(width: Self.slot, height: 20)
            .animation(.spring(response: 0.32, dampingFraction: 0.55), value: mood)
            .animation(.easeInOut(duration: 0.07), value: lidClosed)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: shushing)
    }

    private func gaze(at t: TimeInterval) -> CGSize {
        switch mood {
        case .calm, .attentive:
            return cursorGaze()
        case .alert:
            return CGSize(width: 0, height: 1.5)
        case .pondering:
            return CGSize(width: 2.5 * sin(t * 1.4), height: -2.5)
        case .focused:
            return CGSize(width: 2 * sin(t * 3.2), height: 1.5)
        case .worried:
            return CGSize(width: 0.7 * sin(t * 22), height: 2)
        case .happy:
            return CGSize(width: 0, height: -1 + 0.8 * sin(t * 5))
        }
    }

    private func cursorGaze() -> CGSize {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return .zero }
        let f = screen.frame
        let dx = max(-1, min(1, (mouse.x - f.midX) / (f.width / 2)))
        let dy = max(0, min(1, (f.maxY - mouse.y) / f.height))
        return CGSize(width: 2.6 * dx, height: -0.5 + 2.5 * dy)
    }

    private func blinkLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2.5...5.5)))
            guard mood.blinks, !Task.isCancelled else { continue }
            lidClosed = true
            try? await Task.sleep(for: .milliseconds(110))
            lidClosed = false
        }
    }

    private func shush() {
        shushing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { shushing = false }
    }
}

struct EyeShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var happy: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(width, height), happy) }
        set {
            width = newValue.first.first
            height = newValue.first.second
            happy = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let eye = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        let lid = 1 - 2 * happy
        var p = Path()
        if lid > 0.01 {
            let open = CGRect(x: eye.minX, y: eye.minY, width: eye.width, height: max(eye.height * lid, 1.2))
            p.addRoundedRect(in: open, cornerSize: CGSize(width: min(open.width, open.height) / 2, height: min(open.width, open.height) / 2), style: .continuous)
        }
        if happy > 0.5 {
            var caret = Path()
            caret.move(to: CGPoint(x: eye.minX, y: eye.midY + 2.5))
            caret.addQuadCurve(to: CGPoint(x: eye.maxX, y: eye.midY + 2.5), control: CGPoint(x: eye.midX, y: eye.midY - 6 * (2 * happy - 1)))
            p.addPath(caret.strokedPath(StrokeStyle(lineWidth: 2.6, lineCap: .round)))
        }
        return p
    }
}
