import AppKit
import SwiftUI

final class AgentsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class Agents: ObservableObject {
    static let width: CGFloat = 290

    @Published private(set) var shown: UUID?
    var onUnplug: ((UUID) -> Void)?
    let store: AgentStore
    private let notch: NotchController
    private let reader: WindowReader
    private let panel: AgentsPanel
    private var anchor = NSRect.zero
    private var height: CGFloat = 160
    private var outsideClicks: Any?
    private var proposing = false
    private let ideasFile = JSONLog.directory.appendingPathComponent("ideas.json")

    init(store: AgentStore, notch: NotchController) {
        self.store = store
        self.notch = notch
        reader = WindowReader(store: store)
        panel = AgentsPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.contentView = NSHostingView(rootView: AgentsView(agents: self, store: store) { [weak self] height in self?.fit(height) })
        notch.onCreate = { [weak self] request in self?.hatch(request) }
        if let data = try? Data(contentsOf: ideasFile), let saved = try? JSONDecoder().decode([AgentProposal].self, from: data) {
            notch.setIdeas(saved.map(Self.idea))
        }
        refreshIdeas()
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

    func onAgentClick(_ id: UUID, from anchor: NSRect) {
        guard let agent = store.agents.first(where: { $0.id == id }), !agent.name.isEmpty else { return }
        self.anchor = anchor
        shown = id
        place()
        panel.orderFrontRegardless()
        if outsideClicks == nil {
            outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() }
        }
    }

    func unplug(_ id: UUID) {
        close()
        onUnplug?(id)
    }

    func delete(_ id: UUID) {
        close()
        store.remove(id)
        store.activity[id] = nil
    }

    func close() {
        shown = nil
        panel.orderOut(nil)
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
    }

    private func hatch(_ request: String) {
        let id = UUID()
        let hue = AgentIdea.hue(for: request)
        store.activity[id] = AgentActivity(mood: .forming(Date()))
        store.save(Agent(id: id, name: "", role: "", personality: "", look: .init(hue: hue, accessory: "none"),
                         connectors: [], attachment: nil, createdAt: Date()))
        notch.hatch(id, hue: hue)
        if notch.model.ideas.contains(where: { $0.request == request }) {
            notch.setIdeas(notch.model.ideas.filter { $0.request != request })
            refreshIdeas()
        }
        Task { @MainActor in
            do {
                let created = try await AgentMaker().write(request)
                guard let current = store.agents.first(where: { $0.id == id }) else { return }
                let agent = Agent(id: id, name: created.agent.name, role: created.agent.role, personality: created.agent.personality,
                                  look: .init(hue: hue, accessory: created.agent.look.accessory), connectors: [],
                                  attachment: current.attachment, createdAt: current.createdAt)
                try AgentFolder(agent, in: store).create(agent: agent, voice: created.voice, lines: created.lines)
                store.activity[id] = AgentActivity(mood: .idle, bubble: created.lines.greeting)
                store.save(agent)
                notch.greet(id, created.lines.greeting)
                try? await Task.sleep(for: .seconds(4))
                if notch.model.hint == created.lines.greeting { notch.greet(id, "Drag me onto any window.") }
            } catch {
                store.remove(id)
                store.activity[id] = nil
                fail(error) { [weak self] in self?.hatch(request) }
            }
        }
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

    private func fit(_ height: CGFloat) {
        guard abs(height - self.height) > 0.5 else { return }
        self.height = height
        place()
    }

    private func place() {
        let screen = Screens.containing(NSPoint(x: anchor.midX, y: anchor.midY))?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let gap: CGFloat = 10
        let right = anchor.maxX + gap + Self.width <= screen.maxX
        let x = right ? anchor.maxX + gap : anchor.minX - gap - Self.width
        let y = min(anchor.maxY + 8, screen.maxY) - height
        panel.setFrame(NSRect(x: x, y: max(screen.minY, y), width: Self.width, height: height), display: true)
    }
}
