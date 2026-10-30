import AppKit
import Combine
import SwiftUI
import UserNotifications

final class NeedsYouNotifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((UUID) -> Void)?
    private var notified: Set<UUID> = []

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func update(_ agents: [Agent], _ activity: [UUID: AgentActivity]) {
        for agent in agents {
            guard activity[agent.id]?.mood == .needsYou else {
                notified.remove(agent.id)
                continue
            }
            guard notified.insert(agent.id).inserted else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(agent.name) needs you"
            content.body = activity[agent.id]?.bubble ?? "Open Bean to see why."
            content.userInfo = ["agent": agent.id.uuidString]
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
                guard granted else { return }
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: agent.id.uuidString, content: content, trigger: nil))
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let text = response.notification.request.content.userInfo["agent"] as? String, let id = UUID(uuidString: text) else { return }
        await MainActor.run { onOpen?(id) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner] }
}

final class Agents: ObservableObject {
    @Published private(set) var selected: UUID?
    @Published private(set) var creating = false
    @Published private(set) var creationError: String?
    var onSendHome: ((UUID) -> Void)?
    let store: AgentStore
    let worker: AgentWorker
    private let notch: NotchController
    private let reader: WindowReader
    private let window: NSWindow
    private var previous: NSRunningApplication?
    private var closing: NSObjectProtocol?
    private var shortcut: Any?
    private let notifier = NeedsYouNotifier()
    private var watching: AnyCancellable?
    private static let welcomed = JSONLog.directory.appendingPathComponent("welcomed")
    var onAddKey: (() -> Void)?

