import Foundation

struct AgentChoice: Decodable, Equatable {
    let agent: String
    let sentence: String
    let why: String

    // The enum holds the real names, so an invented one cannot read as "none fits" and make an agent.
    static func schema(names: [String]) -> [String: Any] {
        [
            "type": "object", "additionalProperties": false, "required": ["agent", "sentence", "why"],
            "properties": ["agent": ["type": "string", "enum": names + [""]], "sentence": ["type": "string"], "why": ["type": "string"]],
        ]
    }
}

extension AgentWorker {
    // The one place that picks who takes a piece of work no agent was handed by name. The model judges from the agents' real jobs. Code only keeps Stop: a stopped agent stays in the roster, so nothing new gets made for its job, and it takes nothing.
    // A new agent goes through the normal maker, and lands on the app only if no agent holds it, since each app has one agent.
    // ifNoneFits is a sentence a model already wrote, so no choice is asked for when there is nobody to choose.
    @MainActor
    func agentFor(_ work: String, on window: OpenWindow? = nil, onlyFree: Bool = false, ifNoneFits: String? = nil, leaveWhen: String = "", bornFrom: (String) -> AgentCard.BornFrom) async -> (agent: Agent, isNew: Bool)? {
        let store = storeForBrain
        let team = store.agents.filter { !$0.isBean && !$0.name.isEmpty && (!onlyFree || $0.attachment == nil) }
        var sentence = ifNoneFits
        if !team.isEmpty || ifNoneFits == nil {
            guard let choice = await chooseAgent(for: work, among: team) else { return nil }
            Self.log.append(Entry(agent: "Bean", event: "choseAgent", detail: "\(choice.agent.isEmpty ? "none fits" : choice.agent): \(choice.why)"))
            if let found = team.first(where: { $0.name.caseInsensitiveCompare(choice.agent) == .orderedSame }) {
                if stopHeld(found) { return nil }
                if found.attachment == nil, let window, !store.agents.contains(where: { $0.attachment.map(window.isApp(of:)) == true }) { place(found, on: window) }
                return (store.agents.first { $0.id == found.id } ?? found, false)
            }
            if !choice.sentence.isEmpty {
                sentence = choice.sentence
            } else if !team.isEmpty, choice.agent.isEmpty, ifNoneFits == nil {
                return nil
            }
        }
        guard let sentence, !sentence.isEmpty else { return nil }
        let free = window.flatMap { candidate in store.agents.contains { $0.attachment.map(candidate.isApp(of:)) == true } ? nil : candidate }
        guard let made = try? await createAgent(from: sentence, bornFrom: bornFrom(sentence), on: free, leaveWhen: leaveWhen) else { return nil }
        return (made, true)
    }

    @MainActor
    private func chooseAgent(for work: String, among team: [Agent]) async -> AgentChoice? {
        guard !BeanSettings.shared.effectivePaused else { return nil }
        let text = """
        What the person wants:
        \(Goals.text ?? "nothing said yet")

        \(beanRoster(connected: nil, of: team))
        The work:
        \(work.prefix(1500))
        """
        let schema = AgentChoice.schema(names: team.map(\.name))
        let reply = await CostLedger.$agent.withValue(Agent.beanID.uuidString) { try? await ModelClient().json(system: Prompts.choose, text: OffLimits.redact(text).text, schema: schema, effort: "low") }
        return reply?.text.flatMap { try? JSONDecoder().decode(AgentChoice.self, from: Data($0.utf8)) }
    }
}

extension OpenWindow {
    // An app with no bundle id is known only by its process.
    func isApp(of attachment: Attachment) -> Bool {
        bundleId == attachment.bundleId && (!bundleId.isEmpty || pid == attachment.pid)
    }
}
