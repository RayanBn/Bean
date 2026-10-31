import Foundation

@MainActor
final class SenseBoard {
    private let store: AgentStore
    private let gate: EventGate
    private let attached = LockedValue(Set<Int>())
    private var running: [String: () -> Void] = [:]
    private var held: Set<String> = []
    private var taps: [(SenseEvent) -> Void] = []

    init(store: AgentStore, worker: AgentWorker, gate: EventGate) {
        self.store = store
        self.gate = gate
        worker.onAttachedWindows = { [attached] in attached.value = $0 }
        worker.publishAttachedWindows()
    }

    func listen(_ tap: @escaping (SenseEvent) -> Void) {
        taps.append(tap)
    }

    func hold(_ sense: String, _ on: Bool) {
        if on { held.insert(sense) } else { held.remove(sense) }
        refresh()
    }

    func refresh() {
        var wanted: [String: (sense: Sense, subscription: SenseSubscription?, owner: Agent?)] = [:]
        if !BeanSettings.shared.effectivePaused {
            for id in held { if let sense = Sense.named(id) { wanted[id] = (sense, nil, nil) } }
            for agent in store.agents {
                for subscription in AgentFolder(agent, in: store).subscriptions(of: agent) where !subscription.paused {
                    guard let sense = Sense.named(subscription.sense) else { continue }
                    if sense.perSubscription == true {
                        wanted["\(sense.id)|\(agent.id)|\(subscription.params.sorted { $0.key < $1.key })"] = (sense, subscription, agent)
                    } else if wanted[sense.id] == nil {
                        wanted[sense.id] = (sense, nil, nil)
                    }
                }
            }
        }
        for key in running.keys where wanted[key] == nil { running.removeValue(forKey: key)?() }
        for (key, want) in wanted where running[key] == nil {
            guard let driver = SenseDrivers.make(want.sense.driver, attached: { [attached] in attached.value }) else { continue }
            let owner = want.owner?.id
            let stop = driver.start(SenseRun(params: want.subscription?.params ?? [:], lastSeen: want.subscription?.lastSeen, remember: { [weak self] seen in
                if let want = wanted[key], let agent = want.owner { self?.remember(seen, want.sense.id, want.subscription?.params ?? [:], agent) }
            }, emit: { [weak self] signal in
                DispatchQueue.main.async { self?.sensed(signal, sense: want.sense, only: owner) }
            }))
            running[key] = { withExtendedLifetime(driver) { stop() } }
        }
    }

    private func remember(_ seen: String, _ sense: String, _ params: [String: String], _ agent: Agent) {
        DispatchQueue.main.async { [store] in
            let folder = AgentFolder(agent, in: store)
            var list = folder.subscriptions(of: agent)
            guard let index = list.firstIndex(where: { $0.sense == sense && $0.params == params }) else { return }
            list[index].lastSeen = seen
            folder.save(list)
        }
    }

    func sensed(_ signal: SenseSignal, sense: Sense, only: UUID? = nil) {
        var event = SenseEvent(sense: sense, signal: signal, only: only)
        taps.forEach { $0(event) }
        let place = "\(signal.app ?? "") \(signal.bundleId ?? "") \(signal.title ?? "")"
        if OffLimits.match(place) != nil {
            return gate.record(GateEntry(event: signal.type, app: nil, title: nil, decision: "offLimits", by: "code"))
        }
        let watchers = subscribers(of: event)
        guard !watchers.isEmpty else { return }
        let others = watchers.filter { !$0.agent.isBean }
        if !others.isEmpty {
            event.watching = others.map { "\($0.agent.name) watches this: \($0.subscription.why)" }.joined(separator: " ")
        }
        gate.consider(event)
    }

    func sensed(_ signal: SenseSignal, sense id: String) {
        if let sense = Sense.named(id) { sensed(signal, sense: sense) }
    }

    private func subscribers(of event: SenseEvent) -> [(agent: Agent, subscription: SenseSubscription)] {
        store.agents.compactMap { agent in
            if let only = event.only, only != agent.id { return nil }
            guard let subscription = AgentFolder(agent, in: store).subscriptions(of: agent).first(where: { $0.sense == event.sense.id && !$0.paused }) else { return nil }
            if let app = subscription.params["app"], app.caseInsensitiveCompare(event.app ?? "") != .orderedSame { return nil }
            return (agent, subscription)
        }
    }
}

final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