    init(store: AgentStore, notch: NotchController) {
        self.store = store
        self.notch = notch
        reader = WindowReader(store: store)
        worker = reader.worker
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.title = "Agents"
        window.minSize = NSSize(width: 760, height: 480)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let host = NSHostingController(rootView: AgentsPageRoot(agents: self, store: store, worker: worker))
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1080, height: 680))
        if !window.setFrameUsingName("BeanAgentsWindow") { window.center() }
        window.setFrameAutosaveName("BeanAgentsWindow")
        shortcut = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" else { return event }
            self.window.close()
            return nil
        }
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            NSApp.setActivationPolicy(.accessory)
            self?.previous?.activate()
            self?.previous = nil
        }
        notifier.onOpen = { [weak self] id in self?.open(id) }
        watching = store.$activity.combineLatest(store.$agents).receive(on: DispatchQueue.main).sink { [weak self] activity, agents in
            self?.notifier.update(agents, activity)
        }
        notch.onRoster = { [weak self] id in self?.open(id) }
        notch.rosterProvider = { [weak self] in self?.roster ?? [] }
        notch.onNew = { [weak self] in self?.startNew() }
        notch.onOpen = { [weak self] in self?.open() }
        adoptBean()
        if !FileManager.default.fileExists(atPath: Self.welcomed.path) {
            FileManager.default.createFile(atPath: Self.welcomed.path, contents: nil)
            DispatchQueue.main.async { [weak self] in self?.open() }
        }
    }

    func open(_ id: UUID? = nil) {
        if let id, store.agents.contains(where: { $0.id == id }) {
            selected = id
            creating = false
        }
        if selected == nil || !store.agents.contains(where: { $0.id == selected }) { selected = Self.first(store.agents, store.activity) }
        show()
    }

    func startNew() {
        creating = true
        creationError = nil
        show()
    }

    private func show() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous = front }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private var roster: [RosterItem] {
        let current = feed
        return store.agents
            .sorted { Self.rank(store.activity[$0.id]?.mood) < Self.rank(store.activity[$1.id]?.mood) }
            .map { RosterItem(id: $0.id, name: $0.name, look: $0.look, mood: store.activity[$0.id]?.mood ?? .idle,
                              line: AgentsPage.status(of: $0, activity: store.activity[$0.id], feed: current)) }
    }

    private static func rank(_ mood: AgentActivity.Mood?) -> Int {
        switch PageStatus(mood ?? .idle) {
        case .needsYou: 0
        case .working: 1
        case .idle: 2
        }
    }

    var actions: PageActions {
        PageActions(
            select: { [weak self] id in
                self?.selected = id
                self?.creating = false
            },
            newAgent: { [weak self] in self?.startNew() },
            addKey: { [weak self] in self?.onAddKey?() },
            cancelNew: { [weak self] in self?.creating = false },
            create: { [weak self] mission in self?.hatch(mission) },
            send: { [weak self] id, text in self?.worker.send(id, text) },
            saveMission: { [weak self] id, text in self?.saveMission(text, for: id) },
            undo: { [weak self] id, entry in self?.worker.undo(id, entry: entry) },
            setAbility: { [weak self] id, ability, on in self?.worker.setAbility(id, ability: ability, allowed: on) },
            connect: { [weak self] id, connector in self?.worker.connect(id, connector: connector) },
            addTarget: { [weak self] id, name in self?.worker.addTarget(id, name: name) },
            removeTarget: { [weak self] id, target in self?.worker.removeTarget(id, target: target) },
            sendHome: { [weak self] id in self?.onSendHome?(id) },
            delete: { [weak self] id in self?.delete(id) },
            reveal: { [weak self] id in
                guard let self, let agent = self.store.agents.first(where: { $0.id == id }) else { return }
                NSWorkspace.shared.activateFileViewerSelecting([AgentFolder(agent, in: self.store).url])
            })
    }

    var feed: PageFeed {
        var missions: [UUID: AgentMission] = [:]
        for agent in store.agents { missions[agent.id] = AgentFolder(agent, in: store).mission }
        return PageFeed(journal: worker.journal, doing: worker.doing, sessions: worker.sessions, credits: worker.credits, missions: missions,
                        needsKey: !ModelClient().isReady, targets: worker.targets, connectors: worker.connectors, abilities: worker.abilities, replying: worker.replying)
    }

    private func saveMission(_ text: String, for id: UUID) {
        guard let agent = store.agents.first(where: { $0.id == id }) else { return }
        let folder = AgentFolder(agent, in: store)
        guard var mission = folder.mission else { return }
        mission.mission = text
        folder.save(mission)
        objectWillChange.send()
    }

    private func delete(_ id: UUID) {
        guard id != Agent.beanID else { return }
        if selected == id { selected = store.agents.first(where: { $0.id != id })?.id }
        store.remove(id)
        store.activity[id] = nil
    }

    private func hatch(_ request: String) {
        let id = UUID()
        let hue = Self.hue(for: request)
        store.activity[id] = AgentActivity(mood: .forming(Date()))
        store.save(Agent(id: id, name: "", role: "", personality: "", look: .init(hue: hue, accessory: "none"),
                         connectors: [], attachment: nil, createdAt: Date()))
        selected = id
        creating = false
        creationError = nil
        notch.hatch(id, hue: hue)
        Task { @MainActor in
            do {
                let created = try await AgentMaker().write(request)
                guard let current = store.agents.first(where: { $0.id == id }) else { return }
                let agent = Agent(id: id, name: created.agent.name, role: created.agent.role, personality: created.agent.personality,
                                  look: .init(hue: hue, accessory: created.agent.look.accessory), connectors: [],
                                  attachment: current.attachment, createdAt: current.createdAt)
                let folder = AgentFolder(agent, in: store)
                try folder.create(agent: agent, voice: created.voice, lines: created.lines)
                folder.save(created.mission)
                store.activity[id] = AgentActivity()
                store.save(agent)
                notch.settle(id)
            } catch {
                store.remove(id)
                store.activity[id] = nil
                notch.settle(id)
                if selected == id { selected = nil }
                creationError = "The agent could not be created: \(error.localizedDescription)"
                creating = true
            }
        }
    }

    private static func hue(for text: String) -> Double {
        let sum = text.lowercased().unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }
        return Double(sum % 1000) / 1000
    }

    private static func first(_ agents: [Agent], _ activity: [UUID: AgentActivity]) -> UUID? {
        agents.first { activity[$0.id]?.mood == .needsYou }?.id ?? agents.first { activity[$0.id]?.mood == .working }?.id ?? agents.first(where: \.isBean)?.id
    }

    private func adoptBean() {
        let existing = store.agents.first(where: \.isBean)
        var bean = Agent(id: Agent.beanID, name: "Bean", role: "Main agent. Stands in for you in your Claude sessions and coordinates the other agents.",
                         personality: "A senior engineer who knows your work and your priorities. Direct, precise and calm. Decides what you would decide and records why.",
                         look: .pearl, connectors: existing?.connectors ?? [], attachment: nil, createdAt: .distantPast)
        bean.attachment = existing?.attachment
        let lines = AgentLines(greeting: "Ready.", offLimits: "This window is off limits, so it was not read.")
        try? AgentFolder(bean, in: store).create(agent: bean, voice: "Short, factual sentences. States what was done and what is next. No filler.", lines: lines)
        if existing != bean { store.save(bean) }
    }
}
