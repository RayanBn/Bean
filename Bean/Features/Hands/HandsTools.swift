import Foundation

extension AgentWorker {
    static var handsLine: String {
        Strands.isOn ? "Several actions in your window go through window_hands, and a long list through sweep." : ""
    }

    func handsTools(_ agent: Agent, attachment: Attachment, folder: AgentFolder, offLimits: Bool) -> [BrainTool] {
        guard Strands.isOn, !Self.dryRun else { return [] }
        let hands = BrainTool(name: "window_hands", description: "The fast way to work in your window: several fills and presses at once, under a second each, without the mouse or keyboard. Call it directly with the goal in plain words and everything the goal needs: it reads the window itself, so do not call window_read or window_controls first. Muse Spark plans the steps and writes the text, a local model picks each control, and it reads the window again after each one and checks the result. Use window_act only for a single action. If it reports a control it could not reach, use app_script.", parameters: [
            "goal": ["type": "string", "description": "What the window must end up showing."],
        ], required: ["goal"], effect: .read) { [weak self] args in
            guard let self, let goal = args.string("goal") else { return ToolOutput(text: "goal is needed", ok: false) }
            if offLimits { return ToolOutput(text: "This window is off limits.", ok: false) }
            if await MainActor.run(body: { self.onlyReading.contains(agent.id) }) { return ToolOutput(text: "refused: the user asked you to only read this window: finish with what you read", ok: false) }
            let hands = InstantHands(attachment: attachment, abilities: { folder.abilities }, blocked: { [weak self] in
                if BeanSettings.shared.effectivePaused { return "all agents are paused" }
                guard let self else { return nil }
                return await MainActor.run { self.isOverBudget(agent) } ? "your budget for today is spent" : nil
            }, journal: { [weak self] entry in
                await MainActor.run { self?.record(entry, agent) }
            })
            hands.holdsBack = { [weak self] text in await self?.holdsBack(text, attachment: attachment, agent: agent) == true }
            let report = await hands.run(goal: goal)
            return ToolOutput(text: report.text, ok: report.finished)
        }
        return [hands] + sweepTools(agent, attachment: attachment, folder: folder, offLimits: offLimits)
    }
}
