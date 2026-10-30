import AppKit

enum ActionsProbe {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--probe-app-actions"), args.indices.contains(index + 1) else { return false }
        guard ProcessInfo.processInfo.environment["BEAN_DATA_DIR"] != nil else {
            print("refusing: set BEAN_DATA_DIR")
            exit(2)
        }
        let rest = Array(args[(index + 2)...])
        Task { @MainActor in
            await run(args[index + 1], rest)
            exit(0)
        }
        return true
    }

    private static func attachment(_ target: String) -> Attachment {
        let bundleId = target.hasPrefix("pid:") ? "" : target
        let app = target.hasPrefix("pid:") ? NSRunningApplication(processIdentifier: pid_t(target.dropFirst(4)) ?? 0)
            : NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
        let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        let name = app?.localizedName ?? path?.deletingPathExtension().lastPathComponent ?? target
        let window = app.flatMap { app in
            ((CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? [])
                .first { ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }
        }
        return Attachment(bundleId: bundleId, appName: name, pid: app?.processIdentifier ?? 0,
                          windowNumber: window?[kCGWindowNumber as String] as? Int ?? 0, windowTitle: window?[kCGWindowName as String] as? String)
    }

    private static func abilities(_ target: Attachment, on: [String]) -> [AgentAbility] {
        WindowChannels.abilities(forApp: target, explicit: on) + [
            AgentAbility(id: AppGuard.riskyAbility, title: "Press risky buttons", detail: "", allowed: on.contains("risky"), risk: .irreversible, source: target.appName),
        ]
    }

    private static func run(_ command: String, _ rest: [String]) async {
        switch command {
        case "surface":
            let surface = AppSurface.read(attachment(rest[0]))
            print(surface.summary)
            print("drivable: \(surface.drivable)")
            print("off by default: \(WindowChannels.abilities(forApp: attachment(rest[0]), explicit: []).filter { !$0.allowed }.map(\.title).joined(separator: ", "))")
        case "permission":
            for bundle in rest { print("\(bundle): \(AppAutomation.state(of: bundle, ask: false).rawValue)") }
        case "script-guard":
            let target = attachment(rest[0])
            let on = rest.count > 2 ? rest[2].split(separator: ",").map(String.init) : []
            print(WindowChannels.refusal(script: rest[1], app: target.appName, abilities: abilities(target, on: on)).map { "REFUSED: \($0)" } ?? "ALLOWED")
        case "script":
            let target = attachment(rest[0])
            if let refused = WindowChannels.refusal(script: rest[1], app: target.appName, abilities: abilities(target, on: [])) { print("REFUSED: \(refused)"); return }
            if let problem = AppActions.prepare(rest[0], name: target.appName) { print("not run: \(problem)"); return }
            let outcome = await AppActions.runScript(rest[1])
            print("\(outcome.ok ? "ok" : "failed"): \(outcome.text)")
        case "controls":
            let target = attachment(rest[0])
            print("trusted: \(AXIsProcessTrusted()) window: \(target.windowNumber)")
            print(WindowControls().list(target))
        case "menus":
            AppControls.menuItems(of: attachment(rest[0]).pid, limit: 40).forEach { print($0.path.joined(separator: " > ")) }
        case "control":
            let target = attachment(rest[0]), kind = rest[1], label = rest[2], value = rest.count > 3 ? rest[3] : nil
            let controls = WindowControls()
            _ = controls.list(target)
            guard let index = controls.controls.firstIndex(where: { AppControls.describe($0.element).label == label }) else { print("no control \(label)"); return }
            let control = AppControls.describe(controls.controls[index].element)
            if let refused = AppGuard.refusal(control: control, action: kind) ?? (kind == "press" ? AppGuard.risky(label, abilities(target, on: [])) : nil) { print("REFUSED: \(refused)"); return }
            let failure = kind == "set" ? controls.setValue(index, value ?? "") : controls.press(index)
            print(failure.map { "failed: \($0)" } ?? "ok: \(kind) \(label)")
        case "shortcuts":
            print(AppActions.shortcuts().prefix(5).joined(separator: "\n"))
        default:
            print("usage: --probe-app-actions surface <bundle> | permission <bundle>... | script-guard <bundle> <script> [on] | script <bundle> <script> | controls <bundle> | menus <bundle> | control <bundle> press|set <label> [value] | shortcuts")
        }
    }
}
