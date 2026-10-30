import AppKit

struct ForeignWindow: Equatable {
    let number: Int
    let pid: Int32
    let appName: String
    let title: String?
    let frame: CGRect
    let onScreen: Bool

    var appKitFrame: NSRect { Screens.toAppKit(frame) }

    init?(_ info: [String: Any]) {
        guard let number = info[kCGWindowNumber as String] as? Int,
              let pid = info[kCGWindowOwnerPID as String] as? Int32,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
        self.number = number
        self.pid = pid
        appName = info[kCGWindowOwnerName as String] as? String ?? ""
        title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.frame = frame
        onScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    var attachment: Attachment {
        let app = NSRunningApplication(processIdentifier: pid)
        return Attachment(bundleId: app?.bundleIdentifier ?? "", appName: app?.localizedName ?? appName,
                          pid: pid, windowNumber: number, windowTitle: title)
    }

    static func lookup(_ number: Int) -> ForeignWindow? {
        let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]] ?? []
        return list.lazy.compactMap(ForeignWindow.init).first { $0.number == number }
    }

    static func pickable() -> [ForeignWindow] {
        let me = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter {
            ($0[kCGWindowLayer as String] as? Int) == 0 && (($0[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05
        }
        .compactMap(ForeignWindow.init)
        .filter { $0.pid != me && $0.frame.width >= 120 && $0.frame.height >= 80 }
    }

    static func under(_ point: NSPoint, in windows: [ForeignWindow]) -> ForeignWindow? {
        let p = Screens.toCG(point)
        return windows.first { $0.frame.contains(p) }
    }

    static func replacement(for attachment: Attachment) -> ForeignWindow? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: attachment.bundleId).map(\.processIdentifier))
        guard !pids.isEmpty else { return nil }
        let candidates = pickable().filter { pids.contains($0.pid) }
        return candidates.first { $0.title != nil && $0.title == attachment.windowTitle } ?? candidates.first
    }
}

extension ForeignWindow {
    static func buttonsEnd(of window: ForeignWindow) -> CGPoint? {
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        let windows = (Accessibility.attribute(kAXWindowsAttribute, of: app) as? [AXUIElement]) ?? []
        guard let match = windows.first(where: { frame(of: $0).map { abs($0.minX - window.frame.minX) + abs($0.minY - window.frame.minY) + abs($0.width - window.frame.width) < 4 } ?? false }) else { return nil }
        let buttons = [kAXZoomButtonAttribute, kAXFullScreenButtonAttribute, kAXMinimizeButtonAttribute, kAXCloseButtonAttribute]
            .compactMap { Accessibility.attribute($0, of: match).flatMap { frame(of: $0 as! AXUIElement) } }
            .filter { $0.width > 0 && $0.minY >= window.frame.minY - 1 && $0.maxY <= window.frame.minY + 70 && $0.minX >= window.frame.minX - 1 }
        guard let last = buttons.max(by: { $0.maxX < $1.maxX }) else { return nil }
        return CGPoint(x: last.maxX - window.frame.minX, y: last.midY - window.frame.minY)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = Accessibility.attribute(kAXPositionAttribute, of: element),
              let size = Accessibility.attribute(kAXSizeAttribute, of: element) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }
}

enum Screens {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func toCG(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }

    static func toAppKit(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func containing(_ p: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
    }
}

final class WindowWatch {
    var onChange: ((Int, ForeignWindow?) -> Void)?
    private var watched: [Int: ForeignWindow?] = [:]
    private var timer: Timer?
    private var fastUntil = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private var monitors: [Any] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.kick(for: 1) })
        }
        monitors = [NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] _ in
            self?.kick(for: 0.8)
        }].compactMap { $0 }
    }

    deinit {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        monitors.forEach(NSEvent.removeMonitor)
    }

    func watch(_ number: Int) {
        guard watched[number] == nil else { return }
        watched[number] = .some(nil)
        kick(for: 0.5)
    }

    func unwatch(_ number: Int) {
        watched[number] = nil
        if watched.isEmpty { timer?.invalidate(); timer = nil }
    }

    func kick(for seconds: TimeInterval) {
        guard !watched.isEmpty else { return }
        fastUntil = max(fastUntil, Date().addingTimeInterval(seconds))
        schedule(fast: true)
        poll()
    }

    private func schedule(fast: Bool) {
        let interval = fast ? 1.0 / 60 : 0.25
        if let timer, timer.isValid, timer.timeInterval == interval { return }
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = fast ? 0 : 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        var moved = false
        for (number, old) in watched {
            let now = ForeignWindow.lookup(number)
            guard now != old else { continue }
            if now?.frame != old?.frame { moved = true }
            watched[number] = .some(now)
            onChange?(number, now)
        }
        if moved { fastUntil = max(fastUntil, Date().addingTimeInterval(0.4)) }
        schedule(fast: Date() < fastUntil)
    }
}
