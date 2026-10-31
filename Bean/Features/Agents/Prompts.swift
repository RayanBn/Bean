import Foundation

enum Template: String {
    case base, agent, bean, chat, guide, moment, understanding
}

// Every prompt's rules come from here, as a pure function of the template and the app build, so a stable prefix stays byte for byte the same.
enum Prompts {
    private static func load(_ template: Template) -> String {
        guard let url = Bundle.main.url(forResource: template.rawValue, withExtension: "md"), let text = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("the app was built without its \(template.rawValue) template")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func filled(_ text: String) -> String {
        let skills = Skills.agentSkills
        return text
            .replacingOccurrences(of: "{{services}}", with: Catalogue.services.map { "\($0.id) (\($0.name))" }.joined(separator: ", "))
            .replacingOccurrences(of: "{{serviceNames}}", with: Catalogue.services.map(\.name).joined(separator: ", "))
            .replacingOccurrences(of: "{{agentSkills}}", with: skills.isEmpty ? "" : "It can read know-how on: \(skills.joined(separator: "; ")).")
    }

    private static let baseText = filled(load(.base))
    private static let agentText = baseText + "\n\n" + filled(load(.agent))
    private static let beanText = baseText + "\n\n" + filled(load(.bean))
    private static let chatText = filled(load(.chat)) + "\n\n" + load(.guide)

    static func system(for agent: Agent) -> String { agent.isBean ? beanText : agentText }
    static func chatSystem(for agent: Agent) -> String { system(for: agent) + "\n\n" + chatText }
    static let understanding = load(.understanding)
    static let moment = load(.moment)

    static let writing: String = {
        let lines = baseText.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "Writing") else { return "" }
        return lines[(start + 1)...].prefix { !$0.isEmpty }.map { $0.replacingOccurrences(of: "- ", with: "", options: .anchored) }.joined(separator: " ")
    }()
}

// One short call per moment, apart from understanding. The model proposes, and code decides whether a yes is needed.
struct MomentAnswer: Codable, Equatable {
    enum Verdict: String, Codable { case ignore, remember, offer, place }
    enum Needs: String, Codable { case readWindow = "read the window", hearCall = "hear the call", actInWindow = "act in the window", nothing }
    enum When: String, Codable { case now, nextPause = "next pause", whenBack = "when they come back" }

    let verdict: Verdict
    let result: String
    let saw: String
    let needs: Needs
    let key: String
    let when: When

    var isUsable: Bool { (verdict != .offer && verdict != .place) || (!result.isEmpty && !saw.isEmpty) }

    static let schema: [String: Any] = {
        let text: [String: Any] = ["type": "string"]
        return ["type": "object", "additionalProperties": false, "required": ["verdict", "result", "saw", "needs", "key", "when"], "properties": [
            "verdict": ["type": "string", "enum": ["ignore", "remember", "offer", "place"]], "result": text, "saw": text,
            "needs": ["type": "string", "enum": ["read the window", "hear the call", "act in the window", "nothing"]], "key": text,
            "when": ["type": "string", "enum": ["now", "next pause", "when they come back"]],
        ]]
    }()

    static func ask(about moment: String) async -> MomentAnswer? {
        guard let reply = try? await ModelClient().json(system: Prompts.moment, text: moment, schema: schema, effort: "minimal"), let body = reply.text,
              let answer = try? JSONDecoder().decode(MomentAnswer.self, from: Data(body.utf8)), answer.isUsable else { return nil }
        return answer
    }
}
