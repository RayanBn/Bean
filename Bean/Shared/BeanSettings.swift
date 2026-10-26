import Foundation

final class BeanSettings: ObservableObject {
    enum GateProvider: String, CaseIterable, Identifiable {
        case cloud, local
        var id: String { rawValue }
        var recommendedThreshold: Double { self == .cloud ? 0.5 : 0.65 }
    }

    static let shared = BeanSettings()

    private let defaults = UserDefaults.standard
    private let environment = ProcessInfo.processInfo.environment

    @Published var gateProvider: GateProvider { didSet { defaults.set(gateProvider.rawValue, forKey: "gateProvider") } }
    @Published var cloudThreshold: Double { didSet { defaults.set(cloudThreshold, forKey: "cloudThreshold") } }
    @Published var localThreshold: Double { didSet { defaults.set(localThreshold, forKey: "localThreshold") } }
    @Published var stuckSeconds: Double { didSet { defaults.set(stuckSeconds, forKey: "stuckSeconds") } }
    @Published var idleSeconds: Double { didSet { defaults.set(idleSeconds, forKey: "idleSeconds") } }
    @Published var provider: AIProvider {
        didSet {
            defaults.set(provider.rawValue, forKey: "provider")
            model = defaults.string(forKey: "model.\(provider.rawValue)") ?? provider.defaultModel
        }
    }
    @Published var model: String { didSet { defaults.set(model, forKey: "model.\(provider.rawValue)") } }
    @Published var customBaseURL: String { didSet { defaults.set(customBaseURL, forKey: "customBaseURL") } }
    @Published var brainEffort: String { didSet { defaults.set(brainEffort, forKey: "brainEffort") } }
    @Published var readBrowser: Bool { didSet { defaults.set(readBrowser, forKey: "readBrowser") } }
    @Published var quietInMeetings: Bool { didSet { defaults.set(quietInMeetings, forKey: "quietInMeetings") } }
    @Published var paused = false

    private init() {
        gateProvider = (defaults.string(forKey: "gateProvider")).flatMap(GateProvider.init) ?? .cloud
        cloudThreshold = defaults.object(forKey: "cloudThreshold") as? Double ?? GateProvider.cloud.recommendedThreshold
        localThreshold = defaults.object(forKey: "localThreshold") as? Double ?? GateProvider.local.recommendedThreshold
        stuckSeconds = defaults.object(forKey: "stuckSeconds") as? Double ?? 180
        idleSeconds = defaults.object(forKey: "idleSeconds") as? Double ?? 300
        let provider = defaults.string(forKey: "provider").flatMap(AIProvider.init) ?? .meta
        self.provider = provider
        model = defaults.string(forKey: "model.\(provider.rawValue)") ?? provider.defaultModel
        customBaseURL = defaults.string(forKey: "customBaseURL") ?? "http://localhost:11434/v1"
        brainEffort = defaults.string(forKey: "brainEffort") ?? "low"
        readBrowser = defaults.object(forKey: "readBrowser") as? Bool ?? true
        quietInMeetings = defaults.object(forKey: "quietInMeetings") as? Bool ?? true
    }

    var effectiveGateProvider: GateProvider { environment["BEAN_GATE_PROVIDER"].flatMap(GateProvider.init) ?? gateProvider }
    var effectiveThreshold: Double {
        environment["BEAN_GATE_THRESHOLD"].flatMap(Double.init) ?? (effectiveGateProvider == .cloud ? cloudThreshold : localThreshold)
    }
    var effectiveStuckSeconds: Double { environment["BEAN_STUCK_SECONDS"].flatMap(Double.init) ?? stuckSeconds }
    var effectiveIdleSeconds: Double { environment["BEAN_IDLE_SECONDS"].flatMap(Double.init) ?? idleSeconds }
    var effectiveProvider: AIProvider { environment["BEAN_PROVIDER"].flatMap(AIProvider.init) ?? provider }
    var effectiveModel: String {
        environment["BEAN_BRAIN_MODEL"] ?? (effectiveProvider == provider ? model : defaults.string(forKey: "model.\(effectiveProvider.rawValue)") ?? effectiveProvider.defaultModel)
    }
    var effectiveBaseURL: URL? {
        environment["BEAN_BASE_URL"].flatMap(URL.init(string:)) ?? effectiveProvider.defaultBaseURL ?? URL(string: customBaseURL)
    }
    var effectiveBrainEffort: String { environment["BEAN_BRAIN_EFFORT"] ?? brainEffort }
}
