import AppKit

@MainActor
enum AgentsProbe {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--probe-agents"), args.indices.contains(index + 1) else { return false }
        let rest = Array(args[(index + 2)...])
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            if getppid() == 1 { exit(0) }
        }
        let store = AgentStore()
        Tools.shared.add(Connectors())
        print("data: \(store.root.path)")
        switch args[index + 1] {
        case "idle": print("idle"); fflush(stdout)
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
        case "moment-checks": Task { await MomentChecks.run(); exit(MomentChecks.failed == 0 ? 0 : 1) }
        case "moment-live": MomentLive.run(rest, store: store)
        case "moment-paid": Task { await MomentPaid.run(rest); exit(0) }
        case "local-filter": Task { await LocalFilterProof.run(rest.first ?? ""); exit(0) }
        case "filter-setting": print("filter setting: \(BeanSettings.shared.filtersWhatBeanSees ? "on" : "off")"); exit(0)
        case "moment-filter":
            Task { await MomentChecks.filter(cases: rest.first ?? "", moments: rest.contains("--moments")); exit(0) }
        case "moments-replay":
            let dump = rest.firstIndex(of: "--dump").map { rest[$0 + 1] }
            let files = rest.filter { $0 != "--real" && $0 != "--dump" && $0 != dump }
            MomentReplay.report(files, realAppsOnly: rest.contains("--real"), dump: dump)
            exit(0)
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
        case "takeover-test":
            Agents.adoptBean(in: store)
            Task { @MainActor in
                let worker = AgentWorker(store: store, autostart: false)
                guard let session = UserSessions.latest() else { print("takeover: no session"); exit(1) }
                let row = await Task.detached { UserSessions.listedRow(of: session.id) }.value
                print("takeover state: \(UserSessions.state(of: session, listed: row)), listed \(row?["status"] as? String ?? "no")"); fflush(stdout)
                print("takeover: \(await worker.takeOverUserSession(session) ?? "started")"); fflush(stdout)
                guard let agent = store.agents.first(where: { $0.name == "Relay" }) else { exit(1) }
                let sessions = CodingSessions(folder: AgentFolder(agent, in: store))
                if rest.first == "stop-after-file", let file = rest.dropFirst().first {
                    while !FileManager.default.fileExists(atPath: file) { try? await Task.sleep(for: .milliseconds(300)) }
                    try? await Task.sleep(for: .seconds(1))
                    worker.stopSession(agent.id, session: sessions.all.last?.id ?? "")
                }
                while worker.sessionsStillMoving { try? await Task.sleep(for: .milliseconds(500)) }
                let last = sessions.all.last
                print("takeover end: id \(last?.claudeSession ?? "") status \(last?.status?.rawValue ?? "") step \(last?.step ?? "") branch \(last?.branch ?? "") pr \(last?.pullRequest ?? "none") cost \(last?.costUSD ?? 0)")
                print("takeover replied: \(AgentFolder(agent, in: store).journal.filter { $0.kind == .replied }.map(\.did))"); fflush(stdout)
                withExtendedLifetime(worker) { exit(0) }
            }
        case "reopen":
            guard rest.count == 3, let agent = store.agents.first(where: { $0.name == rest[0] }), let place = ReopenPlace(rawValue: rest[2]) else { print("usage: reopen <agent-name> <session> app|terminal"); exit(64) }
            Task { @MainActor in
                let worker = AgentWorker(store: store, autostart: false)
                print("reopen: \(await worker.reopenSession(agent.id, session: rest[1], in: place) ?? "opened")")
                worker.refresh()
                print("reopensIn: \(worker.sessions[agent.id]?.map { "\($0.id) \($0.reopensIn.map(\.rawValue))" } ?? [])")
                withExtendedLifetime(worker) { exit(0) }
            }
        case "reopen-places":
            print("places: \(UserSessions.reopenPlaces(of: rest.first ?? "").map(\.rawValue))")
            exit(0)
        case "live-under":
            print("live: \(UserSessions.live(underApp: Int32(rest.first ?? "") ?? 0)?.title.isEmpty == false)")
            exit(0)
        case "window-close-test":
            let agent = Agent(id: UUID(), name: "Tester", role: "Keeps notes on this document.", look: .init(hue: 0.5, accessory: "none"), attachment: nil, createdAt: Date())
            AgentFolder(agent, in: store).create(agent: agent, bornFrom: .person("Keep notes on this document."))
            AgentFolder(agent, in: store).save(AgentMission(mission: agent.role))
            store.save(agent)
            guard rest.count == 3, let window = WindowChannels.open().first(where: { $0.title == rest[0] }), let other = WindowChannels.open().first(where: { $0.title == rest[1] }) else { print("usage: window-close-test <title> <other title> <file that closes it>, windows \(WindowChannels.forModel())"); exit(64) }
            store.attach(agent.id, to: WindowChannels.attachment(for: window))
            let reader = WindowReader(store: store)
            let attachment = WindowChannels.attachment(for: window), otherAttachment = WindowChannels.attachment(for: other)
            Task { @MainActor in
                let worker = reader.worker
                let folder = AgentFolder(agent, in: store)
                let tools = worker.windowTools(agent, attachment: attachment, folder: folder)
                let read = tools.first { $0.name == "window_read" }
                print("before: read own: \(await read?.run([:]).text.prefix(40) ?? "")")
                let otherTools: [(String, [String: Any])] = [("app_windows", [:]), ("app_window_read", ["title": rest[1]]), ("tab_read", ["window": 1, "tab": 1])]
                for (name, args) in otherTools { print("on the app, \(name): \(await tools.first { $0.name == name }?.run(args).text.prefix(44) ?? "no tool")") }
                print("own window with no change: \(await read?.run([:]).text.prefix(30) ?? "")")
                for step in ["rename", "minimize", "restore", "hide", "unhide", "tab", "untab"] {
                    FileManager.default.createFile(atPath: rest[2] + "." + step, contents: nil)
                    try? await Task.sleep(for: .seconds(11))
                    print("after \(step): attached \(store.agents.first { $0.id == agent.id }?.attachment != nil), read: \(await read?.run([:]).text.prefix(50) ?? "")")
                }
                FileManager.default.createFile(atPath: rest[2], contents: nil)
                try? await Task.sleep(for: .seconds(2))
                let names = ["window_read", "window_controls", "window_act", "app_script", "app_windows", "app_window_read"]
                for name in names { print("after \(name): \(await tools.first { $0.name == name }?.run(["control": 0, "action": "fill", "text": "x", "did": "x", "why": "x", "script": "tell application \"x\" to beep", "title": rest[1]]).text.prefix(44) ?? "no tool")") }
                print("snapshot of the closed window: \(WindowSnapshot.read(attachment)?.text.prefix(30) ?? "nothing")")
                print("other window still reads: \(WindowSnapshot.read(otherAttachment)?.text.prefix(30) ?? "nothing")")
                let started = Date()
                while store.agents.first(where: { $0.id == agent.id })?.attachment != nil, Date().timeIntervalSince(started) < 20 { try? await Task.sleep(for: .milliseconds(300)) }
                let now = store.agents.first { $0.id == agent.id }
                print("after \(Int(Date().timeIntervalSince(started))) s: attachment \(now?.attachment?.windowTitle ?? "none"), agent exists \(now != nil), card kept \(FileManager.default.fileExists(atPath: AgentFolder(agent, in: store).url.path))")
                print("said: \(folder.journal.filter { $0.kind == .replied }.map(\.did))")
                withExtendedLifetime(reader) { exit(0) }
            }
        case "finished-test":
            guard rest.count == 1 else { print("usage: finished-test <file logging model requests>"); exit(64) }
            Agents.adoptBean(in: store)
            let coder = Agent(id: UUID(), name: "Milo", role: "Fixes code.", look: .init(hue: 0.5, accessory: "none"), attachment: nil, createdAt: Date())
            AgentFolder(coder, in: store).create(agent: coder, bornFrom: .person("Fix code."))
            AgentFolder(coder, in: store).save(AgentMission(mission: coder.role))
            store.save(coder)
            guard let bean = store.agents.first(where: \.isBean), let mission = AgentFolder(bean, in: store).mission else { exit(1) }
            Task { @MainActor in
                let worker = AgentWorker(store: store, autostart: false)
                func requests() -> Int { ((try? String(contentsOfFile: rest[0], encoding: .utf8)) ?? "").split(separator: "\n").count }
                let code = BeanUnderstanding.Step(what: "Add docstrings and open a draft pull request", who: "Milo", why: "asked")
                let other = BeanUnderstanding.Step(what: "Note it in the tracker", who: "Milo", why: "asked")
                worker.startPlan([code], from: "Add docstrings and open a draft pull request")
                worker.noteHandOff(of: worker.stepId(0), to: coder.id)
                CodingSessions(folder: AgentFolder(coder, in: store)).save(CodingSession(id: "done1", repo: "x/y", branch: "b", worktree: "", open: false, task: "docstrings", workId: worker.stepId(0), status: .finished, pullRequest: "https://github.com/x/y/pull/1"))
                var before = requests()
                let delivered = await worker.stepsStillOpen([code], report: "done", since: Date().addingTimeInterval(-3600), bean: bean)
                print("delivered step: open \(delivered.map(\.step.what)), model calls \(requests() - before), state \(worker.readPlan().steps.map(\.state.rawValue))")
                before = requests()
                worker.heldPlan = AgentWorker.HeldPlan(mission: mission, situation: HelpSituation(agent: bean, persona: "", mission: mission, trigger: "test", observation: "", journal: []), decision: HelpDecision(help: true, what: "Do the plan"), steps: [code], began: Date(), summary: "started")
                await worker.planMayBeSettled()
                while worker.sessionsStillMoving { try? await Task.sleep(for: .milliseconds(200)) }
                print("report: \(AgentFolder(bean, in: store).journal.filter { $0.kind == .replied }.count), model calls \(requests() - before)")
                SessionClaims.set(SessionClaim(key: "held-1", session: "done1", agent: coder.name, agentId: coder.id, at: Date()), in: store.root)
                let command = "gh pr diff 1 --repo x/y"
                var reading = worker.perimeter(for: coder)
                print("reading its own pull request, before: \(reading.refusal(.shell(command, .read)) ?? "allowed")")
                reading.mission = reading.mission.reaching("x/y")
                print("reading its own pull request, with its session's repo: \(reading.refusal(.shell(command, .read)) ?? "allowed"); writing there: \(worker.perimeter(for: coder).refusal(.shell("git push origin x", .write)) ?? "allowed")")
                print("hold of an ended session: \(await worker.claim("held-1", agent: coder) ?? "released")")
                print("same pull request for its work id: \(worker.deliveredSession(of: worker.stepId(0), repo: "x/y")?.pullRequest ?? "none")")
                worker.startPlan([code, other], from: "A request")
                worker.noteBlocked(worker.stepId(0), because: "waits for the person")
                worker.startPlan([BeanUnderstanding.Step(what: code.what, who: "Milo", why: "asked", continues: worker.stepId(0)), other], from: "A later request")
                print("request after a blocked step: \(worker.planRequest ?? "none"), board \(worker.readPlan().steps.map(\.state.rawValue))")
                before = requests()
                let open = await worker.stepsStillOpen(worker.planSteps, report: "done", since: Date().addingTimeInterval(-3600), bean: bean)
                print("after a blocked step: open \(open.map(\.step.what)), model calls \(requests() - before)")
                withExtendedLifetime(worker) { exit(0) }
            }
        case "followup-run":
            guard rest.count == 3 else { print("usage: followup-run <repo> <branch> <pull request link>"); exit(64) }
            Agents.adoptBean(in: store)
            let coder = Agent(id: UUID(), name: "Milo", role: "Fixes code and opens draft pull requests.", look: .init(hue: 0.5, accessory: "none"), attachment: nil, createdAt: Date())
            AgentFolder(coder, in: store).create(agent: coder, bornFrom: .person("Fix code and open draft pull requests."))
            var targets = AgentMission(mission: coder.role)
            targets.scope = [rest[0]]
            AgentFolder(coder, in: store).save(targets)
            store.save(coder)
            guard let bean = store.agents.first(where: \.isBean), let mission = AgentFolder(bean, in: store).mission else { exit(1) }
            Task { @MainActor in
                let worker = AgentWorker(store: store, autostart: false)
                await CodeRepos.refresh()
                let asked = "In repo \(rest[0]), add a short docstring to every function in cart.py and prices.py, then open a draft pull request."
                let step = BeanUnderstanding.Step(what: asked, who: "Milo", why: "asked")
                worker.startPlan([step], from: asked)
                worker.noteHandOff(of: worker.stepId(0), to: coder.id)
                CodingSessions(folder: AgentFolder(coder, in: store)).save(CodingSession(id: "seeded01", repo: rest[0], branch: rest[1], worktree: "", open: false, task: asked, workId: worker.stepId(0), startedAt: Date(), status: .finished, pullRequest: rest[2]))
                worker.heldPlan = AgentWorker.HeldPlan(mission: mission, situation: HelpSituation(agent: bean, persona: "", mission: mission, trigger: "The user asked: \(asked)", observation: "", journal: []), decision: HelpDecision(help: true, what: asked), steps: [step], began: Date(), summary: "Milo opened \(rest[2]).")
                await worker.planMayBeSettled()
                let began = Date()
                var quiet = 0
                while quiet < 15, Date().timeIntervalSince(began) < 420 {
                    quiet = worker.sessionsStillMoving ? 0 : quiet + 1
                    try? await Task.sleep(for: .seconds(1))
                }
                print("ended alone: \(quiet >= 15), after \(Int(Date().timeIntervalSince(began))) s")
                print("reports: \(AgentFolder(bean, in: store).journal.filter { $0.kind == .replied }.map { String($0.did.prefix(300)) })")
                print("sessions: \(CodingSessions(folder: AgentFolder(coder, in: store)).all.map { "\($0.id) \($0.branch) \($0.status?.rawValue ?? "") \($0.pullRequest ?? "no pr")" })")
                withExtendedLifetime(worker) { exit(0) }
            }
        case "space-test":
            guard let window = WindowChannels.open().first(where: { window in
                let onScreen = ((CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []).compactMap { $0[kCGWindowNumber as String] as? Int }
                return rest.first == "offscreen" ? !onScreen.contains(window.number) : window.title == rest.first
            }) else { print("space-test: no window"); exit(1) }
            let attachment = WindowChannels.attachment(for: window)
            let listed = (Accessibility.attribute(kAXWindowsAttribute, of: AXUIElementCreateApplication(window.pid)) as? [AXUIElement]) ?? []
            print("space-test AX lists \(listed.count), in the plain lookup \(WindowSnapshot.stillOpen(window.number)), reachable \(WindowSnapshot.element(for: attachment) != nil), presence \(WindowSnapshot.presence(attachment))\(rest.count > 1 ? "" : ", read \(WindowSnapshot.read(attachment)?.text.prefix(16) ?? "nothing")")")
            exit(0)
        case "space-count":
            print("accessibility \(AXIsProcessTrusted()), screen recording \(CGPreflightScreenCaptureAccess())")
            for (app, windows) in Dictionary(grouping: WindowChannels.open(), by: \.app).sorted(by: { $0.key < $1.key }) {
                let off = windows.filter { SpaceWindows.isOnAnotherSpace($0.number) }
                let sealed = OffLimits.match("\(app) \(windows[0].bundleId)") != nil || Skills.forApp(windows[0].bundleId)?.sealed == true || windows[0].bundleId == "com.apple.mail"
                let held = sealed ? 0 : off.filter { SpaceWindows.element(of: $0.number, pid: $0.pid, mayNudge: false) != nil }.count
                print("\(app): listed \(windows.count), titled \(windows.filter { $0.title != nil }.count), minimized or hidden \(windows.filter { !WindowSnapshot.stillOpen($0.number) }.count), on another Space \(off.count), reached there with no side effect \(sealed ? "not tried" : "\(held)")")
            }
            exit(0)
        case "space-follow":
            guard let window = WindowChannels.open().first(where: { $0.title?.contains(rest.first ?? "") == true }) else { print("space-follow: no window"); exit(1) }
            let attachment = WindowChannels.attachment(for: window)
            SpaceWindows.keepUp()
            Thread.detachNewThread {
                for _ in 0..<(Int(rest.dropFirst().first ?? "10") ?? 10) {
                    print("another Space \(SpaceWindows.isOnAnotherSpace(window.number)), presence \(WindowSnapshot.presence(attachment)), read \(WindowSnapshot.read(attachment)?.text.prefix(40) ?? "nothing")")
                    fflush(stdout)
                    sleep(2)
                }
                exit(0)
            }
        case "seed-on", "seed-on-number":
            guard rest.count >= 2, let window = WindowChannels.open().first(where: { args[index + 1] == "seed-on" ? $0.title?.contains(rest[1]) == true : $0.number == Int(rest[1]) }) else { print("seed-on: no window \(rest.dropFirst().first ?? "")"); exit(1) }
            let pip = Agent(id: UUID(), name: rest[0], role: "Works on this one test window.", look: .init(hue: 0.3, accessory: "none"), attachment: nil, createdAt: Date())
            AgentFolder(pip, in: store).create(agent: pip, bornFrom: .person("Works on this one test window."))
            AgentFolder(pip, in: store).save(AgentMission(mission: pip.role))
            store.save(pip)
            store.attach(pip.id, to: WindowChannels.attachment(for: window))
            print("\(pip.name) \(pip.id) on window \(window.number), \(window.app), automation \(AppAutomation.state(of: window.bundleId, ask: false)), another Space \(SpaceWindows.isOnAnotherSpace(window.number))")
            exit(0)
        case "seed-read-only":
            guard let window = WindowChannels.open().first(where: { $0.title == rest.first }) else { print("seed-read-only: no window \(rest.first ?? "")"); exit(1) }
            Agents.adoptBean(in: store)
            let lina = Agent(id: UUID(), name: "Lina", role: "Keeps this invoices document in order.", look: .init(hue: 0.5, accessory: "none"), attachment: nil, createdAt: Date())
            let linaFolder = AgentFolder(lina, in: store)
            linaFolder.create(agent: lina, bornFrom: .moment("Because you were on it"))
            linaFolder.save(AgentMission(mission: lina.role))
            linaFolder.updateCard { $0.readOnly = true }
            store.save(lina)
            store.attach(lina.id, to: WindowChannels.attachment(for: window))
            Task { @MainActor in
                let worker = AgentWorker(store: store, autostart: false)
                if let placed = store.agents.first(where: { $0.id == lina.id }) { worker.askToChangeWindow(placed, after: Perimeter.cardReadOnly) }
                print("seeded: \(linaFolder.needs.map(\.question))")
                if let bean = store.agents.first(where: \.isBean), let asked = linaFolder.needs.first?.question {
                    worker.raise(AgentNeed(kind: .decision, question: asked), agent: bean)
                    print("Bean repeating it: \(AgentFolder(bean, in: store).needs.count) on Bean")
                }
                withExtendedLifetime(worker) { exit(0) }
            }
        case "read-only-real":
            guard rest.count >= 2, let window = WindowChannels.open().first(where: { $0.title == rest[0] }) else { print("usage: read-only-real <title> <request> [own chat], windows \(WindowChannels.forModel())"); exit(64) }
            Agents.adoptBean(in: store)
            let lina = Agent(id: UUID(), name: "Lina", role: "Keeps this invoices document in order.", look: .init(hue: 0.5, accessory: "none"), attachment: nil, createdAt: Date())
            let linaFolder = AgentFolder(lina, in: store)
            linaFolder.create(agent: lina, bornFrom: .moment("Because you were on it"))
            linaFolder.save(AgentMission(mission: lina.role))
            linaFolder.updateCard {
                $0.readOnly = true
                $0.job = AgentJob(goal: "Keep the invoices in order.", output: "", done: "Every invoice is listed and marked checked in the document.", first: "", quiet: "")
            }
            store.save(lina)
            store.attach(lina.id, to: WindowChannels.attachment(for: window))
            let reader = WindowReader(store: store)
            let attachment = WindowChannels.attachment(for: window)
            guard let bean = store.agents.first(where: \.isBean) else { exit(1) }
            Task { @MainActor in
                let worker = reader.worker
                @MainActor func settle() async {
                    let began = Date()
                    var quiet = 0
                    while quiet < 12, Date().timeIntervalSince(began) < 150 {
                        quiet = worker.sessionsStillMoving ? 0 : quiet + 1
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                func replies() -> [String] { [bean, lina].flatMap { agent in AgentFolder(agent, in: store).journal.filter { $0.kind == .replied }.map { "\(agent.name): \($0.did.prefix(300))" } } }
                if rest[1] == "close" {
                    _ = await AppActions.runScript("tell application \"\(attachment.appName)\" to close document \"\(rest[0])\" saving no")
                    exit(0)
                }
                guard WindowSnapshot.read(attachment) != nil else {
                    print("unreachable, nothing sent to the model")
                    _ = await AppActions.runScript("tell application \"\(attachment.appName)\" to close document \"\(rest[0])\" saving no")
                    exit(3)
                }
                try? await Task.sleep(for: .seconds(1))
                worker.send(rest.count > 2 && rest[2] == "own" ? lina.id : bean.id, rest[1])
                if rest.count > 2, rest[2] == "race" {
                    let began = Date()
                    while linaFolder.needs.isEmpty, Date().timeIntervalSince(began) < 60 { try? await Task.sleep(for: .milliseconds(200)) }
                    if let need = linaFolder.needs.first { worker.answer(lina.id, need: need.id, AgentWorker.allowIt) }
                    print("answered at once, Bean still working: \(worker.isBusy(bean.id) || worker.isReplying(bean.id))")
                }
                try? await Task.sleep(for: .seconds(3))
                await settle()
                print("reports: \(replies())")
                print("question: \(linaFolder.needs.map(\.question)), options \(linaFolder.needs.first?.options ?? [])")
                print("questions on Bean: \(AgentFolder(bean, in: store).needs.map(\.question))")
                print("before any yes, text: \(WindowSnapshot.read(attachment)?.text.prefix(200) ?? "unread")")
                guard let need = linaFolder.needs.first else {
                    print("no question")
                    _ = await AppActions.runScript("tell application \"\(attachment.appName)\" to close document \"\(rest[0])\" saving no")
                    exit(0)
                }
                let before = replies().count
                worker.answer(lina.id, need: need.id, AgentWorker.allowIt)
                try? await Task.sleep(for: .seconds(3))
                await settle()
                print("read only now: \(worker.perimeter(for: lina).readOnly)")
                print("reports after the yes: \(replies().dropFirst(before))")
                print("after the yes, text: \(WindowSnapshot.read(attachment)?.text.prefix(300) ?? "unread")")
                print("plan after the yes: \(worker.readPlan().steps.map(\.state.rawValue)), questions on Bean: \(AgentFolder(bean, in: store).needs.map(\.question))")
                _ = await AppActions.runScript("tell application \"\(attachment.appName)\" to close document \"\(rest[0])\" saving no")
                withExtendedLifetime(reader) { exit(0) }
            }
        case "create-test":
            Agents.adoptBean(in: store)
            let lina = Agent(id: UUID(), name: "Lina", role: "Keeps invoices.", look: .init(hue: 0.5, accessory: "none"), attachment: nil, createdAt: Date())
            AgentFolder(lina, in: store).create(agent: lina, bornFrom: .person("Keep invoices."))
            AgentFolder(lina, in: store).save(AgentMission(mission: lina.role))
            store.save(lina)
            guard let bean = store.agents.first(where: \.isBean) else { exit(1) }
            Task { @MainActor in
                let worker = AgentWorker(store: store, autostart: false)
                worker.startPlan([BeanUnderstanding.Step(what: "Keep invoices", who: "Lina", why: "asked")], from: "Keep invoices")
                worker.noteHandOff(of: worker.stepId(0), to: lina.id)
                worker.record(JournalEntry(kind: .handoff, did: "Keep invoices", why: ""), lina)
                print("holdings: \(worker.agentHoldings().prefix(60))")
                let create = worker.beanTools(bean, folder: AgentFolder(bean, in: store)).first { $0.name == "create_agent" }
                for sentence in ["Writes code in acme-shop.", "Edits Python code and opens draft pull requests.", "A coding agent for the shop."] {
                    print("\(sentence) -> \(await create?.run(["sentence": sentence]).text.prefix(40) ?? "")")
                }
                print("agents: \(store.agents.map(\.name))")
                withExtendedLifetime(worker) { exit(0) }
            }
        case "code-after-agent":
            guard rest.count == 1 else { print("usage: code-after-agent <request>"); exit(64) }
            Agents.adoptBean(in: store)
            let lina = Agent(id: UUID(), name: "Lina", role: "Keeps invoices.", look: .init(hue: 0.5, accessory: "none"), attachment: nil, createdAt: Date())
            AgentFolder(lina, in: store).create(agent: lina, bornFrom: .person("Keep invoices."))
            AgentFolder(lina, in: store).save(AgentMission(mission: lina.role))
            store.save(lina)
            guard let bean = store.agents.first(where: \.isBean) else { exit(1) }
            Task { @MainActor in
                let worker = AgentWorker(store: store, autostart: false)
                await CodeRepos.refresh()
                worker.startPlan([BeanUnderstanding.Step(what: "Keep invoices", who: "Lina", why: "asked")], from: "Keep invoices")
                worker.noteHandOff(of: worker.stepId(0), to: lina.id)
                worker.record(JournalEntry(kind: .handoff, did: "Keep invoices", why: ""), lina)
                print("holdings: \(worker.agentHoldings().prefix(60))")
                worker.send(bean.id, rest[0])
                try? await Task.sleep(for: .seconds(5))
                let began = Date()
                var quiet = 0
                while quiet < 15, Date().timeIntervalSince(began) < 280 {
                    quiet = worker.sessionsStillMoving ? 0 : quiet + 1
                    try? await Task.sleep(for: .seconds(1))
                }
                print("ended alone: \(quiet >= 15), agents \(store.agents.map(\.name))")
                print("reports: \(AgentFolder(bean, in: store).journal.filter { $0.kind == .replied }.map { String($0.did.prefix(240)) })")
                print("pull requests: \(store.agents.flatMap { CodingSessions(folder: AgentFolder($0, in: store)).all.compactMap(\.pullRequest) })")
                withExtendedLifetime(worker) { exit(0) }
            }
        case "numbers-read":
            Task { @MainActor in
                print("automation: \(AppAutomation.state(of: "com.apple.iWork.Numbers", ask: false).rawValue)")
                let made = await AppActions.runScript("tell application \"Numbers\"\nset d to make new document\ntell table 1 of sheet 1 of d\nset value of cell \"B3\" to \"Code word: lilac-58\"\nset value of cell \"C4\" to 900\nend tell\nreturn name of d\nend tell")
                print("made: \(made.ok) \(made.text.prefix(60))")
                try? await Task.sleep(for: .seconds(2))
                guard let window = WindowChannels.open().first(where: { $0.app == "Numbers" }) else { print("no Numbers window"); exit(1) }
                let attachment = WindowChannels.attachment(for: window)
                let snapshot = WindowSnapshot.read(attachment)
                print("title \(window.title ?? "-"), read \(snapshot?.text.count ?? -1) chars, has word \(snapshot?.text.contains("lilac") == true), has 900 \(snapshot?.text.contains("900") == true)")
                print("text: \(snapshot?.text.prefix(500).replacingOccurrences(of: "\n", with: " | ") ?? "")")
                print("partial: \(snapshot?.partial ?? "no")")
                _ = await AppActions.runScript("tell application \"Numbers\" to close document \"\(made.text.trimmingCharacters(in: .whitespacesAndNewlines))\" saving no")
                exit(0)
            }
        case "relaunch-test":
            Agents.adoptBean(in: store)
            let milo = Agent(id: UUID(), name: "Milo", role: "Fixes code.", look: .init(hue: 0.5, accessory: "none"), attachment: nil, createdAt: Date())
            let folder = AgentFolder(milo, in: store)
            folder.create(agent: milo, bornFrom: .person("Fix code."))
            folder.save(AgentMission(mission: milo.role))
            store.save(milo)
            CodingSessions(folder: folder).save(CodingSession(id: "cut01", repo: "x/y", branch: "b", worktree: "", task: "Add docstrings", workId: "w-1", startedAt: Date(), status: .running))
            if rest.first == "seed" { exit(0) }
            Task { @MainActor in
                let worker = AgentWorker(store: store, autostart: false)
                worker.settleSessionsAfterLaunch()
                print("session: \(CodingSessions(folder: folder).session("cut01")?.step ?? "")")
                print("said: \(folder.journal.filter { $0.kind == .replied }.map(\.did))")
                worker.refresh()
                print("offers Resume: \(worker.stoppedAgents.contains(milo.id)), restart refused: \(worker.stoppedWorkRefusal(of: ["w-1"], by: milo) != nil)")
                worker.settleSessionsAfterLaunch()
                print("said once: \(folder.journal.filter { $0.kind == .replied }.count)")
                withExtendedLifetime(worker) { exit(0) }
            }
        case "plan-replace-test":
            Agents.adoptBean(in: store)
            let lina = Agent(id: UUID(), name: "Lina", role: "Keeps invoices.", look: .init(hue: 0.5, accessory: "none"), attachment: nil, createdAt: Date())
            AgentFolder(lina, in: store).create(agent: lina, bornFrom: .person("Keep invoices."))
            AgentFolder(lina, in: store).save(AgentMission(mission: lina.role))
            store.save(lina)
            guard let bean = store.agents.first(where: \.isBean) else { exit(1) }
            Task { @MainActor in
                let worker = AgentWorker(store: store, autostart: false)
                let old = BeanUnderstanding.Step(what: "Report the code word", who: "Lina", why: "asked")
                worker.startPlan([old], from: "Report the code word")
                worker.noteHandOff(of: worker.stepId(0), to: lina.id)
                worker.noteCheck(of: worker.stepId(0), done: false, missing: "not reported")
                let oldId = worker.stepId(0)
                let new = BeanUnderstanding.Step(what: "Count the typefaces", who: "Lina", why: "asked")
                worker.startPlan([new], from: "Count the typefaces")
                print("after a new request: board \(worker.planBoard.map(\.step.what)), request \(worker.planRequest ?? "none")")
                let open = await worker.stepsStillOpen(worker.planSteps, report: "done", since: Date().addingTimeInterval(-60), bean: bean)
                print("checked: \(open.map(\.step.what)), old step id gone: \(!worker.planBoard.map(\.id).contains(oldId))")
                withExtendedLifetime(worker) { exit(0) }
            }
        case "numbers-real":
            Agents.adoptBean(in: store)
            guard let bean = store.agents.first(where: \.isBean) else { exit(1) }
            Task { @MainActor in
                let build = "tell application \"Numbers\"\nset d to make new document\ntell table 1 of sheet 1 of d\nset value of cell \"A2\" to \"Code word: lilac-58\"\nset value of cell \"A3\" to \"Rent\"\nset value of cell \"B3\" to 900\nset value of cell \"A4\" to \"Power\"\nset value of cell \"B4\" to 100\nset value of cell \"A5\" to \"Total\"\nset value of cell \"B5\" to 1100\nend tell\nreturn name of d\nend tell"
                let made = await AppActions.runScript(build)
                let name = made.text.trimmingCharacters(in: .whitespacesAndNewlines)
                try? await Task.sleep(for: .seconds(2))
                guard made.ok, let window = WindowChannels.open().first(where: { $0.app == "Numbers" }) else { print("no Numbers window: \(made.text.prefix(80))"); exit(1) }
                let cells = "tell application \"Numbers\" to get value of every cell of table 1 of sheet 1 of document \"\(name)\""
                func filled() async -> Int { await AppActions.runScript(cells).text.components(separatedBy: ", ").filter { $0 != "missing value" }.count }
                let cal = Agent(id: UUID(), name: "Cal", role: "Keeps this expenses sheet in order.", look: .init(hue: 0.5, accessory: "none"), attachment: nil, createdAt: Date())
                let folder = AgentFolder(cal, in: store)
                folder.create(agent: cal, bornFrom: .moment("Because you were on it"))
                folder.save(AgentMission(mission: cal.role))
                folder.updateCard { $0.readOnly = true }
                store.save(cal)
                store.attach(cal.id, to: WindowChannels.attachment(for: window))
                let reader = WindowReader(store: store)
                let worker = reader.worker
                @MainActor func settle() async {
                    try? await Task.sleep(for: .seconds(3))
                    let began = Date()
                    var quiet = 0
                    while quiet < 10, Date().timeIntervalSince(began) < 120 {
                        quiet = worker.sessionsStillMoving ? 0 : quiet + 1
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                func said() -> [String] { [bean, cal].flatMap { agent in AgentFolder(agent, in: store).journal.filter { $0.kind == .replied }.map { "\(agent.name): \($0.did.prefix(260))" } } }
                print("on screen now: \(!SpaceWindows.isOnAnotherSpace(window.number)), cells filled \(await filled())")
                print("read through the window alone: partial \(WindowSnapshot.read(WindowChannels.attachment(for: window))?.partial ?? "no")")
                var seen = 0
                for (index, request) in ["Ask Cal whether the word turquoise is anywhere in its sheet.", "Ask Cal to check that the amounts in its sheet add up to the total and tell me anything odd."].prefix(rest.isEmpty ? 2 : 1).enumerated() {
                    if index == 1 { folder.updateCard { $0.readOnly = false } }
                    worker.send(bean.id, request)
                    await settle()
                    print("== \(request)")
                    print("said: \(said().dropFirst(seen))")
                    seen = said().count
                    print("read only still \(worker.perimeter(for: cal).readOnly), questions on Cal \(folder.needs.count), on Bean \(AgentFolder(bean, in: store).needs.count), cells filled \(await filled())")
                }
                _ = await AppActions.runScript("tell application \"Numbers\" to close document \"\(name)\" saving no")
                withExtendedLifetime(reader) { exit(0) }
            }
        case "vague-real":
            guard rest.count == 1 else { print("usage: vague-real <request>"); exit(64) }
            Agents.adoptBean(in: store)
            guard let bean = store.agents.first(where: \.isBean) else { exit(1) }
            let reader = WindowReader(store: store)
            Task { @MainActor in
                let worker = reader.worker
                worker.send(bean.id, rest[0])
                try? await Task.sleep(for: .seconds(4))
                let began = Date()
                var quiet = 0
                while quiet < 12, Date().timeIntervalSince(began) < 150 {
                    quiet = worker.sessionsStillMoving ? 0 : quiet + 1
                    try? await Task.sleep(for: .seconds(1))
                }
                print("agents: \(store.agents.map { "\($0.name) on \($0.attachment?.windowTitle ?? "nothing")" })")
                print("questions: \(store.agents.flatMap { AgentFolder($0, in: store).needs.map(\.question) })")
                print("said: \(AgentFolder(bean, in: store).journal.filter { $0.kind == .replied }.map { String($0.did.prefix(260)) })")
                withExtendedLifetime(reader) { exit(0) }
            }
        case "bypass-test":
            guard rest.count == 2, let window = WindowChannels.open().first(where: { $0.title == rest[0] }) else { print("usage: bypass-test <title> <folder>"); exit(64) }
            let attachment = WindowChannels.attachment(for: window)
            let app = attachment.appName, folderPath = rest[1]
            let agent = Agent(id: UUID(), name: "Tester", role: "Tests.", look: .init(hue: 0.5, accessory: "none"), attachment: nil, createdAt: Date())
            let folder = AgentFolder(agent, in: store)
            folder.create(agent: agent, bornFrom: .person("Test."))
            folder.save(AgentMission(mission: agent.role))
            store.save(agent)
            store.attach(agent.id, to: attachment)
            Task { @MainActor in
                let worker = AgentWorker(store: store, autostart: false)
                let tool = worker.windowTools(agent, attachment: attachment, folder: folder).first { $0.name == "app_script" }
                func shell(_ name: String) -> String { "do  shell  script \"echo x > \(folderPath)/\(name)\"" }
                let cases: [(String, String)] = [
                    ("comment-tell", "-- tell application \"\(app)\"\nget {|--|:(\(shell("a")))}"),
                    ("pipe-comment", "tell application \"\(app)\"\nget {|--|:(\(shell("b")))}\nend tell"),
                    ("pipe-hash", "tell application \"\(app)\"\nget {|#|:(\(shell("c")))}\nend tell"),
                    ("raw-event", "tell application \"\(app)\" to «event sysoexec» \"echo x > \(folderPath)/d\""),
                    ("raw-angle", "tell application \"\(app)\" to <<event sysoexec>> \"echo x > \(folderPath)/e\""),
                    ("two-spaces", "tell application \"\(app)\" to \(shell("f"))"),
                    ("tabs", "tell application \"\(app)\" to do\tshell\tscript \"echo x > \(folderPath)/g\""),
                    ("continuation", "tell application \"\(app)\" to do ¬\nshell script \"echo x > \(folderPath)/h\""),
                    ("block-comment", "tell application \"\(app)\" to do (* x *) shell (* y *) script \"echo x > \(folderPath)/i\""),
                    ("run-script", "tell application \"\(app)\" to run script \"do shell script \\\"echo x > \(folderPath)/j\\\"\""),
                    ("do-script", "tell application \"\(app)\" to do script \"echo x > \(folderPath)/k\""),
                    ("other-app", "tell application \"\(app)\"\nget name of application \"Finder\"\nend tell"),
                    ("unclosed-pipe", "tell application \"\(app)\" to get |x"),
                ]
                for (label, script) in cases {
                    let output = await tool?.run(["script": script, "did": label, "why": "test"])
                    print("\(label): ok=\(output?.ok ?? false) onlyReads=\(AppGuard.onlyReads(script)) \(output?.text.prefix(70).replacingOccurrences(of: "\n", with: " ") ?? "no tool")")
                }
                for script in ["tell (application \"Music\") to get (play)", "tell application \"\(app)\" to get (display notification \"x\")", "tell application \"\(app)\" to get the clipboard", "tell application \"\(app)\" to get (delay 100)", "tell application \"\(app)\" to get play", "tell application \"\(app)\" to tell document \"x\" to get value of every cell of table 1"] {
                    print("onlyReads \(AppGuard.onlyReads(script)): \(script.prefix(70))")
                }
                let control = await AppActions.runScript("do shell script \"echo x > \(folderPath)/control\"")
                print("control ran: \(control.ok), files: \(((try? FileManager.default.contentsOfDirectory(atPath: folderPath)) ?? []).sorted())")
                withExtendedLifetime(worker) { exit(0) }
            }
        case "safety-test":
            Agents.adoptBean(in: store)
            func make(_ name: String) -> Agent {
                let one = Agent(id: UUID(), name: name, role: "Tests.", look: .init(hue: 0.5, accessory: "none"), attachment: nil, createdAt: Date())
                AgentFolder(one, in: store).create(agent: one, bornFrom: .person("Test."))
                AgentFolder(one, in: store).save(AgentMission(mission: one.role))
                store.save(one)
                return one
            }
            let milo = make("Milo"), lina = make("Lina")
            guard let bean = store.agents.first(where: \.isBean) else { exit(1) }
            let window = Attachment(bundleId: "com.example.sheet", appName: "SheetApp", pid: 0, windowNumber: 11, windowTitle: "Totals")
            store.attach(milo.id, to: window)
            Task { @MainActor in
                let worker = AgentWorker(store: store, autostart: false)
                let root = store.root, miloFolder = AgentFolder(milo, in: store)
                func stop() {
                    StoppedWork.hold([StoppedWork.key(milo.id), StoppedWork.key(bean.id), "s1", "w1"], in: root)
                    Thread.sleep(forTimeInterval: 0.05)
                }
                func held() -> [String] { let all = StoppedWork.all(in: root); return [("Milo", StoppedWork.key(milo.id)), ("Bean", StoppedWork.key(bean.id)), ("s1", "s1"), ("w1", "w1")].filter { all[$0.1] != nil }.map(\.0) }
                CodingSessions(folder: miloFolder).save(CodingSession(id: "s1", repo: "x/y", branch: "b", worktree: "", open: false, task: "t", workId: "w1", startedAt: Date(), status: .stopped))
                stop()
                let card = AgentNeed(kind: .decision, question: "Which one?", options: ["A", "Not now"])
                worker.raise(card, agent: milo)
                if let need = miloFolder.needs.first { worker.answer(milo.id, need: need.id, "A") }
                try? await Task.sleep(for: .seconds(1))
                print("2 card answer: held \(held()), said \(miloFolder.journal.filter { $0.kind == .replied }.map { String($0.did.prefix(40)) })")
                worker.record(JournalEntry(kind: .said, did: "Not now", why: ""), lina)
                worker.record(JournalEntry(kind: .said, did: "Put Lina on x", why: ""), bean)
                print("3 clicks elsewhere: session_drive gate \(worker.stoppedWorkRefusal(of: ["w1"], by: milo) != nil ? "refused" : "open"), held \(held())")
                var words = JournalEntry(kind: .said, did: "a question", why: "")
                words.typed = true
                worker.record(words, lina)
                print("3 words to another agent: gate \(worker.stoppedWorkRefusal(of: ["w1"], by: milo) != nil ? "refused" : "open"), held \(held())")
                worker.liftStop(lina)
                print("4 Stop lifted for another agent: held \(held())")
                worker.liftStop(milo)
                print("4 Stop lifted for Milo: held \(held())")
                StoppedWork.lift(StoppedWork.key(bean.id), in: root)
                stop()
                let hand = worker.beanTools(bean, folder: AgentFolder(bean, in: store)).first { $0.name == "hand_off" }
                print("14 hand_off with no id: \(await hand?.run(["agent": "Milo", "task": "same work", "why": "x"]).text.prefix(40) ?? "")")
                worker.finishingOnYes.insert(lina.id)
                print("hand_off while it finishes on a yes: \(await hand?.run(["agent": "Lina", "task": "same work", "why": "x"]).text.prefix(60) ?? "")")
                worker.finishingOnYes.remove(lina.id)
                worker.resumeWork(milo.id)
                print("4 Resume on Milo: held \(held())")
                StoppedWork.lift(StoppedWork.key(bean.id), in: root)
                miloFolder.updateCard { $0.readOnly = true }
                print("5 born read only on 11: \(Perimeter(folder: miloFolder, window: window).readOnly)")
                if let placed = store.agents.first(where: { $0.id == milo.id }) { worker.askToChangeWindow(placed, after: Perimeter.cardReadOnly) }
                let asked = miloFolder.needs.first { $0.ability == AgentWorker.changeWindow }
                var moved = window
                moved.bundleId = "com.example.other"
                store.attach(milo.id, to: moved)
                if let asked { worker.answer(milo.id, need: asked.id, AgentWorker.allowIt) }
                print("5 stale card answered on another app: allowed \(miloFolder.state.allowedApp ?? "none")")
                store.attach(milo.id, to: window)
                if let placed = store.agents.first(where: { $0.id == milo.id }) { worker.askToChangeWindow(placed, after: Perimeter.cardReadOnly) }
                if let asked = miloFolder.needs.first(where: { $0.ability == AgentWorker.changeWindow }) { worker.answer(milo.id, need: asked.id, AgentWorker.allowIt) }
                try? await Task.sleep(for: .seconds(1))
                print("5 yes on 11: read only there \(Perimeter(folder: miloFolder, window: window).readOnly), on 22 \(Perimeter(folder: miloFolder, window: moved).readOnly)")
                let reading = Perimeter(card: nil, abilities: [], onlyReading: true)
                print("12 only reading: shell \(reading.refusal(.shell("git push", .write)) != nil), session \(reading.refusal(.startSession(repo: "x/y", url: "https://github.com/x/y.git", known: true)) != nil), connector \(reading.refusal(.connector(name: "linear__x", arguments: "", ability: AgentAbility(id: "x", title: "x", detail: "", allowed: true, risk: .outward, source: "linear"))) != nil)")
                let risky = AgentAbility(id: "gh pr close", title: "Close pull requests", detail: "", allowed: false, risk: .irreversible, source: "gh")
                AgentFolder(lina, in: store).save(AgentFolder(lina, in: store).rawAbilities + [risky])
                worker.turnOn("gh pr close", agent: lina, folder: AgentFolder(lina, in: store))
                print("13 turn_on irreversible: allowed \(AgentFolder(lina, in: store).abilities.first { $0.id == "gh pr close" }?.allowed == true), question \(AgentFolder(lina, in: store).needs.map(\.question))")
                let verdict = await DoneCheck.judge(task: "t", claim: "c", facts: "f", measured: true)
                print("8 no model reply: \(verdict.state.rawValue) by \(verdict.by)")
                let checked = await worker.checkedResult(lina, task: "t", claim: "c", since: Date(), windowBefore: nil) { $0 }
                print("8 reported as: \(checked), step done \(worker.lastCheckDone[lina.id].map(String.init) ?? "not noted")")
                print("6 title verdict with no check: \(await PrivateCheck.titleVerdict("Private title"))")
                print("7 off limits term in reads: \(OffLimits.match("TextEdit x qa-secret-title") ?? "none")")
                withExtendedLifetime(worker) { exit(0) }
            }
        case "title-test":
            guard let window = WindowChannels.open().first(where: { $0.title == rest.first }) else { print("title-test: no window"); exit(1) }
            let stale = Attachment(bundleId: window.bundleId, appName: window.app, pid: window.pid, windowNumber: window.number, windowTitle: "a title set before")
            print("7 stale title: off limits now \(WindowSnapshot.offLimitsNow(stale)), read \(WindowSnapshot.read(stale)?.text.prefix(20) ?? "nothing")")
            exit(0)
        case "allow-race":
            Agents.adoptBean(in: store)
            let nora = Agent(id: UUID(), name: "Nora", role: "Keeps a sheet.", look: .init(hue: 0.5, accessory: "none"), attachment: nil, createdAt: Date())
            let folder = AgentFolder(nora, in: store)
            folder.create(agent: nora, bornFrom: .moment("Because"))
            folder.save(AgentMission(mission: nora.role))
            folder.updateCard { $0.readOnly = true }
            store.save(nora)
            store.attach(nora.id, to: Attachment(bundleId: "com.example.sheet", appName: "SheetApp", pid: 0, windowNumber: 11, windowTitle: "Totals"))
            guard let bean = store.agents.first(where: \.isBean) else { exit(1) }
            Task { @MainActor in
                let worker = AgentWorker(store: store, autostart: false)
                if let placed = store.agents.first(where: { $0.id == nora.id }) { worker.askToChangeWindow(placed, after: Perimeter.cardReadOnly) }
                worker.send(bean.id, "Have Nora write ok in cell D1.")
                try? await Task.sleep(for: .seconds(1))
                if let need = folder.needs.first { worker.answer(nora.id, need: need.id, AgentWorker.allowIt) }
                let began = Date()
                while worker.sessionsStillMoving || worker.isReplying(bean.id), Date().timeIntervalSince(began) < 25 { try? await Task.sleep(for: .milliseconds(300)) }
                print("Bean's stale report after the yes: \(AgentFolder(bean, in: store).journal.filter { $0.kind == .replied }.map { String($0.did.prefix(50)) })")
                withExtendedLifetime(worker) { exit(0) }
            }
        case "relaunch-resume":
            guard ProcessInfo.processInfo.environment["BEAN_SESSION_BINARY"] != nil, rest.count == 2 else { print("usage: relaunch-resume <worktree> <starts file>"); exit(64) }
            Agents.adoptBean(in: store)
            guard let bean = store.agents.first(where: \.isBean) else { exit(1) }
            let mira = Agent(id: UUID(), name: "Mira", role: "Writes code.", look: .init(hue: 0.5, accessory: "none"), attachment: nil, createdAt: Date())
            let folder = AgentFolder(mira, in: store)
            folder.create(agent: mira, bornFrom: .person("Write code."))
            folder.save(AgentMission(mission: mira.role))
            store.save(mira)
            CodingSessions(folder: folder).save(CodingSession(id: "cut01", repo: "x/y", branch: "main", worktree: rest[0], task: "Add docstrings", workId: "w-1", startedAt: Date(), status: .running))
            AgentFolder(bean, in: store).updateState { $0.runningTask = "add docstrings in the shop project" }
            Task { @MainActor in
                let worker = AgentWorker(store: store, autostart: false)
                try? await Task.sleep(for: .seconds(1))
                func starts() -> Int { ((try? String(contentsOfFile: rest[1], encoding: .utf8)) ?? "").split(separator: "\n").count }
                print("after the relaunch: starts \(starts()), session \(CodingSessions(folder: folder).session("cut01")?.status?.rawValue ?? ""), held \(StoppedWork.all(in: store.root).keys.count), line \(AgentFolder(bean, in: store).journal.filter { $0.kind == .replied }.map { String($0.did.prefix(70)) })")
                worker.resumeWork(bean.id)
                let began = Date()
                while starts() == 0, Date().timeIntervalSince(began) < 10 { try? await Task.sleep(for: .milliseconds(200)) }
                print("Resume on Bean's banner: starts \(starts()), session \(CodingSessions(folder: folder).session("cut01")?.status?.rawValue ?? ""), held \(StoppedWork.all(in: store.root).keys.count)")
                worker.stopSession(mira.id, session: "cut01")
                try? await Task.sleep(for: .seconds(2))
                withExtendedLifetime(worker) { exit(0) }
            }
        case "relaunch-seed":
            Agents.adoptBean(in: store)
            guard let bean = store.agents.first(where: \.isBean) else { exit(1) }
            let mira = Agent(id: UUID(), name: "Mira", role: "Writes code.", look: .init(hue: 0.5, accessory: "none"), attachment: nil, createdAt: Date())
            let folder = AgentFolder(mira, in: store)
            folder.create(agent: mira, bornFrom: .person("Write code."))
            folder.save(AgentMission(mission: mira.role))
            store.save(mira)
            if rest.first != "bean-only" { CodingSessions(folder: folder).save(CodingSession(id: "cut01", repo: "x/y", branch: "b", worktree: "", task: "Add docstrings to every file", workId: "w-1", startedAt: Date(), status: .running)) }
            AgentFolder(bean, in: store).updateState { $0.runningTask = "add docstrings in the shop project" }
            print("seeded")
            exit(0)
        case "read-only-test":
            guard rest.count == 2, let window = WindowChannels.open().first(where: { $0.title == rest[0] }) else { print("usage: read-only-test <title> <other title>, windows \(WindowChannels.forModel())"); exit(64) }
            let agent = Agent(id: UUID(), name: "Lina", role: "Keeps invoices in order.", look: .init(hue: 0.5, accessory: "none"), attachment: nil, createdAt: Date())
            let card = AgentFolder(agent, in: store)
            card.create(agent: agent, bornFrom: .moment("Because you were on it"))
            card.save(AgentMission(mission: agent.role))
            card.updateCard { $0.readOnly = true }
            store.save(agent)
            store.attach(agent.id, to: WindowChannels.attachment(for: window))
            let reader = WindowReader(store: store)
            let attachment = WindowChannels.attachment(for: window)
            Task { @MainActor in
                let worker = reader.worker
                guard let placed = store.agents.first(where: { $0.id == agent.id }) else { exit(1) }
                let tools = worker.windowTools(placed, attachment: attachment, folder: card)
                func tool(_ name: String, _ args: JSONArgs) async -> String { await tools.first { $0.name == name }?.run(args).text ?? "no tool" }
                let act: JSONArgs = ["control": 0, "action": "fill", "text": "ALPHA changed", "did": "x", "why": "x"]
                let script: JSONArgs = ["script": "tell application \"\(attachment.appName)\" to get name of document \"\(rest[0])\"", "did": "x", "why": "x"]
                print("read: \(await tool("window_read", [:]).prefix(40))")
                print("act: \(await tool("window_act", act).prefix(120))")
                print("script: \(await tool("app_script", script).prefix(60))")
                print("said about it: \(card.needs.map(\.question))")
                guard let need = card.needs.first else { print("no question"); exit(1) }
                print("options: \(need.options), journal stuck \(card.journal.filter { $0.kind == .stuck }.count)")
                print("act before any answer, text: \(await tool("window_read", [:]).contains("ALPHA changed"))")
                worker.answer(agent.id, need: need.id, AgentWorker.notAllowed)
                print("not now: read only \(worker.perimeter(for: placed).readOnly), questions \(card.needs.count)")
                try? await Task.sleep(for: .seconds(2))
                _ = await tool("window_act", act)
                guard let asked = card.needs.first else { print("no question again, as skipped today: journal \(card.journal.filter { $0.kind == .stuck }.count)"); exit(0) }
                worker.answer(agent.id, need: asked.id, AgentWorker.allowIt)
                print("allow: read only \(worker.perimeter(for: placed).readOnly), questions \(card.needs.count)")
                while worker.isBusy(agent.id) { try? await Task.sleep(for: .milliseconds(200)) }
                print("then act: \(await tool("window_act", act).prefix(60)), text changed \(await tool("window_read", [:]).contains("ALPHA changed"))")
                print("other window, no yes: \(await tool("app_window_read", ["title": rest[1]]).prefix(40))")
                print("other document by script: \(await tool("app_script", ["script": "tell application \"\(attachment.appName)\" to get name of document \"\(rest[1])\"", "did": "x", "why": "x"]).prefix(50))")
                withExtendedLifetime(reader) { exit(0) }
            }
        case "stop-test":
            guard ProcessInfo.processInfo.environment["BEAN_SESSION_BINARY"] != nil, rest.count == 2 else { print("usage: BEAN_SESSION_BINARY=<fake> stop-test <worktree> <file counting starts>"); exit(64) }
            Agents.adoptBean(in: store)
            let milo = Agent(id: UUID(), name: "Milo", role: "Fixes code.", look: .init(hue: 0.5, accessory: "none"), attachment: nil, createdAt: Date())
            AgentFolder(milo, in: store).create(agent: milo, bornFrom: .person("Fix code."))
            AgentFolder(milo, in: store).save(AgentMission(mission: milo.role))
            store.save(milo)
            guard let bean = store.agents.first(where: \.isBean) else { exit(1) }
            Task { @MainActor in
                let worker = AgentWorker(store: store, autostart: false)
                let folder = AgentFolder(milo, in: store), sessions = CodingSessions(folder: folder)
                func starts() -> Int { ((try? String(contentsOfFile: rest[1], encoding: .utf8)) ?? "").split(separator: "\n").count }
                @MainActor func settle() async {
                    let began = Date()
                    while worker.sessionsStillMoving, Date().timeIntervalSince(began) < 40 { try? await Task.sleep(for: .milliseconds(200)) }
                }
                @MainActor func states(_ one: AgentWorker) -> String { one.readPlan().steps.map(\.state.rawValue).joined(separator: ",") }
                @MainActor func drive(_ id: String) async {
                    guard let session = sessions.session(id), let mission = folder.mission else { return }
                    let before = starts()
                    worker.startDriving(session, task: "Add docstrings", why: "test", agent: milo, mission: mission, folder: folder)
                    while starts() == before { try? await Task.sleep(for: .milliseconds(100)) }
                    try? await Task.sleep(for: .seconds(1))
                    worker.stopSession(milo.id, session: id)
                }
                let steps = [BeanUnderstanding.Step(what: "Add docstrings", who: "Milo", why: "asked"), BeanUnderstanding.Step(what: "Open a draft pull request", who: "Milo", why: "asked")]
                worker.startPlan(steps, from: "Add docstrings and open a draft pull request")
                let work = worker.stepId(0)
                worker.noteHandOff(of: work, to: milo.id)
                sessions.save(CodingSession(id: "stoptest1", repo: "x/y", branch: "main", worktree: rest[0], task: "Add docstrings", workId: work, startedAt: Date()))
                guard let mission = AgentFolder(bean, in: store).mission else { exit(1) }
                worker.heldPlan = AgentWorker.HeldPlan(mission: mission, situation: HelpSituation(agent: bean, persona: "", mission: mission, trigger: "test", observation: "", journal: []), decision: HelpDecision(help: true, what: "Do the plan"), steps: steps, began: Date(), summary: "started")
                await drive("stoptest1")
                await settle()
                print("after stop: starts \(starts()), session \(sessions.session("stoptest1")?.status?.rawValue ?? ""), plan \(states(worker))")
                print("report: \(AgentFolder(bean, in: store).journal.filter { $0.kind == .replied }.map(\.did))")
                let open = await worker.stepsStillOpen(steps, report: "fake", since: Date().addingTimeInterval(-3600), bean: bean)
                print("plan check, steps open: \(open.count)")
                let hand = worker.beanTools(bean, folder: AgentFolder(bean, in: store)).first { $0.name == "hand_off" }
                let tools = folder.mission.map { worker.sessionTools(milo, $0, folder) } ?? []
                @MainActor func tool(_ label: String, _ one: BrainTool?, _ args: JSONArgs) async {
                    let output = await one?.run(args)
                    print("\(label): ok=\(output?.ok ?? false) \(output?.text.prefix(46) ?? "no tool")")
                }
                @MainActor func attempts() async {
                    await tool("hand_off step 1", hand, ["agent": "Milo", "task": "x", "why": "x", "plan_step": 1])
                    await tool("hand_off step 2", hand, ["agent": "Milo", "task": "x", "why": "x", "plan_step": 2])
                    await tool("hand_off work id", hand, ["agent": "Milo", "task": "x", "why": "x", "work_id": work])
                    await tool("hand_off no id", hand, ["agent": "Milo", "task": "x", "why": "x"])
                }
                await attempts()
                await tool("session_drive continue", tools.first { $0.name == "session_drive" }, ["session": "stoptest1", "task": "x", "why": "x"])
                await tool("session_drive new", tools.first { $0.name == "session_drive" }, ["repo": "x/y", "task": "x", "why": "x", "work_id": work])
                await tool("session_act", tools.first { $0.name == "session_act" }, ["session": "stoptest1", "command": "git status", "did": "x", "why": "x"])
                await worker.planMayBeSettled()
                await settle()
                let relaunched = AgentWorker(store: store, autostart: false)
                relaunched.loadPlan()
                print("after a relaunch: plan \(states(relaunched)), gate \(relaunched.stoppedWorkRefusal(of: [work], by: bean) != nil)")
                print("no restart: starts \(starts())")
                try? await Task.sleep(for: .seconds(1))
                var asked = JournalEntry(kind: .said, did: "Carry on with the docstrings", why: "")
                asked.typed = true
                worker.record(asked, bean)
                await tool("user asked, hand_off step 1", hand, ["agent": "Milo", "task": "x", "why": "x", "plan_step": 1])
                await settle()
                print("user asked: held \(StoppedWork.all(in: store.root).count), plan \(states(worker))")
                await drive("stoptest1")
                await settle()
                print("second stop: starts \(starts()), held \(StoppedWork.all(in: store.root).count), plan \(states(worker))")
                let before = starts()
                worker.resumeSession(milo.id, session: "stoptest1")
                while starts() == before { try? await Task.sleep(for: .milliseconds(100)) }
                print("resume button: starts \(starts()), held \(StoppedWork.all(in: store.root).count)")
                worker.stopSession(milo.id, session: "stoptest1")
                await settle()
                StoppedWork.lift("stoptest1", in: store.root)
                let cameBack = Date()
                try? await Task.sleep(for: .seconds(1))
                folder.append(AgentDecision(kind: .permission, question: "x", answer: "x", why: "x", confidence: 1))
                folder.append(JournalEntry(kind: .action, did: "Opened draft pull request", why: "x"))
                let inWindow = worker.away(milo.id, since: cameBack.addingTimeInterval(-3600), until: cameBack)
                let later = worker.away(milo.id, since: cameBack, until: Date())
                print("away, work after coming back: permissions \(inWindow?.permissionsAnswered ?? -1), then while away: permissions \(later?.permissionsAnswered ?? -1), done \(later?.done.count ?? -1)")
                withExtendedLifetime([worker, relaunched]) { exit(0) }
            }
        case "automation-state":
            for bundle in rest { print("\(bundle): \(AppAutomation.state(of: bundle, ask: false).rawValue)") }
            exit(0)
        case "app-tools":
            guard rest.count >= 1, let window = WindowChannels.open().first(where: { $0.title?.contains(rest[0]) == true }) else { print("usage: app-tools <title> [window.tab ...], windows \(WindowChannels.forModel())"); exit(64) }
            let agent = Agent(id: UUID(), name: "Tester", role: "Tests.", look: .init(hue: 0.5, accessory: "none"), attachment: nil, createdAt: Date())
            let folder = AgentFolder(agent, in: store)
            folder.create(agent: agent, bornFrom: .person("Test."))
            folder.save(AgentMission(mission: agent.role))
            store.save(agent)
            store.attach(agent.id, to: WindowChannels.attachment(for: window))
            let attachment = WindowChannels.attachment(for: window)
            Task { @MainActor in
                let worker = AgentWorker(store: store, autostart: false)
                let tools = worker.windowTools(agent, attachment: attachment, folder: folder)
                func front() -> String { NSWorkspace.shared.frontmostApplication?.localizedName ?? "?" }
                print("front before: \(front()), another Space \(SpaceWindows.isOnAnotherSpace(window.number))")
                let list = await tools.first { $0.name == "app_windows" }?.run([:])
                print("app_windows ok=\(list?.ok ?? false) lines=\(list?.text.split(separator: "\n").count ?? 0)\n\(list?.text.prefix(600) ?? "")")
                let read = await tools.first { $0.name == "window_read" }?.run([:])
                print("window_read ok=\(read?.ok ?? false): \(read?.text.prefix(160) ?? "")")
                for pair in rest.dropFirst() {
                    let parts = pair.split(separator: ".").compactMap { Int($0) }
                    guard parts.count == 2 else { continue }
                    let page = await tools.first { $0.name == "tab_read" }?.run(["window": parts[0], "tab": parts[1]])
                    print("tab_read \(pair) ok=\(page?.ok ?? false) chars=\(page?.text.count ?? 0): \(page?.text.prefix(120) ?? "")")
                }
                let script = tools.first { $0.name == "app_script" }
                for source in ["tell application \"\(attachment.appName)\" to select tab 2 of window 1", "tell application \"\(attachment.appName)\"\nrepeat with w in windows\nget name of w\nend repeat\nend tell"] {
                    print("script: \(await script?.run(["script": source, "did": "x", "why": "x"]).text.prefix(120) ?? "")")
                }
                print("front after: \(front())")
                print("journal: \(folder.journal.map { "\($0.kind.rawValue): \($0.did.prefix(60))" }), questions \(folder.needs.map(\.question))")
                withExtendedLifetime(worker) { exit(0) }
            }
        case "land-real":
            guard rest.count == 2, let window = WindowChannels.open().first(where: { $0.title?.contains(rest[1]) == true }) else { print("usage: land-real <sentence> <title>, windows \(WindowChannels.forModel())"); exit(64) }
            Agents.adoptBean(in: store)
            let reader = WindowReader(store: store)
            Task { @MainActor in
                let worker = reader.worker
                guard let created = try? await AgentMaker().write(rest[0]) else { print("maker failed"); exit(1) }
                AgentMaker.save(created, in: store)
                let id = created.card.id
                print("job: goal \(created.card.job.goal) | gets \(created.card.job.output) | done \(created.card.job.done) | first [\(created.card.job.first)] | quiet \(created.card.job.quiet)")
                store.attach(id, to: WindowChannels.attachment(for: window))
                try? await Task.sleep(for: .seconds(8))
                let began = Date()
                var idle = 0
                while idle < 10, Date().timeIntervalSince(began) < 120 {
                    idle = worker.isBusy(id) ? 0 : idle + 1
                    try? await Task.sleep(for: .seconds(1))
                }
                guard let agent = store.agents.first(where: { $0.id == id }) else { exit(1) }
                let folder = AgentFolder(agent, in: store)
                print("on \(agent.attachment?.appName ?? "nothing"), \(agent.attachment?.windowTitle ?? "")")
                print("bubble: \(store.activity[id]?.bubble ?? "none")")
                print("questions: \(store.agents.flatMap { AgentFolder($0, in: store).needs.map(\.question) })")
                print("replied: \(store.agents.flatMap { AgentFolder($0, in: store).journal.filter { $0.kind == .replied }.map(\.did) })")
                print("journal: \(folder.journal.map { "\($0.kind.rawValue): \($0.did.prefix(80))" })")
                withExtendedLifetime(reader) { exit(0) }
            }
        case "follow-test":
            guard rest.count == 2, let first = WindowChannels.open().first(where: { $0.title?.contains(rest[0]) == true }), let second = WindowChannels.open().first(where: { $0.title?.contains(rest[1]) == true }) else { print("usage: follow-test <sits on> <other>, windows \(WindowChannels.forModel())"); exit(64) }
            let agent = Agent(id: UUID(), name: "Tester", role: "Tests.", look: .init(hue: 0.5, accessory: "none"), attachment: nil, createdAt: Date())
            let folder = AgentFolder(agent, in: store)
            folder.create(agent: agent, bornFrom: .person("Test."))
            folder.save(AgentMission(mission: agent.role))
            store.save(agent)
            let reader = WindowReader(store: store)
            store.attach(agent.id, to: WindowChannels.attachment(for: first))
            Task { @MainActor in
                @MainActor func say(_ line: String) { print("\(line): on \(store.agents.first { $0.id == agent.id }?.attachment?.windowTitle ?? "nothing")") }
                func landings() -> Int { ((try? String(contentsOf: JSONLog.directory.appendingPathComponent("agents.jsonl"), encoding: .utf8)) ?? "").components(separatedBy: "\"event\":\"landed\"").count - 1 }
                try? await Task.sleep(for: .seconds(8))
                say("landed \(landings()) time")
                let app = first.app
                let edit = await AppActions.runScript("tell application \"\(app)\" to set text of document \"\(rest[1])\" to \"changed elsewhere in the app\"")
                print("changed the other document: \(edit.ok)")
                try? await Task.sleep(for: .seconds(28))
                store.attach(agent.id, to: WindowChannels.attachment(for: second))
                try? await Task.sleep(for: .seconds(6))
                say("moved inside the app, landed \(landings()) time")
                store.attach(agent.id, to: WindowChannels.attachment(for: first))
                try? await Task.sleep(for: .seconds(6))
                _ = await AppActions.runScript("tell application \"\(app)\" to close document \"\(rest[0])\" saving no")
                try? await Task.sleep(for: .seconds(14))
                say("its window closed, landed \(landings()) time")
                _ = await AppActions.runScript("tell application \"\(app)\" to close document \"\(rest[1])\" saving no")
                try? await Task.sleep(for: .seconds(14))
                say("the last window closed")
                print("said: \(folder.journal.filter { $0.kind == .replied }.map(\.did))")
                withExtendedLifetime(reader) { exit(0) }
            }
        case "watch-test":
            guard rest.count == 3, let first = WindowChannels.open().first(where: { $0.title == rest[0] }) else { print("usage: watch-test <sits on> <other> <file>, windows \(WindowChannels.forModel())"); exit(64) }
            let agent = Agent(id: UUID(), name: "Tester", role: "Tests.", look: .init(hue: 0.5, accessory: "none"), attachment: nil, createdAt: Date())
            let folder = AgentFolder(agent, in: store)
            folder.create(agent: agent, bornFrom: .person("Test."))
            folder.save(AgentMission(mission: agent.role))
            store.save(agent)
            let reader = WindowReader(store: store)
            let attachment = WindowChannels.attachment(for: first)
            store.attach(agent.id, to: attachment)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(9))
                print("others seen: \(WindowSnapshot.others(of: attachment).map { "\($0.title ?? "untitled"): \($0.text.prefix(30))" })")
                try? "BETA document\nA new line in the other window".write(toFile: rest[2], atomically: true, encoding: .utf8)
                try? await Task.sleep(for: .seconds(28))
                let rows = (try? String(contentsOf: JSONLog.directory.appendingPathComponent("work.jsonl"), encoding: .utf8)) ?? ""
                print("change events: \(rows.split(separator: "\n").filter { $0.contains("windowChanged") }.map { $0.prefix(120) })")
                print("journal \(folder.journal.count), questions \(folder.needs.count)")
                withExtendedLifetime(reader) { exit(0) }
            }
        case "user-session":
            guard let session = UserSessions.latest() else { print("user-session: none"); exit(0) }
            print("user-session: \(session.id) \(session.title)")
            for status in ["none", "idle", "busy"] {
                print("listed \(status): \(UserSessions.state(of: session, listed: status == "none" ? nil : ["status": status]))")
            }
            exit(0)
        case "plan-test":
            guard rest.count == 1, let agent = store.agents.first(where: { $0.name == rest[0] }), let bean = store.agents.first(where: \.isBean) else { print("usage: plan-test <agent-name>, after adopt-bean"); exit(64) }
            Task { @MainActor in
                let worker = AgentWorker(store: store, autostart: false)
                @MainActor func say(_ when: String, _ one: AgentWorker) {
                    one.refresh()
                    print("\(when): \(one.plan.map { "\($0.id) \($0.state.rawValue) \($0.owner) agent=\($0.agent != nil)" }) current=\(one.agentSteps.count)")
                }
                worker.startPlan([BeanUnderstanding.Step(what: "Say ok", who: "new agent", why: "test"), BeanUnderstanding.Step(what: "Say hello", who: "new agent", why: "test"), BeanUnderstanding.Step(what: "Note it in the tracker", who: "Bean", why: "test")], from: "test")
                "planned"
                let hand = worker.beanTools(bean, folder: AgentFolder(bean, in: store)).first { $0.name == "hand_off" }
                let output = await hand?.run(["agent": agent.name, "task": "Finish now with the single word ok.", "plan_step": 2, "why": "test"])
                print("hand_off: \(output?.text.prefix(160) ?? "")")
                "handed off"
                let relaunched = AgentWorker(store: store, autostart: false)
                "after relaunch"
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
        guard let id = args.first.flatMap(UUID.init(uuidString:)), let agent = store.agents.first(where: { $0.id == id }), args.count > 2 else {
            print("usage: guard <agent-id> read|write|undo <command>")
            exit(64)
        }
        if args[1] == "session" {
            let check = Perimeter(folder: AgentFolder(agent, in: store)).reaching("", worktree: AgentFolder(agent, in: store).url, unknownAllowed: true)
            let command = args[2...].joined(separator: " ")
            print(check.inWorkingCopy(command) ?? check.refusal(.shell(command, .write)) ?? "allowed")
            exit(0)
        }
        let mode: ActionGuard.Mode = args[1] == "read" ? .read : args[1] == "undo" ? .undo : .write
        print("\(Perimeter(folder: AgentFolder(agent, in: store)).refusal(.shell(args[2...].joined(separator: " "), mode)) ?? "allowed")")
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
            print("--- AGENT.md\n" + (folder.card?.text ?? "missing"))
            
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
        print("model problem: \(worker.modelProblem ?? "none")")
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
        guard args.count == 3, let id = UUID(uuidString: args[0]), let agent = store.agents.first(where: { $0.id == id }) else {
            print("usage: guard-tool <agent-id> <server__tool> '<json>'")
            exit(64)
        }
        let ability = AgentFolder(agent, in: store).abilities.first { $0.id == args[1] }
        print(Perimeter(folder: AgentFolder(agent, in: store)).refusal(.connector(name: args[1], arguments: args[2], ability: ability)) ?? "allowed")
        exit(0)
    }

    private static func adoptBean(store: AgentStore) {
        Agents.adoptBean(in: store)
        let bean = store.agents.first(where: \.isBean)
        let worker = AgentWorker(store: store, autostart: false)
        print(bean.flatMap { AgentFolder($0, in: store).card?.text.prefix(700) } ?? "no card")
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
            print(String(format: "away: %d decided, %d permissions, %d waiting, %d done", summary.decided.count, summary.permissionsAnswered, summary.waiting.count, summary.done.count))
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
            fflush(stdout)
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
                    "drive: \(output?.ok ?? false) \(output?.text.prefix(120) ?? "")"
                case "until-step":
                    while current()?.step == nil || current()?.step == "Starting" { try? await Task.sleep(for: .milliseconds(100)) }
                    "step: \(current()?.step ?? "")"
                case "send":
                    let text = steps.popFirst() ?? ""
                    "send: \(worker.sendToSession(agent.id, session: current()?.id ?? "", text: text) ?? "accepted")"
                case "answer":
                    let text = steps.popFirst() ?? ""
                    guard let need = folder.needs.first(where: { $0.session == current()?.id }) else { "no question open"; continue }
                    "question: \(need.question)"
                    worker.answer(agent.id, need: need.id, text)
                    try? await Task.sleep(for: .seconds(1))
                case "until":
                    let wanted = steps.popFirst() ?? ""
                    while current()?.status?.rawValue != wanted { try? await Task.sleep(for: .milliseconds(100)) }
                    "status: \(wanted), step \(current()?.step ?? "")"
                case "quiet":
                    while worker.sessionsStillMoving { try? await Task.sleep(for: .milliseconds(200)) }
                    "quiet: \(current()?.status?.rawValue ?? "") \(current()?.step ?? "") branch \(current()?.branch ?? "") pr \(current()?.pullRequest ?? "none") cost \(current()?.costUSD ?? 0)"
                case "show":
                    worker.refresh()
                    for event in worker.sessionEvents[current()?.id ?? ""] ?? [] { "  \(event.id) \(event.kind.rawValue) \(event.tool ?? "") \(event.toolState?.rawValue ?? "") | \(event.text.prefix(70).replacingOccurrences(of: "\n", with: " ")) => \((event.output ?? "").prefix(50).replacingOccurrences(of: "\n", with: " "))" }
                    "needs: \(folder.needs.map(\.question))"
                case "changes":
                    let changes = await worker.sessionChanges(agent.id, session: current()?.id ?? "")
                    "changes: \(changes?.files ?? []), pr \(String(describing: changes?.pullRequest)), diff \(changes?.diff.count ?? 0) chars"
                case "take-over":
                    let over = await worker.takeOver(agent.id, session: current()?.id ?? "")
                    "take-over: \(String(describing: over)), status \(current()?.status?.rawValue ?? "")"
                case "end-take-over":
                    worker.endTakeOver(agent.id, session: current()?.id ?? "")
                    while current()?.status != .handedBack { try? await Task.sleep(for: .milliseconds(100)) }
                    "handed back: \(current()?.branch ?? "") pr \(current()?.pullRequest ?? "none")"
                default: "unknown step \(step)"
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
