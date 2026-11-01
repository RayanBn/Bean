import Foundation

// As with a job in GitHub Actions, state comes from what runs the work and never from what a model says about it. The names follow Paperclip's issue statuses, and a blocked step names what it waits for.
struct PlanStep: Identifiable, Equatable {
    enum State: String { case toDo, doing, done, blocked, stopped, unknown }

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
    var ids: [String]
    var steps: [BeanUnderstanding.Step]
    var board: [BoardStep]
    var progress: [String: StepProgress]
}

struct BoardStep: Codable {
    let id: String
    var step: BeanUnderstanding.Step
}

extension AgentWorker {
    private var planFile: URL { storeForBrain.root.appendingPathComponent("plan.json") }

    func stepId(_ index: Int) -> String { planIds.indices.contains(index) ? planIds[index] : "\(planTag)-\(index + 1)" }

    // As in Paperclip, where work splits exactly once per plan revision: a new revision keeps the ids of the steps it continues, so the same work never starts twice. Bean's model says which those are.
    func startPlan(_ steps: [BeanUnderstanding.Step], from request: String) {
        let open = readPlan().steps.filter { $0.state != .done && $0.state != .stopped }
        let tag = String(UUID().uuidString.prefix(4)).lowercased()
        var blocked = heldWhenReported
        heldWhenReported = [:]
        planIds = steps.enumerated().map { index, step in
            if let id = step.continues, planBoard.contains(where: { $0.id == id }) { return id }
            // Reversible rule in code: an agent that reported a block on its step still holds that step, so what follows for it keeps the id, and its claim stops a second session for the same work.
            if let owner = blocked.first(where: { held in storeForBrain.agents.first { $0.id == held.key }.map { step.who.localizedCaseInsensitiveContains($0.name) } ?? false }) {
                blocked[owner.key] = nil
                return owner.value
            }
            return "\(tag)-\(index + 1)"
        }
        planTag = tag
        if open.isEmpty {
            planBoard = []
            planProgress = [:]
            planRequest = request
        } else {
            planRequest = [planRequest, request].compactMap { $0 }.joined(separator: "\n\n")
        }
        planSteps = steps
        tasksGivenOut = 0
        for (id, step) in zip(planIds, steps) {
            if let index = planBoard.firstIndex(where: { $0.id == id }) { planBoard[index].step = step } else { planBoard.append(BoardStep(id: id, step: step)) }
        }
        savePlan()
    }

    // A plan can be replaced while an earlier one is being checked, so a step finds its id on the board by its words, never by its place in a list.
    func boardId(of step: BeanUnderstanding.Step) -> String? {
        planBoard.first { $0.step.what == step.what }?.id
    }

    func savePlan() {
        try? JSONEncoder().encode(SavedPlan(ids: planIds, steps: planSteps, board: planBoard, progress: planProgress)).write(to: planFile, options: .atomic)
    }

    func loadPlan() {
        guard let saved = (try? Data(contentsOf: planFile)).flatMap({ try? JSONDecoder().decode(SavedPlan.self, from: $0) }) else { return }
        planIds = saved.ids
        planSteps = saved.steps
        planBoard = saved.board
        planProgress = saved.progress
    }

    func noteHandOff(of workId: String, to agent: UUID) {
        guard planBoard.contains(where: { $0.id == workId }) else { return }
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
        let stoppedWork = StoppedWork.all(in: storeForBrain.root)
        let steps = planBoard.map { entry -> PlanStep in
            let id = entry.id, step = entry.step
            let progress = planProgress[id]
            let agent = progress?.agent.flatMap { owner in storeForBrain.agents.first { $0.id == owner } }
            let folder = agent.map { AgentFolder($0, in: storeForBrain) }
            let sessions = folder.map { CodingSessions(folder: $0).all.filter { $0.workId == id } } ?? []
            let session = sessions.last
            let question = folder?.needs.first { need in need.session == session?.id && session != nil }?.question ?? session.flatMap { $0.status == .waiting ? $0.question : nil }
                ?? folder?.needs.first { [.decision, .stuck, .budget].contains($0.kind) && $0.session == nil }?.question
            let running = session.map { drivingSessions.contains($0.id) } ?? agent.map { doing[$0.id] != nil } ?? false
            let state: PlanStep.State
            if progress?.checkedDone == true { state = .done }
            else if stoppedWork[id] != nil, session?.pullRequest == nil { state = .stopped }
            else if let question, !question.isEmpty, !running || session?.status == .waiting { state = .blocked }
            else if running { state = .doing }
            else if progress?.checkedDone == nil, session?.pullRequest != nil { state = .done }
            else if progress?.agent != nil { state = .doing }
            else if step.who.caseInsensitiveCompare("Bean") == .orderedSame { state = .unknown }
            else { state = .toDo }
            if let agent, state == .doing || state == .blocked { current[agent.id] = id }
            return PlanStep(id: id, what: step.what, doneMeans: step.done, owner: agent?.name ?? step.who, agent: agent?.id, state: state, session: session?.id, waitingFor: state == .blocked ? question : nil, missing: state == .done ? nil : progress?.missing)
        }
        return (steps, current)
    }
}
