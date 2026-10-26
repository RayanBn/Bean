import AppKit
import ApplicationServices

enum WindowReader {
    static let privateApps: Set<String> = ["com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password", "com.bitwarden.desktop", "com.apple.systempreferences"]
    private static let textRoles: Set<String> = [kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole, "AXHeading", "AXLink", kAXButtonRole, kAXCellRole]
    private static let skippedRoles: Set<String> = ["AXSecureTextField", kAXMenuBarRole, kAXScrollBarRole, kAXImageRole]
    private static let timeout: Float = 0.25

    static func apps(focusedTextLimit: Int = 6000, otherTextLimit: Int = 600) -> [AppInfo] {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let titles = systemWindowTitles()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .map { app in
                let isFrontmost = app.processIdentifier == frontmost
                let readsText = !privateApps.contains(app.bundleIdentifier ?? "")
                return AppInfo(
                    name: app.localizedName ?? app.bundleIdentifier ?? "?",
                    bundleId: app.bundleIdentifier,
                    isFrontmost: isFrontmost,
                    isHidden: app.isHidden,
                    windows: merge(
                        windows(of: app.processIdentifier, readsText: readsText, focusedLimit: isFrontmost ? focusedTextLimit : otherTextLimit, otherLimit: otherTextLimit),
                        titles[app.processIdentifier] ?? []
                    )
                )
            }
    }

    private static func merge(_ accessible: [WindowInfo], _ titles: [String]) -> [WindowInfo] {
        let known = Set(accessible.map(\.title))
        return accessible + titles.filter { !known.contains($0) }.map { WindowInfo(title: $0, document: nil, isFocused: false, isMinimized: false, text: nil) }
    }

    private static func systemWindowTitles() -> [pid_t: [String]] {
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var titles: [pid_t: [String]] = [:]
        for window in list {
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let name = window[kCGWindowName as String] as? String, !name.isEmpty,
                  let bounds = window[kCGWindowBounds as String] as? [String: Double], (bounds["Width"] ?? 0) > 200, (bounds["Height"] ?? 0) > 150,
                  titles[pid]?.contains(name) != true else { continue }
            titles[pid, default: []].append(name)
        }
        return titles
    }

    private static func windows(of pid: pid_t, readsText: Bool, focusedLimit: Int, otherLimit: Int) -> [WindowInfo] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        let focused = Accessibility.attribute(kAXFocusedWindowAttribute, of: app).map { $0 as! AXUIElement }
        let all = Accessibility.attribute(kAXWindowsAttribute, of: app) as? [AXUIElement] ?? []
        return all.prefix(12).compactMap { window in
            let title = Accessibility.attribute(kAXTitleAttribute, of: window) as? String ?? ""
            let isFocused = focused.map { CFEqual($0, window) } ?? false
            let minimized = Accessibility.attribute(kAXMinimizedAttribute, of: window) as? Bool ?? false
            let document = (Accessibility.attribute(kAXDocumentAttribute, of: window) as? String).flatMap { URL(string: $0)?.path }
            let text = readsText && !minimized ? self.text(in: window, limit: isFocused ? focusedLimit : otherLimit, nodeLimit: isFocused ? 1500 : 300) : nil
            guard !title.isEmpty || text?.isEmpty == false else { return nil }
            return WindowInfo(title: title, document: document, isFocused: isFocused, isMinimized: minimized, text: text)
        }
    }

    static func text(in root: AXUIElement, limit: Int, nodeLimit: Int = 1500) -> String? {
        var queue = [root], index = 0
        var pieces: [String] = []
        var seen = Set<String>()
        var length = 0
        while index < queue.count, index < nodeLimit, length < limit {
            let element = queue[index]
            index += 1
            let role = Accessibility.attribute(kAXRoleAttribute, of: element) as? String ?? ""
            if skippedRoles.contains(role) { continue }
            if textRoles.contains(role) {
                let value = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].lazy
                    .compactMap { Accessibility.attribute($0, of: element) as? String }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                if let value, seen.insert(value).inserted {
                    pieces.append(role == kAXTextAreaRole ? String(value.suffix(limit)) : value)
                    length += value.count + 3
                }
                if role == kAXTextAreaRole || role == kAXTextFieldRole { continue }
            }
            queue += Accessibility.attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
        }
        let joined = pieces.joined(separator: " · ")
        return joined.isEmpty ? nil : String(joined.prefix(limit))
    }
}
