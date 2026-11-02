import Foundation

// A Stop from the user holds the work it stopped, by id, until they ask for it again. It outlives a relaunch, and nothing Bean wakes for lifts it.
enum StoppedWork {
    static func key(_ agent: UUID) -> String { "agent \(agent.uuidString)" }

    private static func file(in root: URL) -> URL { root.appendingPathComponent("stopped-work.json") }

    static func all(in root: URL) -> [String: Date] {
        (try? Data(contentsOf: file(in: root))).flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
    }

    static func hold(_ keys: [String], in root: URL) {
        var held = all(in: root)
        let now = Date()
        for key in keys { held[key] = now }
        try? JSONEncoder().encode(held).write(to: file(in: root), options: .atomic)
    }

    // Only what is lifted comes back: words to one agent do not free what the same Stop held elsewhere.
    static func lift(_ key: String, in root: URL) {
        var held = all(in: root)
        guard held.removeValue(forKey: key) != nil else { return }
        try? JSONEncoder().encode(held).write(to: file(in: root), options: .atomic)
    }
}

extension AgentWorker {
    func isReplying(_ id: UUID) -> Bool { replying.contains(id) }

    var workStillMoving: Bool { heldPlan != nil || settlingPlan || storeForBrain.agents.contains { isBusy($0.id) } }

    @MainActor
    func planMayBeSettled() async {
        guard !settlingPlan else { return }
        guard let bean = storeForBrain.agents.first(where: \.isBean) else { return }
        // A run in progress speaks for the plan when it ends, so one report goes out.
        guard let held = heldPlan, !isBusy(bean.id) else { return }
        settlingPlan = true
        heldPlan = nil
        Task { @MainActor in
            while isBusy(bean.id) { try? await Task.sleep(for: .seconds(1)) }
            await reportHeldPlan(held, bean: bean)
            settlingPlan = false
            if heldPlan != nil { await planMayBeSettled() }
        }
    }

    static let userStoppedWork = "The user stopped this work"

    static func stoppedWork(calls: [String]) -> Worked {
        let line = "Stopped, as you asked."
        return Worked(summary: line, stuck: true, calls: calls, failure: line)
    }

    // Everything this agent has running. Stopping Bean stops what it handed out, and stopping a hand-off stops Bean, so neither goes on without the other.
    @MainActor
    func stopWork(_ agentID: UUID) {
        guard let agent = storeForBrain.agents.first(where: { $0.id == agentID }) else { return }
        var keys = stopRuns(of: agent)
        if leading.contains(agentID), let bean = storeForBrain.agents.first(where: \.isBean) { keys += stopRuns(of: bean) }
        if !keys.isEmpty, agent.isBean || leading.contains(agentID) { keys += readPlan().steps.filter { $0.state != .done }.map(\.id) }
        if !keys.isEmpty { StoppedWork.hold(keys, in: storeForBrain.root) }
        refresh()
    }

    @MainActor
    private func stopRuns(of agent: Agent) -> [String] {
        let folder = AgentFolder(agent, in: storeForBrain)
        SessionTerminals.shared.interrupt(agent: agent.id)
        guard let task = doing[agent.id], runsToStop.insert(agent.id).inserted else { return [] }
        note(.session, Self.userStoppedWork, "", "", agent)
        folder.updateState { $0.stoppedTask = task }
        let led = agent.isBean ? storeForBrain.agents.filter { leading.contains($0.id) } : []
        return [StoppedWork.key(agent.id)] + led.flatMap(stopRuns)
    }

