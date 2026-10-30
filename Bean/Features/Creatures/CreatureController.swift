import AppKit
import Combine
import SwiftUI

final class CreatureController {
    var onAgentClick: ((UUID, NSRect) -> Void)?

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
    private var lostSince: [UUID: Date] = [:]

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
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.perches.values.forEach { $0.raise() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.perches.values.forEach { $0.raise() } }
            }
        }
        rebindTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.rebindLost() }
    }

    private func sync(_ agents: [Agent], _ activity: [UUID: AgentActivity]) {
        let home = agents.filter { $0.attachment == nil || $0.id == homing }
        let member = { (agent: Agent) in CrewMember(id: agent.id, name: agent.name, look: agent.look, mood: activity[agent.id]?.mood ?? .idle) }
        notch.setCrew(home.filter { !$0.isBean }.sorted { $0.createdAt > $1.createdAt }.map(member))
        notch.setBean(home.first(where: \.isBean).map(member))
        notch.call(agents.first { activity[$0.id]?.mood == .needsYou }.map { CreaturePalette(look: $0.look).body })
        let attached = agents.filter { $0.attachment != nil }
        for (id, perch) in perches where !attached.contains(where: { $0.id == id }) {
            if let number = perch.window?.number { release(number, from: id) }
            if agents.contains(where: { $0.id == id }) { perch.dismiss() } else { perch.pop() }
            perches[id] = nil
        }
        for (index, agent) in attached.enumerated() {
            guard let attachment = agent.attachment else { continue }
            let perch = perches[agent.id] ?? makePerch(agent.id)
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
        arrange()
    }

    private func arrange() {
        let groups = Dictionary(grouping: perches.values.filter { $0.window != nil && !$0.lifted }) { $0.window!.number }
        for group in groups.values {
            let order = store.agents.map(\.id)
            let row = group.sorted { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
            for (i, perch) in row.enumerated() { perch.slot = i }
        }
    }

    private func makePerch(_ id: UUID) -> Perch {
        let perch = Perch(id: id,
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
        arrange()
        if window == nil { rebindLost() }
    }

    private func rebindLost() {
        for agent in store.agents {
            guard let attachment = agent.attachment, let perch = perches[agent.id], perch.window == nil, !perch.lifted else {
                lostSince[agent.id] = nil
                continue
            }
            let since = lostSince[agent.id] ?? Date()
            lostSince[agent.id] = since
            guard Date().timeIntervalSince(since) > 2.5, let replacement = ForeignWindow.replacement(for: attachment) else { continue }
            lostSince[agent.id] = nil
            record("rebound", agent, replacement)
            store.attach(agent.id, to: replacement.attachment)
        }
    }

    private func hover() {
        guard !stage.isActive else { return }
        let mouse = NSEvent.mouseLocation
        for perch in perches.values {
            let inside = perch.hitRect?.contains(mouse) ?? false
            if perch.panel.ignoresMouseEvents == inside { perch.panel.ignoresMouseEvents = !inside }
            if perch.model.hovered != inside { perch.model.hovered = inside }
        }
    }

    private func crewGesture(_ id: UUID, _ gesture: CrewGesture) {
        guard let agent = store.agents.first(where: { $0.id == id }) else { return }
        switch gesture {
        case .lift:
            notch.lift(id)
            record("lift", agent, nil, from: "notch")
            stage.begin(look: agent.look, mood: store.activity[id]?.mood ?? .idle, from: grip(ofHeadAt: notch.headPoint(for: id)),
                        size: notch.headSize, limbs: 0, tethered: true) { [weak self] drop in self?.drop(id, drop) }
        case .release(let dragged):
            if dragged { stage.release() } else { click(agent) }
        }
    }

    private func liftFromPerch(_ id: UUID) {
        guard let agent = store.agents.first(where: { $0.id == id }), let perch = perches[id], let grip = perch.grip else { return }
        perch.lifted = true
        record("lift", agent, perch.window, from: "window")
        stage.begin(look: agent.look, mood: store.activity[id]?.mood ?? .idle, from: grip, size: Perch.badge, limbs: 0) { [weak self] drop in
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
        let head = notch.headPoint(for: agent.id), d = notch.headSize
        onAgentClick?(agent.id, perches[agent.id]?.hitRect ?? NSRect(x: head.x - d / 2, y: head.y - d / 2, width: d, height: d))
    }

    func sendHome(_ id: UUID) {
        guard let agent = store.agents.first(where: { $0.id == id }) else { return }
        guard let perch = perches[id], perch.shown, let grip = perch.grip, !stage.isActive else {
            store.attach(id, to: nil)
            return
        }
        perch.lifted = true
        stage.launch(look: agent.look, mood: store.activity[id]?.mood ?? .idle, from: grip, size: Perch.badge, limbs: 0)
        goHome(agent)
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
        let perch = perches[agent.id] ?? makePerch(agent.id)
        perch.lifted = true
        perch.slot = perches.values.filter { $0 !== perch && $0.window?.number == window.number }.count
        let previous = perch.window?.number
        perch.update(window)
        guard let grip = perch.grip else { return goHome(agent) }
        record("drop", agent, window)
        stage.fly(to: grip, size: Perch.badge, limbs: 0, pose: .peek, duration: 0.34, lift: 24) { [weak self] in
            guard let self else { return }
            if let previous, previous != window.number { self.release(previous, from: agent.id) }
            self.watch.watch(window.number)
            self.store.attach(agent.id, to: window.attachment)
            perch.update(window)
            perch.lifted = false
            perch.model.landings += 1
            perch.raise()
            self.arrange()
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
