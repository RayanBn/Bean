import AppKit
import ApplicationServices

struct OpenWindow: Equatable {
    let number: Int
    let pid: Int32
    let app: String
    let bundleId: String
    let title: String?
}

enum WindowChannels {
    static func open() -> [OpenWindow] {
        let filter = ProcessInfo.processInfo.environment["BEAN_WINDOW_FILTER"]
        let options: CGWindowListOption = filter == nil ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        let me = ProcessInfo.processInfo.processIdentifier
        var seen = Set<Int>()
        return list.compactMap { info -> OpenWindow? in
            guard info[kCGWindowLayer as String] as? Int == 0, let number = info[kCGWindowNumber as String] as? Int, seen.insert(number).inserted,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != me, let app = info[kCGWindowOwnerName as String] as? String,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }), bounds.height > 60, bounds.width > 120 else { return nil }
            let running = NSRunningApplication(processIdentifier: pid)
            guard running?.activationPolicy != .prohibited || filter != nil else { return nil }
            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? axTitle(pid: pid, bounds: bounds)
            if let filter, !app.localizedCaseInsensitiveContains(filter), title?.localizedCaseInsensitiveContains(filter) != true { return nil }
            return OpenWindow(number: number, pid: pid, app: app, bundleId: running?.bundleIdentifier ?? "", title: title)
        }
    }

    static func forModel() -> [String] {
        open().compactMap { window in
            OffLimits.match("\(window.app) \(window.bundleId) \(window.title ?? "")") == nil ? "\(window.number): \(window.app), \(window.title ?? "untitled")" : nil
        }
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
