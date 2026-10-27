import AppKit

enum ResumeProbe {
    static func runIfRequested(shellLog: URL) -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-resume") else { return false }
        let args = Array(CommandLine.arguments[(index + 1)...])
        let store = ContextStore(log: JSONLog(name: "context"), shellLog: shellLog)
        let watcher = InventoryWatcher(log: JSONLog(name: "inventory"), context: store)
        objc_setAssociatedObject(NSApp as Any, "resumeProbe", watcher, .OBJC_ASSOCIATION_RETAIN)
        Task { @MainActor in
            await run(args, watcher: watcher, store: store)
            exit(0)
        }
        return true
    }

    @MainActor
    private static func run(_ args: [String], watcher: InventoryWatcher, store: ContextStore) async {
        let started = Date()
        switch args.first {
        case "windows":
            let inventory = await withCheckedContinuation { done in watcher.build { done.resume(returning: $0) } }
            let spaces = Dictionary(uniqueKeysWithValues: WindowPlacer.spaces().map { ($0.id, $0) })
            for app in inventory.apps where app.kind == .dock {
                for window in app.windows {
                    let full = window.space.flatMap { spaces[$0] }?.fullScreen == true
                    print("\(window.id)  \(app.name) — \"\(window.title)\"  space \(window.space.map(String.init) ?? "?")\(full ? " (full screen)" : "")  \(window.width)×\(window.height)")
                    if args.contains("--facts"), let facts = WindowFacts.read(window: window, app: app, element: nil) {
                        for process in facts.processes.prefix(6) { print("      pid \(process.pid) tty \(process.tty ?? "-") cwd \(process.cwd ?? "-")  \(process.args.prefix(90))") }
                    }
                }
            }
        case "projects":
            store.start()
            try? await Task.sleep(for: .seconds(2))
            let inventory = await withCheckedContinuation { done in watcher.build { done.resume(returning: $0) } }
            let projects = ProjectWatcher(store: ResumeStore(dataDir: JSONLog(name: "shell").url.deletingLastPathComponent()), build: watcher.build) {
                store.commandList.map(\.cwd) + store.recentFileList.map { NSString(string: $0).expandingTildeInPath }
            }
            let (live, focused) = projects.group(inventory)
            for (root, windows) in live.sorted(by: { $0.key < $1.key }) {
                print("\(root)\(root == focused ? "  ← focused" : "")")
                for window in windows { print("    \(window.facts.appName) — \"\(window.facts.title)\"\(window.fullScreen ? " (full screen)" : "")") }
            }
        case "snapshot", "restore":
            guard args.count >= 2 else { return print("usage: snapshot|restore <project root>") }
            let root = args[1]
            let dataDir = JSONLog(name: "shell").url.deletingLastPathComponent()
            let resumeStore = ResumeStore(dataDir: dataDir)
            let client = ModelClient()
            let build = { await withCheckedContinuation { done in watcher.build { done.resume(returning: $0) } } }
            if args[0] == "snapshot" {
                store.start()
                try? await Task.sleep(for: .seconds(2))
                let projects = ProjectWatcher(store: resumeStore, build: watcher.build) { store.commandList.map(\.cwd) }
                let reader = ContentReader(client: client, log: JSONLog(name: "content"))
                let inventory = await build()
                let onlyApps = args.count > 2 ? Set(args[2].split(separator: ",").map(String.init)) : nil
                for app in inventory.apps where app.kind == .dock {
                    for window in app.windows where !window.title.isEmpty {
                        if let onlyApps, !onlyApps.contains(where: { filter in
                            let parts = filter.split(separator: ":", maxSplits: 1).map(String.init)
                            return parts[0] == app.name && (parts.count == 1 || window.title.contains(parts[1]))
                        }) { continue }
                        guard var facts = WindowFacts.read(window: window, app: app, element: WindowPlacer.element(for: window.id, pid: app.pid)) else { continue }
                        facts.recentFiles = WindowFacts.recentlyWritten(by: facts.appName, bundleId: facts.bundleId)
                        let content = await reader.describe(facts)
                        projects.remember(content, for: window.id, title: window.title)
                        print("described \(app.name) — \"\(window.title)\" → \(content.map { "\($0.handle)" } ?? "nothing")")
                    }
                }
                let windows = projects.group(inventory).live[root] ?? []
                print("project \(root): " + windows.map { "\($0.facts.appName) \"\($0.facts.title)\"\($0.fullScreen ? " (full screen)" : "")" }.joined(separator: ", "))
                resumeStore.update(root) { project in
                    project.windows = windows
                    project.lastActive = Date()
                    project.leftAt = Date()
                }
            } else {
                guard let project = resumeStore.projects[root] else { return print("no saved project at \(root)") }
                let resumer = Resumer(build: build, opener: ContentOpener(client: client, log: JSONLog(name: "recipes")), client: client)
                for outcome in await resumer.restore(project) {
                    print("\(outcome.app) — \"\(outcome.title)\": \(outcome.result.rawValue), placed \(outcome.placed), full screen \(outcome.fullScreen), \(outcome.seconds) s \(outcome.note ?? "")")
                }
            }
        case "describe":
            guard args.count >= 2, let id = CGWindowID(args[1]) else { return print("usage: describe <windowId>") }
            let inventory = await withCheckedContinuation { done in watcher.build { done.resume(returning: $0) } }
            guard let app = inventory.apps.first(where: { $0.windows.contains { $0.id == id } }), let window = app.windows.first(where: { $0.id == id }),
                  var facts = WindowFacts.read(window: window, app: app, element: WindowPlacer.element(for: id, pid: app.pid)) else { return print("no such window") }
            facts.recentFiles = WindowFacts.recentlyWritten(by: facts.appName, bundleId: facts.bundleId)
            let reader = ContentReader(client: ModelClient(), log: JSONLog(name: "content"))
            for pass in 1 ... (args.contains("--twice") ? 2 : 1) {
                let started = Date()
                let content = await reader.describe(facts)
                print(String(format: "pass \(pass) (%.1f s): ", Date().timeIntervalSince(started)) + (content.map { "\($0.description)\n  \($0.handle)" } ?? "nothing"))
            }
        case "readapp":
            print(ContentReader.readApp(args[2], bundleId: args[1]))
        case "find":
            guard args.count >= 3, let id = CGWindowID(args[1]), let pid = pid_t(args[2]) else { return print("usage: find <windowId> <pid>") }
            let element = WindowPlacer.element(for: id, pid: pid)
            print(element.map { "found \(WindowPlacer.frame(of: $0).map { "\($0)" } ?? "?") full screen \(WindowPlacer.isFullScreen($0))" } ?? "not found")
        case "place":
            guard args.count >= 7, let id = CGWindowID(args[1]), let pid = pid_t(args[2]), let x = Double(args[3]), let y = Double(args[4]), let w = Double(args[5]), let h = Double(args[6]),
                  let element = WindowPlacer.element(for: id, pid: pid) else { return print("usage: place <windowId> <pid> x y w h (window not found?)") }
            let ok = WindowPlacer.setFrame(element, pid: pid, to: CGRect(x: x, y: y, width: w, height: h))
            print("set \(ok) → \(WindowPlacer.frame(of: element).map { "\($0)" } ?? "?")")
        case "fullscreen":
            guard args.count >= 4, let id = CGWindowID(args[1]), let pid = pid_t(args[2]), let element = WindowPlacer.element(for: id, pid: pid) else { return print("usage: fullscreen <windowId> <pid> on|off") }
            if args[3] == "on" {
                print("full screen \(await WindowPlacer.enterFullScreen(element, window: id)) → space \(WindowPlacer.space(of: id) ?? -1)")
            } else {
                WindowPlacer.exitFullScreen(element)
                try? await Task.sleep(for: .seconds(2))
                print("left full screen → space \(WindowPlacer.space(of: id) ?? -1)")
            }
        case "close":
            guard args.count >= 3, let id = CGWindowID(args[1]), let pid = pid_t(args[2]), let element = WindowPlacer.element(for: id, pid: pid) else { return print("usage: close <windowId> <pid> (window not found?)") }
            if WindowPlacer.isFullScreen(element) {
                WindowPlacer.exitFullScreen(element)
                try? await Task.sleep(for: .seconds(2))
            }
            let button = Accessibility.attribute(kAXCloseButtonAttribute, of: element).map { $0 as! AXUIElement }
            print("closed \(button.map { AXUIElementPerformAction($0, kAXPressAction as CFString) == .success } ?? false)")
        case "move":
            guard args.count >= 3, let id = CGWindowID(args[1]), let space = Int(args[2]) else { return print("usage: move <windowId> <space>") }
            print("moved \(await WindowPlacer.move(id, toSpace: space)) → space \(WindowPlacer.space(of: id) ?? -1)")
        default:
            print("usage: --probe-resume windows [--facts] | find <id> <pid> | place <id> <pid> x y w h | fullscreen <id> <pid> on|off | move <id> <space>")
        }
        print(String(format: "--- %.2f s", Date().timeIntervalSince(started)))
    }
}
