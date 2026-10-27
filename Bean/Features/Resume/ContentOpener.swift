import AppKit

/// Reopens exactly what a window showed, for any app: a recipe learned once per app (Muse Spark reads the app in a sandbox,
/// then tries only the app's own channels) and replayed with the window's handle. A recipe is kept only after Bean saw it work.
final class ContentOpener {
    static let maxRounds = 20
    static let settle: TimeInterval = 3.5
    static let system = """
    You are Bean, an agent on the user's Mac. A window the user had open is described below with the handle that identifies its content. \
    Find how to reopen exactly that content in its app, from what is on this Mac: URL schemes the app declares (plutil on its Info.plist), \
    routes and parameters inside the app's own code (Electron apps: Contents/Resources/app.asar, read it with strings or python3), \
    its AppleScript dictionary (sdef), executables inside its bundle, or opening a document with it. \
    run_shell runs in a read-only sandbox; read_app runs a read-only AppleScript. \
    try_action really performs one action and tells you which windows appeared or changed, with a screenshot. Try as soon as you have a good candidate: trying is cheap. \
    When an action worked, call keep with that same action written as a template: put {key} for each value that comes from the handle, \
    so Bean can replay it for other windows of this app.
    """

    private let client: ModelClient
    private let log: JSONLog
    private let url: URL
    private var recipes: [String: OpenAction]
    private var notes: [String: [String]] = [:]

    init(client: ModelClient, log: JSONLog) {
        self.client = client
        self.log = log
        url = log.url.deletingLastPathComponent().appendingPathComponent("recipes.json")
        recipes = (try? JSONDecoder().decode([String: OpenAction].self, from: Data(contentsOf: url))) ?? [:]
    }

    func reopen(_ saved: SavedWindow, verify: @escaping () async -> Bool) async -> Bool {
        let handle = (saved.content?.handle ?? [:]).merging(["title": saved.facts.title], uniquingKeysWith: { first, _ in first })
        if let recipe = recipes[saved.facts.bundleId], let action = recipe.filled(handle), action.isAllowed(appPath: saved.facts.appPath) {
            action.perform(appPath: saved.facts.appPath)
            try? await Task.sleep(for: .seconds(Self.settle))
            let ok = await verify()
            log.append(Entry(at: Date(), bundleId: saved.facts.bundleId, title: saved.facts.title, how: "replayed", action: action, ok: ok, rounds: 0))
            if ok { return true }
            notes[saved.facts.bundleId, default: []].append("The kept recipe \(recipe) was replayed as \(action) and did not reopen the content.")
        }
        return await learn(saved, handle: handle, verify: verify)
    }

    private func learn(_ saved: SavedWindow, handle: [String: String], verify: @escaping () async -> Bool) async -> Bool {
        guard client.isReady else { return false }
        let app = saved.facts.appPath
        let item = "App: \(saved.facts.appName) (\(saved.facts.bundleId)) at \(app)\nWhat it showed: \(saved.content?.description ?? saved.facts.title)\nHandle: \(handle)"
            + (notes[saved.facts.bundleId].map { "\nNotes from earlier attempts:\n" + $0.joined(separator: "\n") } ?? "")
        var messages: [[String: Any]] = [["role": "system", "content": Self.system], ["role": "user", "content": item]]
        var worked: OpenAction?
        for round in 1 ... Self.maxRounds {
            guard let reply = try? await client.chat(messages, tools: Self.tools), !reply.toolCalls.isEmpty else {
                messages.append(["role": "user", "content": "Call run_shell, read_app, try_action or keep."])
                continue
            }
            messages.append(reply.assistantMessage)
            var screens: [Data] = []
            for call in reply.toolCalls {
                let args = (try? JSONSerialization.jsonObject(with: call.arguments) as? [String: Any]) ?? [:]
                var answer: String
                switch call.name {
                case "try_action":
                    guard let action = OpenAction(args), action.isAllowed(appPath: app) else {
                        answer = "refused: only a URL whose scheme this app declares, an existing document, an AppleScript told to this app only, or an executable inside its bundle"
                        break
                    }
                    let before = Self.windowTitles(saved.facts.bundleId)
                    action.perform(appPath: app)
                    try? await Task.sleep(for: .seconds(Self.settle))
                    let ok = await verify()
                    if ok { worked = action }
                    log.append(Entry(at: Date(), bundleId: saved.facts.bundleId, title: saved.facts.title, how: "tried", action: action, ok: ok, rounds: round))
                    answer = """
                        Bean's own check, which looks for the window "\(saved.facts.title)" of this app: \(ok ? "PASSED, the content is back" : "not passed").
                        Windows of the app before: \(before)
                        After: \(Self.windowTitles(saved.facts.bundleId))
                        """
                    if let jpeg = try? await ScreenCapture.mainDisplayJPEG() { screens.append(jpeg) }
                case "keep":
                    guard let template = OpenAction(args), let worked, template.filled(handle) == worked else {
                        answer = "Not kept: keep only the template of an action that passed Bean's check, with {key} placeholders from the handle that fill back to that exact action."
                        break
                    }
                    recipes[saved.facts.bundleId] = template
                    try? JSONEncoder().encode(recipes).write(to: url, options: .atomic)
                    log.append(Entry(at: Date(), bundleId: saved.facts.bundleId, title: saved.facts.title, how: "kept", action: template, ok: true, rounds: round))
                    return true
                case "read_app":
                    answer = ContentReader.readApp(args["script"] as? String ?? "", bundleId: saved.facts.bundleId)
                default:
                    answer = ContentReader.sandboxed(args["command"] as? String ?? "")
                }
                messages.append(["role": "tool", "tool_call_id": call.id, "content": answer])
            }
            for jpeg in screens {
                messages.append(["role": "user", "content": [["type": "text", "text": "Screen after try_action:"], ModelClient.image(jpeg)]])
            }
        }
        if let worked { notes[saved.facts.bundleId, default: []].append("\(worked) reopened the content but no template was kept.") }
        return worked != nil
    }

