import AppKit

enum AgentsProbe {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--probe-agents"), args.indices.contains(index + 1) else { return false }
        let rest = Array(args[(index + 2)...])
        let store = AgentStore()
        Tools.shared.add(Connectors())
        print("data: \(store.root.path)")
        switch args[index + 1] {
        case "propose": Task { await propose() }
        case "create": Task { await create(rest.joined(separator: " "), store: store) }
        case "read": read(rest, store: store)
        case "approve", "decline": decide(args[index + 1], rest, store: store)
        default:
            print("usage: --probe-agents propose | create <request> | read <agent-id> <pid> [seconds] [window] | approve <agent-id> | decline <agent-id>")
            exit(64)
        }
        return true
    }

    private static func propose() async {
        let inventory = MacInventory.scan()
        print("--- inventory sent to Muse Spark\n\(inventory.summary)")
        do {
            let started = Date()
            let proposals = try await AgentMaker().propose(from: inventory)
            print(String(format: "\n--- %d proposals from %@ in %.1f s", proposals.count, ModelClient().label, Date().timeIntervalSince(started)))
            proposals.forEach { print("\($0.name) [\($0.label)]: \($0.role)\n  pitch: \($0.pitch)") }
            exit(0)
        } catch {
            print("propose failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func create(_ request: String, store: AgentStore) async {
        do {
            let started = Date()
            let created = try await AgentMaker().write(request)
            try AgentMaker.save(created, in: store)
            print(String(format: "--- created by %@ in %.1f s", ModelClient().label, Date().timeIntervalSince(started)))
            let folder = AgentFolder(created.agent, in: store)
            let files = FileManager.default.enumerator(atPath: folder.url.path)?.allObjects as? [String] ?? []
            print("folder: \(folder.url.path)\n  \(files.sorted().joined(separator: "\n  "))")
            for file in ["agent.json", "lines.json", "persona.md"] {
                print("\n--- \(file)\n" + ((try? String(contentsOf: folder.url.appendingPathComponent(file), encoding: .utf8)) ?? "missing"))
            }
            print("\nagent id: \(created.agent.id.uuidString)")
            exit(0)
        } catch {
            print("create failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func read(_ args: [String], store: AgentStore) {
        guard args.count >= 2, let id = UUID(uuidString: args[0]), let pid = Int32(args[1]),
              let agent = store.agents.first(where: { $0.id == id }) else {
            print("usage: read <agent-id> <pid> [seconds], with an agent saved in this data dir")
            exit(64)
        }
        let seconds = args.count > 2 ? Double(args[2]) ?? 40 : 40
        let wanted = args.count > 3 ? Int(args[3]) : nil
        func area(_ window: [String: Any]) -> Double {
            (window[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }.map { $0.width * $0.height } ?? 0
        }
        let windows = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .filter { wanted == nil || ($0[kCGWindowNumber as String] as? Int) == wanted }
            .sorted { area($0) > area($1) }
        guard let window = windows.first, let number = window[kCGWindowNumber as String] as? Int,
              let app = NSRunningApplication(processIdentifier: pid) else {
            print("no window for pid \(pid)")
            exit(1)
        }
        print("AX trusted: \(AXIsProcessTrusted())")
        let reader = WindowReader(store: store)
        var last: AgentActivity?
        let watch = store.$activity.sink { activity in
            guard let now = activity[id], now != last else { return }
            last = now
            print("activity: mood=\(now.mood) bubble=\(now.bubble ?? "-")")
        }
        store.attach(id, to: Attachment(bundleId: app.bundleIdentifier ?? "", appName: app.localizedName ?? "", pid: pid,
                                        windowNumber: number, windowTitle: window[kCGWindowName as String] as? String))
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            let folder = AgentFolder(agent, in: store)
            print("\n--- \(folder.window.lastPathComponent)\n" + ((try? String(contentsOf: folder.window, encoding: .utf8)) ?? "missing"))
            print("\n--- pending draft\n" + (reader.help.pending[id].map(describe) ?? "none"))
            print("connectors: \(store.agents.first { $0.id == id }?.connectors ?? [])")
            if reader.help.pending[id] != nil {
                print("left plugged so approve or decline can run")
                withExtendedLifetime((reader, watch)) { exit(0) }
            }
            store.attach(id, to: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                print("after unplug, window.md exists: \(FileManager.default.fileExists(atPath: folder.window.path))")
                withExtendedLifetime((reader, watch)) { exit(0) }
            }
        }
    }

    private static func decide(_ verb: String, _ args: [String], store: AgentStore) {
        guard let id = args.first.flatMap(UUID.init(uuidString:)) else {
            print("usage: \(verb) <agent-id>")
            exit(64)
        }
        let help = AgentHelp(store: store)
        guard let draft = help.pending[id] else {
            print("no pending draft for \(id)")
            exit(1)
        }
        print("--- \(verb)\n" + describe(draft))
        if verb == "decline" {
            help.decline(id)
            print("activity: \(store.activity[id]?.bubble ?? "-")")
            exit(0)
        }
        help.approve(id)
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            guard !help.running.contains(id), help.pending[id] == nil else { return }
            print("activity: mood=\(store.activity[id]?.mood ?? .idle) bubble=\(store.activity[id]?.bubble ?? "-")")
            withExtendedLifetime(help) { exit(0) }
        }
    }

    private static func describe(_ draft: AgentDraft) -> String {
        let action = draft.action
        return """
        title: \(draft.title)
        why: \(draft.why)
        action: \(action.kind.rawValue) "\(action.label)" → \(action.target ?? "-")
        \([action.command.map { "command: \($0)" }, action.tool.map { "tool: \($0) \(action.arguments ?? "")" }, action.url.map { "url: \($0)" }].compactMap { $0 }.joined(separator: "\n"))
        body:
        \(draft.body)
        """
    }
}
