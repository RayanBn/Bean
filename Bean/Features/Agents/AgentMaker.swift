import Foundation

struct AgentProposal: Codable, Identifiable, Equatable {
    var id: String { name }
    let name: String
    let label: String
    let role: String
    let pitch: String

    var request: String { "\(name): \(role) \(pitch)" }
}

struct AgentMaker {
    struct Created {
        var card: AgentCard
        let source: Source
        var agent: Agent { card.agent(attachment: nil) }
    }

    struct Source: Decodable {
        enum Kind: String, Decodable { case window, connected, connect, ask, none }
        let kind: Kind
        let window: Int
        let service: String
        let ask: String
        let named: Bool
    }

    enum MakerError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            if case let .unreadable(text) = self { return "Muse Spark's answer was not readable: \(text.prefix(200))" }
            return nil
        }
    }

    let client = ModelClient()

    func propose(from inventory: MacInventory) async throws -> [AgentProposal] {
        let system = """
        You are Bean, a small creature that lives in the Mac's notch and makes agents for its user. \
        An agent gives its user one kind of result and works in the background. Anyone can use Bean, not only developers. \
        Look at the apps on this Mac only to guess what kind of work this user does, then propose 3 different kinds of helpers that fit them. \
        For each agent give a short neutral name, a label of two or three words, at most 20 characters, that says what it does (like "Keeps PRs moving"), \
        its role in one sentence, and a one-line pitch on why it fits this user, in plain professional words. \
        Never name an app, never say where the agent lives, and never tie it to a tool or service.
        """
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["agents"],
            "properties": ["agents": ["type": "array", "items": [
                "type": "object", "additionalProperties": false, "required": ["name", "label", "role", "pitch"],
                "properties": ["name": ["type": "string"], "label": ["type": "string"], "role": ["type": "string"], "pitch": ["type": "string"]],
            ]]],
        ]
        struct Output: Decodable { let agents: [AgentProposal] }
        let output: Output = try await ask(system: system, text: inventory.summary, schema: schema)
        return Array(output.agents.prefix(3))
    }

    func write(_ request: String, avoiding names: [String] = [], reality: String? = nil) async throws -> Created {
        let source = reality.map { """
        - source: where the real data for this job is, chosen from what is really there, below. window, with its number, if an open window clearly holds that data: never only because it is open. connected, with its name, if a connected service does. connect, with its catalogue id, if a service not connected yet would. ask, if the job needs data that none of these holds, with one plain question saying what it needs and asking the user to open or give it. none if the job can start without such data. window is 0, service and ask are empty when unused. named is true only if the request itself names that window's document or app.
        What is really there:
        \($0)
        """ } ?? "- source: kind none, window 0, service and ask empty, named false."
        let system = """
        You are Bean, a small creature that lives in the Mac's notch and makes agents for its user. Write the agent the user asks for.
        - name: a short, neutral first name\(names.isEmpty ? "" : ", not one of \(names.joined(separator: ", "))").
        - role: what it does, in a few plain words, at most 60 characters.
        - goal: the person's own words for what they want, kept as they said them, as one sentence. Add no step, test, sample or sending they did not ask for. Say how it works or where it lives only if they said so.
        - output: what they receive each time, concretely, such as a short table or a draft to approve. One line.
        - done: how to tell one result is finished and right, as something that can be checked, holding only what they asked for. One line.
        - quiet: when it says nothing, because there is nothing worth saying. One line.
        - accessory: one of \(Agent.Look.accessories.joined(separator: ", ")).
        - targets: the exact names of every repo, project, team or ticket the user named and nothing else, copied as written. kind is repo for owner/name, otherwise project. Empty if the user named none. Never invent one, and never list a window, a document, a file, or a service or app itself.
        - explicitly_allowed: words for irreversible actions the user explicitly allows, like deploy. Usually empty. Merging code is never allowed.
        \(source)
        Write in English, whatever language the request is in.
        """
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "required": ["source", "name", "role", "goal", "output", "done", "quiet", "accessory", "targets", "explicitly_allowed"],
            "properties": [
                "name": ["type": "string"], "role": ["type": "string"], "goal": ["type": "string"], "output": ["type": "string"], "done": ["type": "string"], "quiet": ["type": "string"],
                "accessory": ["type": "string", "enum": Agent.Look.accessories],
                "explicitly_allowed": ["type": "array", "items": ["type": "string"]],
                "source": ["type": "object", "additionalProperties": false, "required": ["kind", "window", "service", "ask", "named"], "properties": [
                    "kind": ["type": "string", "enum": ["window", "connected", "connect", "ask", "none"]], "window": ["type": "integer"], "service": ["type": "string"], "ask": ["type": "string"], "named": ["type": "boolean"],
                ]],
                "targets": ["type": "array", "items": ["type": "object", "additionalProperties": false, "required": ["kind", "name"],
                                                       "properties": ["kind": ["type": "string", "enum": ["repo", "project"]], "name": ["type": "string"]]]],
            ],
        ]
        struct Output: Decodable {
            struct Target: Decodable { let kind, name: String }
            let name, role, goal, output, done, quiet, accessory: String
            let targets: [Target]
            let explicitly_allowed: [String]
            let source: Source
        }
        let output: Output = try await ask(system: system, text: "The user wants: \(request)", schema: schema)
        let accessory = Agent.Look.accessories.contains(output.accessory) ? output.accessory : "none"
        let targets = output.targets.filter { AgentTarget.namesService($0.name, in: request) }.compactMap { target -> AgentTarget? in
            let name = target.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, request.lowercased().contains(name.lowercased()), OffLimits.match(name) == nil else { return nil }
            return AgentTarget(kind: target.kind == "repo" ? .repo : .project, name: name)
        }
        var card = AgentCard(id: UUID(), name: output.name, role: output.role, created: Date(), look: .init(hue: Agent.Look.hues[0], accessory: Agent.Look.accessories.contains(output.accessory) ? output.accessory : "none"),
                             job: AgentJob(goal: output.goal, output: output.output, done: output.done, quiet: output.quiet))
        card.targets = targets
        card.allow = Self.allowedWords(output.explicitly_allowed, request: request)
        card.bornFrom = .person(request)
        return Created(card: card, source: output.source)
    }

    // The model can only propose what is allowed: a word counts only if the person said it and it names an irreversible action. Merging code never does.
    static func allowedWords(_ words: [String], request: String) -> [String] {
        words.filter { request.lowercased().contains($0.lowercased()) && AbilityFinder.irreversible($0) && $0.lowercased() != "merge" }.map { $0.lowercased() }
    }

    @MainActor static func save(_ created: Created, in store: AgentStore) {
        AgentFolder(created.agent, in: store).write(created.card)
        store.save(created.agent)
    }

    private func ask<T: Decodable>(system: String, text: String, schema: [String: Any]) async throws -> T {
        var last = ""
        for _ in 0..<2 {
            let reply = try await client.json(system: system, text: text, schema: schema, effort: "low")
            last = reply.text ?? ""
            if let output = try? JSONDecoder().decode(T.self, from: Data(last.utf8)) { return output }
        }
        throw MakerError.unreadable(last)
    }
}

