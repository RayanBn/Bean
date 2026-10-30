import AppKit
import SwiftUI

final class AgentsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class Agents: ObservableObject {
    enum Screen: Equatable {
        case closed
        case choosing([AgentProposal])
        case agent(UUID)
    }

    static let width: CGFloat = 460

    @Published private(set) var screen = Screen.closed
    @Published var draft = ""
    let store: AgentStore
    private let notch: NotchController
    private let reader: WindowReader
    private let panel: AgentsPanel
    private var height: CGFloat = 120
    private var outsideClicks: Any?
    private var busy = false

    init(store: AgentStore, notch: NotchController) {
        self.store = store
        self.notch = notch
        reader = WindowReader(store: store)
        panel = AgentsPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.contentView = NSHostingView(rootView: AgentsView(agents: self, store: store) { [weak self] height in self?.fit(height) })
    }

    func create() {
        guard !busy else { return }
        busy = true
        notch.think("Thinking of agents for you")
        Task { @MainActor in
            let inventory = await Task.detached { MacInventory.scan() }.value
            do {
                let proposals = try await AgentMaker().propose(from: inventory)
                busy = false
                guard case .thinking = notch.model.phase else { return }
                notch.rest()
                open(.choosing(proposals))
            } catch {
                fail(error, retry: create)
            }
        }
    }

    func onAgentClick(_ id: UUID) {
        guard store.agents.contains(where: { $0.id == id }) else { return }
        open(.agent(id))
    }

    func pick(_ proposal: AgentProposal) {
        write(proposal.request, name: proposal.name)
    }

    func describe() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        write(text, name: nil)
    }

    func unplug(_ id: UUID) {
        store.attach(id, to: nil)
    }

    func delete(_ id: UUID) {
        close()
        store.remove(id)
        store.activity[id] = nil
    }

    func close() {
        screen = .closed
        panel.orderOut(nil)
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
    }

    private func write(_ request: String, name: String?) {
        close()
        busy = true
        notch.think(name.map { "Writing \($0)" } ?? "Writing your agent")
        Task { @MainActor in
            do {
                let created = try await AgentMaker().write(request)
                try AgentMaker.save(created, in: store)
                busy = false
                store.activity[created.agent.id] = AgentActivity(mood: .idle, bubble: created.lines.greeting)
                notch.done("\(created.agent.name) is here")
                try? await Task.sleep(for: .seconds(2.5))
                if case .done = notch.model.phase { notch.rest() }
            } catch {
                fail(error) { self.write(request, name: name) }
            }
        }
    }

    private func fail(_ error: Error, retry: @escaping () -> Void) {
        busy = false
        notch.show(NotchMessage(text: "I couldn't make that agent: \(error.localizedDescription)", choices: [
            NotchChoice(label: "Later", isPrimary: false) { [weak self] in self?.notch.rest() },
            NotchChoice(label: "Try again", isPrimary: true) { [weak self] in
                self?.notch.rest()
                retry()
            },
        ]))
    }

    private func open(_ screen: Screen) {
        self.screen = screen
        place()
        panel.orderFrontRegardless()
        if outsideClicks == nil {
            outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() }
        }
    }

    private func fit(_ height: CGFloat) {
        guard abs(height - self.height) > 0.5 else { return }
        self.height = height
        place()
    }

    private func place() {
        let geometry = NotchGeometry.current()
        let top = geometry.screen.frame.maxY - geometry.notchSize.height - (geometry.hasNotch ? 8 : 14)
        panel.setFrame(NSRect(x: geometry.screen.frame.midX - Self.width / 2, y: top - height, width: Self.width, height: height), display: true)
    }
}
