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
    private var menuOpenedOver: NSRunningApplication?
    private var windowUnderMenu: AXUIElement?

    func list(_ attachment: Attachment, controlLimit: Int = 60, visitLimit: Int = 1500, depthLimit: Int = 30) -> String {
        controls = []
        guard let window = WindowSnapshot.element(for: attachment) else { return "I cannot reach this window through Accessibility." }
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while let (element, depth) = stack.popLast(), visited < visitLimit, controls.count < controlLimit {
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
                let raw = Accessibility.attribute(kAXValueAttribute, of: element)
                let value = described.secure ? " value: (hidden)" : ((raw as? String) ?? (raw as? NSNumber)?.stringValue).map { " value: \($0.prefix(60))" } ?? ""
                controls.append(Control(element: element, line: "\(role.replacingOccurrences(of: "AX", with: "")) \"\(label.prefix(50))\"\(value)\(settable.boolValue ? " (can set)" : "")\(pressable ? " (can press)" : "")",
                                        label: label, settable: settable.boolValue, pressable: pressable))
            }
            if depth < depthLimit {
                let children = (Accessibility.attribute(kAXChildrenAttribute, of: element) as? [AXUIElement]) ?? []
                stack += children.reversed().map { ($0, depth + 1) }
            }
        }
        return controls.isEmpty ? "No control in this window can be used through Accessibility." : numbered
    }

    private var numbered: String {
        controls.enumerated().map { "\($0.offset): \($0.element.line)" }.joined(separator: "\n")
    }

    // A sealed window also shows the user's own conversations. Only the controls its skill names are ever listed.
    func listSealed(_ attachment: Attachment, skill: Skill) -> String {
        // This app's window exposes nothing to Accessibility while it is off screen, and the user is here to watch it.
        if let app = NSRunningApplication(processIdentifier: attachment.pid), !app.isActive {
            app.activate()
            Thread.sleep(forTimeInterval: 1)
        }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(attachment.pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
        _ = list(attachment, controlLimit: 1500, visitLimit: 15000, depthLimit: 60)
        func names(_ element: AXUIElement) -> [String] {
            [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue"].compactMap { Accessibility.attribute($0, of: element) as? String }.filter { !$0.isEmpty }
        }
        if let asks = skill.asks, controls.contains(where: { names($0.element).contains(asks) }) {
            controls = []
            return "\(Self.appAsks) It offers: \(asks)."
        }
        controls = controls.compactMap { control in
            let role = Accessibility.attribute(kAXRoleAttribute, of: control.element) as? String ?? ""
            guard let label = names(control.element).first(where: { skill.allows(role: role, label: $0) }) else { return nil }
            let text = role == "AXTextArea" || role == "AXTextField"
            return Control(element: control.element, line: text ? "\(role.replacingOccurrences(of: "AX", with: "")) \"\(label)\" (can set)" : control.line.replacingOccurrences(of: "\"\(control.label.prefix(50))\"", with: "\"\(label.prefix(50))\""), label: label, settable: control.settable, pressable: control.pressable)
        }
        return controls.isEmpty ? "None of the controls you may use is showing." : numbered
    }

    static let appAsks = "The app is asking something only the user can answer."

    func role(_ index: Int) -> String {
        controls.indices.contains(index) ? Accessibility.attribute(kAXRoleAttribute, of: controls[index].element) as? String ?? "" : ""
    }

    func showsExisting(_ index: Int, marker: String) -> Bool {
        guard controls.indices.contains(index) else { return false }
        var current = controls[index].element
        for _ in 0..<40 {
            guard let parent = Accessibility.attribute(kAXParentAttribute, of: current) else { return false }
            current = parent as! AXUIElement
            guard Accessibility.attribute(kAXRoleAttribute, of: current) as? String == "AXWebArea" else { continue }
            let url = Accessibility.attribute("AXURL", of: current)
            return ((url as? URL)?.absoluteString ?? url as? String ?? "").contains(marker)
        }
        return false
    }

    func setPlainly(_ index: Int, _ text: String) -> String? {
        guard controls.indices.contains(index), controls[index].settable else { return "no field to fill at \(index): call window_controls first" }
        return AXUIElementSetAttributeValue(controls[index].element, kAXValueAttribute as CFString, text as CFString) == .success ? nil : "the app refused the change"
    }

    private func flat(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    func holdsOnly(_ placed: [String]) -> Bool {
        let fields = controls.indices.filter { ["AXTextArea", "AXTextField"].contains(AppControls.describe(controls[$0].element).role) }
            .compactMap { value($0) }.map { flat($0) }.filter { !$0.isEmpty }
        return !fields.isEmpty && fields.allSatisfy { field in placed.contains { flat($0) == field } }
    }

    func refusal(_ index: Int, action: String, abilities: [AgentAbility], ownText: Bool = false) -> String? {
        let label = controls.indices.contains(index) ? controls[index].label : ""
        if action == "fill", abilities.first(where: { $0.id == "window fill" })?.allowed == false { return "Filling fields is turned off for this agent" }
        if action == "press", abilities.first(where: { $0.id == "window press" })?.allowed == false { return "Pressing buttons is turned off for this agent" }
        guard controls.indices.contains(index) else { return nil }
        let control = AppControls.describe(controls[index].element)
        if let refused = AppGuard.refusal(control: control, action: action) { return refused }
        return action == "press" ? AppGuard.pressRefusal(role: control.role, label: label, abilities: abilities, ownText: ownText) : nil
    }

    func value(_ index: Int) -> String? {
        controls.indices.contains(index) ? Accessibility.attribute(kAXValueAttribute, of: controls[index].element) as? String : nil
    }

    func setValue(_ index: Int, _ text: String) -> String? {
        guard controls.indices.contains(index), controls[index].settable else { return "no field to fill at \(index): call window_controls first" }
        let element = controls[index].element, pressable = controls[index].pressable
        func kept() -> Bool { (Accessibility.attribute(kAXValueAttribute, of: element) as? String).map { flat($0) == flat(text) } ?? true }
        // Setting AXFocused brings the app forward, and a web view applies a value to whichever field has the focus. A press moves the focus inside the page and leaves the front app alone.
        if inWebPage(element) {
            guard pressable, AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { return "this field cannot be reached without bringing the app forward" }
        }
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success else { return "the app refused the change" }
        if kept() { return nil }
        if pressable, AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
            if kept() { return nil }
        }
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        if kept() { return nil }
        return "the field did not keep the text, it reads: \((Accessibility.attribute(kAXValueAttribute, of: element) as? String ?? "").prefix(120))"
    }

    private func inWebPage(_ element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<30 {
            guard let parent = Accessibility.attribute(kAXParentAttribute, of: current) else { return false }
            current = parent as! AXUIElement
            if Accessibility.attribute(kAXRoleAttribute, of: current) as? String == "AXWebArea" { return true }
        }
        return false
    }

    // Return in a web form or a long text can send it. Only a search there, or a one-line native field, is safe to confirm.
    func confirmsEntry(_ index: Int) -> Bool {
        guard controls.indices.contains(index), controls[index].settable else { return false }
        let element = controls[index].element
        var names: CFArray?
        AXUIElementCopyActionNames(element, &names)
        guard (names as? [String])?.contains(kAXConfirmAction) == true else { return false }
        let role = Accessibility.attribute(kAXRoleAttribute, of: element) as? String
        let search = Accessibility.attribute(kAXSubroleAttribute, of: element) as? String == "AXSearchField"
            || controls[index].label.range(of: "search|recherche|buscar|suche", options: [.regularExpression, .caseInsensitive]) != nil
        return search || (role == "AXTextField" && !inWebPage(element))
    }

    func confirm(_ index: Int) -> String? {
        let element = controls[index].element, front = appInFront(other: element)
        guard AXUIElementPerformAction(element, kAXConfirmAction as CFString) == .success else { return "the app refused" }
        keepFront(front, from: element)
        return nil
    }

    func press(_ index: Int) -> String? {
        guard controls.indices.contains(index), controls[index].pressable else { return "no button to press at \(index): call window_controls first" }
        let element = controls[index].element
        let role = Accessibility.attribute(kAXRoleAttribute, of: element) as? String
        let front = appInFront(other: element)
        let opensMenu = role == "AXPopUpButton" || role == "AXMenuButton"
        if opensMenu {
            menuOpenedOver = front
            windowUnderMenu = front == nil ? sameAppFrontWindow(of: element) : nil
        }
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { return "the app refused the press" }
        if role == "AXMenuItem" { giveFrontBack() } else if !opensMenu { keepFront(front, from: element) }
        return nil
    }

    // Some controls, such as a button that opens a popover, bring their app forward. The user's app takes the front back at once.
    private func keepFront(_ front: NSRunningApplication?, from element: AXUIElement) {
        guard let front else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { [self] in
            guard appInFront(other: element) == nil else { return }
            DispatchQueue.main.async { front.activate(options: [.activateAllWindows]) }
        }
    }

    func closeOpenMenu() {
        guard let item = controls.first(where: { Accessibility.attribute(kAXRoleAttribute, of: $0.element) as? String == "AXMenuItem" }),
              let menu = Accessibility.attribute(kAXParentAttribute, of: item.element) else { return }
        if AXUIElementPerformAction(menu as! AXUIElement, kAXCancelAction as CFString) == .success { giveFrontBack() }
    }

    private func appInFront(other element: AXUIElement) -> NSRunningApplication? {
        var mine: pid_t = 0, focused: pid_t = 0
        AXUIElementGetPid(element, &mine)
        guard let focus = Accessibility.attribute(kAXFocusedUIElementAttribute, of: AXUIElementCreateSystemWide()) else { return nil }
        AXUIElementGetPid(focus as! AXUIElement, &focused)
        return focused == mine ? nil : NSRunningApplication(processIdentifier: focused)
    }

    // A pop-up menu raises its window over the app the user is in, so that app goes back on top once the menu is gone.
    private func giveFrontBack() {
        let app = menuOpenedOver, window = windowUnderMenu
        menuOpenedOver = nil
        windowUnderMenu = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            app?.activate(options: [.activateAllWindows])
            if let window { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
        }
    }

    private func sameAppFrontWindow(of element: AXUIElement) -> AXUIElement? {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return Accessibility.attribute(kAXFocusedWindowAttribute, of: AXUIElementCreateApplication(pid)).map { $0 as! AXUIElement }
    }
}
