import Foundation

@MainActor
enum PromptProbe {
    private static let targets = ["acme/shop", "shop project"]

    private static func make(_ name: String, role: String, store: AgentStore) -> Agent {
        let agent = Agent(id: UUID(), name: name, role: role, personality: "Careful and brief.", look: .init(hue: 0.5, accessory: "none"), connectors: [], attachment: nil, createdAt: Date())
        let folder = AgentFolder(agent, in: store)
        try? folder.create(agent: agent, voice: "Short, factual sentences.", lines: AgentLines(greeting: "Ready.", offLimits: "That is off limits."),
                           job: AgentJob(goal: role, output: "A short table.", done: "The table holds every row.", first: "Read what is there.", quiet: "Nothing changed."))
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
            let list = abilities(on: item.on ?? false)
            let mission = AgentMission(mission: "fixture", targets: item.noScope == true ? [] : targets.map(AgentTarget.named))
            let input = item.input ?? ""
            let found: String?
            switch item.kind {
            case "command":
                let mode: ActionGuard.Mode = item.mode == "read" ? .read : item.mode == "undo" ? .undo : .write
                found = ActionGuard(mission: mission, worktree: item.worktree == true ? URL(fileURLWithPath: "/private/tmp/worktree") : nil, abilities: list, unknownAllowed: item.unknownAllowed ?? false).refusal(input, mode: mode)
            case "connector":
                let risk = AgentAbility.Risk(rawValue: item.risk ?? "") ?? .outward
                let ability = item.ability.map { AgentAbility(id: $0, title: $0, detail: "", allowed: item.on ?? true, risk: risk, source: "linear") }
                found = AgentWorker.connectorRefusal(ability: ability, name: item.ability ?? "linear__x", arguments: input, mission: mission)
            case "press":
                found = AppGuard.refusal(control: AppControl(role: item.role ?? "AXButton", label: input, secure: item.secure ?? false), action: "press") ?? AppGuard.pressRefusal(role: item.role ?? "AXButton", label: input, abilities: list)
            case "fill":
                found = AppGuard.refusal(control: AppControl(role: item.role ?? "AXTextField", label: input, secure: item.secure ?? false), action: "fill")
            case "script": found = WindowChannels.refusal(script: input, app: "SheetApp", abilities: list)
            case "menu": found = AppGuard.refusal(menu: input.components(separatedBy: " > "), abilities: list)
            case "url": found = AppGuard.refusal(url: input, schemes: item.schemes ?? ["https", "mailto"], app: "SheetApp", abilities: list)
            default: found = "unknown kind"
            }
            return Answer(id: item.id, refusal: found ?? "allowed")
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

            let list = abilities(on: true)
            let guardOn = ActionGuard(mission: AgentMission(mission: "x", targets: targets.map(AgentTarget.named)), abilities: list)
            let viaCommand = guardOn.refusal("gh pr merge 1 --repo acme/shop", mode: .write)
            let viaApi = guardOn.refusal("gh api repos/acme/shop/pulls/1/merge -X PUT", mode: .write)
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
            withExtendedLifetime(worker) { exit(0) }
        }
    }
}
