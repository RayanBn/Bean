import Foundation

struct AgentProposal: Codable, Identifiable, Equatable {
    var id: String { name }
    let name: String
    let role: String
    let pitch: String
    let connectors: [String]

    var request: String { "\(name): \(role) \(pitch)" + (connectors.isEmpty ? "" : " Connectors: \(connectors.joined(separator: ", ")).") }
}

struct AgentMaker {
    struct Created {
        let agent: Agent
        let voice: String
        let lines: AgentLines
        let connectors: [AgentConnector]
    }

    enum MakerError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            if case let .unreadable(text) = self { return "Muse Spark's answer was not readable: \(text.prefix(200))" }
            return nil
        }
    }

    let client = ModelClient()
    let inventory: MacInventory

    func propose() async throws -> [AgentProposal] {
        let system = """
        You are Bean, a small creature that lives in the Mac's notch and makes agents for its user. \
        Each agent has its own personality and gets plugged into one app's window, where it reads what happens and helps in the background. \
        Look at what this Mac has and propose 2 or 3 agents that fit this user, each for a different app they really use. \
        Prefer the running apps. For each agent give a short catchy name, its role in one sentence, a one-line pitch that says which of the user's apps it lives in and why it fits them, \
        and the connectors it would need to help: MCP services that hold the user's work data, such as GitHub, Linear, Slack or Notion, using the names from the list when they exist. Never a connector that drives the Mac itself.
        """
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["agents"],
            "properties": ["agents": ["type": "array", "items": [
                "type": "object", "additionalProperties": false, "required": ["name", "role", "pitch", "connectors"],
                "properties": ["name": ["type": "string"], "role": ["type": "string"], "pitch": ["type": "string"],
                               "connectors": ["type": "array", "items": ["type": "string"]]],
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
        - role: one sentence, what it does and in which kind of app.
        - personality: three or four sentences, a real character with quirks, not a corporate assistant.
        - voice: two sentences on how it talks (tone, sentence length, verbal tics), then two example lines in that voice.
        - greeting: its first line to the user, in its voice, at most 90 characters.
        - offLimits: the line it says, in its voice, when the window it sits on is off limits and it refuses to look, at most 80 characters.
        - hue: its color, a number between 0 and 1 on the color wheel, that matches its character.
        - accessory: one of \(Agent.Look.accessories.joined(separator: ", ")).
        - connectors: the MCP services that hold the data it needs for its job (for example GitHub for a code agent), using the names from the list when they exist. Include the service its job depends on even when it is not connected yet. Never a connector that drives the Mac itself.
        Write in English.
        """
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "required": ["name", "role", "personality", "voice", "greeting", "offLimits", "hue", "accessory", "connectors"],
            "properties": [
                "name": ["type": "string"], "role": ["type": "string"], "personality": ["type": "string"], "voice": ["type": "string"],
                "greeting": ["type": "string"], "offLimits": ["type": "string"], "hue": ["type": "number"],
                "accessory": ["type": "string", "enum": Agent.Look.accessories],
                "connectors": ["type": "array", "items": ["type": "string"]],
            ],
        ]
        struct Output: Decodable {
            let name, role, personality, voice, greeting, offLimits, accessory: String
            let hue: Double
            let connectors: [String]
        }
        let output: Output = try await ask(system: system, text: "The user wants: \(request)\n\nWhat this Mac has:\n\(inventory.summary)", schema: schema)
        let connectors = await inventory.resolve(Array(Set(output.connectors.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted())
        let accessory = Agent.Look.accessories.contains(output.accessory) ? output.accessory : "none"
        let agent = Agent(id: UUID(), name: output.name, role: output.role, personality: output.personality,
                          look: .init(hue: min(max(output.hue, 0), 1), accessory: accessory),
                          connectors: connectors.map(\.name), attachment: nil, createdAt: Date())
        return Created(agent: agent, voice: output.voice, lines: AgentLines(greeting: output.greeting, offLimits: output.offLimits), connectors: connectors)
    }

    static func save(_ created: Created, in store: AgentStore) throws {
        store.save(created.agent)
        try AgentFolder(created.agent, in: store).create(agent: created.agent, voice: created.voice, lines: created.lines, connectors: created.connectors)
    }

    private func ask<T: Decodable>(system: String, text: String, schema: [String: Any]) async throws -> T {
        let reply = try await client.json(system: system, text: text, schema: schema, effort: "low")
        guard let body = reply.text, let output = try? JSONDecoder().decode(T.self, from: Data(body.utf8)) else {
            throw MakerError.unreadable(reply.text ?? "")
        }
        return output
    }
}
