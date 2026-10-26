import ApplicationServices
import Foundation

final class AppObserver {
    enum Event { case focusChanged, titleChanged, valueChanged }

    var onEvent: ((Event) -> Void)?

    private var observer: AXObserver?
    private var app: AXUIElement?
    private var watched: [(AXUIElement, String)] = []
    private var watchesValues = false

    func watch(pid: pid_t, values: Bool) {
        stop()
        watchesValues = values
        guard AXIsProcessTrusted() else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            Unmanaged<AppObserver>.fromOpaque(refcon).takeUnretainedValue().received(notification as String)
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        observer = created
        let app = AXUIElementCreateApplication(pid)
        self.app = app
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        for name in [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification, kAXTitleChangedNotification, kAXMainWindowChangedNotification] {
            add(name, on: app)
        }
        watchFocus()
    }

    func stop() {
        for (element, name) in watched {
            if let observer { AXObserverRemoveNotification(observer, element, name as CFString) }
        }
        watched = []
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        app = nil
    }

    private func add(_ name: String, on element: AXUIElement) {
        guard let observer, AXObserverAddNotification(observer, element, name as CFString, Unmanaged.passUnretained(self).toOpaque()) == .success else { return }
        watched.append((element, name))
    }

    private func watchFocus() {
        guard let app, let observer else { return }
        for (element, name) in watched where !CFEqual(element, app) {
            AXObserverRemoveNotification(observer, element, name as CFString)
        }
        watched.removeAll { !CFEqual($0.0, app) }
        if let window = Accessibility.attribute(kAXFocusedWindowAttribute, of: app) {
            add(kAXTitleChangedNotification, on: window as! AXUIElement)
        }
        if watchesValues, let focused = Accessibility.attribute(kAXFocusedUIElementAttribute, of: app) {
            add(kAXValueChangedNotification, on: focused as! AXUIElement)
        }
    }

    private func received(_ notification: String) {
        switch notification {
        case kAXValueChangedNotification:
            onEvent?(.valueChanged)
        case kAXTitleChangedNotification:
            onEvent?(.titleChanged)
        default:
            watchFocus()
            onEvent?(.focusChanged)
        }
    }
}
