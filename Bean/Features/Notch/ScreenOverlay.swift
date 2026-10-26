import AppKit
import QuartzCore

final class ScreenOverlay {
    static let palette: [NSColor] = [
        NSColor(red: 0.30, green: 0.98, blue: 0.56, alpha: 1),
        NSColor(red: 0.20, green: 0.84, blue: 1.00, alpha: 1),
        NSColor(red: 0.50, green: 0.52, blue: 1.00, alpha: 1),
        NSColor(red: 0.78, green: 1.00, blue: 0.32, alpha: 1),
        NSColor(red: 0.30, green: 0.98, blue: 0.56, alpha: 1),
    ]

    private let window: NSPanel
    private let root = CALayer()
    private let gradient = CAGradientLayer()
    private let glowMask = CALayer()
    private let reveal = CALayer()
    private let revealHalves = [CAShapeLayer(), CAShapeLayer()]
    private let halo = CALayer()
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

        let view = NSView()
        view.layer = root
        view.wantsLayer = true
        window.contentView = view

        gradient.type = .conic
        gradient.colors = Self.palette.map(\.cgColor)
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.mask = glowMask
        for half in revealHalves {
            half.fillColor = nil
            half.strokeColor = NSColor.black.cgColor
            half.lineWidth = 260
            half.strokeEnd = 0
            reveal.addSublayer(half)
        }
        let edge = CALayer()
        edge.addSublayer(gradient)
        edge.mask = reveal
        root.addSublayer(edge)

        let green = Self.palette[0]
        halo.cornerRadius = 9
        halo.cornerCurve = .continuous
        halo.borderWidth = 2
        halo.borderColor = green.cgColor
        halo.backgroundColor = green.withAlphaComponent(0.1).cgColor
        halo.shadowColor = green.cgColor
        halo.shadowOpacity = 0.9
        halo.shadowOffset = .zero
        halo.shadowRadius = 6
        halo.opacity = 0
        root.addSublayer(halo)
    }

    func place(on screen: NSScreen) {
        self.screen = screen
        window.setFrame(screen.frame, display: false)
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = bounds
        root.sublayers?.first?.frame = bounds
        gradient.frame = bounds
        glowMask.frame = bounds
        glowMask.contents = Self.glowImage(size: bounds.size, scale: screen.backingScaleFactor)
        glowMask.contentsScale = screen.backingScaleFactor
        reveal.frame = bounds
        let (clockwise, counter) = Self.halves(in: bounds)
        revealHalves[0].path = clockwise
        revealHalves[1].path = counter
        CATransaction.commit()
    }

    func takeControl(below panel: NSWindow) {
        hideWork?.cancel()
        window.order(.below, relativeTo: panel.windowNumber)
        spin()
        animateReveal(to: 1, duration: 1.1, timing: .easeOut)
    }

    func release() {
        guard window.isVisible else { return }
        highlight(nil)
        animateReveal(to: 0, duration: 0.8, timing: .easeIn)
        let work = DispatchWorkItem { [weak self] in
            self?.window.orderOut(nil)
            self?.gradient.removeAnimation(forKey: "spin")
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: work)
    }

    func highlight(_ globalRect: CGRect?) {
        guard let screen, let primary = NSScreen.screens.first else { return }
        guard let r = globalRect else {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.3)
            halo.opacity = 0
            CATransaction.commit()
            return
        }
        let topLeftY = r.minY - (primary.frame.maxY - screen.frame.maxY)
        let frame = CGRect(x: r.minX - screen.frame.minX, y: screen.frame.height - topLeftY - r.height,
                           width: r.width, height: r.height).insetBy(dx: -7, dy: -7)
        let appearing = halo.opacity == 0
        CATransaction.begin()
        CATransaction.setDisableActions(appearing)
        CATransaction.setAnimationDuration(0.45)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        halo.frame = frame
        halo.shadowPath = CGPath(roundedRect: halo.bounds, cornerWidth: 9, cornerHeight: 9, transform: nil)
        CATransaction.commit()
        guard appearing else { return }
        halo.opacity = 1
        let pop = CABasicAnimation(keyPath: "transform.scale")
        pop.fromValue = 1.5
        pop.toValue = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [pop, fade]
        group.duration = 0.35
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        halo.add(group, forKey: "appear")
        let pulse = CABasicAnimation(keyPath: "shadowRadius")
        pulse.fromValue = 5
        pulse.toValue = 14
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        halo.add(pulse, forKey: "pulse")
    }

    private func spin() {
        guard gradient.animation(forKey: "spin") == nil else { return }
        let spin = CAKeyframeAnimation(keyPath: "endPoint")
        spin.values = (0...36).map { i -> NSValue in
            let a = Double(i) / 36 * 2 * .pi
            return NSValue(point: NSPoint(x: 0.5 + 0.5 * cos(a), y: 0.5 + 0.5 * sin(a)))
        }
        spin.duration = 7
        spin.repeatCount = .infinity
        gradient.add(spin, forKey: "spin")
    }

    private func animateReveal(to value: CGFloat, duration: CFTimeInterval, timing: CAMediaTimingFunctionName) {
        for half in revealHalves {
            let from = half.presentation()?.strokeEnd ?? half.strokeEnd
            let anim = CABasicAnimation(keyPath: "strokeEnd")
            anim.fromValue = from
            anim.toValue = value
            anim.duration = duration
            anim.timingFunction = CAMediaTimingFunction(name: timing)
            half.strokeEnd = value
            half.add(anim, forKey: "reveal")
        }
    }

    private static func halves(in r: CGRect) -> (CGPath, CGPath) {
        let clockwise = CGMutablePath()
        clockwise.move(to: CGPoint(x: r.midX, y: r.maxY))
        clockwise.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        clockwise.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        clockwise.addLine(to: CGPoint(x: r.midX, y: r.minY))
        let counter = CGMutablePath()
        counter.move(to: CGPoint(x: r.midX, y: r.maxY))
        counter.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        counter.addLine(to: CGPoint(x: r.minX, y: r.minY))
        counter.addLine(to: CGPoint(x: r.midX, y: r.minY))
        return (clockwise, counter)
    }

    private static func glowImage(size: CGSize, scale: CGFloat) -> CGImage? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let edge = CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 12, cornerHeight: 12, transform: nil)
        let white = CGColor(gray: 1, alpha: 1)
        for (width, blur, alpha) in [(26.0, 40.0, 0.5), (8.0, 12.0, 0.8), (3.0, 0.0, 1.0)] as [(CGFloat, CGFloat, CGFloat)] {
            ctx.saveGState()
            ctx.setAlpha(alpha)
            if blur > 0 { ctx.setShadow(offset: .zero, blur: blur * scale, color: white) }
            ctx.setStrokeColor(white)
            ctx.setLineWidth(width)
            ctx.addPath(edge)
            ctx.strokePath()
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }
}
