import Foundation

@MainActor
enum PromptProbe {
    private static let targets = ["acme/shop", "shop project"]

    private static func make(_ name: String, role: String, store: AgentStore) -> Agent {
        let agent = Agent(id: UUID(), name: name, role: role, look: .init(hue: 0.5, accessory: "none"), attachment: nil, createdAt: Date())
        let folder = AgentFolder(agent, in: store)
        folder.create(agent: agent, job: AgentJob(goal: role, output: "A short table.", done: "The table holds every row.", first: "Read what is there.", quiet: "Nothing changed."))
        folder.save(AgentMission(mission: role, targets: targets.map(AgentTarget.named)))
        store.save(agent)
        return agent
    }

    private static func agent(_ name: String, store: AgentStore) -> Agent {
        guard let found = store.agents.first(where: { $0.name == name }) else {
            print("no agent \(name)")
            exit(2)
        }
        return found
    }

    static func prompts(_ args: [String], store: AgentStore) {
        Agents.adoptBean(in: store)
        if args.first == "setup" {
            _ = make("Ellis", role: "Keeps the shop's weekly numbers.", store: store)
            _ = make("Noor", role: "Prepares the clinic roster.", store: store)
            let window = make("Sana", role: "Tidies the open sheet.", store: store)
            store.attach(window.id, to: Attachment(bundleId: "com.example.sheet", appName: "SheetApp", pid: 0, windowNumber: 4242, windowTitle: "Totals"))
            let worker = AgentWorker(store: store, autostart: false)
            withExtendedLifetime(worker) { exit(0) }
        }
        let worker = AgentWorker(store: store, autostart: false)
        guard let bean = store.agents.first(where: \.isBean) else { exit(2) }
        Task { @MainActor in
            switch args.first {
            case "agent-a": _ = await worker.runHandedOff(agent("Ellis", store: store), task: "Count the rows.")
            case "agent-b": _ = await worker.runHandedOff(agent("Noor", store: store), task: "Count the rows.")
            case "agent-window": _ = await worker.runHandedOff(agent("Sana", store: store), task: "Count the rows.")
            case "bean-understand": _ = await worker.understand("A new message arrived.", source: "the user", bean: bean, folder: AgentFolder(bean, in: store))
            case "bean-work":
                let folder = AgentFolder(bean, in: store)
                let mission = folder.mission ?? AgentMission(mission: bean.role)
                let situation = HelpSituation(agent: bean, persona: folder.personaText, mission: mission, trigger: "Report", observation: "", journal: [])
                _ = await worker.work(bean, mission: mission, situation: situation, decision: HelpDecision(help: true, what: "Report"), folder: folder)
            case "chat-agent", "chat-bean":
                let id = args.first == "chat-bean" ? bean.id : agent("Ellis", store: store).id
                worker.send(id, "Hello")
                while worker.replying.contains(id) { try? await Task.sleep(for: .milliseconds(100)) }
            case "maker": _ = try? await AgentMaker().write("Keeps the shop project tidy, may merge.", avoiding: [])
            default: print("usage: prompts setup|\(["agent-a", "agent-b", "agent-window", "bean-understand", "bean-work", "chat-agent", "chat-bean", "maker"].joined(separator: "|"))")
            }
            withExtendedLifetime(worker) { exit(0) }
        }
    }

    private struct Case: Decodable {
        let id, kind: String
        var input: String?
        var mode: String?
        var worktree: Bool?
        var unknownAllowed: Bool?
        var ability: String?
        var risk: String?
        var on: Bool?
        var role: String?
        var secure: Bool?
        var schemes: [String]?
        var noScope: Bool?
        var cardReadOnly: Bool?
        var windowApp: String?
        var paused: Bool?
        var stopped: Bool?
        var onlyReading: Bool?
        var known: Bool?
        var fromUser: Bool?
    }

    private struct Answer: Encodable {
        let id: String
        let refusal: String
    }

