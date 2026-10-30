import Foundation

extension AgentWorker {
    func beanTools(_ bean: Agent, folder: AgentFolder) -> [BrainTool] {
        let list = BrainTool(name: "list_windows", description: "List the open windows of every app, with their numbers. Off-limits windows are hidden.", parameters: [:], effect: .read) { _ in
            let lines = await Task.detached { WindowChannels.forModel() }.value
            return ToolOutput(text: lines.isEmpty ? "No window is open." : lines.joined(separator: "\n"))
        }
        let create = BrainTool(name: "create_agent", description: "Create an agent from one sentence: what it does. Reuse an existing agent when one fits.", parameters: [
            "sentence": ["type": "string"],
        ], effect: .read) { [weak self] args in
            guard let self, let sentence = args.string("sentence") else { return ToolOutput(text: "sentence is needed", ok: false) }
            do {
                let created = try await AgentMaker().write(sentence)
                await MainActor.run {
                    try? AgentMaker.save(created, in: self.storeForBrain)
                    self.note(.action, "Created \(created.agent.name): \(created.agent.role)", sentence, "", bean)
                }
                return ToolOutput(text: "Created \(created.agent.name): \(created.agent.role)")
            } catch {
                return ToolOutput(text: ModelClient.plain(error), ok: false)
            }
        }
        let attach = BrainTool(name: "attach_agent", description: "Put an agent on a window, or move it to another one. That window becomes its work.", parameters: [
            "agent": ["type": "string", "description": "The agent's name."],
            "window": ["type": "integer", "description": "The window's number from list_windows."],
        ], effect: .read) { [weak self] args in
            guard let self, let name = args.string("agent"), let number = args["window"] as? Int else { return ToolOutput(text: "agent and window are needed", ok: false) }
            guard let window = await Task.detached(operation: { WindowChannels.open().first { $0.number == number } }).value else { return ToolOutput(text: "no open window \(number)", ok: false) }
            if OffLimits.match("\(window.app) \(window.bundleId) \(window.title ?? "")") != nil { return ToolOutput(text: "refused: this window is off limits", ok: false) }
            let placed: Agent? = await MainActor.run {
                guard let agent = self.agent(named: name) else { return nil }
                self.place(agent, on: window)
                var entry = JournalEntry(kind: .handoff, did: "Put \(agent.name) on \(window.app): \(window.title ?? "untitled")", why: "")
                entry.to = agent.id
                self.record(entry, bean)
                return agent
            }
            guard let placed else { return ToolOutput(text: "no agent named \(name)", ok: false) }
            for _ in 0..<40 {
                if await MainActor.run(body: { self.storeForBrain.agents.first { $0.id == placed.id }?.attachment?.windowNumber == number }) { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return ToolOutput(text: "\(placed.name) is on \(window.app), \(window.title ?? "untitled")")
        }
        let detach = BrainTool(name: "detach_agent", description: "Take an agent off its window.", parameters: ["agent": ["type": "string"]], effect: .read) { [weak self] args in
            guard let self, let name = args.string("agent") else { return ToolOutput(text: "agent is needed", ok: false) }
            return await MainActor.run {
                guard let agent = self.agent(named: name) else { return ToolOutput(text: "no agent named \(name)", ok: false) }
                self.storeForBrain.attach(agent.id, to: nil)
                self.note(.action, "Took \(agent.name) off its window", "", "", bean)
                return ToolOutput(text: "\(agent.name) is off its window")
            }
        }
        let hand = BrainTool(name: "hand_off", description: "Give an agent one concrete task in its window and get its result back. Agents act only when you ask them. Put everything it needs in the task, including results from other agents.", parameters: [
            "agent": ["type": "string"],
            "task": ["type": "string"],
            "why": ["type": "string", "description": "Why this agent, in one sentence."],
        ], effect: .read) { [weak self] args in
            guard let self, let name = args.string("agent"), let task = args.string("task") else { return ToolOutput(text: "agent and task are needed", ok: false) }
            let why = args.string("why") ?? ""
            return await self.handOff(task, to: name, why: why, from: bean)
        }
        return [list, create, attach, detach, hand]
    }

    @MainActor
    private func agent(named name: String) -> Agent? {
        storeForBrain.agents.first { $0.name.caseInsensitiveCompare(name) == .orderedSame && !$0.isBean }
    }

    @MainActor
    private func handOff(_ task: String, to name: String, why: String, from bean: Agent) async -> ToolOutput {
        guard let agent = agent(named: name) else { return ToolOutput(text: "no agent named \(name)", ok: false) }
        let folder = AgentFolder(agent, in: storeForBrain)
        guard agent.attachment != nil || folder.mission?.isActive == true else { return ToolOutput(text: "\(agent.name) has no window: attach it first", ok: false) }
        recordHandoff(task, why: why, from: bean, to: agent)
        let result = await runHandedOff(agent, task: task)
        return ToolOutput(text: "\(agent.name) says: \(result)")
    }

    func beanPrompt() -> String {
        let store = storeForBrain
        let team = store.agents.filter { !$0.isBean }.map { agent -> String in
            let folder = AgentFolder(agent, in: store)
            let window = agent.attachment.map { "on \($0.appName), \($0.windowTitle ?? "untitled")" } ?? "no window"
            let needs = folder.needs.map(\.question).prefix(2).joined(separator: "; ")
            return "- \(agent.name): \(agent.role) \(window)\(needs.isEmpty ? "" : ". Waiting on the user: \(needs)")"
        }.joined(separator: "\n")
        return """
        You are the brain. Your agents act only when you hand_off to them, and they talk to each other through you.
        Your team:
        \(team.isEmpty ? "nobody yet" : team)
        To reach a goal: find the windows with list_windows, reuse or create_agent, attach_agent, then hand_off in order, passing each result into the next task. If a window you need is not open, ask_user. Finish with one short report to the user.
        """
    }
}
