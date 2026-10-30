import SwiftUI

struct NotchShape: Shape {
    struct Metrics: Equatable {
        var width: CGFloat = 0
        var height: CGFloat = 0
        var radius: CGFloat = 0
        var flare: CGFloat = 0
        var offset: CGFloat = 0
    }

    var metrics: Metrics
    let hasNotch: Bool

    var animatableData: AnimatablePair<AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>>, CGFloat> {
        get { AnimatablePair(AnimatablePair(AnimatablePair(metrics.width, metrics.height), AnimatablePair(metrics.radius, metrics.flare)), metrics.offset) }
        set {
            metrics.width = newValue.first.first.first
            metrics.height = newValue.first.first.second
            metrics.radius = newValue.first.second.first
            metrics.flare = newValue.first.second.second
            metrics.offset = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = max(metrics.width, 0), h = max(metrics.height, 0)
        let frame = CGRect(x: rect.midX - w / 2 + metrics.offset, y: rect.minY, width: w, height: h)
        guard hasNotch else {
            return RoundedRectangle(cornerRadius: min(metrics.radius, h / 2), style: .continuous).path(in: frame)
        }
        let f = min(metrics.flare, w / 4, h / 2)
        let r = min(metrics.radius, (w - 2 * f) / 2, h - f)
        let k: CGFloat = 0.55
        var p = Path()
        p.move(to: CGPoint(x: frame.minX, y: frame.minY))
        p.addCurve(to: CGPoint(x: frame.minX + f, y: frame.minY + f),
                   control1: CGPoint(x: frame.minX + f * k, y: frame.minY),
                   control2: CGPoint(x: frame.minX + f, y: frame.minY + f * (1 - k)))
        p.addLine(to: CGPoint(x: frame.minX + f, y: frame.maxY - r))
        p.addCurve(to: CGPoint(x: frame.minX + f + r, y: frame.maxY),
                   control1: CGPoint(x: frame.minX + f, y: frame.maxY - r * (1 - k)),
                   control2: CGPoint(x: frame.minX + f + r * (1 - k), y: frame.maxY))
        p.addLine(to: CGPoint(x: frame.maxX - f - r, y: frame.maxY))
        p.addCurve(to: CGPoint(x: frame.maxX - f, y: frame.maxY - r),
                   control1: CGPoint(x: frame.maxX - f - r * (1 - k), y: frame.maxY),
                   control2: CGPoint(x: frame.maxX - f, y: frame.maxY - r * (1 - k)))
        p.addLine(to: CGPoint(x: frame.maxX - f, y: frame.minY + f))
        p.addCurve(to: CGPoint(x: frame.maxX, y: frame.minY),
                   control1: CGPoint(x: frame.maxX - f, y: frame.minY + f * (1 - k)),
                   control2: CGPoint(x: frame.maxX - f * k, y: frame.minY))
        p.closeSubpath()
        return p
    }
}
