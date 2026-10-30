import AppKit
import SwiftUI

final class PageWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}

final class Agents: ObservableObject {
    @Published private(set) var selected: UUID?
    var onSendHome: ((UUID) -> Void)?
    let store: AgentStore
    let worker: AgentWorker
    private let notch: NotchController
    private let reader: WindowReader
    private let window: PageWindow
    private var previous: NSRunningApplication?
    private var proposing = false
    private var closing: NSObjectProtocol?
    private let ideasFile = JSONLog.directory.appendingPathComponent("ideas.json")

    init(store: AgentStore, notch: NotchController) {
        self.store = store
        self.notch = notch
        reader = WindowReader(store: store)
        worker = reader.worker
        window = PageWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = "Bean"
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = NSColor(red: 0.985, green: 0.978, blue: 0.965, alpha: 1)
        window.minSize = NSSize(width: 760, height: 480)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.setFrameAutosaveName("BeanAgentsPage")
        window.contentView = NSHostingView(rootView: AgentsPageRoot(agents: self, store: store, worker: worker))
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.previous?.activate()
            self?.previous = nil
        }
        notch.onCreate = { [weak self] new in self?.hatch(new) }
        notch.onOpen = { [weak self] in self?.open() }
        if !store.agents.contains(where: \.isBean) { adoptBean() }
        if let data = try? Data(contentsOf: ideasFile), let saved = try? JSONDecoder().decode([AgentProposal].self, from: data) {
            notch.setIdeas(saved.map(Self.idea))
        }
        refreshIdeas()
        refreshSuggestions()
    }

    func refreshIdeas() {
        guard !proposing, ModelClient().isReady else { return }
        proposing = true
        Task { @MainActor in
            defer { proposing = false }
            let inventory = await Task.detached { MacInventory.scan() }.value
            guard let proposals = try? await AgentMaker().propose(from: inventory), !proposals.isEmpty else { return }
            try? JSONEncoder().encode(proposals).write(to: ideasFile, options: .atomic)
            notch.setIdeas(proposals.map(Self.idea))
        }
    }

    func open(_ id: UUID? = nil) {
        if let id, store.agents.contains(where: { $0.id == id }) { selected = id }
        if selected == nil || !store.agents.contains(where: { $0.id == selected }) { selected = Self.first(store.agents, store.activity) }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous = front }
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func select(_ id: UUID) {
        selected = id
    }

    func newAgent() {
        notch.beginCreate()
    }

    func sendHome(_ id: UUID) {
        onSendHome?(id)
    }

    func delete(_ id: UUID) {
        guard id != Agent.beanID else { return }
        if selected == id { selected = store.agents.first(where: { $0.id != id })?.id }
        store.remove(id)
        store.activity[id] = nil
    }

    func save(_ mission: AgentMission, for id: UUID) {
        guard let agent = store.agents.first(where: { $0.id == id }) else { return }
        AgentFolder(agent, in: store).save(mission)
        objectWillChange.send()
        refreshSuggestions()
    }

    func undo(_ id: UUID, entry: UUID) {
        worker.undo(id, entry: entry)
    }

    var feed: PageFeed {
        PageFeed(journal: worker.journal, doing: worker.doing, sessions: worker.sessions, credits: worker.credits,
                 missions: Dictionary(uniqueKeysWithValues: store.agents.map { ($0.id, AgentFolder($0, in: store).mission) }).compactMapValues { $0 })
    }

    private func refreshSuggestions() {
        let others = store.agents.flatMap { AgentFolder($0, in: store).mission?.scope ?? [] }
        notch.model.scopeSuggestions = Array(NSOrderedSet(array: others + worker.knownScopes)) as? [String] ?? []
    }

    private static func first(_ agents: [Agent], _ activity: [UUID: AgentActivity]) -> UUID? {
        agents.first { activity[$0.id]?.mood == .needsYou }?.id ?? agents.first { activity[$0.id]?.mood == .working }?.id ?? agents.first(where: \.isBean)?.id
    }

    private func hatch(_ new: NewAgent) {
        let id = UUID()
        let hue = AgentIdea.hue(for: new.request)
        store.activity[id] = AgentActivity(mood: .forming(Date()))
        store.save(Agent(id: id, name: "", role: "", personality: "", look: .init(hue: hue, accessory: "none"),
                         connectors: [], attachment: nil, createdAt: Date()))
        notch.hatch(id, hue: hue)
        if notch.model.ideas.contains(where: { $0.request == new.request }) {
            notch.setIdeas(notch.model.ideas.filter { $0.request != new.request })
            refreshIdeas()
        }
        Task { @MainActor in
            do {
                let created = try await AgentMaker().write(new.request)
                guard let current = store.agents.first(where: { $0.id == id }) else { return }
                let agent = Agent(id: id, name: created.agent.name, role: created.agent.role, personality: created.agent.personality,
                                  look: .init(hue: hue, accessory: created.agent.look.accessory), connectors: [],
                                  attachment: current.attachment, createdAt: current.createdAt)
                let folder = AgentFolder(agent, in: store)
                try folder.create(agent: agent, voice: created.voice, lines: created.lines)
                var mission = created.mission
                mission.scope = Array(NSOrderedSet(array: new.scope + mission.scope)) as? [String] ?? new.scope
                mission.mayMerge = mission.mayMerge || new.mayMerge
                mission.mayDeploy = mission.mayDeploy || new.mayDeploy
                folder.save(mission)
                store.activity[id] = AgentActivity()
                store.save(agent)
                notch.settle(id)
            } catch {
                store.remove(id)
                store.activity[id] = nil
                fail(error) { [weak self] in self?.hatch(new) }
            }
        }
    }

    private func adoptBean() {
        let bean = Agent(id: Agent.beanID, name: "Bean", role: "Your main agent. It looks after the others and any window you give it.",
                         personality: "Bean is the first drop, the one the others split from. Calm, warm, a little dry. It notices what matters and says it in few words, and it never makes a fuss.",
                         look: .pearl, connectors: [], attachment: nil, createdAt: .distantPast)
        let lines = AgentLines(greeting: "here. i'll keep an eye on this one.", offLimits: "not looking at this one.")
        try? AgentFolder(bean, in: store).create(agent: bean, voice: "Short and warm, often lowercase. One idea per line, never more than one exclamation.", lines: lines)
        store.save(bean)
    }

    private static func idea(_ proposal: AgentProposal) -> AgentIdea {
        AgentIdea(label: proposal.label, request: proposal.request)
    }

    private func fail(_ error: Error, retry: @escaping () -> Void) {
        notch.show(NotchMessage(text: "I couldn't make that agent: \(error.localizedDescription)", choices: [
            NotchChoice(label: "Later", isPrimary: false) { [weak self] in self?.notch.rest() },
            NotchChoice(label: "Try again", isPrimary: true) { [weak self] in
                self?.notch.rest()
                retry()
            },
        ]))
    }
}