extension AgentWorker {
    // The one way an agent gets made, for the person, the drag, Bean and an observed moment alike.
    // stayQuiet fills the job's "Stay quiet when" from an offer's result. leaveWhen is how a placed agent gets out.
    @MainActor
    func createAgent(from sentence: String, bornFrom: AgentCard.BornFrom, on window: OpenWindow? = nil, stayQuiet: String? = nil, leaveWhen: String = "", readOnly: Bool = false, reality: String? = nil) async throws -> Agent {
        let store = storeForBrain
        let names = store.agents.map(\.name)
        var created = try await AgentMaker().write(sentence, avoiding: names, reality: reality)
        if names.contains(created.card.name) {
            var number = 2
            while names.contains("\(created.card.name) \(number)") { number += 1 }
            created.card.name = "\(created.card.name) \(number)"
        }
        created.card.look.hue = Agent.Look.nextHue(taken: store.agents.filter { !$0.isBean }.map(\.look.hue))
        created.card.bornFrom = bornFrom
        created.card.leaveWhen = leaveWhen
        created.card.readOnly = readOnly
        if let stayQuiet { created.card.job.quiet = stayQuiet }
        AgentMaker.save(created, in: store)
        if let window { place(created.agent, on: window) }
        return store.agents.first { $0.id == created.card.id } ?? created.agent
    }

