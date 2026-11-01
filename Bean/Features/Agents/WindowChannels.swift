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

enum WindowChannels {
    static func open() -> [OpenWindow] {
        let environment = ProcessInfo.processInfo.environment
        let wanted = environment["BEAN_WINDOW_FILTER"]
        if wanted == nil, environment["BEAN_DATA_DIR"] != nil { return [] }
        let filter = wanted == "*" ? nil : wanted
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let me = ProcessInfo.processInfo.processIdentifier
        var seen = Set<Int>()
        let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { $0[kCGWindowNumber as String] as? Int }
        let rank = Dictionary(onScreen.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let found = list.compactMap { info -> OpenWindow? in
            guard info[kCGWindowLayer as String] as? Int == 0, let number = info[kCGWindowNumber as String] as? Int, seen.insert(number).inserted,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != me, let app = info[kCGWindowOwnerName as String] as? String,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }), bounds.height > 60, bounds.width > 120 else { return nil }
            let running = NSRunningApplication(processIdentifier: pid)
            guard running?.activationPolicy != .prohibited || filter != nil else { return nil }
            if filter == nil, info[kCGWindowIsOnscreen as String] as? Bool != true {
                // Accessibility lists only the current Space, so it cannot say whether a window off screen is open: the person's window must not vanish because they moved.
                guard running?.activationPolicy == .regular, running?.isHidden == false, WindowSnapshot.stillOpen(number) else { return nil }
            }
            guard running?.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? axTitle(of: number, pid: pid)
            // Without Screen Recording a window off screen has no name here. Being in a Space is what says it is a real window.
            if title == nil, info[kCGWindowIsOnscreen as String] as? Bool != true, SpaceWindows.spaces(of: number).isEmpty { return nil }
            if let filter, !filter.components(separatedBy: "|").contains(where: { entry in
                entry.hasPrefix("app=") ? app == entry.dropFirst(4) : app.localizedCaseInsensitiveContains(entry) || (title ?? "").localizedCaseInsensitiveContains(entry)
            }) { return nil }
            return OpenWindow(number: number, pid: pid, app: app, bundleId: running?.bundleIdentifier ?? "", title: title)
        }
        // `.optionAll` follows no z-order. Front to back is promised only for the on-screen list, and callers take the first window of an app as its front one.
        return found.enumerated().sorted { (rank[$0.element.number] ?? Int.max, $0.offset) < (rank[$1.element.number] ?? Int.max, $1.offset) }.map(\.element)
    }

    static func forModel() -> [String] {
        open().compactMap { window in
            OffLimits.match("\(window.app) \(window.bundleId) \(window.title ?? "")") == nil ? window.described : nil
        }
    }

    // What Bean sees, after off limits and the local private check. A title that looks private stays on this Mac, and so does any title when the check is on and cannot run.
    static func visibleToBean() async -> [(window: OpenWindow, line: String)] {
        let windows = await Task.detached { open() }.value.filter { OffLimits.match("\($0.app) \($0.bundleId) \($0.title ?? "")") == nil }
        var lines: [(window: OpenWindow, line: String)] = []
        for window in windows { lines.append((window, await line(for: window))) }
        return lines
    }

    static func forBean() async -> [String] {
        await visibleToBean().map(\.line)
    }

    static func line(for window: OpenWindow) async -> String {
        let verdict = await PrivateCheck.titleVerdict(window.title)
        return window.title != nil && verdict != .open ? "\(window.number): \(window.app), title kept private" : window.described
    }

    private static func axTitle(of window: Int, pid: Int32) -> String? {
        SpaceWindows.known(of: pid)[window].flatMap { Accessibility.attribute(kAXTitleAttribute, of: $0) as? String }.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func attachment(for window: OpenWindow) -> Attachment {
        Attachment(bundleId: window.bundleId, appName: window.app, pid: window.pid, windowNumber: window.number, windowTitle: window.title)
    }
}
