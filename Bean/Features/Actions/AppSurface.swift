import AppKit
import ApplicationServices

enum AppAutomation: String {
    case allowed, needsConsent, refused, notOpen

    static var mayAsk: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["BEAN_DATA_DIR"] == nil || environment["BEAN_ASK_AUTOMATION"] == "1"
    }

    static func state(of bundleId: String, ask: Bool) -> AppAutomation {
        guard let target = NSAppleEventDescriptor(bundleIdentifier: bundleId).aeDesc else { return .notOpen }
        switch AEDeterminePermissionToAutomateTarget(target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask) {
        case noErr: return .allowed
        case OSStatus(errAEEventWouldRequireUserConsent): return .needsConsent
        case OSStatus(procNotFound): return .notOpen
        default: return .refused
        }
    }
}

struct ScriptDictionary {
    struct Command {
        let name: String
        let summary: String
        let parameters: [String]
    }

    struct Field {
        let name: String
        let readOnly: Bool
        let text: Bool
        let holdsAnything: Bool
    }

    struct Kind {
        let name: String
        let summary: String
        let properties: [String]
        let elements: [String]
        var inherits = ""
        var fields: [Field] = []
    }

    // A class that can be written, with the read-only text it keeps beside it. An inherited one names the object rather than computes it.
    struct Place {
        let beside: [String]
        let label: String?
        let holdsAnything: Bool
    }

    let commands: [Command]
    let kinds: [Kind]

    static func load(appAt path: String) -> ScriptDictionary? {
        guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist"),
              info["OSAScriptingDefinition"] != nil || info["NSAppleScriptEnabled"] != nil else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sdef")
        process.arguments = [path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let document = try? XMLDocument(data: data, options: [.documentXInclude]),
              let root = document.rootElement() else { return nil }
        func text(_ node: XMLNode, _ name: String) -> String { (node as? XMLElement)?.attribute(forName: name)?.stringValue ?? "" }
        let commands = ((try? root.nodes(forXPath: "//command")) ?? []).map { node in
            Command(name: text(node, "name"), summary: text(node, "description"),
                    parameters: ((try? node.nodes(forXPath: "parameter")) ?? []).map { text($0, "name") })
        }
        let kinds = ((try? root.nodes(forXPath: "//class | //class-extension")) ?? []).compactMap { node -> Kind? in
            let name = text(node, "name").isEmpty ? text(node, "extends") : text(node, "name")
            guard !name.isEmpty else { return nil }
            let properties = (try? node.nodes(forXPath: "property")) ?? []
            return Kind(name: name, summary: text(node, "description"),
                        properties: properties.map { text($0, "name") + (text($0, "access") == "r" ? " (read only)" : "") },
                        elements: ((try? node.nodes(forXPath: "element")) ?? []).map { text($0, "type") },
                        inherits: text(node, "inherits"),
                        fields: properties.map { property in
                            let types = [text(property, "type")].filter { !$0.isEmpty } + ((try? property.nodes(forXPath: "type[not(@hidden)]")) ?? []).map { text($0, "type") }
                            return Field(name: text(property, "name").lowercased(), readOnly: text(property, "access") == "r", text: types == ["text"], holdsAnything: types.count > 1 || types == ["any"])
                        })
        }
        guard !commands.isEmpty else { return nil }
        return ScriptDictionary(commands: commands, kinds: kinds)
    }

    var changingCommands: [String] {
        commands.map { $0.name.lowercased() }.filter { !["get", "set", "count", "exists"].contains($0) }
    }

    func holds(_ property: String) -> Bool {
        kinds.contains { $0.fields.contains { $0.name == property } }
    }

    private func label(above kind: Kind) -> String? {
        var parent = kind.inherits, seen = Set<String>()
        while !parent.isEmpty, seen.insert(parent).inserted {
            let found = kinds.filter { $0.name == parent }
            if let field = found.flatMap(\.fields).first(where: { $0.readOnly && $0.text }) { return field.name }
            parent = found.first?.inherits ?? ""
        }
        return nil
    }

    private func place(of kind: Kind, writing property: String) -> Place? {
        let fields = kinds.filter { $0.name == kind.name }.flatMap(\.fields)
        guard let written = fields.first(where: { $0.name == property && !$0.readOnly }) else { return nil }
        let beside = fields.filter { $0.readOnly && $0.text }.map(\.name)
        return beside.isEmpty ? nil : Place(beside: beside, label: label(above: kind), holdsAnything: written.holdsAnything)
    }

    func places(writing property: String) -> [Place] {
        var seen = Set<String>()
        return kinds.filter { seen.insert($0.name).inserted }.compactMap { place(of: $0, writing: property) }
    }

    var valueKinds: [(kind: String, property: String, place: Place)] {
        var seen = Set<String>()
        return kinds.filter { seen.insert($0.name).inserted }.compactMap { kind in
            guard let field = kinds.filter({ $0.name == kind.name }).flatMap(\.fields).first(where: { $0.holdsAnything && !$0.readOnly }),
                  let place = place(of: kind, writing: field.name) else { return nil }
            return (kind.name, field.name, place)
        }
    }

    var overview: String {
        var seen = Set<String>()
        let verbs = commands.filter { seen.insert($0.name).inserted }.map(\.name)
        seen = []
        let nouns = kinds.filter { seen.insert($0.name).inserted }.map(\.name)
        return "Script commands: \(verbs.prefix(80).joined(separator: ", "))\nScript objects: \(nouns.prefix(80).joined(separator: ", "))"
    }

    func details(of term: String) -> String? {
        let wanted = term.lowercased()
        let lines = commands.filter { $0.name.lowercased() == wanted }.map { "command \($0.name): \($0.summary)\n  parameters: \($0.parameters.joined(separator: ", "))" }
            + kinds.filter { $0.name.lowercased() == wanted }.map { "object \($0.name): \($0.summary)\n  properties: \($0.properties.joined(separator: ", "))\n  contains: \($0.elements.joined(separator: ", "))" }
            + valueKinds.filter { $0.kind.lowercased() == wanted }.map { "app_read_rows shows \($0.place.beside.joined(separator: " and ")) beside each \($0.property)." }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

struct AppSurface {
    let name: String
    let bundleId: String
    let pid: pid_t
    let dictionary: ScriptDictionary?
    let schemes: [String]
    let automation: AppAutomation
    let trusted: Bool
    let controls: Int
    let menus: Int

    static func read(_ attachment: Attachment) -> AppSurface {
        let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: attachment.bundleId)?.path
        let schemes = schemes(of: attachment.bundleId)
        let trusted = AXIsProcessTrusted()
        let controls = trusted ? AppControls.count(attachment) : 0
        let menus = trusted ? AppControls.menuItems(of: attachment.pid, limit: 150) : []
        return AppSurface(name: attachment.appName, bundleId: attachment.bundleId, pid: attachment.pid,
                          dictionary: path.flatMap(ScriptDictionary.load(appAt:)), schemes: schemes,
                          automation: AppAutomation.state(of: attachment.bundleId, ask: false),
                          trusted: trusted, controls: controls, menus: menus.count)
    }

    static func schemes(of bundleId: String) -> [String] {
        let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)?.path
        let types = path.flatMap { NSDictionary(contentsOfFile: $0 + "/Contents/Info.plist")?["CFBundleURLTypes"] as? [[String: Any]] } ?? []
        return types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }.filter { !$0.hasPrefix("x-") }
    }