    static func reality(in store: AgentStore, catalogue: Bool = true) async -> String {
        let connected = Set(await Tools.shared.all(context: "", folder: nil).filter { $0.name.contains("__") }.compactMap { $0.name.components(separatedBy: "__").first }).sorted()
        let held = Set(store.agents.compactMap { $0.attachment?.bundleId })
        let windows = await WindowChannels.visibleToBean().map { "- \($0.line)\(held.contains($0.window.bundleId) ? " (another agent is on this app)" : "")" }
        return """
        Open windows:
        \(windows.isEmpty ? "none" : windows.joined(separator: "\n"))
        Connected services: \(connected.isEmpty ? "none" : connected.joined(separator: ", "))
        \(catalogue ? "Services that connect in one click:\n\(Catalogue.forModel)" : "")
        """
    }

    @MainActor
    func connectSource(_ agent: Agent, _ source: AgentMaker.Source, request: String) async {
        guard storeForBrain.agents.first(where: { $0.id == agent.id })?.attachment == nil else { return }
        let folder = AgentFolder(agent, in: storeForBrain)
        guard let job = folder.job else { return }
        let found = source.kind == .window ? WindowChannels.open().first { $0.number == source.window && OffLimits.match("\($0.app) \($0.bundleId) \($0.title ?? "")") == nil } : nil
        let window = found.flatMap { candidate in storeForBrain.agents.contains { $0.attachment?.bundleId == candidate.bundleId } ? nil : candidate }
        switch source.kind {
        case .none: return
        case .connected:
            await land(agent)
        case .window where window != nil:
            guard let window else { return }
            let words = "\(window.app) \(window.title ?? "")".lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.count >= 4 }
            if source.named, words.contains(where: { request.lowercased().contains($0) }) { return await start(agent, on: window) }
            // A window that shares nothing with the request is not its data, so it is never offered as such.
            let asked = "\(request) \(job.goal)".lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.count >= 4 }.map { $0.prefix(4) }
            guard words.contains(where: { word in asked.contains(word.prefix(4)) }) else { return }
            raise(AgentNeed(kind: .decision, question: "Use \(window.app) for this? I read nothing from it until you say yes.", options: [Self.allowIt, Self.notAllowed], recommended: Self.allowIt, sourceWindow: window.number), agent: agent, why: job.goal)
        case .connect where Catalogue.service(matching: source.service) != nil:
            guard let service = Catalogue.service(matching: source.service) else { return }
            raise(AgentNeed(kind: .decision, question: "Connect \(service.name)? \(job.goal)", connector: service.id), agent: agent, why: job.goal)
        default:
            let question = source.ask.isEmpty ? "I do not have the data for this yet. Open it, then put me on its app." : source.ask
            raise(AgentNeed(kind: .setup, question: question), agent: agent)
        }
        refresh()
    }

    // Being put on a window answers where the data is, whichever window it was.
    func dropSourceQuestions() {
        for agent in storeForBrain.agents where agent.attachment != nil && needs[agent.id]?.contains(where: \.asksForSource) == true {
            let folder = AgentFolder(agent, in: storeForBrain)
            folder.save(folder.needs.filter { !$0.asksForSource })
            if folder.needs.isEmpty { storeForBrain.activity[agent.id] = AgentActivity() }
            refresh()
        }
    }

    func dataLine(_ agent: Agent, folder: AgentFolder) -> String {
        if storeForBrain.agents.first(where: { $0.id == agent.id })?.attachment != nil { return "" }
        let unknown = "Until the user gives it, say plainly that you do not have it, and never invent it."
        for need in folder.needs {
            if need.sourceWindow != nil { return "Where its data is: you asked: \(need.question) You have not read it, and you do not until the user says yes. \(unknown)" }
            if need.connector != nil { return "Where its data is: not connected yet. You asked the user to connect it. \(unknown)" }
            if need.kind == .setup { return "Where its data is: not available yet. You asked the user: \(need.question) \(unknown)" }
        }
        return ""
    }

    @MainActor
    func start(_ agent: Agent, on window: OpenWindow) async {
        place(agent, on: window)
        for _ in 0..<40 where storeForBrain.agents.first(where: { $0.id == agent.id })?.attachment?.bundleId != window.bundleId {
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let placed = storeForBrain.agents.first(where: { $0.id == agent.id }) else { return }
        await land(placed)
    }

    @MainActor
    func answerSource(_ number: Int, agent: Agent, text: String) {
        let window = WindowChannels.open().first { $0.number == number && OffLimits.match("\($0.app) \($0.bundleId) \($0.title ?? "")") == nil }
        if text == Self.allowIt, let window {
            Task { @MainActor in await start(agent, on: window) }
            return
        }
        refresh()
    }
}
