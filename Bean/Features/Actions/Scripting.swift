import AppKit

enum Scripting {
    static let readVerbs: Set<String> = ["get", "count", "exists", "properties"]
    static let codePattern = try! NSRegularExpression(pattern: #"(?i)\b(do\s+script|do\s+shell\s+script|do\s+javascript|execute|run\s+script|load\s+script)\b"#)

    static func runsCode(_ source: String) -> Bool {
        codePattern.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil
    }

    static func run(_ source: String, tellingApp bundleId: String) -> (ok: Bool, channel: String, note: String) {
        let script = source.lowercased().contains("tell application") ? source : "tell application id \"\(bundleId)\"\n\(source)\nend tell"
        guard let output = HiddenShell.capture("/usr/bin/osascript", ["-e", script], timeout: 15) else {
            let error = HiddenShell.run("osascript -e \(VisibleTerminal.quoted(script))", timeout: 15).output
            return (false, "script", "AppleScript failed: \(error.suffix(300))")
        }
        return (true, "script", output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "ran" : "result: \(output.prefix(400))")
    }

    static func dictionary(_ bundleId: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return "\(bundleId) is not installed." }
        guard let xml = HiddenShell.capture("/usr/bin/sdef", [url.path], timeout: 10), let data = xml.data(using: .utf8),
              let document = try? XMLDocument(data: data) else {
            return "\(url.lastPathComponent) has no scripting dictionary."
        }
        var lines: [String] = []
        for suite in (try? document.nodes(forXPath: "//suite")) as? [XMLElement] ?? [] {
            let name = suite.attribute(forName: "name")?.stringValue ?? ""
            var parts: [String] = []
            for command in (try? suite.nodes(forXPath: "command")) as? [XMLElement] ?? [] {
                let params = ((try? command.nodes(forXPath: "parameter")) as? [XMLElement] ?? []).compactMap { $0.attribute(forName: "name")?.stringValue }
                parts.append("command \(command.attribute(forName: "name")?.stringValue ?? "")" + (params.isEmpty ? "" : " (\(params.joined(separator: ", ")))"))
            }
            for item in (try? suite.nodes(forXPath: "class|class-extension")) as? [XMLElement] ?? [] {
                let className = item.attribute(forName: "name")?.stringValue ?? item.attribute(forName: "extends")?.stringValue ?? ""
                let properties = ((try? item.nodes(forXPath: "property")) as? [XMLElement] ?? []).compactMap { $0.attribute(forName: "name")?.stringValue }
                let elements = ((try? item.nodes(forXPath: "element")) as? [XMLElement] ?? []).compactMap { $0.attribute(forName: "type")?.stringValue }
                parts.append("class \(className)" + (properties.isEmpty ? "" : " props: \(properties.prefix(20).joined(separator: ", "))") + (elements.isEmpty ? "" : " contains: \(elements.joined(separator: ", "))"))
            }
            if !parts.isEmpty { lines.append("Suite \(name):\n  " + parts.joined(separator: "\n  ")) }
        }
        return lines.isEmpty ? "\(url.lastPathComponent) has an empty scripting dictionary." : String(lines.joined(separator: "\n").prefix(6000))
    }
}
