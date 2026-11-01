import AppKit

struct Agent: Identifiable, Equatable {
    static let beanID = UUID(uuidString: "BEA00000-0000-0000-0000-000000000001")!

    let id: UUID
    var name: String
    var role: String
    var look: Look
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

    // An agent is on the app. The window fields only say where it sits now, so another window of the app is the same attachment.
    static func == (a: Attachment, b: Attachment) -> Bool { a.bundleId == b.bundleId && a.pid == b.pid }

    // The process table decides, because asking NSRunningApplication alone once sent an agent home from a live app. A bundle id that differs means the pid was reused.
    var runningPid: Int32? {
        if pid > 0, kill(pid, 0) == 0 || errno == EPERM, bundleId.isEmpty || NSRunningApplication(processIdentifier: pid)?.bundleIdentifier.map({ $0 == bundleId }) != false { return pid }
        return bundleId.isEmpty ? nil : NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.processIdentifier
    }
}

@MainActor
final class AgentStore: ObservableObject {
    @Published private(set) var agents: [Agent] = []
    // The compiler holds this for Swift code. The check catches a caller from outside it, such as an old callback.
    @Published var activity: [UUID: AgentActivity] = [:] {
        willSet { dispatchPrecondition(condition: .onQueue(.main)) }
    }
    let root: URL

    init(root: URL = JSONLog.directory.appendingPathComponent("Agents")) {
        self.root = root
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let loaded = folders.compactMap { url -> Agent? in
            let folder = AgentFolder(url: url)
            folder.importOldFiles()
            folder.importOldSwitches()
            folder.importOldMemory()
            return folder.card?.agent(attachment: folder.state.attachment)
        }
        for unborn in loaded where unborn.name.isEmpty {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(unborn.id.uuidString))
        }
        agents = loaded.filter { !$0.name.isEmpty }.sorted { $0.createdAt < $1.createdAt }
    }

    nonisolated func folder(for agent: Agent) -> URL {
        root.appendingPathComponent(agent.id.uuidString)
    }

    func save(_ agent: Agent) {
        if let i = agents.firstIndex(where: { $0.id == agent.id }) { agents[i] = agent } else { agents.append(agent) }
        let place = AgentFolder(url: folder(for: agent))
        if var card = place.card {
            card.name = agent.name
            card.role = agent.role
            card.look = agent.look
            place.write(card)
        } else {
            place.create(agent: agent)
        }
        place.updateState { $0.attachment = agent.attachment }
    }

    func attach(_ id: UUID, to attachment: Attachment?) {
        guard var agent = agents.first(where: { $0.id == id }) else { return }
        agent.attachment = attachment
        save(agent)
    }

    func sit(_ id: UUID, pid: Int32, windowNumber: Int, windowTitle: String?) {
        guard let i = agents.firstIndex(where: { $0.id == id }), var attachment = agents[i].attachment else { return }
        attachment.pid = pid
        attachment.windowNumber = windowNumber
        attachment.windowTitle = windowTitle
        agents[i].attachment = attachment
        AgentFolder(url: folder(for: agents[i])).updateState { $0.attachment = attachment }
    }

    func remove(_ id: UUID) {
        guard let agent = agents.first(where: { $0.id == id }) else { return }
        agents.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: folder(for: agent))
    }
}
