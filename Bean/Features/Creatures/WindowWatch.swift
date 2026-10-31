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

struct TitleSlot: Equatable {
    var center: CGPoint
    var pitch: CGFloat
}

struct TitleLayout: Equatable {
    var slot: TitleSlot?
    var fullScreen: Bool
}

extension ForeignWindow {
    static func titleLayout(of window: ForeignWindow) -> TitleLayout? {
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let w = window.frame
        let windows = (Accessibility.attribute(kAXWindowsAttribute, of: app) as? [AXUIElement]) ?? []
        guard let match = windows.first(where: { frame(of: $0).map { abs($0.minX - w.minX) + abs($0.minY - w.minY) + abs($0.width - w.width) < 4 } ?? false }) else { return nil }
        let fullScreen = (Accessibility.attribute("AXFullScreen", of: match) as? Bool) == true
        return TitleLayout(slot: titleSlot(in: match, frame: w, fullScreen: fullScreen), fullScreen: fullScreen)
    }

    private static let fullScreenRow: CGFloat = 16
    private static let fullScreenPitch: CGFloat = 26

    private static func titleSlot(in match: AXUIElement, frame w: CGRect, fullScreen: Bool) -> TitleSlot? {
        let close = button(kAXCloseButtonAttribute, of: match).flatMap { $0.minY >= w.minY - 1 && $0.maxY <= w.minY + 80 ? $0 : nil }
        let zoom = button(kAXZoomButtonAttribute, of: match) ?? button(kAXFullScreenButtonAttribute, of: match)
        let row = fullScreen ? w.minY + Self.fullScreenRow : close?.midY ?? w.minY + 26
        let lightsEnd = close == nil ? w.minX : (zoom?.maxX ?? w.minX)
        var obstacles: [CGRect] = [], items: [CGRect] = []
        var queue: [(AXUIElement, Int)] = [(match, 0)], visited = 0
        while !queue.isEmpty, visited < 1500 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let f = frame(of: element)
            if depth > 0, let f, f.height > 0, f.minY > row + 40 || f.maxY < row - 40 { continue }
            if depth > 0, let f, f.width > 0, f.width < w.width * 0.7, f.minY < row + 12, f.maxY > row - 12 {
                obstacles.append(f)
                let role = Accessibility.attribute(kAXRoleAttribute, of: element) as? String ?? ""
                if Self.controls.contains(role), f.width <= 48, f.height <= 64, f.minX > lightsEnd { items.append(f) }
            }
            if depth < 30 { queue += ((Accessibility.attribute(kAXChildrenAttribute, of: element) as? [AXUIElement]) ?? []).map { ($0, depth + 1) } }
        }
        if fullScreen {
            let half = Self.fullScreenPitch / 2 - 1
            let open = stride(from: w.maxX - 24, to: w.midX, by: -Self.fullScreenPitch).first { x in
                !obstacles.contains { $0.intersects(CGRect(x: x - half, y: row - 6, width: 2 * half, height: 12)) }
            }
            return TitleSlot(center: CGPoint(x: (open ?? w.maxX - 24) - w.minX, y: Self.fullScreenRow), pitch: Self.fullScreenPitch)
        }
        func free(_ x: CGFloat, _ half: CGFloat, around lead: CGRect) -> Bool {
            let slot = CGRect(x: x - half, y: row - 6, width: 2 * half, height: 12)
            return x - half > w.minX && x + half < w.maxX && !obstacles.contains { !$0.contains(lead) && $0.intersects(slot) }
        }
        var runs: [[CGRect]] = []
        for item in Self.unique(items).sorted(by: { $0.midX > $1.midX }) {
            if var run = runs.last, let last = run.last {
                let step = last.midX - item.midX
                let steady = run.count < 2 || abs(step - (run[run.count - 2].midX - last.midX)) <= 4
                if step >= 8, step <= 50, steady, abs(item.midY - last.midY) < 4 {
                    run.append(item)
                    runs[runs.count - 1] = run
                    continue
                }
            }
            runs.append([item])
        }
        for run in runs where run.count > 1 || run[0].midX > w.midX {
            let lead = run[run.count - 1], tail = run[0]
            let pitch = run.count > 1 ? run[run.count - 2].midX - lead.midX : lead.width + 6
            for (x, anchor) in [(lead.midX - pitch, lead), (tail.midX + pitch, tail)] where free(x, pitch / 2 - 1, around: anchor) {
                return TitleSlot(center: CGPoint(x: x - w.minX, y: anchor.midY - w.minY), pitch: x < anchor.midX ? pitch : -pitch)
            }
        }
        return nil
    }

    private static let controls: Set<String> = ["AXButton", "AXCheckBox", "AXMenuButton", "AXPopUpButton", "AXRadioButton"]

    private static func unique(_ frames: [CGRect]) -> [CGRect] {
        frames.reduce(into: []) { kept, f in
            if !kept.contains(where: { abs($0.midX - f.midX) < 4 && abs($0.midY - f.midY) < 4 }) { kept.append(f) }
        }
    }

    private static func button(_ name: String, of window: AXUIElement) -> CGRect? {
        Accessibility.attribute(name, of: window).flatMap { frame(of: $0 as! AXUIElement) }.flatMap { $0.width > 0 ? $0 : nil }
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
