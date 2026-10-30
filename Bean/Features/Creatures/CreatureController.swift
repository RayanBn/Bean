import AppKit
import Combine
import SwiftUI

final class CreatureController {
    var onAgentClick: ((UUID) -> Void)?

    private let store: AgentStore
    private let notch: NotchController
    private let watch = WindowWatch()
    private let stage = DragStage()
    private let log = JSONLog(name: "creatures")
    private var perches: [UUID: Perch] = [:]
    private var homing: UUID?
    private var subscriptions: Set<AnyCancellable> = []
    private var monitors: [Any] = []
    private var rebindTimer: Timer?

    init(store: AgentStore, notch: NotchController) {
        self.store = store
        self.notch = notch
        stage.homeZone = { [weak notch] in notch?.islandFrame ?? .zero }
        notch.onCrewGesture = { [weak self] id, gesture in self?.crewGesture(id, gesture) }
        watch.onChange = { [weak self] number, window in self?.windowChanged(number, window) }
        store.$agents.combineLatest(store.$activity)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] agents, activity in self?.sync(agents, activity) }
            .store(in: &subscriptions)

        let hover: NSEvent.EventTypeMask = [.mouseMoved]
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: hover) { [weak self] _ in self?.hover() },
            NSEvent.addLocalMonitorForEvents(matching: hover) { [weak self] event in self?.hover(); return event },
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .leftMouseDown]) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { self?.perches.values.forEach { $0.raise() } }
            },
        ].compactMap { $0 }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.perches.values.forEach { $0.raise() }
        }
        rebindTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.rebindLost() }
    }

    private func sync(_ agents: [Agent], _ activity: [UUID: AgentActivity]) {
        notch.setCrew(agents.filter { $0.attachment == nil || $0.id == homing }.map {
            CrewMember(id: $0.id, name: $0.name, look: $0.look, mood: activity[$0.id]?.mood ?? .idle)
        })
        let attached = agents.filter { $0.attachment != nil }
        for (id, perch) in perches where !attached.contains(where: { $0.id == id }) {
            if let number = perch.window?.number { release(number, from: id) }
            perch.dismiss()
            perches[id] = nil
        }
        for (index, agent) in attached.enumerated() {
            guard let attachment = agent.attachment else { continue }
            let perch = perches[agent.id] ?? makePerch(agent.id, fraction: 0.72 - 0.1 * CGFloat(index % 4))
            let model = perch.model
            let mood = activity[agent.id]?.mood ?? .idle
            let bubble = activity[agent.id]?.bubble
            if model.name != agent.name { model.name = agent.name }
            if model.look != agent.look { model.look = agent.look }
            if model.mood != mood { model.mood = mood }
            if model.bubble != bubble { withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { model.bubble = bubble } }
            if perch.window?.number != attachment.windowNumber {
                if let old = perch.window?.number { release(old, from: agent.id) }
                perch.update(ForeignWindow.lookup(attachment.windowNumber))
                watch.watch(attachment.windowNumber)
            }
        }
    }

    private func makePerch(_ id: UUID, fraction: CGFloat) -> Perch {
        let perch = Perch(id: id, fraction: fraction,
                          onDragStart: { [weak self] in self?.liftFromPerch(id) },
                          onRelease: { [weak self] dragged in self?.released(id, dragged: dragged) })
        perches[id] = perch
        return perch
    }

    private func release(_ number: Int, from id: UUID) {
        if !perches.contains(where: { $0.key != id && $0.value.window?.number == number }) { watch.unwatch(number) }
    }

    private func windowChanged(_ number: Int, _ window: ForeignWindow?) {
        for perch in perches.values where store.agents.first(where: { $0.id == perch.id })?.attachment?.windowNumber == number {
            perch.update(window)
        }
        if window == nil { rebindLost() }
    }

    private func rebindLost() {
        for agent in store.agents {
            guard let attachment = agent.attachment, let perch = perches[agent.id], perch.window == nil, !perch.lifted,
                  let replacement = ForeignWindow.replacement(for: attachment) else { continue }
            record("rebound", agent, replacement)
            store.attach(agent.id, to: replacement.attachment)
        }
    }

    private func hover() {
        guard !stage.isActive else { return }
        let mouse = NSEvent.mouseLocation
        for perch in perches.values {
            let ignore = !(perch.hitRect?.contains(mouse) ?? false)
            if perch.panel.ignoresMouseEvents != ignore { perch.panel.ignoresMouseEvents = ignore }
        }
    }

    private func crewGesture(_ id: UUID, _ gesture: CrewGesture) {
        guard let agent = store.agents.first(where: { $0.id == id }) else { return }
        switch gesture {
        case .lift:
            notch.lift(id)
            record("lift", agent, nil, from: "notch")
            stage.begin(look: agent.look, mood: store.activity[id]?.mood ?? .idle, from: grip(ofHeadAt: notch.headPoint(for: id)),
                        size: notch.headSize, limbs: 0) { [weak self] drop in self?.drop(id, drop) }
        case .release(let dragged):
            if dragged { stage.release() } else { click(agent) }
        }
    }

    private func liftFromPerch(_ id: UUID) {
        guard let agent = store.agents.first(where: { $0.id == id }), let perch = perches[id], let grip = perch.grip else { return }
        perch.lifted = true
        record("lift", agent, perch.window, from: "window")
        stage.begin(look: agent.look, mood: store.activity[id]?.mood ?? .idle, from: grip, size: Perch.size, limbs: 1) { [weak self] drop in
            self?.drop(id, drop)
        }
    }

    private func released(_ id: UUID, dragged: Bool) {
        if dragged {
            stage.release()
        } else if let agent = store.agents.first(where: { $0.id == id }) {
            click(agent)
        }
    }

    private func click(_ agent: Agent) {
        record("click", agent, nil)
        onAgentClick?(agent.id)
    }

    private func drop(_ id: UUID, _ drop: DragStage.Drop?) {
        guard let agent = store.agents.first(where: { $0.id == id }) else { return finish() }
        if case .window(let window) = drop, let fresh = ForeignWindow.lookup(window.number), fresh.onScreen {
            land(agent, on: fresh)
        } else {
            goHome(agent)
        }
    }

    private func land(_ agent: Agent, on window: ForeignWindow) {
        let f = window.appKitFrame
        let mouse = NSEvent.mouseLocation
        let perch = perches[agent.id] ?? makePerch(agent.id, fraction: 0.5)
        perch.lifted = true
        perch.fraction = max(0, min(1, (mouse.x - f.minX) / max(f.width, 1)))
        let previous = perch.window?.number
        perch.update(window)
        guard let grip = perch.grip else { return goHome(agent) }
        record("drop", agent, window)
        stage.fly(to: grip, size: Perch.size, limbs: 1, pose: .perch, duration: 0.34, lift: 46) { [weak self] in
            guard let self else { return }
            if let previous, previous != window.number { self.release(previous, from: agent.id) }
            self.watch.watch(window.number)
            self.store.attach(agent.id, to: window.attachment)
            perch.update(window)
            perch.lifted = false
            perch.model.landings += 1
            perch.raise()
            self.record("perched", agent, window)
            DispatchQueue.main.async { self.finish() }
        }
    }

    private func goHome(_ agent: Agent) {
        let wasAttached = agent.attachment != nil
        homing = agent.id
        notch.lift(agent.id)
        sync(store.agents, store.activity)
        let target = grip(ofHeadAt: notch.headPoint(for: agent.id))
        record("home", agent, nil)
        stage.fly(to: target, size: notch.headSize, limbs: 0, pose: .peek, duration: 0.42, lift: 70) { [weak self] in
            guard let self else { return }
            if wasAttached { self.store.attach(agent.id, to: nil) }
            DispatchQueue.main.async { self.finish() }
        }
    }

    private func finish() {
        homing = nil
        notch.lift(nil)
        stage.hide()
        sync(store.agents, store.activity)
        hover()
    }

    private func grip(ofHeadAt center: NSPoint) -> NSPoint {
        NSPoint(x: center.x, y: center.y + notch.headSize * (CreatureView.center.y - CreatureView.gripAnchor.y * CreatureView.heightRatio))
    }

    private struct Event: Encodable {
        let at = Date()
        let event: String
        let agent: String
        let from: String?
        let app: String?
        let window: Int?
        let frame: String?
    }

    private func record(_ event: String, _ agent: Agent, _ window: ForeignWindow?, from: String? = nil) {
        let f = window?.frame
        log.append(Event(event: event, agent: agent.name, from: from, app: window?.appName, window: window?.number,
                         frame: f.map { "\(Int($0.minX)) \(Int($0.minY)) \(Int($0.width)) \(Int($0.height))" }))
    }
}
