import AppKit
import ApplicationServices

struct OpenWindow: Equatable {
    let number: Int
    let pid: Int32
    let app: String
    let bundleId: String
    let title: String?

    var described: String {
        "\(number): \(app), \(title ?? "untitled")"
    }
}

enum SpaceWindows {
    private typealias CreateFromToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private typealias WindowNumber = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let create = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementCreateWithRemoteToken").map { unsafeBitCast($0, to: CreateFromToken.self) }
    private static let number = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow").map { unsafeBitCast($0, to: WindowNumber.self) }
    private static let lock = NSLock()
    private static var known: [Int32: (at: Date, windows: [Int: AXUIElement])] = [:]

    static func windows(of pid: Int32) -> [Int: AXUIElement] {
        if let held = lock.withLock({ known[pid] }), Date().timeIntervalSince(held.at) < 10 { return held.windows }
        guard let create, let number else { return [:] }
        var found: [Int: AXUIElement] = [:]
        for id: UInt64 in 0..<2000 {
            var token = Data()
            withUnsafeBytes(of: pid) { token.append(contentsOf: $0) }
            withUnsafeBytes(of: Int32(0)) { token.append(contentsOf: $0) }
            withUnsafeBytes(of: Int32(0x636f636f)) { token.append(contentsOf: $0) }
            withUnsafeBytes(of: id) { token.append(contentsOf: $0) }
            guard let element = create(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(element, 0.2)
            guard Accessibility.attribute(kAXSubroleAttribute, of: element) as? String == kAXStandardWindowSubrole else { continue }
            var window: CGWindowID = 0
            if number(element, &window) == .success, window != 0 { found[Int(window)] = element }
        }
        lock.withLock { known[pid] = (Date(), found) }
        return found
    }
}

enum WindowChannels {
    static func open() -> [OpenWindow] {
        let environment = ProcessInfo.processInfo.environment
        let wanted = environment["BEAN_WINDOW_FILTER"]
        if wanted == nil, environment["BEAN_DATA_DIR"] != nil { return [] }
        let filter = wanted == "*" ? nil : wanted
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let me = ProcessInfo.processInfo.processIdentifier
        var seen = Set<Int>()
        return list.compactMap { info -> OpenWindow? in
            guard info[kCGWindowLayer as String] as? Int == 0, let number = info[kCGWindowNumber as String] as? Int, seen.insert(number).inserted,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != me, let app = info[kCGWindowOwnerName as String] as? String,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }), bounds.height > 60, bounds.width > 120 else { return nil }
            let running = NSRunningApplication(processIdentifier: pid)
            guard running?.activationPolicy != .prohibited || filter != nil else { return nil }
            if filter == nil, info[kCGWindowIsOnscreen as String] as? Bool != true {
                guard running?.activationPolicy == .regular, running?.isHidden == false, SpaceWindows.windows(of: pid)[number] != nil else { return nil }
            }
            guard running?.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? axTitle(pid: pid, bounds: bounds)
            if title == nil, info[kCGWindowIsOnscreen as String] as? Bool != true { return nil }
            if let filter, !filter.components(separatedBy: "|").contains(where: { entry in
                entry.hasPrefix("app=") ? app == entry.dropFirst(4) : app.localizedCaseInsensitiveContains(entry) || (title ?? "").localizedCaseInsensitiveContains(entry)
            }) { return nil }
            return OpenWindow(number: number, pid: pid, app: app, bundleId: running?.bundleIdentifier ?? "", title: title)
        }
    }

    static func forModel() -> [String] {
        open().compactMap { window in
            OffLimits.match("\(window.app) \(window.bundleId) \(window.title ?? "")") == nil ? window.described : nil
        }
    }

    // What Bean sees, after off limits and the local private check. A title that looks private stays on this Mac.
    static func forBean() async -> [String] {
        let windows = await Task.detached { open() }.value.filter { OffLimits.match("\($0.app) \($0.bundleId) \($0.title ?? "")") == nil }
        var lines: [String] = []
        for window in windows {
            lines.append(await PrivateCheck.titleIsPrivate(window.title) ? "\(window.number): \(window.app), title kept private" : window.described)
        }
        return lines
    }

    private static func axTitle(pid: Int32, bounds: CGRect) -> String? {
        let windows = (Accessibility.attribute(kAXWindowsAttribute, of: AXUIElementCreateApplication(pid)) as? [AXUIElement]) ?? []
        return windows.first { window in
            guard let position = Accessibility.attribute(kAXPositionAttribute, of: window) else { return false }
            var origin = CGPoint.zero
            AXValueGetValue(position as! AXValue, .cgPoint, &origin)
            return abs(origin.x - bounds.minX) + abs(origin.y - bounds.minY) < 4
        }.flatMap { Accessibility.attribute(kAXTitleAttribute, of: $0) as? String }
    }

    static func attachment(for window: OpenWindow) -> Attachment {
        Attachment(bundleId: window.bundleId, appName: window.app, pid: window.pid, windowNumber: window.number, windowTitle: window.title)
    }
}
