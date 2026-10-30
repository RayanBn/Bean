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
    static let notScriptable = "This app has no scripting dictionary."
    private static let refused = try! NSRegularExpression(pattern: #"(do shell script|system events|system attribute|run script|load script|store script|open location|display dialog|display alert|with administrator|keystroke|key code|\bactivate\b|\bclick\b|\bpath to\b|\bread\b|\bwrite\b|\bopen for access\b|\bcurrent application\b|\buse framework\b|\bsay\b|\bbeep\b)"#, options: .caseInsensitive)
    private static let tells = try! NSRegularExpression(pattern: #"\b(tell|using terms from)\s+(application|app)\s+("[^"]*"|id\s+"[^"]*"|\S+)"#, options: .caseInsensitive)
    private static let strings = try! NSRegularExpression(pattern: #""(\\.|[^"\\])*""#)
    private static let readVerbs: Set<String> = ["count", "exists", "get"]
    private static let extraIrreversible = try! NSRegularExpression(pattern: #"\b(send|quit|close|erase|empty|pay|buy|purchase|submit|bounce|forward|redirect|reply|sign out|log out|restart|shut down)\b"#, options: .caseInsensitive)

    static func open() -> [OpenWindow] {
        let filter = ProcessInfo.processInfo.environment["BEAN_WINDOW_FILTER"]
        let options: CGWindowListOption = filter == nil ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        let me = ProcessInfo.processInfo.processIdentifier
        var seen = Set<Int>()
        return list.compactMap { info -> OpenWindow? in
            guard info[kCGWindowLayer as String] as? Int == 0, let number = info[kCGWindowNumber as String] as? Int, seen.insert(number).inserted,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != me, let app = info[kCGWindowOwnerName as String] as? String,
                  filter.map({ app.localizedCaseInsensitiveContains($0) }) ?? true,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }), bounds.height > 60, bounds.width > 120 else { return nil }
            let running = NSRunningApplication(processIdentifier: pid)
            guard running?.activationPolicy != .prohibited || filter != nil else { return nil }
            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? axTitle(pid: pid, bounds: bounds)
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

    static func abilities(forApp attachment: Attachment, explicit: [String]) -> [AgentAbility] {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: attachment.bundleId),
              let dictionary = ScriptDictionary.load(appAt: url.path) else { return [] }
        var seen = Set<String>()
        return dictionary.commands.compactMap { command in
            guard seen.insert(command.name).inserted else { return nil }
            let verb = command.name.split(separator: " ").first.map(String.init) ?? command.name
            let risk: AgentAbility.Risk
            if readVerbs.contains(verb) { risk = .safe }
            else if isIrreversible(command.name) || !AbilityFinder.outwardVerb(verb) { risk = .irreversible }
            else { risk = .outward }
            return AgentAbility(id: "\(attachment.appName): \(command.name)", title: AbilityFinder.humanized(command.name), detail: String(command.summary.prefix(140)),
                                allowed: AbilityFinder.defaultAllowed(risk, id: command.name, explicit: explicit), risk: risk, source: attachment.appName)
        }
    }

    static func isIrreversible(_ text: String) -> Bool {
        AbilityFinder.irreversible(text) || extraIrreversible.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func refusal(script: String, app: String, abilities: [AgentAbility]) -> String? {
        if let term = OffLimits.match(script) { return "off limits: \(term)" }
        if let refused = AppGuard.refusal(script: script, app: app) { return refused }
        let whole = NSRange(script.startIndex..., in: script)
        let tellsApps = tells.matches(in: script, range: whole).compactMap { Range($0.range(at: 3), in: script).map { script[$0].replacingOccurrences(of: "\"", with: "") } }
        guard !tellsApps.isEmpty else { return "the script must start with tell application \"\(app)\"" }
        if let other = tellsApps.first(where: { $0.caseInsensitiveCompare(app) != .orderedSame }) { return "you only work in \(app), not \(other)" }
        let code = strings.stringByReplacingMatches(in: script, range: whole, withTemplate: "\"\"")
        if let match = refused.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)), let range = Range(match.range, in: code) {
            return "\(code[range]) is not allowed: agents never take over the Mac or leave their app"
        }
        for ability in abilities where ability.source == app && !ability.allowed {
            let command = ability.id.components(separatedBy: ": ").last ?? ability.id
            let word = try! NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: command))\\b", options: .caseInsensitive)
            if word.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil { return "\(ability.title) is turned off for this agent" }
        }
        let words = code.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        for word in words where isIrreversible(word) {
            let allowed = abilities.contains { $0.source == app && $0.allowed && ($0.id.components(separatedBy: ": ").last ?? "").caseInsensitiveCompare(word) == .orderedSame }
            if !allowed { return "\(word) cannot be taken back and is turned off for this agent" }
        }
        return nil
    }
}

final class WindowControls {
    struct Control {
        let element: AXUIElement
        let line: String
        let label: String
        let settable: Bool
        let pressable: Bool
    }

    private(set) var controls: [Control] = []

    func list(_ attachment: Attachment) -> String {
        controls = []
        guard let window = WindowSnapshot.element(for: attachment) else { return "I cannot reach this window through Accessibility." }
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while let (element, depth) = stack.popLast(), visited < 1500, controls.count < 60 {
            visited += 1
            let role = Accessibility.attribute(kAXRoleAttribute, of: element) as? String ?? ""
            var settable = DarwinBoolean(false)
            AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
            var names: CFArray?
            AXUIElementCopyActionNames(element, &names)
            let pressable = (names as? [String])?.contains(kAXPressAction) == true
            if settable.boolValue || pressable {
                let described = AppControls.describe(element)
                let label = described.label
                let value = described.secure ? " value: (hidden)" : (Accessibility.attribute(kAXValueAttribute, of: element) as? String).map { " value: \($0.prefix(60))" } ?? ""
                controls.append(Control(element: element, line: "\(controls.count): \(role.replacingOccurrences(of: "AX", with: "")) \"\(label.prefix(50))\"\(value)\(settable.boolValue ? " (can set)" : "")\(pressable ? " (can press)" : "")",
                                        label: label, settable: settable.boolValue, pressable: pressable))
            }
            if depth < 30 {
                let children = (Accessibility.attribute(kAXChildrenAttribute, of: element) as? [AXUIElement]) ?? []
                stack += children.reversed().map { ($0, depth + 1) }
            }
        }
        return controls.isEmpty ? "No control in this window can be used through Accessibility." : controls.map(\.line).joined(separator: "\n")
    }

    func setValue(_ index: Int, _ text: String) -> String? {
        guard controls.indices.contains(index), controls[index].settable else { return "no field to fill at \(index): call window_controls first" }
        let element = controls[index].element
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success else { return "the app refused the change" }
        if let now = Accessibility.attribute(kAXValueAttribute, of: element) as? String, now != text { return "the field did not keep the text, it reads: \(now.prefix(120))" }
        return nil
    }

    func press(_ index: Int) -> String? {
        guard controls.indices.contains(index), controls[index].pressable else { return "no button to press at \(index): call window_controls first" }
        return AXUIElementPerformAction(controls[index].element, kAXPressAction as CFString) == .success ? nil : "the app refused the press"
    }
}
