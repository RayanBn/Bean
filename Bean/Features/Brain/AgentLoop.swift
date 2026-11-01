import Foundation

struct AgentLoop {
    struct Result {
        let final: String?
        let args: JSONArgs
        let rounds: Int
        let calls: [String]
        let promptTokens: Int
        let failure: String?
        var messages: [[String: Any]] = []
    }

    let client: ModelClient
    var maxRounds = 12
    var stopEarly: (() async -> Bool)?
    var stopNow: (() async -> Bool)?
    var around: ((String, JSONArgs, @escaping @Sendable () async -> ToolOutput) async -> ToolOutput)?
    var said: ((String) async -> Void)?

    func run(system: String, text: String, tools: [BrainTool], finals: [BrainTool]) async -> Result {
        var messages: [[String: Any]] = [["role": "system", "content": system], ["role": "user", "content": text]]
        var byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let finalNames = Set(finals.map(\.name))
        var schemas = (tools + finals).map(\.schema)
        var calls: [String] = [], tokens = 0
        for round in 1...maxRounds {
            if await stopNow?() == true { return Result(final: nil, args: [:], rounds: round, calls: calls, promptTokens: tokens, failure: "stopped", messages: messages) }
            let reply: ModelClient.Reply
            do {
                let offered: [[String: Any]]
                let stopping = await stopEarly?() ?? false
                if round == maxRounds || stopping {
                    offered = finals.map(\.schema)
                    messages.append(["role": "user", "content": "This is your last turn: call \(finals.first?.name ?? "the final tool") now with what you have."])
                } else {
                    offered = schemas
                }
                reply = try await client.chat(messages, tools: offered)
            } catch {
                return Result(final: nil, args: [:], rounds: round, calls: calls, promptTokens: tokens, failure: error.localizedDescription)
            }
            tokens += reply.promptTokens ?? 0
            if await stopNow?() == true { return Result(final: nil, args: [:], rounds: round, calls: calls, promptTokens: tokens, failure: "stopped", messages: messages) }
            guard !reply.toolCalls.isEmpty else {
                if let text = reply.text, !text.isEmpty, let first = finals.first {
                    return Result(final: first.name, args: ["summary": text], rounds: round, calls: calls, promptTokens: tokens, failure: nil, messages: messages)
                }
                return Result(final: nil, args: [:], rounds: round, calls: calls, promptTokens: tokens, failure: "no tool call: \(reply.text?.prefix(200) ?? "")", messages: messages)
            }
            messages.append(reply.assistantMessage)
            if let text = reply.text { await said?(text) }
            var images: [Data] = []
            let together = reply.toolCalls.compactMap { call -> (id: String, tool: BrainTool, args: JSONArgs)? in
                let name = call.name.hasPrefix("default.") ? String(call.name.dropFirst(8)) : call.name
                guard let tool = byName[name], tool.runsAtOnce else { return nil }
                return (call.id, tool, (try? JSONSerialization.jsonObject(with: call.arguments)) as? JSONArgs ?? [:])
            }
            var ready: [String: ToolOutput] = [:]
            if together.count > 1 {
                await withTaskGroup(of: (String, ToolOutput).self) { group in
                    for call in together { group.addTask { (call.id, await run(call.tool, call.args)) } }
                    for await (id, output) in group { ready[id] = output }
                }
            }
            for call in reply.toolCalls {
                let args = (try? JSONSerialization.jsonObject(with: call.arguments)) as? JSONArgs ?? [:]
                let name = call.name.hasPrefix("default.") ? String(call.name.dropFirst(8)) : call.name
                calls.append(name)
                if finalNames.contains(name) {
                    return Result(final: name, args: args, rounds: round, calls: calls, promptTokens: tokens, failure: nil, messages: messages)
                }
                let done = ready[call.id]
                let output: ToolOutput
                if let done { output = done } else if let tool = byName[name] { output = await run(tool, args) } else { output = ToolOutput(text: "unknown tool \(name)", ok: false) }
                for added in output.addsTools where byName[added.name] == nil {
                    byName[added.name] = added
                    schemas.append(added.schema)
                }
                if let image = output.image { images.append(image) }
                messages.append(["role": "tool", "tool_call_id": call.id, "content": output.text])
            }
            if !images.isEmpty {
                messages.append(["role": "user", "content": [["type": "text", "text": "Screenshot:"]] + images.map(ModelClient.image)])
            }
        }
        return Result(final: nil, args: [:], rounds: maxRounds, calls: calls, promptTokens: tokens, failure: "no answer after \(maxRounds) rounds", messages: messages)
    }

    private func run(_ tool: BrainTool, _ args: JSONArgs) async -> ToolOutput {
        guard let around else { return await tool.run(args) }
        return await around(tool.name, args) { await tool.run(args) }
    }
}