    // For the page: everything that Stop held comes back, and Bean hands out again what it had handed out.
    func resumeWork(_ agentID: UUID) {
        let root = storeForBrain.root
        let held = StoppedWork.all(in: root)
        guard let aimed = storeForBrain.agents.first(where: { $0.id == agentID }) else { return }
        let stopped = held[StoppedWork.key(agentID)]
        // Resume on Bean is Resume on what it led. On any other agent it is that agent's work only.
        let together = [aimed] + (aimed.isBean ? storeForBrain.agents.filter { $0.id != agentID && stopped != nil && held[StoppedWork.key($0.id)] == stopped } : [])
        if aimed.isBean { for key in planBoard.map(\.id) { StoppedWork.lift(key, in: root) } }
        for agent in together { liftKeys(of: agent, in: root) }
        let tasks = together.compactMap { agent -> (Agent, String)? in
            let folder = AgentFolder(agent, in: storeForBrain)
            guard let task = folder.state.stoppedTask else { return nil }
            folder.updateState { $0.stoppedTask = nil }
            return (agent, task)
        }
        for (agent, task) in tasks.first(where: { $0.0.isBean }).map({ [$0] }) ?? tasks {
            carryOn(agent, task: task, trigger: "You were stopped in the middle of this, and the user pressed Resume. Carry on, and do not redo what your journal shows as done")
        }
        wakeAfterStop()
        refresh()
    }

    func stopHeld(_ agent: Agent) -> Bool {
        StoppedWork.all(in: storeForBrain.root)[StoppedWork.key(agent.id)] != nil
    }

    func liftStop(_ agent: Agent) {
        liftKeys(of: agent, in: storeForBrain.root)
        wakeAfterStop()
    }

    private func liftKeys(of agent: Agent, in root: URL) {
        StoppedWork.lift(StoppedWork.key(agent.id), in: root)
        guard !agent.isBean else { return }
        for (id, progress) in planProgress where progress.agent == agent.id { StoppedWork.lift(id, in: root) }
    }

    func userStoppedWork(_ agent: Agent, since date: Date) -> Bool {
        AgentFolder(agent, in: storeForBrain).journal.contains { $0.did == Self.userStoppedWork && $0.at >= date }
    }

    // Words typed to Bean or to this agent since then. A click on a card, a drag or a toggle elsewhere says nothing about stopped work.
    func personAsked(after date: Date, actor: Agent?) -> Bool {
        storeForBrain.agents.filter { $0.isBean || $0.id == actor?.id }.contains { agent in AgentFolder(agent, in: storeForBrain).journal.contains { $0.typed == true && $0.at > date } }
    }

    var stepsStoppedByUser: [BoardStep] {
        let held = StoppedWork.all(in: storeForBrain.root)
        return planBoard.filter { held[$0.id] != nil }
    }

    // True while the user's Stop is the last word on this plan.
    var planHeldByStop: Bool {
        let held = StoppedWork.all(in: storeForBrain.root)
        return planBoard.compactMap { held[$0.id] }.contains { !personAsked(after: $0, actor: nil) }
    }

    // The one gate for work that could restart. Words typed after the Stop, to Bean or to this agent, open it, and the model then judges whether they asked for this.
    func stoppedWorkRefusal(of keys: [String?], by actor: Agent) -> String? {
        let held = StoppedWork.all(in: storeForBrain.root)
        let named = keys.compactMap { $0 }.filter { held[$0] != nil }
        if (actor.isBean && planHeldByStop) || named.contains(where: { !personAsked(after: held[$0] ?? .distantFuture, actor: actor) }) {
            Self.log.append(Entry(agent: "Bean", event: "stoppedWorkHeld", detail: keys.compactMap { $0 }.joined(separator: " ")))
            return "The user stopped this work. That is their decision, and nothing restarts it until they ask. Do not do it again: say plainly that it stopped because they stopped it."
        }
        for key in named { StoppedWork.lift(key, in: storeForBrain.root) }
        return nil
    }

}

extension AgentWorker {
    // One flow, so a deleted agent leaves no terminal running.
    @MainActor
    func forget(_ agent: Agent) {
        SessionTerminals.shared.reset(agent: agent.id)
        storeForBrain.remove(agent.id)
        storeForBrain.activity[agent.id] = nil
    }

    func spent(by agent: Agent) -> Double {
        CostLedger.spentToday(agent: agent.id.uuidString)
    }

    @MainActor
    func budgetLeft(for agent: Agent) -> Double {
        max(0, Self.runawayStopUSD - spent(by: agent))
    }

    @MainActor
    func sayBudgetSpent(_ agent: Agent) {
        let folder = AgentFolder(agent, in: storeForBrain)
        guard !folder.needs.contains(where: { $0.kind == .budget }) else { return }
        raise(AgentNeed(kind: .budget, question: AgentStrings.stoppedToday), agent: agent)
    }

}
