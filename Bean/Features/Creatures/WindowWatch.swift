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
}

struct TitleSlot: Equatable {
    var center: CGPoint
    var pitch: CGFloat
    var size: CGFloat
    // Nothing to join yet. A Chromium app builds its tree seconds after it is asked, so this one is measured again.
    var alone = false
}

extension ForeignWindow {
    static func front(of pid: Int32, in windows: [ForeignWindow]) -> ForeignWindow? {
        windows.first { $0.pid == pid && isPlainWindow($0) }
    }

    private static var plain: [Int: (answer: Bool, asked: Date, tries: Int)] = [:]

    // A sheet, a dialog or a popover draws as a window of its own, but it is not where an agent sits. A new window can reach Accessibility just after it is drawn, so one not listed is asked about a few times.
    private static func isPlainWindow(_ window: ForeignWindow) -> Bool {
        let known = plain[window.number]
        if let known, known.answer || known.tries >= 4 || Date().timeIntervalSince(known.asked) < 0.25 { return known.answer }
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        let listed = (Accessibility.attribute(kAXWindowsAttribute, of: app) as? [AXUIElement]) ?? []
        let match = listed.first { frame(of: $0).map { abs($0.minX - window.frame.minX) + abs($0.minY - window.frame.minY) + abs($0.width - window.frame.width) < 4 } ?? false }
        let subrole = match.flatMap { Accessibility.attribute(kAXSubroleAttribute, of: $0) as? String } ?? ""
        let answer = listed.isEmpty || (match != nil && !["AXDialog", "AXSystemDialog"].contains(subrole))
        plain[window.number] = (answer, Date(), (known?.tries ?? 0) + 1)
        return answer
    }

    static func titleSlot(of window: ForeignWindow) -> TitleSlot? {
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let w = window.frame
        let windows = (Accessibility.attribute(kAXWindowsAttribute, of: app) as? [AXUIElement]) ?? []
        guard let match = windows.first(where: { frame(of: $0).map { abs($0.minX - w.minX) + abs($0.minY - w.minY) + abs($0.width - w.width) < 4 } ?? false }) else { return nil }
        return titleSlot(in: match, frame: w)
    }

    private static let topBand: CGFloat = 64
    private static let alonePitch: CGFloat = 26
    private static let controls: Set<String> = ["AXButton", "AXCheckBox", "AXMenuButton", "AXPopUpButton", "AXRadioButton"]
    // What holds other things and takes no click of its own. A window's title area is often one, across the whole row.
    private static let holders: Set<String> = ["AXGroup", "AXToolbar", "AXSplitGroup", "AXTabGroup", "AXScrollArea", "AXLayoutArea", "AXUnknown", "AXSplitter"]