    var scriptable: Bool { dictionary != nil && automation != .refused }
    var drivable: Bool { scriptable || controls > 0 || menus > 0 || !schemes.isEmpty }

    var reason: String? {
        guard !drivable else { return nil }
        var causes: [String] = []
        if dictionary == nil { causes.append("it has no scripting dictionary") }
        if dictionary != nil, automation == .refused { causes.append("automation of it is turned off in System Settings, Privacy & Security, Automation") }
        if !trusted {
            causes.append("Bean does not have the switch \(WindowAccess.paneName) (System Settings, Privacy & Security)")
        } else {
            causes.append("its window exposes no controls")
        }
        return "\(name) cannot be driven in the background: \(causes.joined(separator: ", and ")). I can still work from what is on its window and through connectors."
    }

    var summary: String {
        var lines = ["App: \(name) (\(bundleId))"]
        if let dictionary {
            lines.append("AppleScript: yes, \(automation == .allowed ? "allowed" : automation == .needsConsent ? "macOS will ask the user once" : automation == .notOpen ? "the app is not open" : "turned off by the user in System Settings")")
            lines.append(dictionary.overview)
        } else {
            lines.append("AppleScript: no")
        }
        lines.append("Window controls: \(trusted ? "\(controls) controls in the window, \(menus) menu items" : "Bean does not have the switch \(WindowAccess.paneName)")")
        lines.append("URLs: \(schemes.isEmpty ? "none" : schemes.joined(separator: ", "))")
        if let reason { lines.append(reason) }
        return lines.joined(separator: "\n")
    }
}

struct AppControl {
    let role: String
    let label: String
    let secure: Bool
}

enum AppControls {
    private static func string(_ name: String, of element: AXUIElement) -> String? {
        (Accessibility.attribute(name, of: element) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func describe(_ element: AXUIElement) -> AppControl {
        AppControl(role: string(kAXRoleAttribute, of: element) ?? "",
                   label: string(kAXTitleAttribute, of: element) ?? string(kAXDescriptionAttribute, of: element)
                    ?? string("AXPlaceholderValue", of: element) ?? string(kAXHelpAttribute, of: element)
                    ?? Accessibility.attribute(kAXTitleUIElementAttribute, of: element).flatMap { string(kAXValueAttribute, of: $0 as! AXUIElement) } ?? "",
                   secure: string(kAXSubroleAttribute, of: element) == "AXSecureTextField")
    }

    static func count(_ attachment: Attachment) -> Int {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(attachment.pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let controls = WindowControls()
        _ = controls.list(attachment)
        return controls.controls.count
    }

    static func menuItems(of pid: pid_t, limit: Int) -> [(path: [String], element: AXUIElement)] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        guard let bar = Accessibility.attribute(kAXMenuBarAttribute, of: app) else { return [] }
        var found: [(path: [String], element: AXUIElement)] = []
        func walk(_ element: AXUIElement, _ path: [String], _ depth: Int) {
            guard found.count < limit, depth < 5 else { return }
            for child in (Accessibility.attribute(kAXChildrenAttribute, of: element) as? [AXUIElement]) ?? [] where found.count < limit {
                let title = string(kAXTitleAttribute, of: child) ?? ""
                let next = title.isEmpty ? path : path + [title]
                let inner = (Accessibility.attribute(kAXChildrenAttribute, of: child) as? [AXUIElement]) ?? []
                if inner.isEmpty {
                    if !title.isEmpty, path.count >= 1 { found.append((next, child)) }
                } else {
                    walk(child, next, depth + 1)
                }
            }
        }
        for top in ((Accessibility.attribute(kAXChildrenAttribute, of: bar as! AXUIElement) as? [AXUIElement]) ?? []).dropFirst() {
            walk(top, [string(kAXTitleAttribute, of: top) ?? ""], 1)
        }
        return found
    }
}
