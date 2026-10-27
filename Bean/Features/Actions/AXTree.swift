import AppKit
import ApplicationServices

struct AXNode {
    let element: AXUIElement
    let role: String
    let title: String?
    let label: String?
    let value: String?
    let identifier: String?
    let domId: String?
    let url: String?
    let actions: [String]
    var ancestors: [String] = []

    var text: String? { [title, label, value].compactMap { $0 }.first { !$0.isEmpty } }

    var line: String {
        var line = role
        if let title, !title.isEmpty { line += " \"\(title.prefix(80))\"" }
        if let label, !label.isEmpty, label != title { line += " label \"\(label.prefix(80))\"" }
        if let value, !value.isEmpty, value != title { line += " = \"\(value.prefix(60))\"" }
        if let identifier, !identifier.isEmpty { line += " #\(identifier)" }
        if let domId, !domId.isEmpty { line += " dom #\(domId)" }
        if let url { line += " <\(url.prefix(120))>" }
        let useful = actions.filter { $0 != "AXScrollToVisible" && $0 != "AXShowMenu" }
        if !useful.isEmpty { line += " [\(useful.joined(separator: ","))]" }
        return line
    }

    var frame: CGRect? {
        guard let position = Accessibility.attribute(kAXPositionAttribute, of: element),
              let size = Accessibility.attribute(kAXSizeAttribute, of: element) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    func matches(_ locator: Locator) -> Bool {
        func same(_ wanted: String?, _ actual: String?) -> Bool {
            guard let wanted else { return true }
            return actual?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(wanted.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }
        return same(locator.role, role) && same(locator.title, title ?? label) && same(locator.label, label ?? title)
            && same(locator.identifier, identifier) && same(locator.domId, domId)
            && (locator.url.map { wanted in url?.contains(wanted) ?? false } ?? true)
            && (locator.ancestors.map { wanted in Self.contains(ancestors, inOrder: wanted) } ?? true)
    }

    static func contains(_ path: [String], inOrder wanted: [String]) -> Bool {
        var remaining = wanted[...]
        for role in path where role == remaining.first { remaining = remaining.dropFirst() }
        return remaining.isEmpty
    }
}

enum AXTree {
    static let nodeLimit = 5000
    static let timeLimit: TimeInterval = 0.4
    static let interactiveRoles: Set<String> = [
        kAXButtonRole, "AXLink", kAXTextFieldRole, kAXTextAreaRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole,
        kAXMenuButtonRole, kAXComboBoxRole, "AXTab", kAXMenuItemRole, kAXSliderRole, "AXSearchField", kAXCellRole, kAXRowRole, "AXDisclosureTriangle",
    ]
    private static let attributes = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute, "AXDOMIdentifier", kAXURLAttribute, kAXChildrenAttribute] as CFArray

    static func app(_ bundleId: String?) -> NSRunningApplication? {
        guard let bundleId else { return NSWorkspace.shared.frontmostApplication }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
    }

    static func window(of pid: pid_t, matching title: String?) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let title else { return Accessibility.focusedWindow(of: pid) ?? windows(of: pid).first }
        return windows(of: pid).first { (Accessibility.attribute(kAXTitleAttribute, of: $0) as? String)?.localizedCaseInsensitiveContains(title) ?? false }
    }

    static func windows(of pid: pid_t) -> [AXUIElement] {
        (Accessibility.attribute(kAXWindowsAttribute, of: AXUIElementCreateApplication(pid)) as? [AXUIElement]) ?? []
    }

    static func nodes(in root: AXUIElement, limit: Int = nodeLimit) -> [AXNode] {
        let started = Date()
        var queue: [(AXUIElement, [String])] = [(root, [])], result: [AXNode] = []
        while !queue.isEmpty, result.count < limit, Date().timeIntervalSince(started) < timeLimit {
            let (element, path) = queue.removeFirst()
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let list = values as? [AnyObject], list.count == 8 else { continue }
            let role = list[0] as? String ?? ""
            if role == "AXSecureTextField" { continue }
            var actions: CFArray?
            AXUIElementCopyActionNames(element, &actions)
            let url = (list[6] as? URL)?.absoluteString ?? (list[6] as? String)
            result.append(AXNode(
                element: element, role: role, title: list[1] as? String, label: list[2] as? String,
                value: (list[3] as? String).map { String($0.prefix(400)) } ?? (list[3] as? NSNumber)?.stringValue,
                identifier: list[4] as? String, domId: list[5] as? String, url: url, actions: actions as? [String] ?? [], ancestors: path
            ))
            queue += (list[7] as? [AXUIElement] ?? []).map { ($0, path + [role]) }
        }
        return result
    }

