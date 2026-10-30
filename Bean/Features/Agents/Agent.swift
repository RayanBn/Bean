import Foundation

struct Agent: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var role: String
    var personality: String
    var look: Look
    var connectors: [String]
    var attachment: Attachment?
    let createdAt: Date

    struct Look: Codable, Equatable {
        static let accessories = ["none", "glasses", "headset", "antenna", "cap", "bow", "scarf"]
        var hue: Double
        var accessory: String
    }
}

struct AgentActivity: Equatable {
    enum Mood: Equatable {
        case idle, reading, working, needsYou, sleeping, forming(Date)

        var isForming: Bool {
            if case .forming = self { return true }
            return false
        }
    }
    var mood: Mood = .idle
    var bubble: String?
}

struct Attachment: Codable, Equatable {
    var bundleId: String
    var appName: String
    var pid: Int32
    var windowNumber: Int
    var windowTitle: String?
}

final class AgentStore: ObservableObject {
    @Published private(set) var agents: [Agent] = []
    @Published var activity: [UUID: AgentActivity] = [:]
    let root: URL

    init(root: URL = JSONLog.directory.appendingPathComponent("Agents")) {
        self.root = root
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let loaded = folders.compactMap { folder in
            (try? Data(contentsOf: folder.appendingPathComponent("agent.json"))).flatMap { try? decoder.decode(Agent.self, from: $0) }
        }
        for unborn in loaded where unborn.name.isEmpty {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(unborn.id.uuidString))
        }
        agents = loaded.filter { !$0.name.isEmpty }.sorted { $0.createdAt < $1.createdAt }
    }

    func folder(for agent: Agent) -> URL {
        root.appendingPathComponent(agent.id.uuidString)
    }

    func save(_ agent: Agent) {
        if let i = agents.firstIndex(where: { $0.id == agent.id }) { agents[i] = agent } else { agents.append(agent) }
        let folder = folder(for: agent)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(agent).write(to: folder.appendingPathComponent("agent.json"), options: .atomic)
    }

    func attach(_ id: UUID, to attachment: Attachment?) {
        guard var agent = agents.first(where: { $0.id == id }) else { return }
        agent.attachment = attachment
        save(agent)
    }

    func remove(_ id: UUID) {
        guard let agent = agents.first(where: { $0.id == id }) else { return }
        agents.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: folder(for: agent))
    }
}
