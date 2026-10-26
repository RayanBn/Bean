import Foundation

struct ModelClient {
    var provider: AIProvider { BeanSettings.shared.effectiveProvider }
    var model: String { BeanSettings.shared.effectiveModel }
    var reasoningEffort: String { BeanSettings.shared.effectiveBrainEffort }
    var label: String { "\(provider.rawValue)/\(model)" }
    var isReady: Bool { (APIKeyStore.current().key != nil || provider.keyIsOptional) && BeanSettings.shared.effectiveBaseURL != nil && !model.isEmpty }

    struct ToolCall {
        let name: String
        let arguments: Data
    }

    struct Reply {
        let toolCall: ToolCall?
        let text: String?
        let promptTokens: Int?
        let completionTokens: Int?
    }

    func complete(system: String, text: String, jpeg: Data?, tools: [[String: Any]]) async throws -> Reply {
        var content: [[String: Any]] = [["type": "text", "text": text]]
        if let jpeg {
            content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]])
        }
        return try await send([
            "model": model,
            "reasoning_effort": reasoningEffort,
            "messages": [["role": "system", "content": system], ["role": "user", "content": content]],
            "tools": tools,
            "tool_choice": "auto",
        ])
    }

    func json(system: String, text: String, schema: [String: Any], effort: String) async throws -> Reply {
        try await send([
            "model": model,
            "reasoning_effort": effort,
            "messages": [["role": "system", "content": system], ["role": "user", "content": text]],
            "response_format": ["type": "json_schema", "json_schema": ["name": "bean", "strict": true, "schema": schema]],
        ])
    }

    private func send(_ body: [String: Any]) async throws -> Reply {
        let key = APIKeyStore.current().key
        guard key != nil || provider.keyIsOptional else { throw SparkError.noKey }
        guard let base = BeanSettings.shared.effectiveBaseURL else { throw SparkError.noEndpoint }
        var body = body
        if !provider.acceptsReasoningEffort { body["reasoning_effort"] = nil }
        var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if provider == .openRouter {
            request.setValue("https://github.com/RayanBn/Bean", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Bean", forHTTPHeaderField: "X-Title")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SparkError.http((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data.prefix(300), as: UTF8.self))
        }
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    struct Call: Decodable { struct Function: Decodable { let name: String; let arguments: String }; let function: Function }
                    let content: String?
                    let tool_calls: [Call]?
                }
                let message: Message
            }
            struct Usage: Decodable { let prompt_tokens: Int?; let completion_tokens: Int? }
            let choices: [Choice]
            let usage: Usage?
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let message = decoded.choices.first?.message else { throw SparkError.empty }
        let call = message.tool_calls?.first.map { ToolCall(name: $0.function.name, arguments: Data($0.function.arguments.utf8)) }
        return Reply(toolCall: call, text: message.content, promptTokens: decoded.usage?.prompt_tokens, completionTokens: decoded.usage?.completion_tokens)
    }

    enum SparkError: LocalizedError {
        case noKey, noEndpoint, empty, http(Int, String)
        var errorDescription: String? {
            switch self {
            case .noKey: return "no API key for \(BeanSettings.shared.effectiveProvider.displayName): paste one in Settings"
            case .noEndpoint: return "no base URL for the OpenAI-compatible provider"
            case .empty: return "empty answer"
            case let .http(code, body): return "HTTP \(code): \(body)"
            }
        }
    }
}
