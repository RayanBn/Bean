import AppKit
import Combine
import SwiftUI

final class MenuBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var pausedWatch: AnyCancellable?

    init(notch: NotchModel, localGateAvailable: Bool, shellLog: URL, openInspector: @escaping () -> Void) {
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: MenuBarView(
            settings: .shared, notch: notch, localGateAvailable: localGateAvailable, shellLog: shellLog, openInspector: openInspector
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
        NSApp.activate()
        popover.show(relativeTo: rect, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func toggle() {
        popover.isShown ? popover.performClose(nil) : open()
    }

    static func glyph(paused: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
            let head = NSRect(x: rect.midX - 9, y: rect.midY - 6, width: 18, height: 12)
            let path = NSBezierPath(roundedRect: head, xRadius: 6, yRadius: 6)
            for x in [rect.midX - 4.5, rect.midX + 1.5] {
                let eye = paused
                    ? NSRect(x: x - 0.5, y: rect.midY - 1, width: 4, height: 1.8)
                    : NSRect(x: x, y: rect.midY - 3, width: 3, height: 6)
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
