import Foundation

struct MuseSpark {
    static let endpoint = URL(string: "https://api.meta.ai/v1/chat/completions")!

    let model: String
    let reasoningEffort: String
    private let apiKey: String?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        model = environment["BEAN_BRAIN_MODEL"] ?? "muse-spark-1.3"
        reasoningEffort = environment["BEAN_BRAIN_EFFORT"] ?? "low"
        apiKey = environment["MODEL_API_KEY"] ?? Self.keyFromSourceEnvFile()
    }

    struct Reply {
        let json: Data
        let promptTokens: Int?
        let completionTokens: Int?
    }

    func complete(system: String, text: String, jpeg: Data?, schema: [String: Any]) async throws -> Reply {
        guard let apiKey else { throw SparkError.noKey }
        var content: [[String: Any]] = [["type": "text", "text": text]]
        if let jpeg {
            content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]])
        }
        let body: [String: Any] = [
            "model": model,
            "reasoning_effort": reasoningEffort,
            "messages": [["role": "system", "content": system], ["role": "user", "content": content]],
            "response_format": ["type": "json_schema", "json_schema": ["name": "bean_reply", "strict": true, "schema": schema]],
        ]
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
            struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message }
            struct Usage: Decodable { let prompt_tokens: Int?; let completion_tokens: Int? }
            let choices: [Choice]
            let usage: Usage?
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let text = decoded.choices.first?.message.content else { throw SparkError.empty }
        return Reply(json: Data(text.utf8), promptTokens: decoded.usage?.prompt_tokens, completionTokens: decoded.usage?.completion_tokens)
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
