import Foundation

struct AgentLoop {
    struct Result {
        let final: String?
        let args: JSONArgs
        let rounds: Int
        let calls: [String]
        let promptTokens: Int
        let failure: String?
    }

    let client: ModelClient
    var maxRounds = 12

    func run(system: String, text: String, tools: [BrainTool], finals: [BrainTool]) async -> Result {
        var messages: [[String: Any]] = [["role": "system", "content": system], ["role": "user", "content": text]]
        let byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let finalNames = Set(finals.map(\.name))
        let schemas = (tools + finals).map(\.schema)
        var calls: [String] = [], tokens = 0
        for round in 1...maxRounds {
            let reply: ModelClient.Reply
            do {
                reply = try await client.chat(messages, tools: round == maxRounds ? finals.map(\.schema) : schemas)
            } catch {
                return Result(final: nil, args: [:], rounds: round, calls: calls, promptTokens: tokens, failure: error.localizedDescription)
            }
            tokens += reply.promptTokens ?? 0
            guard !reply.toolCalls.isEmpty else {
                return Result(final: nil, args: [:], rounds: round, calls: calls, promptTokens: tokens, failure: "no tool call: \(reply.text?.prefix(200) ?? "")")
            }
            messages.append(reply.assistantMessage)
            var images: [Data] = []
            for call in reply.toolCalls {
                let args = (try? JSONSerialization.jsonObject(with: call.arguments)) as? JSONArgs ?? [:]
                calls.append(call.name)
                if finalNames.contains(call.name) {
                    return Result(final: call.name, args: args, rounds: round, calls: calls, promptTokens: tokens, failure: nil)
                }
                let output = await byName[call.name]?.run(args) ?? ToolOutput(text: "unknown tool \(call.name)", ok: false)
                if let image = output.image { images.append(image) }
                messages.append(["role": "tool", "tool_call_id": call.id, "content": output.text])
            }
            if !images.isEmpty {
                messages.append(["role": "user", "content": [["type": "text", "text": "Screenshot:"]] + images.map(ModelClient.image)])
            }
        }
        return Result(final: nil, args: [:], rounds: maxRounds, calls: calls, promptTokens: tokens, failure: "no answer after \(maxRounds) rounds")
    }
}
