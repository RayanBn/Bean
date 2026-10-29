import Foundation

struct ShieldCandidate: Encodable {
    let id: Int
    let app: String
    let window: String
    let type: String
    let shape: String
    let before: String
    let after: String
}

struct ShieldPolicy {
    static let reviewable: Set<String> = ["private_person", "private_url", "private_date"]
    let client: ModelClient

    private static let system = """
    You are Bean, an assistant on the user's Mac. The user is sharing their whole screen with viewers they may not know. \
    An on-device detector found candidate private spans on screen and Bean already hides all of them. You never see the values: \
    only the app, the window title, the detected type, the shape of the value, and up to 3 words around it. \
    Decide which shields to keep. Keep hiding what could harm the user or others if seen: credentials and secrets, contact and identity data, \
    financial data, one-time codes, people named in personal or confidential contexts. \
    When in doubt, hide: a leak is worse than an extra mask. Release only what is clearly ordinary and public in context, \
    such as commit hashes, code identifiers, public links and ordinary work chatter. \
    A detected person is often not a person: release names of apps, tools, products, companies, AI assistants and public figures.
    """

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "hide": ["type": "array", "items": ["type": "integer"]],
            "release": ["type": "array", "items": ["type": "integer"]],
        ],
        "required": ["hide", "release"],
        "additionalProperties": false,
    ]

    func release(_ candidates: [ShieldCandidate]) async throws -> Set<Int> {
        guard !candidates.isEmpty else { return [] }
        let payload = String(decoding: try JSONEncoder().encode(candidates), as: UTF8.self)
        let reply = try await client.json(system: Self.system, text: payload, schema: Self.schema, effort: "minimal")
        struct Answer: Decodable { let hide: [Int]; let release: [Int] }
        let answer = try JSONDecoder().decode(Answer.self, from: Data((reply.text ?? "{}").utf8))
        return Set(answer.release).subtracting(answer.hide)
    }

    static func shape(of value: String) -> String {
        let classes = [("lower", "a-z"), ("upper", "A-Z"), ("digits", "0-9"), ("symbols", "^\\w\\s"), ("spaces", "\\s")]
            .filter { value.range(of: "[\($0.1)]", options: .regularExpression) != nil }.map(\.0)
        return "\(value.count) chars, \(classes.joined(separator: "+"))"
    }
}
