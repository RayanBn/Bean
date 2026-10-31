import Foundation

// The states follow Paperclip's issue statuses: an agent-owned step in progress is backed by real work, and a blocked one names what it waits for.
struct PlanStep: Identifiable, Equatable {
    enum State: String { case toDo, doing, done, blocked }

    let id: String
    let what: String
    let doneMeans: String?
    let owner: String
    let agent: UUID?
    let state: State
    let session: String?
    let waitingFor: String?
    let missing: String?
}

struct StepProgress: Codable {
    var agent: UUID?
    var checkedDone: Bool?
    var missing: String?
}

struct SavedPlan: Codable {
    var tag: String
    var steps: [BeanUnderstanding.Step]
    var progress: [String: StepProgress]
}

extension AgentWorker {
    private var planFile: URL { storeForBrain.root.appendingPathComponent("plan.json") }

    func stepId(_ index: Int) -> String { "\(planTag)-\(index + 1)" }

    func savePlan() {
        try? JSONEncoder().encode(SavedPlan(tag: planTag, steps: planSteps, progress: planProgress)).write(to: planFile, options: .atomic)
    }

    func loadPlan() {
        guard let saved = (try? Data(contentsOf: planFile)).flatMap({ try? JSONDecoder().decode(SavedPlan.self, from: $0) }) else { return }
        planTag = saved.tag
        planSteps = saved.steps
        planProgress = saved.progress
    }

    func noteHandOff(of workId: String, to agent: UUID) {
        guard planSteps.indices.contains(where: { stepId($0) == workId }) else { return }
        planProgress[workId, default: StepProgress()].agent = agent
        planProgress[workId]?.checkedDone = nil
        savePlan()
    }

    func noteCheck(of workId: String, done: Bool, missing: String) {
        planProgress[workId, default: StepProgress()].checkedDone = done
        planProgress[workId]?.missing = done || missing.isEmpty ? nil : missing
        savePlan()
    }

    // Every state is read from what happened: the hand-off, the session and the check. An agent's words do not move a step.
    func readPlan() -> (steps: [PlanStep], current: [UUID: String]) {
        var current: [UUID: String] = [:]
        let steps = planSteps.enumerated().map { index, step -> PlanStep in
            let id = stepId(index)
            let progress = planProgress[id]
            let agent = progress?.agent.flatMap { owner in storeForBrain.agents.first { $0.id == owner } }
            let folder = agent.map { AgentFolder($0, in: storeForBrain) }
            let sessions = folder.map { CodingSessions(folder: $0).all.filter { $0.workId == id } } ?? []
            let session = sessions.last
            let question = folder?.needs.first { need in need.session == session?.id && session != nil }?.question ?? session.flatMap { $0.status == .waiting ? $0.question : nil }
                ?? folder?.needs.first { [.decision, .stuck, .budget].contains($0.kind) && $0.session == nil }?.question
            let running = session.map { drivingSessions.contains($0.id) } == true || agent.map { doing[$0.id] != nil } == true
            let state: PlanStep.State
            if progress?.checkedDone == true { state = .done }
            else if let question, !question.isEmpty, !running || session?.status == .waiting { state = .blocked }
            else if running { state = .doing }
            else if progress?.checkedDone == nil, session?.pullRequest != nil { state = .done }
            else if progress?.agent != nil { state = .doing }
            else { state = .toDo }
            if let agent, state == .doing || state == .blocked { current[agent.id] = id }
            return PlanStep(id: id, what: step.what, doneMeans: step.done, owner: agent?.name ?? step.who, agent: agent?.id, state: state, session: session?.id, waitingFor: state == .blocked ? question : nil, missing: state == .done ? nil : progress?.missing)
        }
        return (steps, current)
    }
}