    static func root(for locator: Locator?) -> (NSRunningApplication, AXUIElement)? {
        guard let app = app(locator?.bundleId), let window = window(of: app.processIdentifier, matching: locator?.window) else { return nil }
        return (app, window)
    }

    enum Resolution {
        case found(AXNode, NSRunningApplication)
        case missing(String)
    }

    static func resolve(_ locator: Locator) -> Resolution {
        guard let (app, window) = root(for: locator) else { return .missing("no window for \(locator.bundleId ?? "the frontmost app")\(locator.window.map { " titled \($0)" } ?? "")") }
        let matches = nodes(in: window).filter { $0.matches(locator) }
        if let index = locator.index {
            return index < matches.count ? .found(matches[index], app) : .missing("only \(matches.count) elements match \(locator.summary)")
        }
        switch matches.count {
        case 1: return .found(matches[0], app)
        case 0: return .missing("no element matches \(locator.summary)")
        default: return .missing("\(matches.count) elements match \(locator.summary): add a field or an index")
        }
    }

    static func describe(_ locator: Locator?, limit: Int = 160) -> String {
        guard let (app, window) = root(for: locator) else { return "No window: is the app running, with a window on this Space?" }
        let title = Accessibility.attribute(kAXTitleAttribute, of: window) as? String ?? ""
        let all = nodes(in: window)
        let interactive = all.filter { interactiveRoles.contains($0.role) || $0.actions.contains(kAXPressAction) || $0.url != nil && $0.role == "AXWebArea" }
        var lines = ["\(app.localizedName ?? "") — window \"\(title)\", \(all.count) elements read, \(interactive.count) you can act on:"]
        lines += interactive.prefix(limit).map { "- " + $0.line }
        if interactive.count > limit { lines.append("… \(interactive.count - limit) more") }
        return lines.joined(separator: "\n")
    }
}

struct AXSnapshot: Equatable {
    let lines: [String]
    let title: String?

    static func capture(_ bundleId: String?) -> AXSnapshot? {
        guard let (_, window) = AXTree.root(for: Locator(bundleId: bundleId)) else { return nil }
        let nodes = AXTree.nodes(in: window)
        return AXSnapshot(lines: nodes.compactMap { node in node.text.map { "\(node.role) \($0.prefix(120))" } ?? node.url.map { "\(node.role) <\($0)>" } },
                          title: Accessibility.attribute(kAXTitleAttribute, of: window) as? String)
    }

    var urls: [String] { lines.compactMap { line in line.firstIndex(of: "<").map { String(line[line.index(after: $0)...].dropLast()) } } }

    func diff(to after: AXSnapshot) -> AXDiff {
        let before = Set(lines), now = Set(after.lines)
        return AXDiff(added: after.lines.filter { !before.contains($0) }, removed: lines.filter { !now.contains($0) }, titleBefore: title, titleAfter: after.title)
    }
}

struct AXDiff: Codable, Equatable {
    let added: [String]
    let removed: [String]
    let titleBefore: String?
    let titleAfter: String?

    var isEmpty: Bool { added.isEmpty && removed.isEmpty && titleBefore == titleAfter }

    var summary: String {
        if isEmpty { return "no visible change" }
        var parts: [String] = []
        if titleBefore != titleAfter { parts.append("title \"\(titleBefore ?? "")\" → \"\(titleAfter ?? "")\"") }
        if !added.isEmpty { parts.append("added: " + added.prefix(6).joined(separator: " | ")) }
        if !removed.isEmpty { parts.append("removed: " + removed.prefix(6).joined(separator: " | ")) }
        return parts.joined(separator: "; ")
    }

    var learnedCheck: Check? {
        if let title = titleAfter, title != titleBefore, !title.isEmpty { return Check(kind: .titleContains, value: title) }
        if let line = added.first(where: { !$0.contains("<") }), let text = line.split(separator: " ", maxSplits: 1).last { return Check(kind: .textAppears, value: String(text)) }
        return nil
    }
}