    private static func titleSlot(in match: AXUIElement, frame w: CGRect) -> TitleSlot? {
        let close = button(kAXCloseButtonAttribute, of: match).flatMap { $0.minY >= w.minY - 1 && $0.maxY <= w.minY + 80 ? $0 : nil }
        let zoom = button(kAXZoomButtonAttribute, of: match) ?? button(kAXFullScreenButtonAttribute, of: match)
        let lightsEnd = close == nil ? w.minX : (zoom?.maxX ?? w.minX)
        var obstacles: [CGRect] = [], items: [CGRect] = []
        var queue: [(AXUIElement, Int)] = [(match, 0)], visited = 0
        while !queue.isEmpty, visited < 1500 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let f = frame(of: element)
            if depth > 0, let f, f.height > 0, f.minY > w.minY + topBand + 16 { continue }
            let role = Accessibility.attribute(kAXRoleAttribute, of: element) as? String ?? ""
            if depth > 0, let f, f.width > 0, f.minY < w.minY + topBand, !holders.contains(role) {
                obstacles.append(role == kAXStaticTextRole ? shownText(of: element, in: f) : f)
                if controls.contains(role), f.width <= 64, f.height <= 80, f.minX > lightsEnd { items.append(f) }
            }
            // A page's own buttons are not the app's. Where the web area is the whole window, as in Electron, it is the app.
            if role == "AXWebArea", let f, f.width < w.width * 0.95 || f.minY > w.minY + 8 { continue }
            if depth < 30 { queue += ((Accessibility.attribute(kAXChildrenAttribute, of: element) as? [AXUIElement]) ?? []).map { ($0, depth + 1) } }
        }
        let found = unique(items)
        // With the window buttons showing, their row is the title bar. Without them, as in full screen, it is the highest row of controls.
        guard let row = close?.midY ?? found.map(\.midY).min() else { return nil }
        func free(_ x: CGFloat, _ half: CGFloat, around lead: CGRect?) -> Bool {
            let slot = CGRect(x: x - half, y: row - 6, width: 2 * half, height: 12)
            return x - half > max(w.minX, lightsEnd) && x + half < w.maxX && !obstacles.contains { o in lead.map { !o.contains($0) } ?? true && o.intersects(slot) }
        }
        var groups: [[CGRect]] = []
        for item in found.filter({ abs($0.midY - row) < 12 }).sorted(by: { $0.midX < $1.midX }) {
            if let last = groups.last?.last, item.minX - last.maxX <= 40 { groups[groups.count - 1].append(item) } else { groups.append([item]) }
        }
        func middle(_ values: [CGFloat]) -> CGFloat { values.sorted()[values.count / 2] }
        for group in groups.reversed() where group.count > 1 || group[0].midX > w.midX {
            let width = middle(group.map(\.width)), height = middle(group.map(\.height))
            let gap = group.count > 1 ? max(min(middle(zip(group, group.dropFirst()).map { $1.minX - $0.maxX }), 16), 2) : 6
            // A toolbar button with a label below is tall, and its icon stays on the row.
            let pitch = width + gap, half = min(pitch / 2 - 1, 14), y = (height > 44 ? row : middle(group.map(\.midY))) - w.minY
            let size = min(max(min(width, height) * 0.62, 12), 18)
            if let x = [group[0].minX - gap - width / 2, group[group.count - 1].maxX + gap + width / 2].first(where: { x in free(x, half, around: x < group[0].midX ? group[0] : group[group.count - 1]) }) {
                return TitleSlot(center: CGPoint(x: x - w.minX, y: y), pitch: x < group[0].midX ? pitch : -pitch, size: size)
            }
        }
        // No row to join and no title bar: no seat in the window, and the agent shows in the notch.
        guard close != nil else { return nil }
        let half = alonePitch / 2 - 1
        guard let x = stride(from: lightsEnd + half + 6, to: w.midX, by: alonePitch).first(where: { free($0, half, around: nil) }) else { return nil }
        return TitleSlot(center: CGPoint(x: x - w.minX, y: row - w.minY), pitch: -alonePitch, size: 14, alone: true)
    }

    // A title's frame can fill the whole row, while its words take only the start of it.
    private static func shownText(of element: AXUIElement, in f: CGRect) -> CGRect {
        guard let text = Accessibility.attribute(kAXValueAttribute, of: element) as? String else { return f }
        var shown = f
        shown.size.width = min(f.width, (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 17, weight: .bold)]).width + 8)
        return shown
    }

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
    var onChange: ((Int32, ForeignWindow?) -> Void)?
    private var watched: [Int32: ForeignWindow?] = [:]
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

    func watch(_ pid: Int32) {
        guard watched[pid] == nil else { return }
        watched[pid] = .some(nil)
        kick(for: 0.5)
    }

    func unwatch(_ pid: Int32) {
        watched[pid] = nil
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
        let open = ForeignWindow.pickable()
        for (pid, old) in watched {
            // With nothing of the app on this Space, the agent keeps its seat on the window it knew, unseen.
            let now = ForeignWindow.front(of: pid, in: open) ?? old.flatMap { ForeignWindow.lookup($0.number) }
            guard now != old else { continue }
            if now?.frame != old?.frame { moved = true }
            watched[pid] = .some(now)
            onChange?(pid, now)
        }
        if moved { fastUntil = max(fastUntil, Date().addingTimeInterval(0.4)) }
        schedule(fast: Date() < fastUntil)
    }
}
