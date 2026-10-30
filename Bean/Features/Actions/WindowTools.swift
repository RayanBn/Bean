import Foundation

extension AgentWorker {
    func windowTools(_ agent: Agent, attachment: Attachment, folder: AgentFolder) -> [BrainTool] {
        let controls = WindowControls()
        let offLimits = OffLimits.match("\(attachment.appName) \(attachment.bundleId) \(attachment.windowTitle ?? "")") != nil
        let read = BrainTool(name: "window_read", description: "Read what your window shows now.", parameters: [:], effect: .read) { _ in
            if offLimits { return ToolOutput(text: "This window is off limits.", ok: false) }
            guard let snapshot = await Task.detached(operation: { WindowSnapshot.read(attachment) }).value else { return ToolOutput(text: "I cannot read this window.", ok: false) }
            return ToolOutput(text: "Title: \(snapshot.title ?? "untitled")\n\(OffLimits.redact(snapshot.text).text.prefix(4000))")
        }
        let list = BrainTool(name: "window_controls", description: "List the fields and buttons of your window that can be used without the mouse or keyboard, with their numbers.", parameters: [:], effect: .read) { _ in
            if offLimits { return ToolOutput(text: "This window is off limits.", ok: false) }
            return ToolOutput(text: controls.list(attachment))
        }
        let act = BrainTool(name: "window_act", description: "Fill a field or press a button of your window, by its number from window_controls, without the mouse or keyboard.", parameters: [
            "control": ["type": "integer"],
            "action": ["type": "string", "enum": ["fill", "press"]],
            "text": ["type": "string", "description": "For fill: the new content of the field."],
            "did": ["type": "string", "description": "What this does, in plain words, for the journal."],
            "why": ["type": "string"],
        ], required: ["control", "action", "did", "why"], effect: .read) { [weak self] args in
            guard let self, let index = args["control"] as? Int, let action = args.string("action") else { return ToolOutput(text: "control and action are needed", ok: false) }
            let did = args.string("did") ?? action, why = args.string("why") ?? ""
            let abilities = folder.abilities
            let label = controls.controls.indices.contains(index) ? controls.controls[index].label : ""
            var refusal: String?
            if offLimits { refusal = "this window is off limits" }
            else if await MainActor.run(body: { self.isOverBudget(agent) }) { refusal = "your budget for today is spent" }
            else if BeanSettings.shared.effectivePaused { refusal = "all agents are paused" }
            else if action == "fill", abilities.first(where: { $0.id == "window fill" })?.allowed == false { refusal = "Filling fields is turned off for this agent" }
            else if action == "press", abilities.first(where: { $0.id == "window press" })?.allowed == false { refusal = "Pressing buttons is turned off for this agent" }
            else if action == "press", WindowChannels.isIrreversible(label), abilities.first(where: { $0.id == "window press risky" })?.allowed != true { refusal = "\"\(label)\" cannot be taken back, and that is turned off for this agent" }
            else if controls.controls.indices.contains(index), let refused = AppGuard.refusal(control: AppControls.describe(controls.controls[index].element), action: action) { refusal = refused }
            else if action == "press", let refused = AppGuard.risky(label, abilities) { refusal = refused }
            if let refusal {
                await MainActor.run { self.note(.refused, did, why, refusal, agent) }
                return ToolOutput(text: "refused: \(refusal)", ok: false)
            }
            if Self.dryRun {
                await MainActor.run { self.note(.action, "Dry run: \(did)", why, "", agent) }
                return ToolOutput(text: "done")
            }
            let failure = action == "fill" ? controls.setValue(index, args.string("text") ?? "") : controls.press(index)
            await MainActor.run { self.note(failure == nil ? .action : .failed, did, why, failure ?? "", agent) }
            return ToolOutput(text: failure ?? "done", ok: failure == nil)
        }
        let script = BrainTool(name: "app_script", description: "Drive \(attachment.appName) through its own scripting, in the background: one AppleScript that starts with tell application \"\(attachment.appName)\". It cannot bring the app to the front or leave the app. Use it to read and change its documents.", parameters: [
            "script": ["type": "string"],
            "did": ["type": "string", "description": "What this does, in plain words, for the journal."],
            "why": ["type": "string"],
            "undo": ["type": "string", "description": "How to undo it, in plain words, if it can be undone."],
        ], required: ["script", "did", "why"], effect: .read) { [weak self] args in
            guard let self, let source = args.string("script") else { return ToolOutput(text: "script is needed", ok: false) }
            let did = args.string("did") ?? "Ran a script", why = args.string("why") ?? ""
            var refusal = WindowChannels.refusal(script: source, app: attachment.appName, abilities: folder.abilities)
            if offLimits { refusal = "this window is off limits" }
            if await MainActor.run(body: { self.isOverBudget(agent) }) { refusal = "your budget for today is spent" }
            if BeanSettings.shared.effectivePaused { refusal = "all agents are paused" }
            if let refusal {
                await MainActor.run { self.note(.refused, did, why, refusal, agent) }
                return ToolOutput(text: "refused: \(refusal)", ok: false)
            }
            if Self.dryRun {
                await MainActor.run { self.note(.action, "Dry run: \(did)", why, source, agent) }
                return ToolOutput(text: "done")
            }
            if let problem = await Task.detached(operation: { AppActions.prepare(attachment.bundleId, name: attachment.appName) }).value {
                await MainActor.run { self.note(.failed, did, why, problem, agent) }
                return ToolOutput(text: problem, ok: false)
            }
            let outcome = await AppActions.runScript(source)
            let result = (ok: outcome.ok, output: outcome.text)
            await MainActor.run {
                self.record(JournalEntry(kind: result.ok ? .action : .failed, did: did, why: why, result: String(result.output.prefix(300)), undo: result.ok ? args.string("undo") : nil), agent)
                self.markUsed(attachment.appName, by: agent)
            }
            return ToolOutput(text: OffLimits.redact(result.output).text.prefix(3000).description, ok: result.ok)
        }
        let more = AppActions.tools(attachment: attachment, folder: folder, explicit: folder.mission?.explicitlyAllowed ?? [], dryRun: Self.dryRun, blocked: { [weak self] in
            if BeanSettings.shared.effectivePaused { return "all agents are paused" }
            guard let self else { return nil }
            return await MainActor.run { self.isOverBudget(agent) } ? "your budget for today is spent" : nil
        }, journal: { [weak self] entry in
            await MainActor.run { self?.record(entry, agent) }
        })
        return [read, list, act, script] + more
    }
}
