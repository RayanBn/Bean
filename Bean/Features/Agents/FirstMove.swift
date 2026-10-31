import Foundation

extension AgentWorker {
    private var offeredFile: URL { JSONLog.directory.appendingPathComponent("first-move-offered") }

    @MainActor
    func offerFirstMove() async {
        guard let bean = storeForBrain.agents.first(where: \.isBean), ModelClient().isReady, !BeanSettings.shared.effectivePaused,
              !FileManager.default.fileExists(atPath: offeredFile.path), !storeForBrain.agents.contains(where: { !$0.isBean && !$0.name.isEmpty }) else { return }
        let folder = AgentFolder(bean, in: storeForBrain)
        guard folder.goals == nil, folder.journal.isEmpty, folder.needs.isEmpty else { return }
        let reality = await Self.reality(in: storeForBrain, catalogue: false)
        guard !WindowChannels.forModel().isEmpty || !reality.contains("Connected services: none") else { return }
        try? FileManager.default.createDirectory(at: offeredFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: offeredFile)
        let system = """
        You are Bean, which runs agents for its user on their Mac. It just started, has no goal and no agent, and the user has not asked for anything yet. Below is all you know: the titles of their open windows and their connected services. You have read nothing inside them.
        Offer at most 3 concrete things you could do now, each tied to one window or service below, that this person would plainly want. Only what the titles support: if a title says too little, offer nothing for it. No question, no setup and no introduction.
        - label: what it does, at most 6 words, naming the document or service.
        - task: the same as one sentence the user would say to you.
        \(AgentWriting.rule)
        """
        let schema: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["offers"], "properties": ["offers": ["type": "array", "items": [
            "type": "object", "additionalProperties": false, "required": ["label", "task"], "properties": ["label": ["type": "string"], "task": ["type": "string"]],
        ]]]]
        struct Output: Decodable {
            struct Offer: Decodable { let label, task: String }
            let offers: [Offer]
        }
        guard let reply = await CostLedger.$agent.withValue(bean.id.uuidString, operation: { try? await ModelClient().json(system: system, text: reality, schema: schema, effort: "low") }),
              let body = reply.text, let output = try? JSONDecoder().decode(Output.self, from: Data(body.utf8)), !output.offers.isEmpty else { return }
        let offers = Array(output.offers.prefix(3))
        guard folder.journal.isEmpty else { return }
        raise(AgentNeed(kind: .decision, question: "Here is what I can do now. Pick one, or tell me what you want.", options: offers.map(\.label),
                        consequences: Dictionary(offers.map { ($0.label, $0.task) }, uniquingKeysWith: { first, _ in first }), firstMove: true), agent: bean)
    }

    func dropFirstMove() {
        guard let bean = storeForBrain.agents.first(where: \.isBean) else { return }
        let folder = AgentFolder(bean, in: storeForBrain)
        guard folder.needs.contains(where: { $0.firstMove == true }) else { return }
        folder.save(folder.needs.filter { $0.firstMove != true })
        refresh()
    }
}