    static func windowTitles(_ bundleId: String) -> [String] {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).map(\.processIdentifier))
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter { pids.contains($0[kCGWindowOwnerPID as String] as? pid_t ?? 0) && $0[kCGWindowLayer as String] as? Int == 0 }
            .compactMap { $0[kCGWindowName as String] as? String }.filter { !$0.isEmpty }
    }

    private struct Entry: Encodable {
        let at: Date
        let bundleId: String
        let title: String
        let how: String
        let action: OpenAction
        let ok: Bool
        let rounds: Int
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "function", "function": ["name": name, "description": description, "parameters": ["type": "object", "properties": properties, "required": required]]]
    }

    private static let actionFields: [String: Any] = [
        "kind": ["type": "string", "enum": ["url", "document", "applescript", "bundled_cli"]],
        "target": ["type": "string", "description": "url: the URL. document: the file path. applescript: a script that only tells this app. bundled_cli: the executable path inside the app bundle."],
        "args": ["type": "array", "items": ["type": "string"], "description": "bundled_cli only."],
    ]
    static let tools: [[String: Any]] = [
        ContentReader.investigation[0], ContentReader.investigation[1],
        tool("try_action", "Really perform one action that should reopen the content, then get Bean's check and a screenshot.", actionFields, required: ["kind", "target"]),
        tool("keep", "Keep the action that passed Bean's check as a template with {key} placeholders from the handle.", actionFields, required: ["kind", "target"]),
    ]
}

/// The only things a learned recipe may do: open a URL of a scheme the app declares, open an existing document with the app,
/// tell the app an AppleScript, or run an executable from inside the app's bundle. Never a shell.
struct OpenAction: Codable, Equatable, CustomStringConvertible {
    enum Kind: String, Codable { case url, document, applescript, bundled_cli }
    let kind: Kind
    let target: String
    var args: [String] = []

    init?(_ json: [String: Any]) {
        guard let kind = (json["kind"] as? String).flatMap(Kind.init), let target = json["target"] as? String, !target.isEmpty else { return nil }
        self.kind = kind
        self.target = target
        args = json["args"] as? [String] ?? []
    }

    init(kind: Kind, target: String, args: [String]) {
        self.kind = kind
        self.target = target
        self.args = args
    }

    var description: String { "\(kind.rawValue) \(target)\(args.isEmpty ? "" : " \(args)")" }

    func filled(_ handle: [String: String]) -> OpenAction? {
        func fill(_ text: String) -> String {
            handle.reduce(text) { $0.replacingOccurrences(of: "{\($1.key)}", with: kind == .url ? ($1.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $1.value) : $1.value) }
        }
        let action = OpenAction(kind: kind, target: fill(target), args: args.map(fill))
        let unfilled = ([action.target] + action.args).contains { $0.range(of: #"\{[A-Za-z_][A-Za-z0-9_]*\}"#, options: .regularExpression) != nil }
        return unfilled ? nil : action
    }

    func isAllowed(appPath: String) -> Bool {
        switch kind {
        case .url:
            let scheme = target.split(separator: ":").first.map { $0.lowercased() } ?? ""
            let types = Bundle(path: appPath)?.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
            let declared = Set(types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }.map { $0.lowercased() })
            return declared.contains(scheme) || (["http", "https"].contains(scheme) && !declared.isDisjoint(with: ["http", "https"]))
        case .document:
            return FileManager.default.fileExists(atPath: target)
        case .applescript:
            let name = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
            let bundleId = Bundle(path: appPath)?.bundleIdentifier ?? ""
            let told = target.matches(of: /tell application (?:id )?"([^"]+)"/).map { String($0.1) }
            return !told.isEmpty && told.allSatisfy { $0 == name || $0 == bundleId }
                && target.range(of: #"do shell script|System Events|\bdelete\b|\bquit\b|do script|\bclose\b"#, options: [.regularExpression, .caseInsensitive]) == nil
        case .bundled_cli:
            let resolved = URL(fileURLWithPath: target).resolvingSymlinksInPath().path
            let evaluates = args.contains { ["-e", "--eval", "--exec", "-c", "--command", "-p", "--print"].contains($0) || $0.hasPrefix("--eval=") }
            return !evaluates && resolved.hasPrefix(URL(fileURLWithPath: appPath).resolvingSymlinksInPath().path + "/") && FileManager.default.isExecutableFile(atPath: resolved)
        }
    }

    func perform(appPath: String) {
        switch kind {
        case .url: _ = HiddenShell.capture("/usr/bin/open", [target], timeout: 10)
        case .document: _ = HiddenShell.capture("/usr/bin/open", ["-a", appPath, target], timeout: 10)
        case .applescript: _ = HiddenShell.capture("/usr/bin/osascript", ["-e", target], timeout: 15)
        case .bundled_cli: _ = HiddenShell.capture(target, args, timeout: 15)
        }
    }
}
