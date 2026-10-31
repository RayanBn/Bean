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
        var agent: Agent
        let voice: String
        let lines: AgentLines
        let mission: AgentMission
        let job: AgentJob
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

    func write(_ request: String, avoiding names: [String] = []) async throws -> Created {
        let system = """
        You are Bean, a small creature that lives in the Mac's notch and makes agents for its user. Write the agent the user asks for.
        - name: a short, neutral first name\(names.isEmpty ? "" : ", not one of \(names.joined(separator: ", "))").
        - goal: one sentence, the result the person gets from this agent, in words anyone understands, keeping the concrete things they named. Say how it works or where it lives only if they said so.
        - output: what they receive each time, concretely, such as a short table or a draft to approve. One line.
        - done: how to tell one result is finished and right, as something that can be checked. One line.
        - first: its first move when it starts: read what is there and give one small result. One line.
        - quiet: when it says nothing, because there is nothing worth saying. One line.
        - voice: two sentences on how it writes, plain and fit for this work and whoever reads it, then two example lines. No slang, jokes, metaphors, catchphrases, filler, emoji or exclamation marks.
        - greeting: its first line to the user, plain and professional, at most 90 characters.
        - offLimits: the plain line it says when the window it sits on is off limits and it will not read it, at most 80 characters. Name no app.
        - accessory: one of \(Agent.Look.accessories.joined(separator: ", ")).
        - targets: the exact names of every repo, project, team or ticket the user named and nothing else, copied as written. kind is repo for owner/name, otherwise project. Empty if the user named none. Never invent one, and never list a window, a document, a file, or a service or app itself.
        - explicitly_allowed: words for irreversible actions the user explicitly allows, like merge or deploy. Usually empty.
        Write in English.
        """
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "required": ["name", "goal", "output", "done", "first", "quiet", "voice", "greeting", "offLimits", "accessory", "targets", "explicitly_allowed"],
            "properties": [
                "name": ["type": "string"], "goal": ["type": "string"], "output": ["type": "string"], "done": ["type": "string"], "first": ["type": "string"], "quiet": ["type": "string"], "voice": ["type": "string"],
                "greeting": ["type": "string"], "offLimits": ["type": "string"],
                "accessory": ["type": "string", "enum": Agent.Look.accessories],
                "explicitly_allowed": ["type": "array", "items": ["type": "string"]],
                "targets": ["type": "array", "items": ["type": "object", "additionalProperties": false, "required": ["kind", "name"],
                                                       "properties": ["kind": ["type": "string", "enum": ["repo", "project"]], "name": ["type": "string"]]]],
            ],
        ]
        struct Output: Decodable {
            struct Target: Decodable { let kind, name: String }
            let name, goal, output, done, first, quiet, voice, greeting, offLimits, accessory: String
            let targets: [Target]
            let explicitly_allowed: [String]
        }
        let output: Output = try await ask(system: system, text: "The user wants: \(request)", schema: schema)
        let accessory = Agent.Look.accessories.contains(output.accessory) ? output.accessory : "none"
        let agent = Agent(id: UUID(), name: output.name, role: output.goal, personality: "",
                          look: .init(hue: Agent.Look.hues[0], accessory: accessory),
                          connectors: [], attachment: nil, createdAt: Date())
        let targets = output.targets.filter { AgentTarget.namesService($0.name, in: request) }.compactMap { target -> AgentTarget? in
            let name = target.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, request.lowercased().contains(name.lowercased()), OffLimits.match(name) == nil else { return nil }
            return AgentTarget(kind: target.kind == "repo" ? .repo : .project, name: name)
        }
        let allowed = output.explicitly_allowed.filter { request.lowercased().contains($0.lowercased()) && AbilityFinder.irreversible($0) }.map { $0.lowercased() }
        let mission = AgentMission(mission: output.goal, targets: targets, explicitlyAllowed: allowed)
        return Created(agent: agent, voice: output.voice, lines: AgentLines(greeting: output.greeting, offLimits: output.offLimits), mission: mission,
                       job: AgentJob(goal: output.goal, output: output.output, done: output.done, first: output.first, quiet: output.quiet))
    }

    static func save(_ created: Created, in store: AgentStore) throws {
        store.save(created.agent)
        let folder = AgentFolder(created.agent, in: store)
        try folder.create(agent: created.agent, voice: created.voice, lines: created.lines, job: created.job)
        folder.save(created.mission)
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
