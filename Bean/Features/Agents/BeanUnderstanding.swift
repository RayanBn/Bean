import Foundation

struct BeanUnderstanding: Codable {
    struct Decision: Codable {
        let question: String
        let canDecide: Bool
        let choice: String
        let why: String
        let options: [String]
    }

    struct Link: Codable {
        let kind: String
        let name: String
        let why: String
    }

    struct Step: Codable {
        let what: String
        let who: String
        let why: String
        var size: String?
        var after: String?
        var done: String?
        var continues: String?
    }

    let summary: String
    let decisions: [Decision]
    let links: [Link]
    var steps: [Step]
    let remember: [String]
    var settled: [String]?
    var waitsForAnswer: Bool?
    var report: String?

    var plan: String {
        steps.enumerated().map { "\($0.offset + 1). \($0.element.who)\($0.element.size.map { ", \($0)" } ?? ""): \($0.element.what) (\($0.element.why))\($0.element.after.flatMap { $0.isEmpty ? nil : " After: \($0)." } ?? "")" }.joined(separator: "\n")
    }

    static let schema: [String: Any] = {
        func object(_ fields: [String: Any]) -> [String: Any] {
            ["type": "object", "additionalProperties": false, "required": Array(fields.keys), "properties": fields]
        }
        let text: [String: Any] = ["type": "string"]
        func list(_ item: [String: Any]) -> [String: Any] { ["type": "array", "items": item] }
        return object([
            "summary": text,
            "decisions": list(object(["question": text, "canDecide": ["type": "boolean"], "choice": text, "why": text, "options": list(text)])),
            "links": list(object(["kind": text, "name": text, "why": text])),
            "steps": list(object(["what": text, "who": text, "why": text, "size": text, "after": text, "done": text, "continues": text])),
            "remember": list(text),
            "settled": list(text),
            "report": text,
        ])
    }()
}

struct BeanMemory: Codable {
    var at = Date()
    let source: String
    let understanding: BeanUnderstanding
}

extension AgentFolder {
    private var understandingFile: URL { memory.appendingPathComponent("understanding.jsonl") }

    var understandings: [BeanMemory] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let text = (try? String(contentsOf: understandingFile, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? decoder.decode(BeanMemory.self, from: Data($0.utf8)) }
    }

    func remember(_ entry: BeanMemory) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(entry) else { return }
        try? FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        JSONLines.append(data, to: understandingFile)
    }
}

extension AgentWorker {
    static let understandingLog = JSONLog(name: "understanding")

    func beanRoster(connected: [String]?, of agents: [Agent]? = nil) -> String {
        let store = storeForBrain
        let team = (agents ?? store.agents.filter { !$0.isBean && !$0.name.isEmpty }).map { agent -> String in
            let folder = AgentFolder(agent, in: store)
            let window = agent.attachments.isEmpty ? "on no app" : "on " + agent.attachments.map { $0.runningPid == nil ? "\($0.appName), closed now" : "\($0.appName), sitting on \($0.windowTitle ?? "untitled")" }.joined(separator: "; ")
            let allowed = folder.abilities.filter { $0.allowed && $0.risk != .safe }.map(\.title).prefix(6).joined(separator: "; ")
            let off = folder.abilities.filter { !$0.allowed }.map(\.title).prefix(6).joined(separator: "; ")
            let done = folder.journal.filter { $0.kind == .action || $0.kind == .replied }.suffix(2).map { String($0.did.prefix(110)) }.joined(separator: "; ")
            let waits = folder.needs.map(\.question).prefix(2).joined(separator: "; ")
            let goal = folder.mission?.mission ?? agent.role
            var parts = ["\(agent.name): \(agent.role)"] + (goal == agent.role ? [] : ["goal: \(goal.prefix(160))"]) + [window]
            if let output = folder.job?.output, !output.isEmpty { parts.append("gives the person: \(output.prefix(120))") }
            if let targets = folder.mission?.named, !targets.isEmpty { parts.append("targets: \(targets)") }
            if let doing = doing[agent.id] { parts.append("working now on: \(doing.prefix(100))") }
            if !allowed.isEmpty { parts.append("may: \(allowed)") }
            if !off.isEmpty { parts.append("may not: \(off)") }
            if let held = holdings(of: agent) { parts.append("holds: \(held)") }
            if !done.isEmpty { parts.append("last: \(done)") }
            if !waits.isEmpty { parts.append("waits for the user on: \(waits)") }
            if folder.wantsCalls { parts.append("asked to hear calls") }
            if stopHeld(agent) { parts.append("stopped by the person") }
            return "- " + parts.joined(separator: " | ")
        }
        return """
        Your agents:
        \(team.isEmpty ? "none yet" : team.joined(separator: "\n"))
        \(connected.map { "Connected services: \($0.isEmpty ? "none" : $0.joined(separator: ", "))." } ?? "")
        """
    }

    private func holdings(of agent: Agent) -> String? {
        let tasks = AgentFolder(agent, in: storeForBrain).journal.filter { $0.kind == .handoff && $0.to == nil && Date().timeIntervalSince($0.at) < 43200 }.suffix(4).map { String($0.did.prefix(160)) }
        guard !tasks.isEmpty else { return nil }
        return tasks.joined(separator: "; ") + (doing[agent.id] == nil ? " (finished)" : " (the last one is under way)")
    }

    func agentHoldings() -> String {
        let lines = storeForBrain.agents.filter { !$0.isBean && !$0.name.isEmpty }.compactMap { agent in holdings(of: agent).map { "- \(agent.name): \($0)" } }
        let stopped = stepsStoppedByUser.map { "- Stopped by the user, not to restart unless they ask: \($0.step.what)" }
        return lines.isEmpty && stopped.isEmpty ? "nothing yet" : (lines + stopped).joined(separator: "\n")
    }

