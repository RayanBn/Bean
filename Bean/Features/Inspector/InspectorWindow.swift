import AppKit
import SwiftUI

final class InspectorWindow: NSObject, NSWindowDelegate {
    private let model: InspectorModel
    private var window: NSWindow?

    init(model: InspectorModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: InspectorView(model: model)))
            window.title = "Bean Inspector"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 980, height: 640))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        model.start()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
    }
}
