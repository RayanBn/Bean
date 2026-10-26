import Foundation

struct MuseSpark {
    static let endpoint = URL(string: "https://api.meta.ai/v1/chat/completions")!

    var model: String { BeanSettings.shared.effectiveBrainModel }
    var reasoningEffort: String { BeanSettings.shared.effectiveBrainEffort }
    var hasKey: Bool { apiKey != nil }
    private let apiKey: String?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        apiKey = environment["MODEL_API_KEY"] ?? Self.keyFromSourceEnvFile()
    }

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
            "parallel_tool_calls": false,
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
        guard let apiKey else { throw SparkError.noKey }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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

    private static func keyFromSourceEnvFile() -> String? {
        guard let root = Bundle.main.object(forInfoDictionaryKey: "BeanSourceRoot") as? String,
              let text = try? String(contentsOfFile: root + "/.env", encoding: .utf8) else { return nil }
        return text.split(separator: "\n")
            .first { $0.hasPrefix("MODEL_API_KEY=") }
            .map { $0.dropFirst("MODEL_API_KEY=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
    }

    enum SparkError: LocalizedError {
        case noKey, empty, http(Int, String)
        var errorDescription: String? {
            switch self {
            case .noKey: return "no MODEL_API_KEY in the environment or in the repo .env"
            case .empty: return "empty answer"
            case let .http(code, body): return "HTTP \(code): \(body)"
            }
        }
    }
}
