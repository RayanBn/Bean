import Foundation

struct ModelClient {
    var provider: AIProvider { BeanSettings.shared.effectiveProvider }
    var model: String { BeanSettings.shared.effectiveModel }
    var reasoningEffort: String { BeanSettings.shared.effectiveBrainEffort }
    var label: String { "\(provider.rawValue)/\(model)" }
    var isReady: Bool { (APIKeyStore.current().key != nil || provider.keyIsOptional) && BeanSettings.shared.effectiveBaseURL != nil && !model.isEmpty }

    struct ToolCall {
        let id: String
        let name: String
        let arguments: Data
    }

    struct Reply {
        let toolCalls: [ToolCall]
        let text: String?
        let promptTokens: Int?
        let completionTokens: Int?

        var assistantMessage: [String: Any] {
            var message: [String: Any] = ["role": "assistant", "content": text ?? ""]
            if !toolCalls.isEmpty {
                message["tool_calls"] = toolCalls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": String(decoding: $0.arguments, as: UTF8.self)]] }
            }
            return message
        }
    }

    static func image(_ jpeg: Data) -> [String: Any] {
        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]]
    }

    func chat(_ messages: [[String: Any]], tools: [[String: Any]]) async throws -> Reply {
        try await send([
            "model": model,
            "reasoning_effort": reasoningEffort,
            "messages": messages,
            "tools": tools,
            "tool_choice": "auto",
        ])
    }

    func json(system: String, text: String, schema: [String: Any], effort: String) async throws -> Reply {
        try await json(messages: [["role": "system", "content": system], ["role": "user", "content": text]], schema: schema, effort: effort)
    }

    func json(messages: [[String: Any]], schema: [String: Any], effort: String) async throws -> Reply {
        try await send([
            "model": model,
            "reasoning_effort": effort,
            "messages": messages,
            "response_format": ["type": "json_schema", "json_schema": ["name": "bean", "strict": true, "schema": schema]],
        ])
    }

    private func send(_ body: [String: Any]) async throws -> Reply {
        do {
            let reply = try await perform(body)
            Self.setProblem(nil)
            return reply
        } catch {
            Self.setProblem(Self.plain(error))
            throw error
        }
    }

    private static let problemLock = NSLock()
    private static var currentProblem: String?

    static var problem: String? { problemLock.withLock { currentProblem } }

    private static func setProblem(_ problem: String?) {
        problemLock.withLock { currentProblem = problem }
    }

    static func plain(_ error: Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return "Muse Spark did not answer in time."
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return "No connection to Muse Spark. Check the network."
            default: return "Could not reach Muse Spark."
            }
        }
        return error.localizedDescription
    }

    func checkKey() async -> String? {
        guard let base = BeanSettings.shared.effectiveBaseURL else { return SparkError.noEndpoint.localizedDescription }
        var request = URLRequest(url: base.appendingPathComponent("models"))
        if let key = APIKeyStore.current().key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return code == 200 ? nil : SparkError.http(code, String(decoding: data.prefix(300), as: UTF8.self)).localizedDescription
        } catch {
            return Self.plain(error)
        }
    }

    private func perform(_ body: [String: Any]) async throws -> Reply {
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
                    struct Call: Decodable { struct Function: Decodable { let name: String; let arguments: String }; let id: String?; let function: Function }
                    let content: String?
                    let tool_calls: [Call]?
                }
                let message: Message
            }
            struct Usage: Decodable {
                struct Details: Decodable { let cached_tokens: Int? }
                let prompt_tokens: Int?
                let completion_tokens: Int?
                let prompt_tokens_details: Details?
            }
            let choices: [Choice]
            let usage: Usage?
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        if let usage = decoded.usage {
            CostLedger.record(model: model, prompt: usage.prompt_tokens ?? 0, cached: usage.prompt_tokens_details?.cached_tokens ?? 0, completion: usage.completion_tokens ?? 0)
        }
        guard let message = decoded.choices.first?.message else { throw SparkError.empty }
        let calls = (message.tool_calls ?? []).map { ToolCall(id: $0.id ?? UUID().uuidString, name: $0.function.name, arguments: Data($0.function.arguments.utf8)) }
        return Reply(toolCalls: calls, text: message.content, promptTokens: decoded.usage?.prompt_tokens, completionTokens: decoded.usage?.completion_tokens)
    }

    enum SparkError: LocalizedError {
        case noKey, noEndpoint, empty, http(Int, String)
        var errorDescription: String? {
            switch self {
            case .noKey: return "Add an API key so agents can think."
            case .noEndpoint: return "Set the address of the AI provider."
            case .empty: return "Muse Spark returned an empty answer."
            case let .http(code, _):
                switch code {
                case 401, 403: return "Your API key was refused."
                case 402: return "Your AI credits have run out."
                case 429: return "Too many requests, or no credits left. Bean will try again later."
                case 500...599: return "Muse Spark is having problems. Bean will try again later."
                default: return "Muse Spark returned an error (\(code))."
                }
            }
        }
    }
}
