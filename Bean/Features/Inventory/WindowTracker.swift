import AppKit
import ApplicationServices

struct TrackedWindow {
    let id: CGWindowID
    let pid: pid_t
    let element: AXUIElement
    var title: String
    var minimized: Bool
}

final class WindowTracker {
    static let callTimeout: Float = 0.25
    static let retryDelays: [TimeInterval] = [0.5, 2, 6]
    private static let notifications = [
        kAXWindowCreatedNotification, kAXUIElementDestroyedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
        kAXTitleChangedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, "AXFocusedTabChanged",
    ]

    var onEvent: ((InventoryEvent) -> Void)?
    var onFocus: ((pid_t) -> Void)?

    let thread = AXThread()
    private var observers: [pid_t: AXObserver] = [:]
    private var names: [pid_t: (name: String?, bundleId: String?)] = [:]
    private(set) var windows: [CGWindowID: TrackedWindow] = [:]
    private(set) var focused: [pid_t: CGWindowID] = [:]

    init() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1)
    }

    func track(_ app: NSRunningApplication, attempt: Int = 0) {
        let pid = app.processIdentifier, name = app.localizedName, bundleId = app.bundleIdentifier
        thread.async { [self] in
            guard observers[pid] == nil, AXIsProcessTrusted() else { return }
            names[pid] = (name, bundleId)
            var created: AXObserver?
            let callback: AXObserverCallback = { _, element, notification, refcon in
                guard let refcon else { return }
                Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue().received(notification as String, element)
            }
            guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return retry(app, attempt) }
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, Self.callTimeout)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            let added = Self.notifications.filter { AXObserverAddNotification(observer, element, $0 as CFString, refcon) == .success }
            guard added.contains(kAXWindowCreatedNotification) else { return retry(app, attempt) }
            CFRunLoopAddSource(thread.runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
            observers[pid] = observer
            for window in Accessibility.attribute(kAXWindowsAttribute, of: element) as? [AXUIElement] ?? [] { remember(window, pid: pid) }
            if let window = Accessibility.attribute(kAXFocusedWindowAttribute, of: element), let id = WindowServer.windowId(of: window as! AXUIElement) {
                focused[pid] = id
            }
        }
    }

    func untrack(_ pid: pid_t) {
        thread.async { [self] in
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(thread.runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            windows = windows.filter { $0.value.pid != pid }
            focused[pid] = nil
            names[pid] = nil
        }
    }

    private func retry(_ app: NSRunningApplication, _ attempt: Int) {
        guard attempt < Self.retryDelays.count, !app.isTerminated else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelays[attempt]) { [weak self] in self?.track(app, attempt: attempt + 1) }
    }

    @discardableResult
    private func remember(_ window: AXUIElement, pid: pid_t) -> TrackedWindow? {
        guard Accessibility.attribute(kAXRoleAttribute, of: window) as? String == kAXWindowRole, let id = WindowServer.windowId(of: window) else { return nil }
        let tracked = TrackedWindow(
            id: id, pid: pid, element: window, title: Accessibility.attribute(kAXTitleAttribute, of: window) as? String ?? "",
            minimized: Accessibility.attribute(kAXMinimizedAttribute, of: window) as? Bool ?? false
        )
        windows[id] = tracked
        return tracked
    }

    private func received(_ notification: String, _ element: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        func emit(_ event: String, _ window: TrackedWindow?, detail: String? = nil) {
            let app = names[pid]
            onEvent?(InventoryEvent(at: Date(), event: event, app: app?.name, bundleId: app?.bundleId, detail: detail ?? window?.title, pid: pid, windowId: window?.id))
        }
        switch notification {
        case kAXWindowCreatedNotification:
            emit("windowOpened", remember(element, pid: pid))
        case kAXUIElementDestroyedNotification:
            guard let window = windows.values.first(where: { CFEqual($0.element, element) }) else { return }
            windows[window.id] = nil
            emit("windowClosed", window)
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            guard let window = windows[WindowServer.windowId(of: element) ?? 0] ?? remember(element, pid: pid), focused[pid] != window.id else { return }
            focused[pid] = window.id
            emit("windowFocused", window)
            onFocus?(pid)
        case kAXTitleChangedNotification:
            guard Accessibility.attribute(kAXRoleAttribute, of: element) as? String == kAXWindowRole, let id = WindowServer.windowId(of: element),
                  var window = windows[id] ?? remember(element, pid: pid) else { return }
            let title = Accessibility.attribute(kAXTitleAttribute, of: element) as? String ?? ""
            guard title != window.title || windows[id] == nil else { return }
            window.title = title
            windows[id] = window
            emit("titleChanged", window)
            if focused[pid] == id { onFocus?(pid) }
        case kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification:
            guard let id = WindowServer.windowId(of: element), var window = windows[id] else { return }
            window.minimized = notification == kAXWindowMiniaturizedNotification
            windows[id] = window
            emit(window.minimized ? "windowMinimized" : "windowRestored", window)
        case "AXFocusedTabChanged":
            emit("tabChanged", nil, detail: Accessibility.attribute(kAXTitleAttribute, of: element) as? String)
            onFocus?(pid)
        default:
            break
        }
    }

    func snapshot(_ reply: @escaping ([CGWindowID: TrackedWindow], [pid_t: CGWindowID]) -> Void) {
        thread.async { [self] in reply(windows, focused) }
    }
}
