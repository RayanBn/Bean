import AppKit
import Combine
import SwiftUI

final class MenuBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var pausedWatch: AnyCancellable?
    private var before: NSRunningApplication?
    var openAgents: (() -> Void)?
    var openSettings: (() -> Void)?

    init(notch: NotchModel) {
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: MenuBarView(
            settings: .shared, notch: notch, openAgents: { [weak self] in
                self?.closeThenOpen { self?.openAgents?() }
            }, openSettings: { [weak self] in
                self?.closeThenOpen { self?.openSettings?() }
            }
        ) { [weak self] in self?.popover.performClose(nil) })

        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            button.setAccessibilityTitle("Bean")
            button.toolTip = "Bean"
        }
        pausedWatch = BeanSettings.shared.$paused.sink { [weak self] paused in
            self?.item.button?.image = Self.glyph(paused: paused)
        }
    }

    func open() {
        guard let button = item.button else { return }
        open(relativeTo: button.bounds, of: button)
    }

    func open(relativeTo rect: NSRect, of view: NSView) {
        guard !popover.isShown else { return }
        let front = NSWorkspace.shared.frontmostApplication
        before = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        NSApp.activate()
        popover.show(relativeTo: rect, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // The page makes Bean a regular app. While Bean is active that sends the person to the desktop Space, so focus goes back first and Bean comes in from outside, as it does from the notch.
    private func closeThenOpen(_ page: @escaping () -> Void) {
        popover.performClose(nil)
        guard let before else { return page() }
        self.before = nil
        before.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: page)
    }

    @objc private func toggle() {
        popover.isShown ? popover.performClose(nil) : open()
    }

    static func glyph(paused: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let path = NSBezierPath()
            let w: CGFloat = 13, h: CGFloat = 16, x = rect.midX - w / 2, y = rect.midY - h / 2
            path.move(to: NSPoint(x: rect.midX, y: y + h))
            path.curve(to: NSPoint(x: x + w, y: y + h * 0.38), controlPoint1: NSPoint(x: rect.midX + w * 0.2, y: y + h * 0.8), controlPoint2: NSPoint(x: x + w, y: y + h * 0.64))
            path.curve(to: NSPoint(x: x, y: y + h * 0.38), controlPoint1: NSPoint(x: x + w, y: y - h * 0.06), controlPoint2: NSPoint(x: x, y: y - h * 0.06))
            path.curve(to: NSPoint(x: rect.midX, y: y + h), controlPoint1: NSPoint(x: x, y: y + h * 0.64), controlPoint2: NSPoint(x: rect.midX - w * 0.2, y: y + h * 0.8))
            path.close()
            for ex in [rect.midX - 3.6, rect.midX + 1] {
                let eye = paused
                    ? NSRect(x: ex, y: y + 5.4, width: 2.6, height: 1.2)
                    : NSRect(x: ex, y: y + 4.4, width: 2.6, height: 2.8)
                path.append(NSBezierPath(roundedRect: eye, xRadius: min(eye.width, eye.height) / 2, yRadius: min(eye.width, eye.height) / 2))
            }
            path.windingRule = .evenOdd
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
