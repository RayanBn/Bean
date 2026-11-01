import AppKit

struct Agent: Identifiable, Equatable {
    static let beanID = UUID(uuidString: "BEA00000-0000-0000-0000-000000000001")!

    let id: UUID
    var name: String
    var role: String
    var look: Look
    // Its apps, kept by bundle id even while one has quit. Only the person taking it off removes one.
    var attachments: [Attachment]
    let createdAt: Date

    var isBean: Bool { id == Self.beanID }

    // The app it is in now: the first of its apps that runs.
    var attachment: Attachment? {
        get { attachments.first { $0.runningPid != nil } ?? attachments.first }
        set { attachments = newValue.map { [$0] } ?? [] }
    }

    func holds(_ bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return attachments.contains { $0.bundleId == bundleId }
    }

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

extension Agent {
    init(id: UUID, name: String, role: String, look: Look, attachment: Attachment?, createdAt: Date) {
        self.init(id: id, name: name, role: role, look: look, attachments: attachment.map { [$0] } ?? [], createdAt: createdAt)
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

    // An app with no bundle id is known only by its process.
    var key: String { bundleId.isEmpty ? "pid \(pid)" : bundleId }

    // A kept app can outlive its pid by days, so a live pid counts only for a process that is this app. A bundle id that differs means the pid was reused.
    var runningPid: Int32? {
        if pid > 0, kill(pid, 0) == 0 || errno == EPERM {
            if bundleId.isEmpty { return pid }
            if pidIsThisApp { return pid }
        }
        return bundleId.isEmpty ? nil : NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.processIdentifier
    }

    // NSRunningApplication can lose sight of a live app for a moment, which once sent an agent home, so the process's own file decides then.
    private var pidIsThisApp: Bool {
        if let running = NSRunningApplication(processIdentifier: pid) { return running.bundleIdentifier == bundleId }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, 4096) > 0 else { return false }
        let file = String(cString: path)
        guard let end = file.range(of: ".app/")?.lowerBound else { return false }
        return Bundle(path: file[..<end] + ".app")?.bundleIdentifier == bundleId
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
            return folder.card?.agent(attachments: folder.state.apps)
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
        place.updateState { $0.apps = agent.attachments }
    }

    // Adds the app to the ones it holds. Nil takes it off all of them.
    func attach(_ id: UUID, to attachment: Attachment?) {
        guard var agent = agents.first(where: { $0.id == id }) else { return }
        if let attachment {
            if let i = agent.attachments.firstIndex(where: { $0.key == attachment.key }) { agent.attachments[i] = attachment } else { agent.attachments.append(attachment) }
        } else {
            agent.attachments = []
        }
        save(agent)
    }

    func detach(_ id: UUID, app key: String) {
        guard var agent = agents.first(where: { $0.id == id }) else { return }
        agent.attachments.removeAll { $0.key == key }
        save(agent)
    }

    func sit(_ id: UUID, app key: String, pid: Int32, windowNumber: Int, windowTitle: String?) {
        guard let i = agents.firstIndex(where: { $0.id == id }), let held = agents[i].attachments.firstIndex(where: { $0.key == key }) else { return }
        agents[i].attachments[held].pid = pid
        agents[i].attachments[held].windowNumber = windowNumber
        agents[i].attachments[held].windowTitle = windowTitle
        let apps = agents[i].attachments
        AgentFolder(url: folder(for: agents[i])).updateState { $0.apps = apps }
    }

    func remove(_ id: UUID) {
        guard let agent = agents.first(where: { $0.id == id }) else { return }
        agents.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: folder(for: agent))
    }
}
