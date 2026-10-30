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
        For each agent give a short catchy name, a label of two or three words, at most 20 characters, that says what it does (like "Keeps PRs moving"), \
        its role in one sentence, and a one-line pitch on why it fits this user. \
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
        - name: a short first name that fits it.
        - role: one sentence, what it does. It belongs to no app and no tool: the user can plug it into any window.
        - personality: three or four sentences, a real character with quirks, not a corporate assistant.
        - voice: two sentences on how it talks (tone, sentence length, verbal tics), then two example lines in that voice.
        - greeting: its first line to the user, in its voice, at most 90 characters.
        - offLimits: the line it says, in its voice, when the window it sits on is off limits and it refuses to look, at most 80 characters. Name no app.
        - hue: its color, a number between 0 and 1 on the color wheel, that matches its character.
        - accessory: one of \(Agent.Look.accessories.joined(separator: ", ")).
        Write in English.
        """
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "required": ["name", "role", "personality", "voice", "greeting", "offLimits", "hue", "accessory"],
            "properties": [
                "name": ["type": "string"], "role": ["type": "string"], "personality": ["type": "string"], "voice": ["type": "string"],
                "greeting": ["type": "string"], "offLimits": ["type": "string"], "hue": ["type": "number"],
                "accessory": ["type": "string", "enum": Agent.Look.accessories],
            ],
        ]
        struct Output: Decodable {
            let name, role, personality, voice, greeting, offLimits, accessory: String
            let hue: Double
        }
        let output: Output = try await ask(system: system, text: "The user wants: \(request)", schema: schema)
        let accessory = Agent.Look.accessories.contains(output.accessory) ? output.accessory : "none"
        let agent = Agent(id: UUID(), name: output.name, role: output.role, personality: output.personality,
                          look: .init(hue: min(max(output.hue, 0), 1), accessory: accessory),
                          connectors: [], attachment: nil, createdAt: Date())
        return Created(agent: agent, voice: output.voice, lines: AgentLines(greeting: output.greeting, offLimits: output.offLimits))
    }

    static func save(_ created: Created, in store: AgentStore) throws {
        store.save(created.agent)
        try AgentFolder(created.agent, in: store).create(agent: created.agent, voice: created.voice, lines: created.lines)
    }

    private func ask<T: Decodable>(system: String, text: String, schema: [String: Any]) async throws -> T {
        let reply = try await client.json(system: system, text: text, schema: schema, effort: "low")
        guard let body = reply.text, let output = try? JSONDecoder().decode(T.self, from: Data(body.utf8)) else {
            throw MakerError.unreadable(reply.text ?? "")
        }
        return output
    }
}
