import Foundation

protocol GateModel {
    var name: String { get }
    func score(_ trigger: Trigger) async throws -> Double?
}

struct CloudGate: GateModel {
    static let effort = "minimal"
    static let schema: [String: Any] = [
        "type": "object",
        "properties": ["stepIn": ["type": "boolean"], "confidence": ["type": "number"]],
        "required": ["stepIn", "confidence"],
        "additionalProperties": false,
    ]

    let client: ModelClient
    var name: String { client.provider.acceptsReasoningEffort ? "\(client.label) (\(Self.effort))" : client.label }

    func score(_ trigger: Trigger) async throws -> Double? {
        let system = Gate.system + "\nAnswer in JSON: stepIn, and confidence between 0 and 1 in that answer."
        let reply = try await client.json(system: system, text: trigger.summary + "\nShould Bean step in now?", schema: Self.schema, effort: Self.effort)
        struct Output: Decodable { let stepIn: Bool; let confidence: Double }
        guard let text = reply.text, let output = try? JSONDecoder().decode(Output.self, from: Data(text.utf8)) else { return nil }
        let confidence = min(max(output.confidence, 0), 1)
        return output.stepIn ? 0.5 + confidence / 2 : 0.5 - confidence / 2
    }
}

struct LocalGate: GateModel {
    let server: GateServer
    var name: String { server.modelName }

    func score(_ trigger: Trigger) async throws -> Double? {
        server.startIfNeeded()
        guard await server.waitUntilReady(timeout: 30) else { throw GateError.localNotReady }
        let body: [String: Any] = [
            "messages": [["role": "system", "content": Gate.system + "\nAnswer with one word: yes or no."], ["role": "user", "content": trigger.summary + "\nShould Bean step in now?"]],
            "max_tokens": 1, "temperature": 0, "logprobs": true, "top_logprobs": 10,
        ]
        var request = URLRequest(url: server.endpoint.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20
        return try Self.score(from: await URLSession.shared.data(for: request).0)
    }

    static func score(from data: Data) throws -> Double? {
        struct Response: Decodable {
            struct Choice: Decodable { let logprobs: Logprobs? }
            struct Logprobs: Decodable { let content: [Token] }
            struct Token: Decodable { let top_logprobs: [Candidate] }
            struct Candidate: Decodable { let token: String; let logprob: Double }
            let choices: [Choice]
        }
        let candidates = try JSONDecoder().decode(Response.self, from: data).choices.first?.logprobs?.content.first?.top_logprobs ?? []
        func probability(of word: String) -> Double {
            candidates.filter { $0.token.trimmingCharacters(in: .whitespaces).lowercased() == word }.reduce(0) { $0 + exp($1.logprob) }
        }
        let yes = probability(of: "yes"), no = probability(of: "no")
        return yes + no > 0 ? yes / (yes + no) : nil
    }

    enum GateError: LocalizedError {
        case localNotReady
        var errorDescription: String? { "the local gate server is not ready (llama-server or the model is missing)" }
    }
}
