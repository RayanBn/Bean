import Foundation

struct SenseRow: Identifiable {
    let id: String
    let title: String
    let sentence: String
    let on: Bool
}

extension AgentWorker {
    private static let senseAllow = "Allow"
    private static let senseRefuse = "Don't allow"

    func senseTools(_ agent: Agent, folder: AgentFolder) -> [BrainTool] {
        let list = BrainTool(name: "list_senses", description: "What you can ask to notice on this Mac, and what you already notice.", parameters: [:], effect: .read) { _ in
            let mine = folder.subscriptions(of: agent)
            return ToolOutput(text: Sense.all.map { sense in
                let held = mine.first { $0.sense == sense.id }
                let state = held == nil ? "off" : held?.paused == true ? "turned off by the user" : "on"
                let params = sense.params.map { " Params: \($0.map { "\($0.key): \($0.value)" }.sorted().joined(separator: " "))" } ?? ""
                return "\(sense.id) (\(state)): \(sense.sentence)\(params)"
            }.joined(separator: "\n"))
        }
        let request = BrainTool(name: "request_sense", description: "Ask the user to let you notice something, so that it can wake the team when it happens. Ask only when your mission needs it, and only for what list_senses offers.", parameters: [
            "id": ["type": "string", "description": "The sense's id from list_senses."],
            "why": ["type": "string", "description": "What you will do with it, in one short sentence the user reads."],
            "params": ["type": "object", "description": "The params the sense lists. Values are strings. Leave it empty when it lists none.", "additionalProperties": ["type": "string"]],
        ], required: ["id", "why"], effect: .read) { [weak self] args in
            guard let self else { return ToolOutput(text: "not available", ok: false) }
            let params = (args["params"] as? [String: String]) ?? [:]
            let answer = await requestSense(agent, id: args.string("id") ?? "", why: args.string("why") ?? "", params: params)
            return ToolOutput(text: answer, ok: !answer.hasPrefix("refused"))
        }
        let drop = BrainTool(name: "drop_sense", description: "Stop noticing a sense you no longer need.", parameters: [
            "id": ["type": "string", "description": "The sense's id."],
        ], effect: .read) { [weak self] args in
            guard let self, let id = args.string("id") else { return ToolOutput(text: "not available", ok: false) }
            folder.save(folder.subscriptions(of: agent).filter { $0.sense != id })
            await MainActor.run { self.senses?.refresh() }
            return ToolOutput(text: "Dropped.")
        }
        return [list, request, drop]
    }

    private func requestSense(_ agent: Agent, id: String, why: String, params: [String: String]) async -> String {
        guard let sense = Sense.named(id) else { return "refused: there is no sense \(id). See list_senses." }
        if let unknown = params.keys.first(where: { $0 != "app" && sense.params?[$0] == nil }) { return "refused: \(id) takes no param \(unknown)." }
        if let term = OffLimits.match(params.values.joined(separator: " ")) { return "refused: off limits: \(term)." }
        if sense.driver == "connector" {
            guard let tool = params["tool"] else { return "refused: \(id) needs the param tool." }
            guard await ConnectorDriver.readTool(tool) != nil else { return "refused: \(tool) is not a read tool of a connected connector." }
            guard ConnectorDriver.arguments(params) != nil else { return "refused: args is not a JSON object." }
        }
        let folder = AgentFolder(agent, in: storeForBrain)
        if let held = folder.subscriptions(of: agent).first(where: { $0.sense == id && $0.params == params }) {
            return held.paused ? "refused: the user turned this off." : "already on"
        }
        let extra = params["tool"].map { " Tool: \($0)." } ?? params["app"].map { " Only \($0)." } ?? ""
        await MainActor.run {
            raise(AgentNeed(kind: .decision, question: "Let \(agent.name) notice \(sense.title.lowercased())?", options: [Self.senseAllow, Self.senseRefuse], recommended: Self.senseAllow,
                            consent: id, detail: "\(sense.sentence)\(extra) \(why)", senseParams: params, senseWhy: why), agent: agent)
        }
        return "Asked, and still off: you notice nothing until the user allows it. Never say it is on. Say you asked to notice \(sense.title.lowercased()), and never use the word sense with the user."
    }

    func answerSenseRequest(_ need: AgentNeed, agent: Agent, text: String) {
        close(need, agent: agent, answer: text)
        record(JournalEntry(kind: .said, did: text, why: need.question), agent)
        guard text == Self.senseAllow, let id = need.consent else { return }
        let folder = AgentFolder(agent, in: storeForBrain)
        folder.save(folder.subscriptions(of: agent) + [SenseSubscription(sense: id, params: need.senseParams ?? [:], why: need.senseWhy ?? "")])
        senses?.refresh()
        refresh()
    }

    func senseRows(_ agent: Agent) -> [SenseRow] {
        AgentFolder(agent, in: storeForBrain).subscriptions(of: agent).compactMap { held in
            Sense.named(held.sense).map { SenseRow(id: $0.id, title: $0.title, sentence: $0.sentence, on: !held.paused) }
        }
    }

    func setSense(_ agent: Agent, id: String, on: Bool) {
        let folder = AgentFolder(agent, in: storeForBrain)
        folder.save(folder.subscriptions(of: agent).map { held in
            var held = held
            if held.sense == id { held.paused = !on }
            return held
        })
        record(JournalEntry(kind: .said, did: "\(on ? "Turned on" : "Turned off") \(Sense.named(id)?.title ?? id)", why: ""), agent)
        senses?.refresh()
    }

    func sensesLine(_ agent: Agent, folder: AgentFolder) -> String {
        let names = folder.subscriptions(of: agent).filter { !$0.paused }.compactMap { Sense.named($0.sense)?.title }
        let calls = folder.wantsCalls ? "You asked to hear calls, so the person is asked when one starts." : "You have not asked to hear calls."
        return "You notice: \(names.isEmpty ? "nothing yet" : names.joined(separator: ", ")). list_senses shows what else you can ask for. \(calls)"
    }
}
