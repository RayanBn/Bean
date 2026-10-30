import Foundation

final class BeanSettings: ObservableObject {
    static let shared = BeanSettings()

    private let defaults = BeanDefaults.shared
    private let environment = ProcessInfo.processInfo.environment

    @Published var provider: AIProvider {
        didSet {
            defaults.set(provider.rawValue, forKey: "provider")
            model = defaults.string(forKey: "model.\(provider.rawValue)") ?? provider.defaultModel
        }
    }
    @Published var model: String { didSet { defaults.set(model, forKey: "model.\(provider.rawValue)") } }
    @Published var customBaseURL: String { didSet { defaults.set(customBaseURL, forKey: "customBaseURL") } }
    @Published var brainEffort: String { didSet { defaults.set(brainEffort, forKey: "brainEffort") } }
    @Published var offLimits: [String] { didSet { defaults.set(offLimits, forKey: "offLimits") } }
    @Published var paused = false
    @Published var decidesOnThisMac: Bool { didSet { defaults.set(decidesOnThisMac, forKey: "usesStrands") } }

    private init() {
        let provider = defaults.string(forKey: "provider").flatMap(AIProvider.init) ?? .meta
        self.provider = provider
        model = defaults.string(forKey: "model.\(provider.rawValue)") ?? provider.defaultModel
        customBaseURL = defaults.string(forKey: "customBaseURL") ?? "http://localhost:11434/v1"
        brainEffort = defaults.string(forKey: "brainEffort") ?? "low"
        offLimits = defaults.stringArray(forKey: "offLimits") ?? []
        decidesOnThisMac = defaults.bool(forKey: "usesStrands")
    }

    var effectiveDecidesOnThisMac: Bool { environment["BEAN_DECIDER"].map { $0 == "strands" } ?? decidesOnThisMac }
    var effectivePaused: Bool { environment["BEAN_PAUSED"].map { $0 == "1" } ?? paused }
    var effectiveProvider: AIProvider { environment["BEAN_PROVIDER"].flatMap(AIProvider.init) ?? provider }
    var effectiveModel: String {
        environment["BEAN_BRAIN_MODEL"] ?? (effectiveProvider == provider ? model : defaults.string(forKey: "model.\(effectiveProvider.rawValue)") ?? effectiveProvider.defaultModel)
    }
    var effectiveBaseURL: URL? {
        environment["BEAN_BASE_URL"].flatMap(URL.init(string:)) ?? effectiveProvider.defaultBaseURL ?? URL(string: customBaseURL)
    }
    var effectiveBrainEffort: String { environment["BEAN_BRAIN_EFFORT"] ?? brainEffort }
    var effectiveOffLimits: [String] {
        environment["BEAN_OFF_LIMITS"].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } ?? offLimits
    }
}
