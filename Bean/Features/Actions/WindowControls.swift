import AppKit
import ApplicationServices

extension WindowChannels {
    static let notScriptable = "This app has no scripting dictionary."
    private static let refused = try! NSRegularExpression(pattern: #"(do shell script|system events|system attribute|run script|load script|store script|open location|display dialog|display alert|with administrator|keystroke|key code|\bactivate\b|\bclick\b|\bpath to\b|\bread\b|\bwrite\b|\bopen for access\b|\bcurrent application\b|\buse framework\b|\bsay\b|\bbeep\b)"#, options: .caseInsensitive)
    private static let tells = try! NSRegularExpression(pattern: #"\b(tell|using terms from)\s+(application|app)\s+("[^"]*"|id\s+"[^"]*"|\S+)"#, options: .caseInsensitive)
    private static let strings = try! NSRegularExpression(pattern: #""(\\.|[^"\\])*""#)
    private static let readVerbs: Set<String> = ["count", "exists", "get"]
    private static let extraIrreversible = try! NSRegularExpression(pattern: #"\b(send|quit|close|erase|empty|pay|buy|purchase|submit|bounce|forward|redirect|reply|sign out|log out|restart|shut down)\b"#, options: .caseInsensitive)

    static func abilities(forApp attachment: Attachment, explicit: [String]) -> [AgentAbility] {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: attachment.bundleId),
              let dictionary = ScriptDictionary.load(appAt: url.path) else { return [] }
        var seen = Set<String>()
        let messages = AppGuard.holdsMessages(dictionary) ? [AgentAbility(id: AppGuard.messageAbility(attachment.appName), title: "Prepare messages", detail: "A draft syncs to the user's account, so it leaves this Mac even if it is never sent.",
                                                                           allowed: explicit.contains { ["draft", "message", "email"].contains($0.lowercased()) }, risk: .outward, source: attachment.appName)] : []
        return messages + dictionary.commands.compactMap { command in
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
        if let refused = AppGuard.refusal(script: script, app: app) ?? AppGuard.refusal(message: AppGuard.code(of: script), app: app, abilities: abilities) { return refused }
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

    func holdsOnly(_ placed: [String]) -> Bool {
        let fields = controls.indices.filter { ["AXTextArea", "AXTextField"].contains(AppControls.describe(controls[$0].element).role) }
            .compactMap { value($0) }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return !fields.isEmpty && fields.allSatisfy { field in placed.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == field } }
    }

    func value(_ index: Int) -> String? {
        controls.indices.contains(index) ? Accessibility.attribute(kAXValueAttribute, of: controls[index].element) as? String : nil
    }

    func setValue(_ index: Int, _ text: String) -> String? {
        guard controls.indices.contains(index), controls[index].settable else { return "no field to fill at \(index): call window_controls first" }
        let element = controls[index].element
        func flat(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        func kept() -> Bool { (Accessibility.attribute(kAXValueAttribute, of: element) as? String).map { flat($0) == flat(text) } ?? true }
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success else { return "the app refused the change" }
        if kept() { return nil }
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
        if kept() { return nil }
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        if kept() { return nil }
        return "the field did not keep the text, it reads: \((Accessibility.attribute(kAXValueAttribute, of: element) as? String ?? "").prefix(120))"
    }

    func press(_ index: Int) -> String? {
        guard controls.indices.contains(index), controls[index].pressable else { return "no button to press at \(index): call window_controls first" }
        return AXUIElementPerformAction(controls[index].element, kAXPressAction as CFString) == .success ? nil : "the app refused the press"
    }
}