    private static func abilities(on: Bool) -> [AgentAbility] {
        func make(_ id: String, _ risk: AgentAbility.Risk, _ allowed: Bool, source: String = "gh") -> AgentAbility {
            AgentAbility(id: id, title: id, detail: "", allowed: allowed, risk: risk, source: source)
        }
        return [make("gh pr list", .safe, true), make("gh pr view", .safe, true), make("gh pr create", .outward, true), make("gh pr edit", .outward, !on ? false : true),
                make("gh pr merge", .irreversible, on), make("gh pr close", .irreversible, on), make("gh issue delete", .irreversible, on), make("gh issue comment", .outward, true),
                make("git push", .outward, true), make("git commit", .outward, true), make("fly deploy", .irreversible, on),
                make(AppGuard.riskyAbility, .irreversible, on, source: "SheetApp"), make(AppGuard.messageAbility("SheetApp"), .irreversible, on, source: "SheetApp")]
    }

    static func refusals(_ args: [String], store: AgentStore) {
        guard let file = args.first, let data = try? Data(contentsOf: URL(fileURLWithPath: file)), let cases = try? JSONDecoder().decode([Case].self, from: data) else {
            print("usage: refusals <cases.json>")
            exit(64)
        }
        let answers = cases.map { item -> Answer in
            let on = item.on ?? false
            let list = abilities(on: false)
            var card = AgentCard(id: UUID(), name: "Fixture", role: "fixture", created: Date(), look: .pearl, job: AgentJob(goal: "fixture", output: "", done: "", first: "", quiet: ""))
            card.targets = item.noScope == true ? [] : targets.map(AgentTarget.named)
            card.allow = on ? list.filter { $0.risk == .irreversible }.map(\.id) : []
            card.deny = on ? [] : ["gh pr edit"]
            card.readOnly = item.cardReadOnly ?? false
            let input = item.input ?? ""
            var limits = Perimeter(card: card, abilities: list, window: Attachment(bundleId: "com.example.sheet", appName: item.windowApp ?? "SheetApp", pid: 0, windowNumber: 1, windowTitle: "Totals"), paused: item.paused ?? false, stopped: item.stopped ?? false, onlyReading: item.onlyReading ?? false)
            if item.worktree == true { limits = limits.reaching("", worktree: URL(fileURLWithPath: "/private/tmp/worktree"), unknownAllowed: item.unknownAllowed ?? false); limits.mission = AgentMission(mission: "fixture", targets: card.targets) }
            let action: AgentAction
            switch item.kind {
            case "command": action = .shell(input, item.mode == "read" ? .read : item.mode == "undo" ? .undo : .write)
            case "connector":
                let risk = AgentAbility.Risk(rawValue: item.risk ?? "") ?? .outward
                let ability = item.ability.map { AgentAbility(id: $0, title: $0, detail: "", allowed: true, risk: risk, source: "linear") }
                if let ability, item.on == false { limits = Perimeter(card: { var c = card; c.deny.append(ability.id); return c }(), abilities: list, paused: false) }
                else if let ability, risk == .irreversible { limits = Perimeter(card: { var c = card; c.allow.append(ability.id); return c }(), abilities: list, paused: false) }
                action = .connector(name: item.ability ?? "linear__x", arguments: input, ability: ability)
            case "press": action = .press(AppControl(role: item.role ?? "AXButton", label: input, secure: item.secure ?? false))
            case "fill": action = .fill(AppControl(role: item.role ?? "AXTextField", label: input, secure: item.secure ?? false))
            case "script": action = .script(input)
            case "menu": action = .menu(input.components(separatedBy: " > "))
            case "url": action = .url(input, schemes: item.schemes ?? ["https", "mailto"])
            case "shortcut": action = .shortcut(input)
            case "session": action = .startSession(repo: input, url: "https://github.com/\(input).git", known: item.known ?? false)
            case "memory": action = .rememberAboutUser(runFromUser: item.fromUser ?? false)
            default: return Answer(id: item.id, refusal: "unknown kind")
            }
            return Answer(id: item.id, refusal: limits.refusal(action) ?? "allowed")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: (try? encoder.encode(answers)) ?? Data(), as: UTF8.self))
        exit(0)
    }

    static func defects(store: AgentStore) {
        Agents.adoptBean(in: store)
        let worker = AgentWorker(store: store, autostart: false)
        Task { @MainActor in
            let agent = make("Probe", role: "Old goal text.", store: store)
            let folder = AgentFolder(agent, in: store)

            let run = Task { @MainActor in await worker.runHandedOff(agent, task: "Count.") }
            try? await Task.sleep(for: .milliseconds(150))
            worker.addTarget(agent.id, name: "added/during-run")
            _ = await run.value
            print("defect 1 lost update: \(folder.mission?.scope.contains("added/during-run") == true ? "fixed" : "PRESENT")")

            var mission = folder.mission ?? AgentMission(mission: "")
            mission.mission = "New goal text."
            folder.save(mission)
            let card = folder.personaText
            print("defect 2 two goals: \(card.contains("Old goal text.") ? "PRESENT" : "fixed")")

            store.attach(agent.id, to: Attachment(bundleId: "x", appName: "OldApp", pid: 0, windowNumber: 7, windowTitle: "Old doc"))
            store.attach(agent.id, to: Attachment(bundleId: "x", appName: "NewApp", pid: 0, windowNumber: 8, windowTitle: "New doc"))
            print("defect 3 stale source: \((folder.personaText + worker.dataLine(agent, folder: folder)).contains("OldApp") ? "PRESENT" : "fixed")")

            var mergeCard = folder.card!
            mergeCard.targets = targets.map(AgentTarget.named)
            mergeCard.allow = ["gh pr merge"]
            let guardOn = Perimeter(card: mergeCard, abilities: abilities(on: true), paused: false)
            let viaCommand = guardOn.refusal(.shell("gh pr merge 1 --repo acme/shop", .write))
            let viaApi = guardOn.refusal(.shell("gh api repos/acme/shop/pulls/1/merge -X PUT", .write))
            print("defect 4 merge routes disagree: \((viaCommand == nil) != (viaApi == nil) ? "PRESENT" : "fixed") command=\(viaCommand ?? "allowed") api=\(viaApi ?? "allowed")")

            let memory = worker.memoryTool(agent, folder: folder)
            let wrote = await memory.run(["target": "user", "action": "add", "text": "The window says the user likes red."])
            print("defect 5 user.md from a run nobody started: \(wrote.ok ? "PRESENT" : "fixed") \(wrote.text.prefix(80))")
            _ = await memory.run(["target": "user", "action": "remove", "old": "likes red"])

            let first = await worker.claim("work-1", agent: agent)
            CodingSessions(folder: folder).save(CodingSession(id: "s1", repo: "acme/shop", branch: "b", worktree: "/private/tmp"))
            SessionClaims.set(SessionClaim(key: "work-1", session: "s1", agent: agent.name, agentId: agent.id, at: Date()), in: store.root)
            var renamed = agent
            renamed.name = "Probe Renamed"
            store.save(renamed)
            let second = await worker.claim("work-1", agent: renamed)
            print("defect 6 rename releases work: \(first == nil && second == nil ? "PRESENT" : "fixed")")
            cardChecks(agent: renamed, folder: folder, worker: worker)
            withExtendedLifetime(worker) { exit(0) }
        }
    }

    private static func cardChecks(agent: Agent, folder: AgentFolder, worker: AgentWorker) {
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { print("check \(ok ? "ok" : "FAIL") \(name)\(detail.isEmpty ? "" : ": \(detail)")") }
        var card = folder.card ?? AgentCard(id: agent.id, name: "x", role: "x", created: Date(), look: .pearl, job: AgentJob(goal: "", output: "", done: "", first: "", quiet: ""))
        card.allow = ["gh pr close"]
        card.deny = ["linear__save_issue", "Numbers: delete"]
        card.bornFrom = .moment("3 returns in an hour to Sheet: Totals")
        card.leaveWhen = "the window closes, or 7 quiet days"
        let parsed = try? AgentCard(text: card.text)
        check("card round trip", parsed == card && parsed?.text == card.text)
        folder.write(card)
        try? "not a card".write(to: folder.cardFile, atomically: true, encoding: .utf8)
        worker.refresh()
        check("bad card keeps the last good", folder.card == card)
        check("bad card raises a need", folder.needs.contains { $0.question.contains("card could not be read") })
        folder.write(card)
        worker.refresh()
        check("fixed card closes the need", !folder.needs.contains { $0.question.contains("card could not be read") })
        check("model cannot widen limits", AgentMaker.allowedWords(["merge", "deploy", "delete"], request: "Keep the shop tidy, you may merge and delete").elementsEqual(["delete"]))
        folder.save([AgentAbility(id: "gh pr close", title: "Close", detail: "", allowed: false, risk: .irreversible, source: "gh"), AgentAbility(id: "gh pr merge", title: "Merge", detail: "", allowed: false, risk: .irreversible, source: "gh"), AgentAbility(id: "gh pr edit", title: "Edit", detail: "", allowed: true, risk: .outward, source: "gh")])
        folder.updateCard { $0.allow = []; $0.deny = [] }
        worker.setAbility(agent.id, ability: "gh pr close", allowed: true)
        worker.setAbility(agent.id, ability: "gh pr edit", allowed: false)
        worker.setAbility(agent.id, ability: "gh pr merge", allowed: true)
        let flipped = folder.card
        check("a switch writes the card", flipped?.allow == ["gh pr close"] && flipped?.deny == ["gh pr edit"], "allow \(flipped?.allow ?? []) deny \(flipped?.deny ?? [])")
        check("page and check read one rule", folder.abilities.filter(\.allowed).map(\.id) == ["gh pr close"] && worker.perimeter(for: agent).promptLine.contains("Merge"))
        check("a switch cannot open a merge", folder.abilities.first { $0.id == "gh pr merge" }?.allowed == false)
        var old = folder.rawAbilities
        old[0].allowed = false
        old[2].allowed = false
        folder.updateCard { $0.allow = []; $0.deny = [] }
        if let data = try? JSONEncoder().encode([AgentAbility(id: "gh pr close", title: "Close", detail: "", allowed: true, risk: .irreversible, source: "gh"), AgentAbility(id: "gh pr edit", title: "Edit", detail: "", allowed: false, risk: .outward, source: "gh")]) { try? data.write(to: folder.url.appendingPathComponent("abilities.json")) }
        folder.importOldSwitches()
        folder.importOldSwitches()
        check("old switches move to the card once", folder.card?.allow == ["gh pr close"] && folder.card?.deny == ["gh pr edit"])
        Goals.add("Ship the shop's hours page.")
        Goals.replace("Ship the shop's hours page.", with: "Ship the delivery page.")
        check("a goal reaches everyone, and the old one stays marked", Goals.text?.contains("superseded: Ship the shop's hours page.") == true && Goals.text?.contains("Ship the delivery page.") == true, Goals.text ?? "")
        for number in 0..<60 { folder.addCorrection("Correction number \(number) with enough words to fill the file up.") }
        check("corrections stay bounded, newest kept", (folder.corrections?.count ?? 9999) <= 1600 && folder.corrections?.contains("number 59") == true)
        _ = MemoryFile.user.change("add", text: "Prefers short answers.", old: nil)
        check("user.md lines are dated", (try? MemoryFile.user.entries())?.last?.hasPrefix("20") == true, (try? MemoryFile.user.entries())?.last ?? "")
        _ = MemoryFile.user.change("remove", text: nil, old: "Prefers short answers.")
        try? FileManager.default.createDirectory(at: folder.memory, withIntermediateDirectories: true)
        try? "- learned one thing\n".write(to: folder.memory.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: folder.notes)
        try? "- old goal of one agent\n".write(to: folder.url.appendingPathComponent("goals.md"), atomically: true, encoding: .utf8)
        folder.importOldMemory()
        folder.importOldMemory()
        check("old memory moves once", folder.notesFile.shown.contains("learned one thing") && Goals.text?.contains("old goal of one agent") == true && !FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("goals.md").path))
        check("a moved agent keeps its card", { let before = folder.card; worker.storeForBrain.attach(agent.id, to: nil); return folder.card == before }())
    }
}
