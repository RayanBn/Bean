import AppKit
import ApplicationServices

enum AppActions {
    struct Outcome {
        let text: String
        let ok: Bool
    }

    static func runScript(_ script: String, timeout: TimeInterval = 15) async -> Outcome {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-"]
            let input = Pipe(), output = Pipe(), failure = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = failure
            guard (try? process.run()) != nil else { return Outcome(text: "Could not start the script.", ok: false) }
            try? input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
            try? input.fileHandleForWriting.close()
            let killer = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let result = output.fileHandleForReading.readDataToEndOfFile()
            let problem = failure.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()
            if process.terminationStatus == 0 {
                return Outcome(text: String(decoding: result, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), ok: true)
            }
            return Outcome(text: plain(String(decoding: problem, as: UTF8.self)), ok: false)
        }.value
    }

    static func plain(_ error: String) -> String {
        let text = error.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("-1743") { return "The user has not allowed Bean to control this app. It is in System Settings, Privacy & Security, Automation." }
        if text.contains("-600") { return "The app is not open." }
        if text.contains("-1712") { return "The app took too long to answer." }
        if text.isEmpty { return "The app did not answer in time. It may still have done it: read it back before you try again." }
        let message = text.components(separatedBy: "execution error: ").last ?? text
        return "The app refused: \(message.prefix(300))"
    }

    static func pressMenu(_ path: [String], pid: pid_t) -> Outcome {
        let wanted = path.map { $0.lowercased() }
        guard let item = AppControls.menuItems(of: pid, limit: 800).first(where: { $0.path.map { $0.lowercased() } == wanted }) else {
            return Outcome(text: "There is no menu item \(path.joined(separator: " > ")).", ok: false)
        }
        if Accessibility.attribute(kAXEnabledAttribute, of: item.element) as? Bool == false {
            return Outcome(text: "\(path.joined(separator: " > ")) is greyed out right now.", ok: false)
        }
        let status = AXUIElementPerformAction(item.element, kAXPressAction as CFString)
        return status == .success ? Outcome(text: "Chose \(path.joined(separator: " > ")).", ok: true) : Outcome(text: "The menu item did not respond (\(status.rawValue)).", ok: false)
    }

    static func open(_ url: URL, bundleId: String) async -> Outcome {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return Outcome(text: "The app is not installed.", ok: false) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
            return Outcome(text: "Opened \(url.absoluteString.prefix(200)).", ok: true)
        } catch {
            return Outcome(text: "\(error.localizedDescription)", ok: false)
        }
    }

    static func shortcuts() -> [String] {
        let result = HiddenShell.run("/usr/bin/shortcuts list", timeout: 5)
        guard result.exit == 0 else { return [] }
        return result.output.split(separator: "\n").map(String.init)
    }

    static func runShortcut(_ name: String) async -> Outcome {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", name]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            guard (try? process.run()) != nil else { return Outcome(text: "Could not start Shortcuts.", ok: false) }
            let killer = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            process.waitUntilExit()
            killer.cancel()
            return Outcome(text: text.isEmpty ? "Ran \(name)." : String(text.prefix(1000)), ok: process.terminationStatus == 0)
        }.value
    }

    static func prepare(_ bundleId: String, name: String) -> String? {
        switch AppAutomation.state(of: bundleId, ask: false) {
        case .allowed: return nil
        case .notOpen: return "\(name) is not open."
        case .refused: return "The user has turned off Bean's control of \(name). It is in System Settings, Privacy & Security, Automation."
        case .needsConsent:
            guard AppAutomation.mayAsk else { return "macOS needs the user to allow Bean to control \(name) first." }
            return AppAutomation.state(of: bundleId, ask: true) == .allowed ? nil : "The user did not allow Bean to control \(name)."
        }
    }

    static func tools(attachment: Attachment, folder: AgentFolder, explicit: [String], dryRun: Bool, blocked: @escaping () async -> String?, journal: @escaping (JournalEntry) async -> Void) -> [BrainTool] {
        var list = folder.abilities
        if !list.contains(where: { $0.id == AppGuard.shortcutAbility }) {
            list.append(AgentAbility(id: AppGuard.shortcutAbility, title: "Run the user's shortcuts", detail: "Run a shortcut from the Shortcuts app. Bean cannot see what a shortcut does.",
                                     allowed: AbilityFinder.defaultAllowed(.irreversible, id: "shortcut", explicit: explicit), risk: .irreversible, source: attachment.appName))
            folder.save(list)
        }
        let audit: [String: Any] = [
            "did": ["type": "string", "description": "What this does, in plain words, for the journal."],
            "why": ["type": "string", "description": "Why, in one sentence."],
            "undo": ["type": "string", "description": "How to undo it, in plain words, if it can be undone."],
        ]
        let offLimits = OffLimits.match("\(attachment.appName) \(attachment.bundleId) \(attachment.windowTitle ?? "")") != nil
        func action(_ args: JSONArgs, text: String, refusal: ([AgentAbility]) -> String?, run: @escaping () async -> Outcome) async -> ToolOutput {
            let did = args.string("did") ?? "Acted in \(attachment.appName)", why = args.string("why") ?? ""
            var refused = offLimits ? "this window is off limits" : OffLimits.match(text).map { "off limits: \($0)" }
            if refused == nil { refused = await blocked() }
            if refused == nil { refused = refusal(folder.abilities) }
            if let refused {
                await journal(JournalEntry(kind: .refused, did: did, why: why, result: refused))
                return ToolOutput(text: "refused: \(refused)", ok: false)
            }
            if dryRun {
                await journal(JournalEntry(kind: .action, did: "Dry run: \(did)", why: why, result: "not executed"))
                return ToolOutput(text: "done")
            }
            let outcome = await run()
            let shown = OffLimits.redact(outcome.text).text
            await journal(JournalEntry(kind: outcome.ok ? .action : .failed, did: did, why: why, result: String(shown.prefix(500)), undo: outcome.ok ? args.string("undo") : nil))
            return ToolOutput(text: shown.isEmpty ? "done" : String(shown.prefix(4000)), ok: outcome.ok)
        }
        return [
            BrainTool(name: "app_surface", description: "See how \(attachment.appName) can be driven in the background: its AppleScript commands and objects, its controls and menus, its URLs and the user's shortcuts. If it says the app cannot be driven, tell the user what you can do instead.", parameters: [:], effect: .read) { _ in
                if offLimits { return ToolOutput(text: "This window is off limits.", ok: false) }
                let surface = AppSurface.read(attachment)
                let names = shortcuts()
                return ToolOutput(text: surface.summary + (names.isEmpty ? "" : "\nShortcuts: \(names.prefix(30).joined(separator: ", "))"), ok: surface.drivable)
            },
            BrainTool(name: "app_dictionary", description: "Read one AppleScript command or object of the app in detail: its parameters, properties and what it contains.", parameters: ["term": ["type": "string", "description": "A command or object name from app_surface."]], effect: .read) { args in
                let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: attachment.bundleId)?.path
                guard let dictionary = path.flatMap(ScriptDictionary.load(appAt:)) else { return ToolOutput(text: "\(attachment.appName) has no scripting dictionary.", ok: false) }
                return ToolOutput(text: args.string("term").flatMap(dictionary.details(of:)) ?? "Not in the dictionary. \(dictionary.overview)")
            },
            BrainTool(name: "app_menu", description: "Choose a menu item of the app without opening the menu. With no path, lists the menu items.", parameters: audit.merging(["path": ["type": "string", "description": "Like \"File > New\"."]]) { $1 }, required: [], effect: .read) { args in
                guard AXIsProcessTrusted() else { return ToolOutput(text: "Bean has no Accessibility permission. It is in System Settings, Privacy & Security, Accessibility.", ok: false) }
                guard let path = args.string("path") else {
                    if offLimits { return ToolOutput(text: "This window is off limits.", ok: false) }
                    return ToolOutput(text: OffLimits.redact(AppControls.menuItems(of: attachment.pid, limit: 200).map { $0.path.joined(separator: " > ") }.joined(separator: "\n")).text)
                }
                let parts = path.components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) }
                return await action(args, text: path, refusal: { AppGuard.refusal(menu: parts, abilities: $0) }) { pressMenu(parts, pid: attachment.pid) }
            },
            BrainTool(name: "app_open", description: "Open a URL in the app, without bringing it forward. Only schemes the app handles, listed in app_surface.", parameters: audit.merging(["url": ["type": "string"]]) { $1 }, required: ["url", "did", "why"], effect: .read) { args in
                guard let text = args.string("url"), let url = URL(string: text) else { return ToolOutput(text: "not a valid URL", ok: false) }
                let schemes = AppSurface.schemes(of: attachment.bundleId)
                return await action(args, text: text, refusal: { AppGuard.refusal(url: text, schemes: schemes, app: attachment.appName, abilities: $0) }) { await open(url, bundleId: attachment.bundleId) }
            },
            BrainTool(name: "app_shortcut", description: "Run one of the user's shortcuts by name. Off unless the user allows it, because Bean cannot see what a shortcut does.", parameters: audit.merging(["name": ["type": "string"]]) { $1 }, required: ["name", "did", "why"], effect: .read) { args in
                guard let name = args.string("name") else { return ToolOutput(text: "no name", ok: false) }
                return await action(args, text: name, refusal: { abilities in
                    abilities.first { $0.id == AppGuard.shortcutAbility }?.allowed == true ? nil : "Running the user's shortcuts is turned off for this agent"
                }) { await runShortcut(name) }
            },
        ]
    }
}
