import AppKit
import Combine
import SwiftUI

@MainActor
final class CreatureController {
    var onAgentClick: ((UUID) -> Void)?
    var onMissedDrop: ((UUID) -> Void)?
    var onAppQuit: ((UUID, Attachment) -> Void)?

    private let store: AgentStore
    private let notch: NotchController
    private let watch = WindowWatch()
    private let stage = DragStage()
    private let log = JSONLog(name: "creatures")
    private var perches: [UUID: Perch] = [:]
    private var homing: UUID?
    private var settling: [UUID: DispatchWorkItem] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var monitors: [Any] = []

    init(store: AgentStore, notch: NotchController) {
        self.store = store
        self.notch = notch
        stage.homeZone = { [weak notch] in notch?.islandFrame ?? .zero }
        notch.onCrewGesture = { [weak self] id, gesture in self?.crewGesture(id, gesture) }
        watch.onChange = { [weak self] pid, window in self?.appChanged(pid, window) }
        watch.onReorder = { [weak self] in self?.perches.values.forEach { $0.raise() } }
        store.$agents.combineLatest(store.$activity)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] agents, activity in self?.sync(agents, activity) }
            .store(in: &subscriptions)

        let hover: NSEvent.EventTypeMask = [.mouseMoved]
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.perches.values.forEach { $0.raise() }
            }
        }
        monitors = [
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
                DispatchQueue.main.async { self?.perches.values.forEach { $0.raise() } }
                return event
            },
            NSEvent.addGlobalMonitorForEvents(matching: hover) { [weak self] _ in self?.hover() },
            NSEvent.addLocalMonitorForEvents(matching: hover) { [weak self] event in self?.hover(); return event },
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .leftMouseDown]) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { self?.perches.values.forEach { $0.raise() } }
            },
        ].compactMap { $0 }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sync(self.store.agents, self.store.activity)
        }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.perches.values.forEach { $0.raise() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.perches.values.forEach { $0.raise() } }
            }
        }
    }

    private func sync(_ agents: [Agent], _ activity: [UUID: AgentActivity]) {
        let attached = agents.filter { $0.attachment != nil }
        for (id, perch) in perches where !attached.contains(where: { $0.id == id }) && id != landing {
            if let app = perch.app { release(app, from: id) }
            if agents.contains(where: { $0.id == id }) { perch.dismiss() } else { perch.pop() }
            perches[id] = nil
        }
        for agent in attached {
            guard let attachment = agent.attachment else { continue }
            let perch = perches[agent.id] ?? makePerch(agent.id)
            let model = perch.model
            let mood = activity[agent.id]?.mood ?? .idle
            if model.name != agent.name { model.name = agent.name }
            if model.look != agent.look { model.look = agent.look }
            if model.mood != mood { model.mood = mood }
            guard agent.id != landing else { continue }
            guard let pid = attachment.runningPid else {
                onAppQuit?(agent.id, attachment)
                continue
            }
            if perch.app != pid {
                if let old = perch.app { release(old, from: agent.id) }
                perch.app = pid
                watch.watch(pid)
                let window = ForeignWindow.front(of: pid, in: ForeignWindow.pickable()) ?? ForeignWindow.lookup(attachment.windowNumber)
                perch.update(window)
                if let window { sit(agent.id, on: window) }
            }
        }
        arrange()
        updateCrew()
    }

    private func updateCrew() {
        let agents = store.agents, activity = store.activity
        let unseated = { (agent: Agent) in agent.attachment != nil && self.perches[agent.id].map { !$0.lifted && !$0.seated } ?? false }
        let home = agents.filter { $0.attachment == nil || $0.id == homing || unseated($0) }
        let member = { (agent: Agent) in CrewMember(id: agent.id, name: agent.name, look: agent.look, mood: activity[agent.id]?.mood ?? .idle) }
        notch.setCrew(home.filter { !$0.isBean }.sorted { $0.createdAt > $1.createdAt }.map(member))
        notch.setBean(home.first(where: \.isBean).map(member))
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
        perch.onSeated = { [weak self] in self?.updateCrew() }
        perches[id] = perch
        return perch
    }

    private func release(_ app: Int32, from id: UUID) {
        if !perches.contains(where: { $0.key != id && $0.value.app == app }) { watch.unwatch(app) }
    }

    private func appChanged(_ pid: Int32, _ window: ForeignWindow?) {
        if window == nil { sync(store.agents, store.activity) }
        for perch in perches.values where perch.app == pid && !perch.lifted {
            perch.update(window)
            if let window { sit(perch.id, on: window) }
        }
        arrange()
        updateCrew()
    }

    // The front window is written at once. A title can change many times a second, as a terminal's does, so it waits to settle.
    private func sit(_ id: UUID, on window: ForeignWindow) {
        guard let attachment = store.agents.first(where: { $0.id == id })?.attachment else { return }
        let moved = attachment.windowNumber != window.number || attachment.pid != window.pid
        let title = window.title ?? (moved ? nil : attachment.windowTitle)
        guard moved || attachment.windowTitle != title else { return }
        settling[id]?.cancel()
        let write = DispatchWorkItem { [weak self] in self?.store.sit(id, pid: window.pid, windowNumber: window.number, windowTitle: title) }
        settling[id] = write
        if moved { write.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: write) }
    }

    private func hover() {
        guard !stage.isActive else { return }
        let mouse = NSEvent.mouseLocation
        for perch in perches.values {
            let inside = perch.hitRect?.contains(mouse) ?? false
            if perch.panel.ignoresMouseEvents == inside { perch.panel.ignoresMouseEvents = !inside }
            if perch.model.hovering != inside { perch.model.hovering = inside }
        }
    }

    private func crewGesture(_ id: UUID, _ gesture: CrewGesture) {
        guard let agent = store.agents.first(where: { $0.id == id }) else { return }
        switch gesture {
        case .lift:
            if notch.liftedFromPanel, perches[id]?.shown == true { return liftFromPage(id) }
            held = id
            restorePage = pageWasFront()
            notch.lift(id)
            record("lift", agent, nil, from: "notch")
            let inPanel = notch.liftedFromPanel
            stage.begin(name: agent.name, look: agent.look, mood: store.activity[id]?.mood ?? .idle, from: inPanel ? NSEvent.mouseLocation : grip(ofHeadAt: notch.headPoint(for: id)),
                        size: inPanel ? 30 : notch.headSize, limbs: 0, tethered: !inPanel) { [weak self] drop in self?.drop(id, drop) }
        case .release(let dragged):
            if dragged { stage.release() } else { click(agent) }
        }
    }

    private func liftFromPerch(_ id: UUID) {
        guard let agent = store.agents.first(where: { $0.id == id }), let perch = perches[id], let grip = perch.grip else { return }
        perch.lifted = true
        held = id
        record("lift", agent, perch.window, from: "window")
        stage.begin(name: agent.name, look: agent.look, mood: store.activity[id]?.mood ?? .idle, from: grip, size: perch.landingSize, limbs: 0) { [weak self] drop in
            self?.drop(id, drop)
        }
    }

    private var held: UUID?
    private var landing: UUID?
    private var restorePage = false
    var pageWasFront: () -> Bool = { false }
    var pageComeBack: () -> Void = {}

    private func putBack(_ perch: Perch, grip: NSPoint) {
        stage.fly(to: grip, size: perch.landingSize, limbs: 0, pose: .peek, duration: 0.3, lift: 24) { [weak self] in
            perch.lifted = false
            DispatchQueue.main.async { self?.finish() }
        }
    }

    func liftFromPage(_ id: UUID) {
        guard let agent = store.agents.first(where: { $0.id == id }), !stage.isActive else { return }
        held = id
        let perch = perches[id].flatMap { $0.shown ? $0 : nil }
        if let perch { perch.lifted = true } else { notch.lift(id) }
        record("lift", agent, perch?.window, from: "page")
        stage.begin(name: agent.name, look: agent.look, mood: store.activity[id]?.mood ?? .idle, from: NSEvent.mouseLocation, size: 24, limbs: 1) { [weak self] drop in
            guard let self else { return }
            if drop == nil, let perch, let grip = perch.grip {
                self.putBack(perch, grip: grip)
            } else {
                self.drop(id, drop)
            }
        }
    }

    func endPageDrag() {
        stage.release()
    }

    var dragBlocked: (NSPoint) -> Bool {
        get { stage.blocked }
        set { stage.blocked = newValue }
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

    func sendHome(_ id: UUID) {
        guard let agent = store.agents.first(where: { $0.id == id }) else { return }
        guard !stage.isActive else { return }
        guard let perch = perches[id], perch.shown, let grip = perch.grip else {
            store.attach(id, to: nil)
            return
        }
        perch.lifted = true
        stage.launch(look: agent.look, mood: store.activity[id]?.mood ?? .idle, from: grip, size: perch.landingSize, limbs: 0)
        goHome(agent)
    }

    private func drop(_ id: UUID, _ drop: DragStage.Drop?) {
        guard let agent = store.agents.first(where: { $0.id == id }) else { return finish() }
        if case .window(let window) = drop, let fresh = ForeignWindow.lookup(window.number), fresh.onScreen {
            land(agent, on: fresh)
        } else {
            if drop == nil { stage.showNotice("Drop it on an app") }
            onMissedDrop?(id)
            goHome(agent)
        }
    }

    func attachFromBean(_ id: UUID, windowNumber: Int) {
        guard let agent = store.agents.first(where: { $0.id == id }), let window = ForeignWindow.lookup(windowNumber) else { return }
        guard window.onScreen, !stage.isActive else {
            record("no flight", agent, window, from: window.onScreen ? "stage busy" : "off screen")
            return store.attach(id, to: window.attachment)
        }
        notch.lift(id)
        record("lift", agent, nil, from: "bean")
        stage.launch(look: agent.look, mood: store.activity[id]?.mood ?? .idle, from: grip(ofHeadAt: notch.headPoint(for: id)), size: notch.headSize, limbs: 0)
        land(agent, on: window)
    }

    private func land(_ agent: Agent, on dropped: ForeignWindow) {
        let window = ForeignWindow.front(of: dropped.pid, in: ForeignWindow.pickable()) ?? dropped
        let perch = perches[agent.id] ?? makePerch(agent.id)
        landing = agent.id
        perch.lifted = true
        perch.slot = perches.values.filter { $0 !== perch && $0.window?.number == window.number }.count
        let previous = perch.app
        perch.app = window.pid
        perch.update(window)
        record("drop", agent, window)
        perch.measureNow { [weak self] in
            guard let self else { return }
            let target = perch.grip ?? self.grip(ofHeadAt: self.notch.headPoint(for: agent.id))
            self.stage.fly(to: target, size: perch.seated ? perch.landingSize : self.notch.headSize, limbs: 0, pose: .peek, duration: 0.34, lift: 24) { [weak self] in
                guard let self else { return }
                if let previous, previous != window.pid { self.release(previous, from: agent.id) }
                self.watch.watch(window.pid)
                self.landing = nil
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
        if restorePage {
            restorePage = false
            pageComeBack()
        }
        held = nil
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
