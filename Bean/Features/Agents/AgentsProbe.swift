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
        case "guard": guardCheck(rest, store: store)
        case "work": work(rest, store: store)
        case "adopt-bean": adoptBean(store: store)
        case "standin": standIn(rest, store: store)
        case "say": say(rest, store: store)
        case "settings": settings(rest, store: store)
        case "connect": connect(rest, store: store)
        case "needs": needs(rest, store: store)
        case "app": appAbilities(rest)
        case "windows": print(WindowChannels.forModel().joined(separator: "\n")); exit(0)
        case "bean-tool": beanTool(rest, store: store)
        case "takeover": takeOver(rest, store: store)
        case "strings": Task { await AgentStrings.translateNow(AgentStrings.known, to: rest.first ?? "French"); print("translated"); exit(0) }
        case "guard-tool": guardTool(rest, store: store)
        case "connector-write": Task { await connectorWrite(rest) }
        default:
            print("usage: --probe-agents propose | create <request> | read <agent-id> <pid> [seconds] [window] | guard <agent-id> read|write|undo <command> | work <agent-id> [runs] [gap-seconds]")
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
            for file in ["agent.json", "mission.json", "lines.json", "persona.md"] {
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
            store.attach(id, to: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                print("after unplug, window.md exists: \(FileManager.default.fileExists(atPath: folder.window.path))")
                withExtendedLifetime((reader, watch)) { exit(0) }
            }
        }
    }

    private static func guardCheck(_ args: [String], store: AgentStore) {
        guard let id = args.first.flatMap(UUID.init(uuidString:)), let agent = store.agents.first(where: { $0.id == id }), let mission = AgentFolder(agent, in: store).mission, args.count > 2 else {
            print("usage: guard <agent-id> read|write|undo <command>")
            exit(64)
        }
        let mode: ActionGuard.Mode = args[1] == "read" ? .read : args[1] == "undo" ? .undo : .write
        print("\(ActionGuard(mission: mission, abilities: AgentFolder(agent, in: store).abilities).refusal(args[2...].joined(separator: " "), mode: mode) ?? "allowed")")
        exit(0)
    }

    private static func work(_ args: [String], store: AgentStore) {
        guard let id = args.first.flatMap(UUID.init(uuidString:)), let agent = store.agents.first(where: { $0.id == id }) else {
            print("usage: work <agent-id> [runs] [gap-seconds]")
            exit(64)
        }
        let runs = args.count > 1 ? Int(args[1]) ?? 1 : 1
        let gap = args.count > 2 ? UInt64(args[2]) ?? 0 : 0
        let worker = AgentWorker(store: store, autostart: false)
        Task { @MainActor in
            for number in 1...runs {
                let started = Date()
                let outcome = await worker.run(agent, trigger: "Your regular look")
                print(String(format: "--- run %d, %.1f s", number, Date().timeIntervalSince(started)))
                print("decision: \(outcome.decided.map { "\($0.help ? "work" : "quiet"): \($0.what)" } ?? "nothing changed")")
                print("calls: \(outcome.calls.joined(separator: ", "))")
                print("summary: \(outcome.summary ?? "-")\(outcome.failure.map { " failure: \($0)" } ?? "")")
                if gap > 0, number < runs { try? await Task.sleep(for: .seconds(gap)) }
            }
            let folder = AgentFolder(agent, in: store)
            print("\n--- journal.jsonl\n" + ((try? String(contentsOf: folder.journalFile, encoding: .utf8)) ?? "empty"))
            print("--- mission.json\n" + ((try? String(contentsOf: folder.missionFile, encoding: .utf8)) ?? "missing"))
            print("connectors: \(store.agents.first { $0.id == id }?.connectors ?? [])")
            withExtendedLifetime(worker) { exit(0) }
        }
    }

    private static func standIn(_ args: [String], store: AgentStore) {
        guard args.count >= 4, let id = UUID(uuidString: args[0]), let agent = store.agents.first(where: { $0.id == id }), let mission = AgentFolder(agent, in: store).mission else {
            print("usage: standin <agent-id> <repo> <clone-url> <task>")
            exit(64)
        }
        let folder = AgentFolder(agent, in: store)
        let worker = AgentWorker(store: store, autostart: false)
        let sessions = CodingSessions(folder: folder)
        Task { @MainActor in
            guard case let .success(session) = sessions.create(repo: args[1], cloneURL: args[2]) else { print("create failed"); exit(1) }
            let started = Date()
            let report = await ClaudeStandIn(agent: agent, mission: mission, folder: folder, worker: worker, session: session).drive(task: args[3...].joined(separator: " "))
            print(String(format: "--- %.1f s, %d turns, Claude $%.4f, session %@", Date().timeIntervalSince(started), report.turns, report.costUSD, report.claudeSession ?? "-"))
            print("outcome: \(report.outcome)")
            report.answers.forEach { print("answered: \($0)") }
            report.allowed.forEach { print("allowed: \($0)") }
            report.denied.forEach { print("denied: \($0)") }
            report.replies.forEach { print("replied: \($0)") }
            print("\n--- changes\n\(sessions.changes(session))")
            print("--- spent on Muse Spark by this agent today: $\(CostLedger.spentToday(agent: id.uuidString))")
            sessions.close(session)
            withExtendedLifetime(worker) { exit(0) }
        }
    }

    private static func connectorWrite(_ args: [String]) async {
        guard args.count == 2 else {
            print("usage: connector-write <server__tool> '<json arguments>'")
            exit(64)
        }
        _ = await Tools.shared.all(context: "", folder: nil)
        guard let tool = await Tools.shared.tool(named: args[0]) else {
            print("no tool \(args[0])")
            exit(1)
        }
        let arguments = (try? JSONSerialization.jsonObject(with: Data(args[1].utf8))) as? JSONArgs ?? [:]
        let output = await tool.run(arguments)
        print("ok=\(output.ok)\n\(output.text.prefix(1500))")
        exit(output.ok ? 0 : 1)
    }

    private static func say(_ args: [String], store: AgentStore) {
        guard args.count >= 2, let id = UUID(uuidString: args[0]) else {
            print("usage: say <agent-id> <text>")
            exit(64)
        }
        let worker = AgentWorker(store: store, autostart: false)
        let started = Date()
        worker.send(id, args[1...].joined(separator: " "))
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            guard !worker.replying.contains(id) else { return }
            print(String(format: "--- %.1f s", Date().timeIntervalSince(started)))
            worker.journal[id]?.suffix(14).forEach { print("\($0.kind.rawValue): \($0.did)\($0.link.map { " " + $0 } ?? "")") }
            withExtendedLifetime(worker) { exit(0) }
        }
    }

    private static func settings(_ args: [String], store: AgentStore) {
        guard let id = args.first.flatMap(UUID.init(uuidString:)), store.agents.contains(where: { $0.id == id }) else {
            print("usage: settings <agent-id> [ability-id on|off]")
            exit(64)
        }
        let worker = AgentWorker(store: store, autostart: false)
        if args.count >= 3 { worker.setAbility(id, ability: args[1...(args.count - 2)].joined(separator: " "), allowed: args.last == "on") }
        print(String(format: "spend: $%.4f today of $%.2f, all agents $%.4f today, model problem: %@", worker.spend[id]?.today ?? 0, worker.spend[id]?.budget ?? 0, worker.spentToday, worker.modelProblem ?? "none"))
        print("targets:")
        (worker.targets[id] ?? []).forEach { print("  \($0.kind.rawValue) \($0.name)\($0.link.map { " " + $0 } ?? "")") }
        print("connectors:")
        (worker.connectors[id] ?? []).forEach { print("  \($0.name) [\($0.source.rawValue), \($0.status.rawValue)] for: \($0.usedFor.joined(separator: "; "))") }
        print("abilities:")
        (worker.abilities[id] ?? []).sorted { ($0.risk.rawValue, $0.id) < ($1.risk.rawValue, $1.id) }.forEach { print("  [\($0.allowed ? "on " : "off")] \($0.risk.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) \($0.id): \($0.title)") }
        withExtendedLifetime(worker) { exit(0) }
    }

    private static func connect(_ args: [String], store: AgentStore) {
        guard args.count == 2, let id = UUID(uuidString: args[0]) else {
            print("usage: connect <agent-id> <connector-name>")
            exit(64)
        }
        let worker = AgentWorker(store: store, autostart: false)
        worker.connect(id, connector: args[1])
        var wait = 0
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            wait += 1
            guard wait > 90 || worker.journal[id]?.last?.did == "Connected \(args[1])" else { return }
            (worker.connectors[id] ?? []).forEach { print("\($0.name) [\($0.source.rawValue), \($0.status.rawValue)]") }
            print("abilities: \(worker.abilities[id]?.count ?? 0)")
            withExtendedLifetime(worker) { exit(0) }
        }
    }

    private static func guardTool(_ args: [String], store: AgentStore) {
        guard args.count == 3, let id = UUID(uuidString: args[0]), let agent = store.agents.first(where: { $0.id == id }), let mission = AgentFolder(agent, in: store).mission else {
            print("usage: guard-tool <agent-id> <server__tool> '<json>'")
            exit(64)
        }
        let ability = AgentFolder(agent, in: store).abilities.first { $0.id == args[1] }
        print(AgentWorker.connectorRefusal(ability: ability, name: args[1], arguments: args[2], mission: mission) ?? "allowed")
        exit(0)
    }

    private static func adoptBean(store: AgentStore) {
        let bean = Agent(id: Agent.beanID, name: "Bean", role: "The user's main agent.", personality: "Calm and precise.", look: .pearl, connectors: [], attachment: nil, createdAt: .distantPast)
        try? AgentFolder(bean, in: store).create(agent: bean, voice: "Plain and short.", lines: AgentLines(greeting: "", offLimits: "That is off limits."))
        store.save(bean)
        let worker = AgentWorker(store: store, autostart: false)
        print(((try? String(contentsOf: AgentFolder(bean, in: store).missionFile, encoding: .utf8)) ?? "no mission").prefix(700))
        withExtendedLifetime(worker) { exit(0) }
    }

    private static func needs(_ args: [String], store: AgentStore) {
        guard let id = args.first.flatMap(UUID.init(uuidString:)), store.agents.contains(where: { $0.id == id }) else {
            print("usage: needs <agent-id> [answer <text> | correct <text> | away <minutes>]")
            exit(64)
        }
        let worker = AgentWorker(store: store, autostart: false)
        let finish = {
            print("mood: \(store.activity[id]?.mood ?? .idle), needs: \(worker.needs[id]?.map { "\($0.kind.rawValue): \($0.question) \($0.options) rec=\($0.recommended ?? "-")" } ?? [])")
            let judgment = worker.decisions[id]?.filter { $0.kind == .judgment } ?? []
            judgment.suffix(8).forEach { print("decision [\($0.state.rawValue) \(String(format: "%.2f", $0.confidence))] \($0.question.prefix(90)) → \($0.answer.prefix(70)) | \($0.why.prefix(70))") }
            print("permissions recorded: \(worker.decisions[id]?.filter { $0.kind == .permission }.count ?? 0)")
            withExtendedLifetime(worker) { exit(0) }
        }
        if args.count > 2, args[1] == "answer", let need = worker.needs[id]?.last {
            worker.answer(id, need: need.id, args[2...].joined(separator: " "))
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                if !worker.isBusy(id), !worker.replying.contains(id), store.activity[id]?.mood != .working { finish() }
            }
        } else if args.count > 2, args[1] == "correct", let last = worker.decisions[id]?.last(where: { $0.kind == .judgment }) {
            worker.correct(id, decision: last.id, args[2...].joined(separator: " "))
            finish()
        } else if args.count > 2, args[1] == "away", let summary = worker.away(id, since: Date().addingTimeInterval(-60 * (Double(args[2]) ?? 60))) {
            print(String(format: "away: %d decided, %d permissions, %d waiting, %d done, Muse Spark $%.3f, Claude $%.3f", summary.decided.count, summary.permissionsAnswered, summary.waiting.count, summary.done.count, summary.museSparkUSD, summary.claudeUSD))
            finish()
        } else {
            finish()
        }
    }

    private static func appAbilities(_ args: [String]) {
        guard args.count >= 2 else {
            print("usage: app <bundle-id> <app-name> [script to check]")
            exit(64)
        }
        let attachment = Attachment(bundleId: args[0], appName: args[1], pid: 0, windowNumber: 0, windowTitle: nil)
        let abilities = WindowChannels.abilities(forApp: attachment, explicit: [])
        if args.count > 2 {
            print(WindowChannels.refusal(script: args[2...].joined(separator: " "), app: args[1], abilities: abilities) ?? "allowed")
        } else {
            print(abilities.isEmpty ? WindowChannels.notScriptable : abilities.sorted { ($0.risk.rawValue, $0.id) < ($1.risk.rawValue, $1.id) }.map { "[\($0.allowed ? "on " : "off")] \($0.risk.rawValue) \($0.id.components(separatedBy: ": ").last ?? $0.id)" }.joined(separator: "\n"))
        }
        exit(0)
    }

    private static func beanTool(_ args: [String], store: AgentStore) {
        guard args.count == 2, let bean = store.agents.first(where: \.isBean) else {
            print("usage: bean-tool <tool> '<json>', after adopt-bean")
            exit(64)
        }
        let worker = AgentWorker(store: store, autostart: false)
        let arguments = (try? JSONSerialization.jsonObject(with: Data(args[1].utf8))) as? JSONArgs ?? [:]
        Task { @MainActor in
            let output = await worker.beanTools(bean, folder: AgentFolder(bean, in: store)).first { $0.name == args[0] }?.run(arguments)
            print("ok=\(output?.ok ?? false) \(output?.text ?? "no such tool")")
            withExtendedLifetime(worker) { exit(0) }
        }
    }

    private static func takeOver(_ args: [String], store: AgentStore) {
        guard args.count == 3, let number = Int(args[1]), let seconds = Double(args[2]), let bean = store.agents.first(where: \.isBean) else {
            print("usage: takeover <agent-name> <window> <seconds>, after adopt-bean")
            exit(64)
        }
        let reader = WindowReader(store: store)
        let worker = reader.worker
        let folder = AgentFolder(bean, in: store)
        if var mission = folder.mission {
            mission.paused = false
            mission.every = 60
            folder.save(mission)
        }
        Task { @MainActor in
            let output = await worker.beanTools(bean, folder: folder).first { $0.name == "attach_agent" }?.run(["agent": args[0], "window": number])
            print("\(Date()): \(output?.text ?? "no tool")")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            let rows = CostLedger.lines.filter { $0.agent == bean.id.uuidString }
            print("Bean's model calls: \(rows.count), \(String(format: "$%.4f", rows.reduce(0) { $0 + $1.usd }))")
            rows.forEach { print("  call at \($0.at)") }
            withExtendedLifetime(reader) { exit(0) }
        }
    }
}