    func beanMemoryText(folder: AgentFolder) -> String {
        let past = folder.understandings.suffix(12)
        func when(_ date: Date) -> String {
            let calendar = Calendar.current
            return calendar.isDateInToday(date) ? "today" : calendar.isDateInYesterday(date) ? "yesterday" : date.formatted(date: .abbreviated, time: .omitted)
        }
        let lately = past.suffix(5).map { "- \(when($0.at)): \($0.understanding.summary)" }.joined(separator: "\n")
        let kept = past.flatMap(\.understanding.remember).suffix(15).map { "- \($0)" }.joined(separator: "\n")
        let links = past.flatMap(\.understanding.links).suffix(10).map { "- \($0.kind) \($0.name): \($0.why)" }.joined(separator: "\n")
        let decided = folder.decisions.filter { $0.kind == .judgment && $0.state != .escalated }.suffix(8).map { "- \($0.question): \($0.answer)" }.joined(separator: "\n")
        let open = folder.needs.map { "- \($0.question)" }.joined(separator: "\n")
        let done = folder.journal.filter { $0.kind == .action || ($0.kind == .handoff && $0.to != nil) }.suffix(10).map { "- \(when($0.at)): \($0.did.prefix(140))" }.joined(separator: "\n")
        return """
        Goals:
        \(folder.goals ?? "none yet")
        What you understood lately:
        \(lately.isEmpty ? "nothing" : lately)
        What you noted before:
        \(kept.isEmpty ? "nothing" : kept)
        Links you noted:
        \(links.isEmpty ? "none" : links)
        Decided already:
        \(decided.isEmpty ? "nothing" : decided)
        Waiting on the user:
        \(open.isEmpty ? "nothing" : open)
        Done or handed off lately, not to do twice unless it is asked again:
        \(done.isEmpty ? "nothing" : done)
        """
    }

    @MainActor
    func understand(_ information: String, source: String, bean: Agent, folder: AgentFolder) async -> BeanUnderstanding? {
        let brain = await Tools.shared.all(context: information, folder: nil)
        let connected = Set(brain.filter { $0.name.contains("__") }.compactMap { $0.name.components(separatedBy: "__").first }).sorted()
        let windows = await WindowChannels.places().map { "- \($0)" }.joined(separator: "\n")
        let underWay = readPlan().steps.filter { $0.state == .blocked || $0.agent.map { doing[$0] != nil } == true }.map { "- \($0.id), \($0.state.rawValue), \($0.owner): \($0.what.prefix(160))" }.joined(separator: "\n")
        let text = """
        \(Prompts.understanding)

        \(AgentContext.user())
        \(folder.remembered)

        \(beanRoster(connected: connected))

        Open windows, the one the person is in first:
        \(windows.isEmpty ? "none" : windows)

        \(beanMemoryText(folder: folder))

        \(underWay.isEmpty ? "" : "Steps under way, with their ids:\n\(underWay)\n")
        New, from \(source):
        \(OffLimits.redact(information).text.prefix(6000))
        """
        let reply = await CostLedger.$agent.withValue(bean.id.uuidString) { try? await ModelClient().json(system: Prompts.understandingSystem, text: text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression), schema: BeanUnderstanding.schema, effort: "low") }
        guard let body = reply?.text, var understanding = try? JSONDecoder().decode(BeanUnderstanding.self, from: Data(body.utf8)) else { return nil }
        folder.remember(BeanMemory(source: source, understanding: understanding))
        Self.understandingLog.append(BeanMemory(source: source, understanding: understanding))
        understanding.settled?.forEach { _ = closeNeed(matching: $0, agent: bean) }
        let answered = folder.decisions.filter { $0.state == .answered && Date().timeIntervalSince($0.at) < 86400 }
        let askedByAgents = storeForBrain.agents.filter { !$0.isBean }.flatMap { AgentFolder($0, in: storeForBrain).journal.filter { $0.kind == .stuck && Date().timeIntervalSince($0.at) < 86400 }.map(\.did) }
        for decision in understanding.decisions where !answered.contains(where: { AgentNeed.similar($0.question, decision.question) }) && !askedByAgents.contains(where: { AgentNeed.similar($0, decision.question) }) {
            if decision.canDecide {
                folder.append(AgentDecision(kind: .judgment, question: decision.question, answer: decision.choice, why: decision.why, confidence: 0.8))
            } else {
                var asked = AgentDecision(kind: .judgment, question: decision.question, answer: decision.choice, why: decision.why, confidence: 0)
                asked.state = .escalated
                folder.append(asked)
                raise(AgentNeed(kind: .decision, question: decision.question, options: decision.options, recommended: decision.options.first, decision: asked.id), agent: bean, why: decision.why)
            }
        }
        // A question to the person means waiting for the answer: acting anyway and retracting it later is worse than either choice.
        let waitsForAnswer = source == "the user" && understanding.decisions.contains { decision in !decision.canDecide && folder.needs.contains { AgentNeed.similar($0.question, decision.question) } }
        if waitsForAnswer {
            understanding.steps = []
            understanding.waitsForAnswer = true
        }
        if !understanding.steps.isEmpty {
            startPlan(understanding.steps, from: String(OffLimits.redact(information).text.prefix(3000)))
        }
        refresh()
        return understanding
    }

    @MainActor
    func inform(source: String, text: String) async -> String? {
        guard let bean = storeForBrain.agents.first(where: \.isBean) else { return nil }
        while isBusy(bean.id) { try? await Task.sleep(for: .seconds(1)) }
        let outcome = await run(bean, trigger: "\(source): \(text)", changed: true, gated: true)
        return outcome.summary
    }
}
