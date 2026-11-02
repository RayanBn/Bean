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
        guard let found = list.lazy.compactMap(ForeignWindow.init).first(where: { $0.number == number }) else { return nil }
        guard found.frame.height < barHeight else { return found }
        let all = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        return all.lazy.compactMap(ForeignWindow.init).first(where: found.isBar) ?? found
    }

    private static let barHeight: CGFloat = 120

    // In full screen an app can draw its bar in a window of its own, laid over the top of its main one. An agent sits on the main one.
    func isBar(of other: ForeignWindow) -> Bool {
        other.pid == pid && abs(other.frame.minX - frame.minX) < 2 && abs(other.frame.minY - frame.minY) < 2 && abs(other.frame.width - frame.width) < 2 && frame.height < Self.barHeight && other.frame.height > frame.height
    }

    static func pickable() -> [ForeignWindow] {
        let me = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = list.filter {
            ($0[kCGWindowLayer as String] as? Int) == 0 && (($0[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05
        }
        .compactMap(ForeignWindow.init)
        .filter { $0.pid != me && $0.frame.width >= 120 && $0.frame.height >= 80 }
        return windows.filter { window in !windows.contains(where: window.isBar) }
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
    var control: CGSize
    // How many agents fit from here on, side by side, covering nothing.
    var room: Int
    // Nothing to join yet. A Chromium app builds its tree seconds after it is asked, so this one is measured again.
    var alone = false
    // The flat color of the row's icons, when a picture could show it.
    var ink: NSColor?
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
        let tries = (known?.tries ?? 0) + 1
        // A busy app answers with no list at all, and only an app that never answers gets the benefit of the doubt.
        let answer = match.map { _ in !["AXDialog", "AXSystemDialog"].contains(subrole) } ?? (listed.isEmpty && tries >= 4)
        plain[window.number] = (answer, Date(), tries)
        return answer
    }

    var barWindow: Int? {
        let above = CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow, CGWindowID(number)) as? [[String: Any]] ?? []
        return above.first { (($0[kCGWindowAlpha as String] as? Double) ?? 1) > 0.05 && ForeignWindow($0)?.isBar(of: self) == true }.flatMap { $0[kCGWindowNumber as String] as? Int }
    }

    private static func element(of window: ForeignWindow) -> AXUIElement? {
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let w = window.frame
        let windows = (Accessibility.attribute(kAXWindowsAttribute, of: app) as? [AXUIElement]) ?? []
        return windows.first { frame(of: $0).map { abs($0.minX - w.minX) + abs($0.minY - w.minY) + abs($0.width - w.width) < 4 } ?? false }
    }

    static func titleSlot(of window: ForeignWindow, picture: BarPicture? = nil) -> TitleSlot? {
        element(of: window).flatMap { titleSlot(in: $0, frame: window.frame, picture: picture) }
    }

    // What the bar is made of, to tell when an app rearranges it while its window keeps its size.
    static func barMarks(of window: ForeignWindow) -> [CGRect]? {
        element(of: window).map { match in
            let scan = scanBar(of: match, frame: window.frame)
            return (scan.items + scan.pages).map { $0.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY) }
        }
    }

    private static let topBand: CGFloat = 64
    private static let alonePitch: CGFloat = 24
    private static let controls: Set<String> = ["AXButton", "AXCheckBox", "AXMenuButton", "AXPopUpButton", "AXRadioButton"]

    private struct BarScan {
        var lightsEnd: CGFloat
        var obstacles: [CGRect] = [], pages: [CGRect] = [], items: [CGRect] = [], titles: [CGRect] = []
        var toolbar: CGRect?
    }

    private static func scanBar(of match: AXUIElement, frame w: CGRect) -> BarScan {
        let close = button(kAXCloseButtonAttribute, of: match).flatMap { $0.minY >= w.minY - 1 && $0.maxY <= w.minY + 80 ? $0 : nil }
        let zoom = button(kAXZoomButtonAttribute, of: match) ?? button(kAXFullScreenButtonAttribute, of: match)
        var scan = BarScan(lightsEnd: close == nil ? w.minX : (zoom?.maxX ?? w.minX))
        var queue: [(element: AXUIElement, depth: Int, parent: String)] = [(match, 0, "")], visited = 0
        while !queue.isEmpty, visited < 1500 {
            let (element, depth, parent) = queue.removeFirst()
            visited += 1
            let f = frame(of: element)
            if depth > 0, let f, f.height > 0, f.minY > w.minY + topBand + 16 { continue }
            let role = Accessibility.attribute(kAXRoleAttribute, of: element) as? String ?? ""
            if role == kAXToolbarRole, let f, f.height > 0, f.minY < w.minY + topBand, f.width > scan.toolbar?.width ?? 0 { scan.toolbar = f }
            if depth > 0, let f, f.width > 0, f.width < w.width * 0.7, f.minY < w.minY + topBand {
                if role == kAXStaticTextRole {
                    let text = shownText(of: element, in: f)
                    scan.obstacles.append(text)
                    scan.titles.append(text)
                } else {
                    scan.obstacles.append(f)
                }
                if controls.contains(role), f.width <= 64, f.height >= 12, f.height <= 80, f.minX > scan.lightsEnd { scan.items.append(f) }
            }
            // A page's own buttons are not the app's. A web area that fills the window inside nothing but groups, as in Electron, is the app. In a browser's split view or scroll area it is still a page, even with no bar left around it.
            if role == "AXWebArea", let f, f.width < w.width * 0.95 || parent != "AXGroup" {
                scan.pages.append(f)
                continue
            }
            if depth < 30 { queue += ((Accessibility.attribute(kAXChildrenAttribute, of: element) as? [AXUIElement]) ?? []).map { ($0, depth + 1, role) } }
        }
        return scan
    }

    private static func titleSlot(in match: AXUIElement, frame w: CGRect, picture: BarPicture?) -> TitleSlot? {
        let close = button(kAXCloseButtonAttribute, of: match).flatMap { $0.minY >= w.minY - 1 && $0.maxY <= w.minY + 80 ? $0 : nil }
        let scan = scanBar(of: match, frame: w)
        let lightsEnd = scan.lightsEnd, obstacles = scan.obstacles, pages = scan.pages, items = scan.items, titles = scan.titles, toolbar = scan.toolbar
        // A small control right after the title is the title's own, like a document menu, and no button of the bar.
        let found = unique(items.filter { item in !(item.height <= 18 && titles.contains { abs($0.maxX - item.minX) < 12 && abs($0.midY - item.midY) < 8 }) })
        // The app's toolbar is the bar. Without one, controls that span the window buttons' line share their bar, and they set its center: an app can hide those buttons higher up than its own row. Without window buttons, as in full screen, the bar is the highest row of controls.
        let inToolbar = toolbar.map { t in found.filter { t.contains(CGPoint(x: $0.midX, y: $0.midY)) } } ?? []
        let bar = !inToolbar.isEmpty ? inToolbar : close.map { c in found.filter { $0.minY <= c.midY && c.midY <= $0.maxY } } ?? []
        let line = bar.filter { $0.height <= 44 }.map(\.midY).sorted()
        guard let row = line.isEmpty ? toolbar?.midY ?? close?.midY ?? found.map(\.midY).min() : line[line.count / 2] else { return nil }
        // A picture settles it where it can: a frame can be far wider than what it shows. A page is never the bar.
        func free(_ x: CGFloat, _ half: CGFloat, around lead: CGRect?) -> Bool {
            let slot = CGRect(x: x - half, y: row - 6, width: 2 * half, height: 12)
            guard x - half > max(w.minX, lightsEnd), x + half < w.maxX, !pages.contains(where: { $0.intersects(slot) }) else { return false }
            // A greyed-out button can look empty, so a frame the size of a button always holds.
            if let picture { return picture.isEmpty(slot.insetBy(dx: 1, dy: -4).offsetBy(dx: -w.minX, dy: -w.minY)) && !obstacles.contains { $0.width <= 64 && !($0.contains(lead ?? .null)) && $0.intersects(slot) } }
            return !obstacles.contains { o in lead.map { !o.contains($0) } ?? true && o.intersects(slot) }
        }
        func room(_ x: CGFloat, _ pitch: CGFloat, _ half: CGFloat, around lead: CGRect?) -> Int {
            1 + (1..<6).prefix { free(x - CGFloat($0) * pitch, half, around: lead) }.count
        }
        var runs: [[CGRect]] = []
        for item in found.filter({ abs($0.midY - row) < 12 || bar.contains($0) }).sorted(by: { $0.midX > $1.midX }) {
            if var run = runs.last, let last = run.last {
                let step = last.midX - item.midX
                let steady = run.count < 2 || abs(step - (run[run.count - 2].midX - last.midX)) <= 4
                if step >= 8, step <= 64, steady {
                    run.append(item)
                    runs[runs.count - 1] = run
                    continue
                }
            }
            runs.append([item])
        }
        for run in runs {
            let lead = run[run.count - 1], tail = run[0]
            let height = min(lead.height, 32), width = min(lead.width, height)
            let gap = max(run.count > 1 ? run[run.count - 2].minX - lead.maxX : 6, 2)
            let half = width / 2 + gap / 2 - 1
            for (x, anchor) in [(lead.minX - gap - width / 2, lead), (tail.maxX + gap + width / 2, tail)] where free(x, half, around: anchor) {
                // A toolbar button with a label below is tall, and its icon stays on the row.
                let glyphs = picture.map { p in run.compactMap { p.glyph(in: $0.offsetBy(dx: -w.minX, dy: -w.minY)) } } ?? []
                func middle(_ values: [CGFloat]) -> CGFloat? { values.isEmpty ? nil : values.sorted()[values.count / 2] }
                // A button with no label holds its icon at its center. Only a tall one can hold it higher.
                let centered = (anchor.height > 44 ? row : anchor.midY) - w.minY
                let y = middle(glyphs.map(\.centerY)).flatMap { anchor.height >= 40 || abs($0 - centered) <= 3 ? $0 : nil } ?? centered
                let size = middle(glyphs.map(\.extent)).map { min(max($0 * 0.95, 12), 17) } ?? min(max(min(anchor.width, height) * 0.62, 11), 16)
                let ink = glyphs.sorted { $0.ink.brightnessComponent < $1.ink.brightnessComponent }.dropFirst(glyphs.count / 2).first?.ink
                let signed = x < anchor.midX ? width + gap : -(width + gap)
                return TitleSlot(center: CGPoint(x: x - w.minX, y: y), pitch: signed, size: size,
                                 control: CGSize(width: width, height: height), room: room(x, signed, half, around: anchor), ink: ink)
            }
        }
        // A full row can still have room to the eye, since a button's frame is wider than its icon. The widest gap between two buttons takes the agent, if the picture shows it empty.
        if let picture {
            let inRow = found.filter { abs($0.midY - row) < 12 || bar.contains($0) }.sorted { $0.minX < $1.minX }
            let gaps = zip(inRow, inRow.dropFirst()).filter { $1.minX - $0.maxX >= 4 }.sorted { $0.1.minX - $0.0.maxX > $1.1.minX - $1.0.maxX }
            for (a, b) in gaps {
                let x = (a.maxX + b.minX) / 2 - w.minX, y = a.midY - w.minY
                let extent = picture.glyph(in: a.offsetBy(dx: -w.minX, dy: -w.minY))?.extent ?? 14
                let size = min(max(extent * 0.95, 12), 15)
                let shows = CGRect(x: x - size / 2 - 3, y: y - size / 2 - 2, width: size + 6, height: size + 4)
                guard x + w.minX - size / 2 > lightsEnd, picture.isEmpty(shows) else { continue }
                let ink = picture.glyph(in: a.offsetBy(dx: -w.minX, dy: -w.minY))?.ink
                return TitleSlot(center: CGPoint(x: x, y: y), pitch: size + 6, size: size, control: CGSize(width: size + 6, height: min(a.height, 32)), room: 1, ink: ink)
            }
        }
        // No row to join: right after the window buttons, or right after the title. Without them there is no seat in the window, and the agent shows in the notch.
        guard close != nil else { return nil }
        let half = alonePitch / 2 - 1
        let after = [lightsEnd + half + 6] + obstacles.filter { abs($0.midY - row) < 12 && $0.minX > lightsEnd }.sorted { $0.minX < $1.minX }.map { $0.maxX + half + 6 }
        guard let x = after.first(where: { free($0, half, around: nil) }) else { return nil }
        let ink = titles.first { abs($0.midY - row) < 12 }.flatMap { picture?.glyph(in: $0.insetBy(dx: -3, dy: -3).offsetBy(dx: -w.minX, dy: -w.minY)) }?.ink
        return TitleSlot(center: CGPoint(x: x - w.minX, y: row - w.minY), pitch: -alonePitch, size: 13, control: CGSize(width: alonePitch, height: alonePitch),
                         room: room(x, -alonePitch, half, around: nil), alone: true, ink: ink)
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

// The window server says when a window moves, resizes or changes order, as it happens. Reading the list on a timer only catches up.
private enum WindowEvents {
    typealias Handler = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
    typealias Register = @convention(c) (Handler, UInt32, UnsafeMutableRawPointer?) -> Int32
    typealias Request = @convention(c) (Int32, UnsafeMutablePointer<UInt32>, Int32) -> Int32
    typealias Connection = @convention(c) () -> Int32

    static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    static let register = dlsym(skyLight, "SLSRegisterNotifyProc").map { unsafeBitCast($0, to: Register.self) }
    static let request = dlsym(skyLight, "SLSRequestNotificationsForWindows").map { unsafeBitCast($0, to: Request.self) }
    static let connection = dlsym(skyLight, "SLSMainConnectionID").map { unsafeBitCast($0, to: Connection.self)() }
    static let moved: UInt32 = 806, resized: UInt32 = 807, reordered: UInt32 = 808
}

final class WindowWatch {
    var onChange: ((Int32, ForeignWindow?) -> Void)?
    var onReorder: (() -> Void)?
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
        for event in [WindowEvents.moved, WindowEvents.resized, WindowEvents.reordered] {
            _ = WindowEvents.register?({ event, _, _, context in
                guard let context else { return }
                let watch = Unmanaged<WindowWatch>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { watch.serverSaid(event) }
            }, event, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    private func serverSaid(_ event: UInt32) {
        if event == WindowEvents.reordered { onReorder?() }
        kick(for: 0.3)
    }

    private func listen() {
        guard let connection = WindowEvents.connection else { return }
        var numbers = watched.values.compactMap { $0.map { UInt32($0.number) } }
        _ = WindowEvents.request?(connection, &numbers, Int32(numbers.count))
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
        let interval = fast ? 1.0 / 60 : 0.5
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
            let listening = now?.number != old?.number
            watched[pid] = .some(now)
            if listening { listen() }
            onChange?(pid, now)
        }
        if moved { fastUntil = max(fastUntil, Date().addingTimeInterval(0.4)) }
        schedule(fast: Date() < fastUntil)
    }
}
