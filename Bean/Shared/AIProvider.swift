import Foundation

enum AIProvider: String, CaseIterable, Identifiable {
    case meta, openRouter, openAICompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .meta: return "Meta (Muse Spark)"
        case .openRouter: return "OpenRouter"
        case .openAICompatible: return "OpenAI-compatible"
        }
    }

    var defaultBaseURL: URL? {
        switch self {
        case .meta: return URL(string: "https://api.meta.ai/v1")
        case .openRouter: return URL(string: "https://openrouter.ai/api/v1")
        case .openAICompatible: return nil
        }
    }

    var defaultModel: String {
        switch self {
        case .meta: return "muse-spark-1.3"
        case .openRouter: return "meta-llama/llama-4-maverick"
        case .openAICompatible: return ""
        }
    }

    var keyURL: URL? {
        switch self {
        case .meta: return URL(string: "https://dev.meta.ai/platform")
        case .openRouter: return URL(string: "https://openrouter.ai/settings/keys")
        case .openAICompatible: return nil
        }
    }

    var acceptsReasoningEffort: Bool { self == .meta }
    var keyIsOptional: Bool { self == .openAICompatible }
}
