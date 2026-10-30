import Foundation

struct Agent: Codable, Identifiable, Equatable {
    static let beanID = UUID(uuidString: "BEA00000-0000-0000-0000-000000000001")!

    let id: UUID
    var name: String
    var role: String
    var personality: String
    var look: Look
    var connectors: [String]
    var attachment: Attachment?
    let createdAt: Date

    var isBean: Bool { id == Self.beanID }

    struct Look: Codable, Equatable {
        static let accessories = ["none", "star", "bolt", "leaf", "heart", "sparkle"]
        static let hues = [0.6, 0.02, 0.12, 0.47, 0.78, 0.92, 0.3, 0.54]
        static let pearl = Look(hue: 0.66, accessory: "pearl")
        var hue: Double
        var accessory: String
        var chosen: Bool?

        var isPearl: Bool { accessory == Self.pearl.accessory }

        static func symbol(for mark: String) -> String? {
            switch mark {
            case "star": "star.fill"
            case "bolt": "bolt.fill"
            case "leaf": "leaf.fill"
            case "heart": "heart.fill"
            case "sparkle": "sparkle"
            default: nil
            }
        }

        static func nextHue(taken: [Double]) -> Double {
            func gap(_ hue: Double) -> Double {
                taken.map { min(abs($0 - hue), 1 - abs($0 - hue)) }.min() ?? 1
            }
            return hues.first { gap($0) >= 0.06 } ?? hues.max { gap($0) < gap($1) } ?? 0.6
        }
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
