import AppKit

@MainActor
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
        case "prompts": PromptProbe.prompts(rest, store: store)
        case "refusals": PromptProbe.refusals(rest, store: store)
        case "defects": PromptProbe.defects(store: store)
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
        case "understand": understand(rest, store: store)
        case "decide": decide(rest, store: store)
        case "events": events(rest, store: store)
        case "inform":
            guard rest.count == 2 else { print("usage: inform <source> <text>"); exit(64) }
            let worker = AgentWorker(store: store, autostart: false)
            Task { @MainActor in
                var shown = ""
                let reply = ProcessInfo.processInfo.environment["BEAN_TEST_ANSWER"]
                let watch = Task { @MainActor in
                    while !Task.isCancelled {
                        worker.refresh()
                        let now = worker.plan.map { "\($0.id) \($0.state.rawValue) \($0.owner)\($0.session.map { " session \($0)" } ?? "")\($0.waitingFor.map { " waiting: \($0.prefix(70))" } ?? "")\(($0.missing ?? "").isEmpty ? "" : " missing: \(($0.missing ?? "").prefix(60))")" }.joined(separator: " | ")
                        if now != shown {
                            shown = now
                            print("plan \(Date().formatted(date: .omitted, time: .standard)): \(now)")
                            fflush(stdout)
                        }
                        if let reply, let step = worker.plan.first(where: { $0.state == .blocked }), let agent = store.agents.first(where: { $0.id == step.agent }), let need = AgentFolder(agent, in: store).needs.first(where: { $0.question == step.waitingFor }), !worker.isBusy(agent.id) {
                            try? await Task.sleep(for: .seconds(4))
                            worker.answer(agent.id, need: need.id, reply)
                        }
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                }
                let answer = await worker.inform(source: rest[0], text: rest[1])
                print("answer: \(answer ?? "none")")
                try? await Task.sleep(for: .seconds(2))
                while worker.sessionsStillMoving { try? await Task.sleep(for: .seconds(2)) }
                watch.cancel()
                worker.refresh()
                print("final plan: \(worker.plan.map { "\($0.id) \($0.state.rawValue) \($0.owner)" })")
                withExtendedLifetime(worker) { exit(0) }
            }
        case "call-recap":
            guard rest.count == 3, let agent = store.agents.first(where: { $0.name == rest[0] }) else { print("usage: call-recap <agent-name> <app> <transcript>"); exit(64) }
            let worker = AgentWorker(store: store, autostart: false)
            Task { @MainActor in
                await worker.callEnded(agent, app: rest[1], startedAt: Date().addingTimeInterval(-600), endedAt: Date(), transcript: rest[2])
                withExtendedLifetime(worker) { exit(0) }
            }
        case "sees":
            let sees = WhatBeanSeesReader.read(store.agents)
            print("apps \(sees.apps.count), windows \(sees.windows.count), hidden \(sees.hidden), tabs \(sees.tabs.count), focused \(sees.focused.map { "\($0.text.count) chars" } ?? "none"), commands \(sees.commands.count)")
            sees.commands.forEach { print("command: \($0.command) | exit \($0.exit)") }
            sees.windows.forEach { print("window: \($0.number) \($0.app) \($0.title ?? "") agent \($0.agent?.uuidString ?? "none")") }
            exit(0)
        case "tab-scripts":
            let bundle = rest.count > 1 ? rest[1] : "company.thebrowser.Browser"
            print(AppTabs.listScript(app: rest[0], bundleId: bundle)); print("=====")
            print(AppTabs.identityScript(app: rest[0], bundleId: bundle, window: 1, tab: 1)); print("=====")
            print(AppTabs.readScript(app: rest[0], bundleId: bundle, window: 1, tab: 1))
            exit(0)
        case "window-tool": Task { await windowTool(rest, store: store) }
        case "stop-resume":
            guard rest.count == 2, let agent = store.agents.first(where: { $0.name == rest[0] }) else { print("usage: stop-resume <agent-name> <session_drive json>"); exit(64) }
            Task { @MainActor in
                let worker = AgentWorker(store: store, autostart: false)
                let folder = AgentFolder(agent, in: store)
                await CodeRepos.refresh()
                let tools = folder.mission.map { worker.sessionTools(agent, $0, folder) } ?? []
                let args = (try? JSONSerialization.jsonObject(with: Data(rest[1].utf8))) as? JSONArgs ?? [:]
                print("start: \(await tools.first { $0.name == "session_drive" }?.run(args).text ?? "no tool")")
                let sessions = CodingSessions(folder: folder)
                while sessions.all.last?.step == nil || sessions.all.last?.step == "Starting" { try? await Task.sleep(for: .milliseconds(200)) }
                guard let id = sessions.all.last?.id else { exit(1) }
                print("working: \(sessions.session(id)?.step ?? "")")
                worker.stopSession(agent.id, session: id)
                while worker.sessionsStillMoving { try? await Task.sleep(for: .milliseconds(200)) }
                let stopped = sessions.session(id)
                print("stopped: \(stopped?.status?.rawValue ?? "") \(stopped?.step ?? "") resume \(stopped?.claudeSession ?? "")")
                worker.resumeSession(agent.id, session: id)
                while worker.sessionsStillMoving { try? await Task.sleep(for: .milliseconds(200)) }
                let ended = sessions.session(id)
                print("ended: \(ended?.status?.rawValue ?? "") \(ended?.step ?? "") resume \(ended?.claudeSession ?? "") branch \(ended?.branch ?? "") pr \(ended?.pullRequest ?? "none")")
                withExtendedLifetime(worker) { exit(0) }
            }
        case "session-script": sessionScript(rest, store: store)
        case "plan-test":
            guard rest.count == 1, let agent = store.agents.first(where: { $0.name == rest[0] }), let bean = store.agents.first(where: \.isBean) else { print("usage: plan-test <agent-name>, after adopt-bean"); exit(64) }
            Task { @MainActor in
                let worker = AgentWorker(store: store, autostart: false)
                @MainActor func say(_ when: String, _ one: AgentWorker) {
                    one.refresh()
                    print("\(when): \(one.plan.map { "\($0.id) \($0.state.rawValue) \($0.owner) agent=\($0.agent != nil)" }) current=\(one.agentSteps.count)")
                }
                worker.startPlan([BeanUnderstanding.Step(what: "Say ok", who: "new agent", why: "test"), BeanUnderstanding.Step(what: "Say hello", who: "new agent", why: "test"), BeanUnderstanding.Step(what: "Note it in the tracker", who: "Bean", why: "test")], from: "test")
                say("planned", worker)
                let hand = worker.beanTools(bean, folder: AgentFolder(bean, in: store)).first { $0.name == "hand_off" }
                let output = await hand?.run(["agent": agent.name, "task": "Finish now with the single word ok.", "plan_step": 2, "why": "test"])
                print("hand_off: \(output?.text.prefix(160) ?? "")")
                say("handed off", worker)
                let relaunched = AgentWorker(store: store, autostart: false)
                say("after relaunch", relaunched)
                withExtendedLifetime((worker, relaunched)) { exit(0) }
            }
        case "judge-done":
            guard rest.count == 3 else { print("usage: judge-done <task> <claim> <facts>"); exit(64) }
            Task {
                let verdict = await DoneCheck.judge(task: rest[0], claim: rest[1], facts: rest[2], measured: true)
                print("verdict: \(verdict.state.rawValue) by \(verdict.by) \(verdict.confidence) \(verdict.missing)")
                exit(0)
            }
        case "open-terminal":
            guard rest.count == 2, let agent = store.agents.first(where: { $0.name == rest[0] }) else { print("usage: open-terminal <agent-name> <session>"); exit(64) }
            Task { @MainActor in
                let worker = AgentWorker(store: store, autostart: false)
                print("open-terminal: \(worker.openInTerminal(agent.id, session: rest[1]) ?? "opened")")
                withExtendedLifetime(worker) { exit(0) }
            }
        case "decide-eval": Task { await decideEval(rest, store: store) }
        case "hear": hear(rest, store: store)
        case "senses": Task { await sensesProbe(rest, store: store) }
        case "call-watch": callWatch(rest)
        case "call-name":
            if #available(macOS 14.2, *) { print(CallWatcher.appName(pid: pid_t(rest[0]) ?? 0, bundle: rest.count > 1 ? rest[1] : nil) ?? "unknown") }
            exit(0)
        case "strands-eval": Task { await strandsEval(rest) }
        case "strands-up": Task { await strandsUp(rest) }
        case "takeover": takeOver(rest, store: store)
        case "strings": Task { await AgentStrings.translateNow(AgentStrings.known, to: rest.first ?? "French"); print("translated"); exit(0) }
        case "guard-tool": guardTool(rest, store: store)
        case "connector-write": Task { await connectorWrite(rest) }
        case "scenario":
            if #available(macOS 14.2, *) { ScenarioProbe.run(rest, store: store) }
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
            let created = try await AgentMaker().write(request, avoiding: store.agents.map(\.name))
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
        if args[1] == "session" {
            let check = ActionGuard(mission: mission, worktree: AgentFolder(agent, in: store).url, abilities: AgentFolder(agent, in: store).abilities, unknownAllowed: true)
            let command = args[2...].joined(separator: " ")
            print(check.inWorkingCopy(command) ?? check.refusal(command, mode: .write) ?? "allowed")
            exit(0)
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
        var pausedAt: Date?
        if let delay = ProcessInfo.processInfo.environment["BEAN_PAUSE_AFTER"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                pausedAt = Date()
                BeanSettings.shared.paused = true
                print("paused at \(pausedAt!), model calls so far: \(CostLedger.lines.count)")
            }
        }
        let resumeAfter = ProcessInfo.processInfo.environment["BEAN_RESUME_AFTER"].flatMap(Double.init)
        var resumed = resumeAfter == nil
        if let resumeAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + resumeAfter) {
                BeanSettings.shared.paused = false
                print("resumed, model calls so far: \(CostLedger.lines.count)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { resumed = true }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            guard !worker.replying.contains(id), resumed else { return }
            print(String(format: "--- %.1f s", Date().timeIntervalSince(started)))
            if let pausedAt { print("model calls started after the pause: \(CostLedger.lines.filter { $0.at > pausedAt.addingTimeInterval(3) }.count)") }
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
        if args.count > 3, args[1] == "permission", let agent = store.agents.first(where: { $0.id == id }), let attachment = agent.attachment {
            worker.askPermission(agent, attachment: Attachment(bundleId: args[2], appName: args[3], pid: attachment.pid, windowNumber: attachment.windowNumber, windowTitle: attachment.windowTitle), problem: "macOS needs the user to allow Bean to control \(args[3]) first.", task: "Fill in the total row")
            finish()
        } else if args.count > 2, args[1] == "raise", let agent = store.agents.first(where: { $0.id == id }) {
            worker.raise(AgentNeed(kind: .decision, question: args[2...].joined(separator: " ")), agent: agent)
            finish()
        } else if args.count > 2, args[1] == "answer", let need = worker.needs[id]?.first {
            worker.answer(id, need: need.id, args[2...].joined(separator: " "))
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                if !worker.isBusy(id), !worker.replying.contains(id), store.activity[id]?.mood != .working { finish() }
            }
        } else if args.count > 2, args[1] == "correct", let last = worker.decisions[id]?.last(where: { $0.kind == .judgment }) {
            worker.correct(id, decision: last.id, args[2...].joined(separator: " "))
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                if !worker.isBusy(id), !worker.replying.contains(id) { finish() }
            }
        } else if args.count > 1, args[1] == "undo", let last = worker.journal[id]?.last(where: { $0.undoCommand != nil || $0.undoText != nil }) {
            print("undoing: \(last.did), \(last.undoCommand ?? "put back the earlier text")")
            worker.undo(id, entry: last.id)
            Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
                worker.journal[id]?.suffix(1).forEach { print("\($0.kind.rawValue): \($0.did) \($0.result ?? "")") }
                finish()
            }
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

    private static func understand(_ args: [String], store: AgentStore) {
        guard args.count == 2, let bean = store.agents.first(where: \.isBean) else {
            print("usage: understand <source> <text>, after adopt-bean")
            exit(64)
        }
        let worker = AgentWorker(store: store, autostart: false)
        Task { @MainActor in
            let understood = await worker.understand(args[1], source: args[0], bean: bean, folder: AgentFolder(bean, in: store))
            print(understood?.plan ?? "nothing understood")
            withExtendedLifetime(worker) { exit(0) }
        }
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

    private static func hear(_ args: [String], store: AgentStore) {
        guard #available(macOS 14.2, *), args.count >= 2, let id = UUID(uuidString: args[0]), let agent = store.agents.first(where: { $0.id == id }), let pid = agent.attachment?.pid, let seconds = Double(args[1]) else {
            print("usage: hear <agent-id> <seconds>, with BEAN_MIC_FILE and BEAN_THEM_FILE")
            exit(64)
        }
        let worker = AgentWorker(store: store, autostart: false)
        let listening = CallListening(store: store, worker: worker)
        listening.simulate(pid: pid, app: agent.attachment?.appName ?? "test", seconds: seconds)
        let answer = args.count > 2 ? args[2] : "yes"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if args.count > 3, args[3] == "late" {
                print("asked before the request: \(AgentFolder(agent, in: store).needs.contains { $0.consent != nil })")
                AgentFolder(agent, in: store).requestCalls(why: "late")
                worker.onSenseRequested?()
            }
            if let need = AgentFolder(agent, in: store).needs.first(where: { $0.consent != nil }) {
                print("asked: \(need.question) | \(need.detail ?? "")")
                worker.answer(id, need: need.id, need.options[["yes": 0, "no": 1, "always": 2][answer] ?? 1])
            }
            try? await Task.sleep(for: .seconds(seconds + (answer == "no" ? 2 : 60)))
            for who in store.agents {
                print("--- \(who.name)")
                worker.journal[who.id]?.suffix(8).forEach { print("\($0.kind.rawValue): \($0.did.prefix(500))") }
            }
            print("listening now: \(worker.listening.count)")
            withExtendedLifetime((worker, listening)) { exit(0) }
        }
    }

    private final class FakeRead: ToolSource {
        func tools(context: String, folder: String?) async -> [BrainTool] { [] }
        func tool(named name: String) async -> BrainTool? {
            guard name == "fake__read", let file = ProcessInfo.processInfo.environment["BEAN_SENSE_FAKE_FILE"] else { return nil }
            return BrainTool(name: name, description: "", parameters: [:], effect: .read) { _ in ToolOutput(text: (try? String(contentsOfFile: file, encoding: .utf8)) ?? "") }
        }
    }

    private static func sensesProbe(_ args: [String], store: AgentStore) async {
        guard args.count >= 2, let agent = store.agents.first(where: { $0.id.uuidString == args[0] }) else {
            print("usage: senses <agent-id> list | request <id> <why> [tool] | allow | refuse | off <id> | on <id> | drop <id> | ask <text> | show")
            exit(64)
        }
        Tools.shared.add(FakeRead())
        let worker = AgentWorker(store: store, autostart: false)
        let folder = AgentFolder(agent, in: store)
        let tools = worker.senseTools(agent, folder: folder)
        func call(_ name: String, _ input: JSONArgs) async { if let output = await tools.first(where: { $0.name == name })?.run(input) { print("\(name): \(output.text)") } }
        switch args[1] {
        case "list": await call("list_senses", [:])
        case "request": await call("request_sense", ["id": args[2], "why": args[3], "params": args.count > 4 ? ["tool": args[4]] : [String: String]()])
        case "allow", "refuse":
            guard let need = folder.needs.first(where: { $0.consent != nil }) else { print("no card"); break }
            print("card: \(need.question) | \(need.detail ?? "")")
            worker.answer(agent.id, need: need.id, args[1] == "allow" ? need.options[0] : need.options[1])
        case "ask":
            let outcome = await worker.run(agent, trigger: args[2], fromUser: true)
            print("calls: \(outcome.calls.joined(separator: ", "))\nsummary: \(outcome.summary ?? "-")\(outcome.failure.map { " failure: \($0)" } ?? "")")
            print("cards: \(folder.needs.map(\.question))")
        case "off", "on": worker.setSense(agent, id: args[2], on: args[1] == "on")
        case "drop": await call("drop_sense", ["id": args[2]])
        default: break
        }
        print(worker.sensesLine(agent, folder: folder))
        exit(0)
    }

    private static func callWatch(_ args: [String]) {
        guard #available(macOS 14.2, *) else { exit(1) }
        let watcher = CallWatcher()
        watcher.onStart = { print("start \($0.app ?? "?") pid \($0.pid) chain \(CallWatcher.parents(of: $0.pid))") }
        watcher.onEnd = { print("end \($0.app ?? "?")") }
        watcher.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + (args.first.flatMap(Double.init) ?? 20)) { withExtendedLifetime(watcher) { exit(0) } }
    }

    private static func strandsEval(_ args: [String]) async {
        struct Case: Decodable { let id, label: Int; let cat, mission, trigger, seen, journal: String }
        guard let path = args.first, let data = FileManager.default.contents(atPath: path), let cases = try? JSONDecoder().decode([Case].self, from: data) else {
            print("usage: strands-eval <cases.json>")
            exit(64)
        }
        print("decider: \(AgentWorker.decider)")
        let cold = Date()
        guard await StrandsServer.shared.ready() != nil else { print("Strands is not ready"); exit(1) }
        print(String(format: "ready in %.1f s", Date().timeIntervalSince(cold)))
        var quiet = 0, missed = 0, passedOn = 0
        var times: [TimeInterval] = []
        for item in cases {
            let started = Date()
            guard let score = await StrandsDecider.score(state: StrandsDecider.state(mission: item.mission, goals: nil, trigger: item.trigger, seen: item.seen, journal: item.journal.isEmpty ? [] : [item.journal])) else { print("no score for \(item.id)"); exit(1) }
            times.append(Date().timeIntervalSince(started))
            let silenced = score <= StrandsDecider.quietAtOrBelow
            if silenced { quiet += 1 } else if item.label == 0 { passedOn += 1 }
            if silenced, item.label == 1 { missed += 1; print("MISSED \(item.id) \(item.cat) \(score)") }
        }
        let sorted = times.sorted()
        print(String(format: "cases %d: quiet with no Muse Spark call %d, work missed %d, quiet but passed on %d, median %.0f ms, slowest %.0f ms", cases.count, quiet, missed, passedOn, sorted[sorted.count / 2] * 1000, (sorted.last ?? 0) * 1000))
        print("server pid: see pgrep; quitting stops it")
        await StrandsServer.shared.stop()
        exit(0)
    }

    private static func strandsUp(_ args: [String]) async {
        print("decider: \(AgentWorker.decider)")
        let score = await StrandsDecider.score(state: "Mission: test\nWhat happened: nothing\nWhat is there now:\nnothing\nJournal: empty")
        print("score: \(score.map { String($0) } ?? "none")")
        try? await Task.sleep(for: .seconds(args.first.flatMap(Double.init) ?? 60))
        await StrandsServer.shared.stop()
        exit(0)
    }

    private static func decideEval(_ args: [String], store: AgentStore) async {
        struct Case: Decodable { let expected: Bool; let note, mission, goals, trigger, observation: String; let journal: [String] }
        guard let bean = store.agents.first(where: \.isBean), let path = args.first,
              let cases = try? String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map({ try JSONDecoder().decode(Case.self, from: Data($0.utf8)) }) else {
            print("usage: decide-eval <cases.jsonl>, after adopt-bean")
            exit(64)
        }
        let serverStart = Date()
        guard await StrandsServer.shared.ready() != nil else { print("Strands is not ready"); exit(1) }
        print(String(format: "ready in %.1f s", Date().timeIntervalSince(serverStart)))
        var withLocal = 0, museRight = 0, quieted = 0, missed = 0, needless = 0
        var times: [TimeInterval] = []
        let museSpent = CostLedger.lines.reduce(0) { $0 + $1.usd }
        for item in cases {
            let situation = HelpSituation(agent: bean, persona: "", mission: AgentMission(mission: item.mission), trigger: item.trigger, observation: item.observation, journal: item.journal, goals: item.goals)
            let started = Date()
            let score = await StrandsDecider.score(situation) ?? 1
            times.append(Date().timeIntervalSince(started))
            let muse = (try? await MuseSparkDecider().decide(situation))?.help
            let quiet = score <= StrandsDecider.quietAtOrBelow
            if quiet { quieted += 1 }
            let final = quiet ? false : muse ?? false
            if final == item.expected { withLocal += 1 } else if item.expected { missed += 1 } else { needless += 1 }
            if muse == item.expected { museRight += 1 }
            print(String(format: "%@ local %.2f%@ muse %@ | %@", item.expected ? "ACT  " : "QUIET", score, quiet ? " quiet" : "      ", muse.map { $0 ? "act  " : "quiet" } ?? "fail ", item.note))
        }
        let sorted = times.sorted()
        print("cases \(cases.count): with local \(withLocal) (missed \(missed), needless \(needless)), Muse Spark alone \(museRight)")
        print("no Muse Spark call for \(quieted) of \(cases.count)")
        print(String(format: "latency median %.3f s, slowest %.3f s", sorted[sorted.count / 2], sorted.last ?? 0))
        print(String(format: "Muse Spark for all cases: $%.4f", CostLedger.lines.reduce(0) { $0 + $1.usd } - museSpent))
        exit(0)
    }

    private static func windowTool(_ args: [String], store: AgentStore) async {
        guard args.count >= 2, let agent = store.agents.first(where: { $0.name == args[0] }) else {
            print("usage: window-tool <agent-name> <tool> [json] [<tool> [json]]...")
            exit(64)
        }
        let worker = AgentWorker(store: store, autostart: false)
        let folder = AgentFolder(agent, in: store)
        await CodeRepos.refresh()
        let tools = (agent.attachment.map { worker.windowTools(agent, attachment: $0, folder: folder) } ?? []) + (folder.mission.map { worker.sessionTools(agent, $0, folder) } ?? [])
        await CodeRepos.refresh()
        var rest = args.dropFirst()
        worker.refresh()
        while let name = rest.popFirst() {
            let json = rest.first.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? JSONArgs }
            if json != nil { rest.removeFirst() }
            let output = await tools.first { $0.name == name }?.run(json ?? [:])
            print("\(name): ok=\(output?.ok ?? false) \(output?.text ?? "no such tool")")
        }
        while worker.sessionsStillMoving { try? await Task.sleep(for: .seconds(1)) }
        worker.refresh()
        print("sessions: \(worker.sessions[agent.id] ?? [])")
        withExtendedLifetime(worker) { exit(0) }
    }

    // steps: drive <json> | until-step | send <text> | until <status> | quiet | budget <usd> | show | changes | take-over | end-take-over | answer <text>
    private static func sessionScript(_ args: [String], store: AgentStore) {
        guard args.count >= 2, let agent = store.agents.first(where: { $0.name == args[0] }) else { print("usage: session-script <agent-name> <step>..."); exit(64) }
        Task { @MainActor in
            let worker = AgentWorker(store: store, autostart: false)
            let folder = AgentFolder(agent, in: store)
            await CodeRepos.refresh()
            let sessions = CodingSessions(folder: folder)
            var steps = args.dropFirst()
            func say(_ text: String) { print("[\(Date().formatted(date: .omitted, time: .standard))] \(text)") }
            func current() -> CodingSession? { sessions.all.last }
            while let step = steps.popFirst() {
                switch step {
                case "drive":
                    let json = (try? JSONSerialization.jsonObject(with: Data((steps.popFirst() ?? "").utf8))) as? JSONArgs ?? [:]
                    let tools = folder.mission.map { worker.sessionTools(agent, $0, folder) } ?? []
                    let output = await tools.first { $0.name == "session_drive" }?.run(json)
                    say("drive: \(output?.ok ?? false) \(output?.text.prefix(120) ?? "")")
                case "until-step":
                    while current()?.step == nil || current()?.step == "Starting" { try? await Task.sleep(for: .milliseconds(100)) }
                    say("step: \(current()?.step ?? "")")
                case "send":
                    let text = steps.popFirst() ?? ""
                    say("send: \(worker.sendToSession(agent.id, session: current()?.id ?? "", text: text) ?? "accepted")")
                case "answer":
                    let text = steps.popFirst() ?? ""
                    guard let need = folder.needs.first(where: { $0.session == current()?.id }) else { say("no question open"); continue }
                    say("question: \(need.question)")
                    worker.answer(agent.id, need: need.id, text)
                    try? await Task.sleep(for: .seconds(1))
                case "until":
                    let wanted = steps.popFirst() ?? ""
                    while current()?.status?.rawValue != wanted { try? await Task.sleep(for: .milliseconds(100)) }
                    say("status: \(wanted), step \(current()?.step ?? "")")
                case "quiet":
                    while worker.sessionsStillMoving { try? await Task.sleep(for: .milliseconds(200)) }
                    say("quiet: \(current()?.status?.rawValue ?? "") \(current()?.step ?? "") branch \(current()?.branch ?? "") pr \(current()?.pullRequest ?? "none") cost \(current()?.costUSD ?? 0)")
                case "budget":
                    worker.setBudget(agent.id, usd: Double(steps.popFirst() ?? "") ?? 1)
                    say("budget set")
                case "show":
                    worker.refresh()
                    for event in worker.sessionEvents[current()?.id ?? ""] ?? [] { say("  \(event.id) \(event.kind.rawValue) \(event.tool ?? "") \(event.toolState?.rawValue ?? "") | \(event.text.prefix(70).replacingOccurrences(of: "\n", with: " ")) => \((event.output ?? "").prefix(50).replacingOccurrences(of: "\n", with: " "))") }
                    say("needs: \(folder.needs.map(\.question))")
                case "changes":
                    let changes = await worker.sessionChanges(agent.id, session: current()?.id ?? "")
                    say("changes: \(changes?.files ?? []), pr \(String(describing: changes?.pullRequest)), diff \(changes?.diff.count ?? 0) chars")
                case "take-over":
                    let over = await worker.takeOver(agent.id, session: current()?.id ?? "")
                    say("take-over: \(String(describing: over)), status \(current()?.status?.rawValue ?? "")")
                case "end-take-over":
                    worker.endTakeOver(agent.id, session: current()?.id ?? "")
                    while current()?.status != .handedBack { try? await Task.sleep(for: .milliseconds(100)) }
                    say("handed back: \(current()?.branch ?? "") pr \(current()?.pullRequest ?? "none")")
                default: say("unknown step \(step)")
                }
            }
            withExtendedLifetime(worker) { exit(0) }
        }
    }

    private static func events(_ args: [String], store: AgentStore) {
        guard let seconds = args.first.flatMap(Double.init), let bean = store.agents.first(where: \.isBean) else {
            print("usage: events <seconds>, after adopt-bean")
            exit(64)
        }
        Tools.shared.add(FakeRead())
        let reader = WindowReader(store: store)
        var shown = 0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            let all = reader.worker.gateDecisions
            for entry in all.suffix(max(0, all.count - shown)) {
                let score = entry.score.map { String(format: "%.2f", $0) } ?? "-"
                print("\(entry.at.formatted(date: .omitted, time: .standard)) \(entry.event) [\(entry.title ?? entry.app ?? "")] \(entry.decision) by \(entry.by) score \(score) \(entry.ms.map { "\($0) ms" } ?? "") \(entry.detail?.prefix(120) ?? "")")
            }
            shown = all.count
            fflush(stdout)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            let rows = CostLedger.lines.filter { $0.agent == bean.id.uuidString && $0.run == ProcessInfo.processInfo.environment["BEAN_RUN_ID"] }
            print("Bean's model calls: \(rows.count)")
            withExtendedLifetime(reader) { exit(0) }
        }
    }

    private static func decide(_ args: [String], store: AgentStore) {
        guard let bean = store.agents.first(where: \.isBean), let mission = AgentFolder(bean, in: store).mission else {
            print("usage: decide <what happened>, after adopt-bean")
            exit(64)
        }
        let situation = HelpSituation(agent: bean, persona: "", mission: mission, trigger: args.joined(separator: " "), observation: "", journal: [])
        Task {
            let started = Date()
            let decision = try? await AgentWorker.decider.decide(situation)
            print(String(format: "%.2f s: help=%@ what=%@", Date().timeIntervalSince(started), decision.map { String($0.help) } ?? "failed", decision?.what ?? "-"))
            exit(0)
        }
    }
}
