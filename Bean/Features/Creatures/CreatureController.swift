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
    private var lostSince: [UUID: Date] = [:]

    init(store: AgentStore, notch: NotchController) {
        self.store = store
        self.notch = notch
        stage.homeZone = { [weak notch] in notch?.islandFrame ?? .zero }
        stage.occupant = { [weak self] window in self?.occupant(of: window) }
        notch.onCrewGesture = { [weak self] id, gesture in self?.crewGesture(id, gesture) }
        watch.onChange = { [weak self] number, window in self?.windowChanged(number, window) }
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
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.perches.values.forEach { $0.raise() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.perches.values.forEach { $0.raise() } }
            }
        }
        rebindTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.rebindLost()
        }
    }

    private func sync(_ agents: [Agent], _ activity: [UUID: AgentActivity]) {
        notch.call(agents.first { activity[$0.id]?.mood == .needsYou }.map { CreaturePalette(look: $0.look).body })
        let attached = agents.filter { $0.attachment != nil }
        for (id, perch) in perches where !attached.contains(where: { $0.id == id }) {
            if let number = perch.window?.number { release(number, from: id) }
            if agents.contains(where: { $0.id == id }) { perch.dismiss() } else { perch.pop() }
            perches[id] = nil
        }
        for (index, agent) in attached.enumerated() {
            guard let attachment = agent.attachment else { continue }
            let perch = perches[agent.id] ?? makePerch(agent.id, fraction: 0.72 - 0.1 * CGFloat(index % 4))
            let model = perch.model
            let mood = activity[agent.id]?.mood ?? .idle
            if model.name != agent.name { model.name = agent.name }
            if model.look != agent.look { model.look = agent.look }
            if model.mood != mood { model.mood = mood }
            if perch.window?.number != attachment.windowNumber {
                if let old = perch.window?.number { release(old, from: agent.id) }
                perch.update(ForeignWindow.lookup(attachment.windowNumber))
                watch.watch(attachment.windowNumber)
            }
        }
        arrange()
        updateCrew()
        updateAsks()
    }

    func setNeeds(_ needs: [UUID: [AgentNeed]]) {
        self.needs = needs
        updateAsks()
    }

    private func updateAsks() {
        for (id, perch) in perches {
            let list = needs[id] ?? []
            perch.setAsk((list.first { $0.consent != nil } ?? list.first).map(PerchAsk.init))
        }
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

    private func makePerch(_ id: UUID, fraction: CGFloat) -> Perch {
        let perch = Perch(id: id, fraction: fraction,
                          onDragStart: { [weak self] in self?.liftFromPerch(id) },
                          onRelease: { [weak self] dragged in self?.released(id, dragged: dragged) })
        perch.onSeated = { [weak self] in self?.updateCrew() }
        perch.bubbleRedundant = { [weak self] in self?.pageShows(id) ?? false }
        perch.onAnswer = { [weak self] need, text in self?.onAnswer?(id, need, text) }
        perch.onDetails = { [weak self] in self?.onAgentClick?(id) }
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
        updateCrew()
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
        }
    }

    private func crewGesture(_ id: UUID, _ gesture: CrewGesture) {
        guard let agent = store.agents.first(where: { $0.id == id }) else { return }
        switch gesture {
        case .lift:
            held = id
            restorePage = pageWasFront()
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
        held = id
        record("lift", agent, perch.window, from: "window")
        stage.begin(look: agent.look, mood: store.activity[id]?.mood ?? .idle, from: grip, size: perch.landingSize, limbs: perch.mode == .sit ? 1 : 0) { [weak self] drop in
            self?.drop(id, drop)
        }
    }

    private var held: UUID?
    private var needs: [UUID: [AgentNeed]] = [:]
    var onAnswer: ((UUID, UUID, String) -> Void)?
    private var restorePage = false
    var pageWasFront: () -> Bool = { false }
    var pageShows: (UUID) -> Bool = { _ in false }
    var pageComeBack: () -> Void = {}

    private func occupant(of window: ForeignWindow) -> String? {
        store.agents.first { $0.id != held && $0.attachment?.windowNumber == window.number }?.name
    }

    private func putBack(_ perch: Perch, grip: NSPoint) {
        stage.fly(to: grip, size: perch.landingSize, limbs: perch.mode == .sit ? 1 : 0, pose: perch.mode == .sit ? .perch : .peek, duration: 0.3, lift: 24) { [weak self] in
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
        stage.begin(look: agent.look, mood: store.activity[id]?.mood ?? .idle, from: NSEvent.mouseLocation, size: 24, limbs: 1) { [weak self] drop in
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
        stage.launch(look: agent.look, mood: store.activity[id]?.mood ?? .idle, from: grip, size: perch.landingSize, limbs: perch.mode == .sit ? 1 : 0)
        goHome(agent)
    }

    private func drop(_ id: UUID, _ drop: DragStage.Drop?) {
        guard let agent = store.agents.first(where: { $0.id == id }) else { return finish() }
        if case .refused = drop {
            if let perch = perches[id], perch.shown, let grip = perch.grip { return putBack(perch, grip: grip) }
            return goHome(agent)
        }
        if case .window(let window) = drop, let fresh = ForeignWindow.lookup(window.number), fresh.onScreen {
            land(agent, on: fresh)
        } else {
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
        land(agent, on: window, at: window.appKitFrame.midX)
    }

    private func land(_ agent: Agent, on window: ForeignWindow, at point: CGFloat? = nil) {
        let perch = perches[agent.id] ?? makePerch(agent.id, fraction: 0.5)
        perch.lifted = true
        perch.slot = perches.values.filter { $0 !== perch && $0.window?.number == window.number }.count
        let f = window.appKitFrame
        var x = point ?? NSEvent.mouseLocation.x
        let neighbours = perches.values.filter { $0 !== perch && $0.window?.number == window.number && $0.mode == .sit }.compactMap { $0.seat?.x }
        for _ in 0..<4 {
            guard let near = neighbours.first(where: { abs($0 - x) < Perch.size * 1.4 }) else { break }
            x = near + (x >= near ? 1 : -1) * Perch.size * 1.4
            if x > f.maxX - Perch.size || x < f.minX + Perch.size { x = near - (x - near) }
        }
        perch.fraction = max(0, min(1, (x - f.minX) / max(f.width, 1)))
        let previous = perch.window?.number
        perch.update(window)
        perch.measureNow()
        record("drop", agent, window)
        let target = perch.grip ?? grip(ofHeadAt: notch.headPoint(for: agent.id))
        let sits = perch.mode == .sit
        stage.fly(to: target, size: perch.seated ? perch.landingSize : notch.headSize, limbs: sits ? 1 : 0, pose: sits ? .perch : .peek,
                  duration: 0.34, lift: sits ? 46 : 24) { [weak self] in
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
