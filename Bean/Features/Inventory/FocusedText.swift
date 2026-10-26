import AppKit
import ApplicationServices

struct WindowText: Codable, Equatable {
    let at: Date
    let pid: pid_t
    let app: String?
    let window: String?
    let text: String
    let nodes: Int
    let milliseconds: Int
    let truncated: Bool
}

enum FocusedText {
    static let nodeLimit = 5000
    static let timeLimit: TimeInterval = 0.25
    static let characterLimit = 20000
    static let manualRefresh: TimeInterval = 60
    static let manualAccessibilityExcluded: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.anthropic.claudefordesktop"]
    private static let attributes = [kAXRoleAttribute, kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute] as CFArray
    private static let textRoles: Set<String> = [kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole, "AXHeading", "AXLink", kAXCellRole, "AXWebArea"]
    private static let skippedRoles: Set<String> = ["AXSecureTextField", kAXMenuBarRole, kAXScrollBarRole, kAXImageRole, kAXMenuRole]
    private static var manualSetAt: [pid_t: Date] = [:]

    static func read(_ app: NSRunningApplication) -> WindowText? {
        let pid = app.processIdentifier
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, WindowTracker.callTimeout)
        if needsManualAccessibility(app), Date().timeIntervalSince(manualSetAt[pid] ?? .distantPast) > manualRefresh {
            manualSetAt[pid] = Date()
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            Thread.sleep(forTimeInterval: 0.15)
        }
        guard let window = Accessibility.attribute(kAXFocusedWindowAttribute, of: element) else { return nil }
        let title = Accessibility.attribute(kAXTitleAttribute, of: window as! AXUIElement) as? String
        let started = Date()
        var page: [AXUIElement] = [], rest = [window as! AXUIElement], visited = 0
        var pieces: [String] = [], seen = Set<String>(), length = 0
        while visited < nodeLimit, length < characterLimit, Date().timeIntervalSince(started) < timeLimit {
            let inPage = !page.isEmpty
            guard let node = inPage ? page.removeFirst() : rest.isEmpty ? nil : rest.removeFirst() else { break }
            visited += 1
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(node, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let list = values as? [AnyObject], list.count == 5 else { continue }
            let role = list[0] as? String ?? ""
            if skippedRoles.contains(role) { continue }
            if textRoles.contains(role), role != "AXWebArea", let text = [list[1], list[2], list[3]].lazy.compactMap({ $0 as? String }).map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { !$0.isEmpty }),
               seen.insert(text).inserted {
                pieces.append(text)
                length += text.count + 1
            }
            if role == kAXTextAreaRole || role == kAXTextFieldRole { continue }
            let children = list[4] as? [AXUIElement] ?? []
            if inPage || role == "AXWebArea" { page += children } else { rest += children }
        }
        let index = visited
        let truncated = !page.isEmpty || !rest.isEmpty
        guard !pieces.isEmpty else { return nil }
        let text = String(pieces.joined(separator: "\n").prefix(characterLimit))
        return WindowText(
            at: Date(), pid: pid, app: app.localizedName, window: title, text: text, nodes: index,
            milliseconds: Int(Date().timeIntervalSince(started) * 1000), truncated: truncated
        )
    }

    static func resetManualAccessibility() {
        for pid in manualSetAt.keys {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanFalse)
        }
        manualSetAt = [:]
    }

    private static func needsManualAccessibility(_ app: NSRunningApplication) -> Bool {
        guard let bundle = app.bundleURL, !manualAccessibilityExcluded.contains(app.bundleIdentifier ?? "") else { return false }
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks")
        return ["Electron Framework.framework", "Chromium Embedded Framework.framework"].contains { FileManager.default.fileExists(atPath: frameworks.appendingPathComponent($0).path) }
            || TabReader.chromiumBundleIds.contains(app.bundleIdentifier ?? "")
    }
}
