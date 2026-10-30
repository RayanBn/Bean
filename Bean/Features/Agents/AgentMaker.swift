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
        let agent: Agent
        let voice: String
        let lines: AgentLines
        let mission: AgentMission
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
        An agent is a personality and a role. It belongs to no app: the user can plug any agent into any window, where it reads what happens and helps in the background. \
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

    func write(_ request: String) async throws -> Created {
        let system = """
        You are Bean, a small creature that lives in the Mac's notch and makes agents for its user. Write the agent the user asks for.
        - name: a short, neutral first name.
        - role: one sentence, what it does. It belongs to no app and no tool: the user can plug it into any window.
        - personality: two or three sentences on how it works: what it pays attention to, what it holds to, how it decides. A competent professional, not a character: no quirks, jokes or backstory.
        - voice: two sentences on how it writes, professional and precise like a senior engineer, then two example lines. No slang, jokes, metaphors, catchphrases, filler, emoji or exclamation marks.
        - greeting: its first line to the user, plain and professional, at most 90 characters.
        - offLimits: the plain line it says when the window it sits on is off limits and it will not read it, at most 80 characters. Name no app.
        - hue: its color, a number between 0 and 1 on the color wheel, that matches its character.
        - accessory: one of \(Agent.Look.accessories.joined(separator: ", ")).
        - mission: what it does on its own, in the background, in one sentence with the concrete things the user named.
        - scope: the exact names of every repo, project, team, ticket or service the user named and nothing else, copied as written. Empty if the user named none. Never invent one.
        - allowed: the actions it may take without asking, short verbs and objects, from what the user said.
        - may_merge: true only if the user explicitly allows merging to the main branch.
        - may_deploy: true only if the user explicitly allows deploying.
        - may_run_sessions: true only if the user asks it to start or drive coding sessions.
        Write in English.
        """
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "required": ["name", "role", "personality", "voice", "greeting", "offLimits", "hue", "accessory", "mission", "scope", "allowed", "may_merge", "may_deploy", "may_run_sessions"],
            "properties": [
                "name": ["type": "string"], "role": ["type": "string"], "personality": ["type": "string"], "voice": ["type": "string"],
                "greeting": ["type": "string"], "offLimits": ["type": "string"], "hue": ["type": "number"],
                "accessory": ["type": "string", "enum": Agent.Look.accessories],
                "mission": ["type": "string"], "scope": ["type": "array", "items": ["type": "string"]], "allowed": ["type": "array", "items": ["type": "string"]],
                "may_merge": ["type": "boolean"], "may_deploy": ["type": "boolean"], "may_run_sessions": ["type": "boolean"],
            ],
        ]
        struct Output: Decodable {
            let name, role, personality, voice, greeting, offLimits, accessory, mission: String
            let hue: Double
            let scope, allowed: [String]
            let may_merge, may_deploy, may_run_sessions: Bool
        }
        let output: Output = try await ask(system: system, text: "The user wants: \(request)", schema: schema)
        let accessory = Agent.Look.accessories.contains(output.accessory) ? output.accessory : "none"
        let agent = Agent(id: UUID(), name: output.name, role: output.role, personality: output.personality,
                          look: .init(hue: min(max(output.hue, 0), 1), accessory: accessory),
                          connectors: [], attachment: nil, createdAt: Date())
        let scope = output.scope.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && request.lowercased().contains($0.lowercased()) }
        let mission = AgentMission(mission: output.mission, scope: scope, allowed: output.allowed, mayMerge: output.may_merge, mayDeploy: output.may_deploy, mayRunSessions: output.may_run_sessions)
        return Created(agent: agent, voice: output.voice, lines: AgentLines(greeting: output.greeting, offLimits: output.offLimits), mission: mission)
    }

    static func save(_ created: Created, in store: AgentStore) throws {
        store.save(created.agent)
        let folder = AgentFolder(created.agent, in: store)
        try folder.create(agent: created.agent, voice: created.voice, lines: created.lines)
        folder.save(created.mission)
    }

    private func ask<T: Decodable>(system: String, text: String, schema: [String: Any]) async throws -> T {
        let reply = try await client.json(system: system, text: text, schema: schema, effort: "low")
        guard let body = reply.text, let output = try? JSONDecoder().decode(T.self, from: Data(body.utf8)) else {
            throw MakerError.unreadable(reply.text ?? "")
        }
        return output
    }
}
