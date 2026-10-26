import AppKit

struct NotchGeometry {
    let screen: NSScreen
    let notchSize: CGSize
    let hasNotch: Bool

    init(screen: NSScreen) {
        self.screen = screen
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            hasNotch = true
            notchSize = CGSize(width: screen.frame.width - left.width - right.width, height: top)
        } else {
            hasNotch = false
            notchSize = CGSize(width: 8, height: 28)
        }
    }

    static func current() -> NotchGeometry {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        return NotchGeometry(screen: screen)
    }

    func frame(for size: CGSize) -> NSRect {
        let f = screen.frame
        let topInset: CGFloat = hasNotch ? 0 : 6
        return NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height - topInset, width: size.width, height: size.height)
    }
}
