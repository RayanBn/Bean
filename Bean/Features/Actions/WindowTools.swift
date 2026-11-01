import Foundation

extension AgentWorker {
    func windowTools(_ agent: Agent, attachment: Attachment, folder: AgentFolder) -> [BrainTool] {
        let controls = WindowControls()
        let appOffLimits = OffLimits.match("\(attachment.appName) \(attachment.bundleId)") != nil
        let offLimits = appOffLimits || OffLimits.match("\(attachment.appName) \(attachment.bundleId) \(attachment.windowTitle ?? "")") != nil
        let sealedBy = Skills.forApp(attachment.bundleId).flatMap { $0.sealed ? $0 : nil }
        let offLimitsText = "This is off limits."
        let read = BrainTool(name: "window_read", description: "Read what your app shows in front: the window you sit on. app_windows and the reads below reach everything else in the app.", parameters: [:], effect: .read) { _ in
            if offLimits { return ToolOutput(text: offLimitsText, ok: false) }
            if sealedBy != nil { return ToolOutput(text: "This window shows the user's own conversations, so it is not read and nothing can be sent to it. To get code written use session_drive.", ok: false) }
            guard let snapshot = await Task.detached(operation: { WindowSnapshot.read(attachment) }).value else {
                return ToolOutput(text: "I cannot read this window. Use app_windows for the rest of the app. If it is scriptable, read a document with app_script before you write anything: never write to a document you have not read.", ok: false) }
            return ToolOutput(text: snapshot.shown(limit: 4000))
        }
        let others = BrainTool(name: "app_windows", description: "See all of your app: the title of each of its windows and, in a browser, each tab with its title and URL, numbered for tab_read. Use it before you say something is missing or ask anything about it.", parameters: [:], effect: .read) { _ in
            if appOffLimits { return ToolOutput(text: offLimitsText, ok: false) }
            if AppTabs.isBrowser(attachment.bundleId), let problem = await Task.detached(operation: { AppActions.prepare(attachment.bundleId, name: attachment.appName) }).value {
                let titles = await Task.detached(operation: { AppTabs.windowTitles(of: attachment) }).value
                return ToolOutput(text: "\(problem) The tabs cannot be listed, so what they hold is unknown. Windows: \(titles.filter { OffLimits.match("\(attachment.appName) \($0)") == nil }.joined(separator: "; "))", ok: false)
            }
            return ToolOutput(text: await AppTabs.list(attachment))
        }
        let readOther = BrainTool(name: "app_window_read", description: "Read another window of your app in the background, by its exact title from app_windows.", parameters: [
            "title": ["type": "string"],
        ], required: ["title"], effect: .read) { args in
            guard let title = args.string("title") else { return ToolOutput(text: "title is needed", ok: false) }
            if appOffLimits || OffLimits.match("\(attachment.appName) \(attachment.bundleId) \(title)") != nil { return ToolOutput(text: offLimitsText, ok: false) }
            let other = await Task.detached(operation: { WindowChannels.open().first { $0.bundleId == attachment.bundleId && $0.title == title }.map(WindowChannels.attachment(for:)) }).value
                ?? Attachment(bundleId: attachment.bundleId, appName: attachment.appName, pid: attachment.pid, windowNumber: 0, windowTitle: title)
            guard let snapshot = await Task.detached(operation: { WindowSnapshot.read(other) }).value else {
                return ToolOutput(text: "I cannot read that window.", ok: false)
            }
            return ToolOutput(text: snapshot.shown(limit: 4000))
        }
        let readTab = BrainTool(name: "tab_read", description: "Read the text of a tab of your app in the background, by its numbers from app_windows: tab 2.3 is window 2, tab 3. The person's view does not change.", parameters: [
            "window": ["type": "integer"],
            "tab": ["type": "integer"],
            "from": ["type": "integer", "description": "Where to go on from, when a page is longer than one read."],
        ], required: ["window", "tab"], effect: .read) { args in
            guard AppTabs.isBrowser(attachment.bundleId) else { return ToolOutput(text: "\(attachment.appName) is not a browser this works with.", ok: false) }
            guard let window = args["window"] as? Int, let tab = args["tab"] as? Int else { return ToolOutput(text: "window and tab are needed", ok: false) }
            if appOffLimits { return ToolOutput(text: offLimitsText, ok: false) }
            if let problem = await Task.detached(operation: { AppActions.prepare(attachment.bundleId, name: attachment.appName) }).value {
                return ToolOutput(text: "\(problem) What the tab holds is unknown.", ok: false)
            }
            let page = await AppTabs.read(attachment, window: window, tab: tab, from: args["from"] as? Int ?? 0)
            return ToolOutput(text: page.text, ok: page.ok)
        }
        let list = BrainTool(name: "window_controls", description: "List the fields and buttons of the window you sit on that can be used without the mouse or keyboard, with their numbers.", parameters: [:], effect: .read) { _ in
            if offLimits { return ToolOutput(text: "This window is off limits.", ok: false) }
            return ToolOutput(text: controls.list(attachment))
        }
        let act = BrainTool(name: "window_act", description: "Fill a field or press a button of the window you sit on, by its number from window_controls, without the mouse or keyboard.", parameters: [
            "control": ["type": "integer"],
            "action": ["type": "string", "enum": ["fill", "press"]],
            "text": ["type": "string", "description": "For fill: the new content of the field."],
            "did": ["type": "string", "description": "What this does, in plain words, for the journal."],
            "why": ["type": "string"],
        ], required: ["control", "action", "did", "why"], effect: .read) { [weak self] args in
            guard let self, let index = args["control"] as? Int, let action = args.string("action") else { return ToolOutput(text: "control and action are needed", ok: false) }
            let did = args.string("did") ?? action, why = args.string("why") ?? ""
            let limits = await MainActor.run { self.perimeter(for: agent) }
            let refusal = controls.refusal(index, action: action, perimeter: limits)
            if let refusal {
                await MainActor.run { self.askToChangeWindow(agent, after: refusal) }
                await MainActor.run { self.note(.refused, did, why, refusal, agent) }
                return ToolOutput(text: "refused: \(refusal)", ok: false)
            }
            if Self.dryRun {
                await MainActor.run { self.note(.action, "Dry run: \(did)", why, "", agent) }
                return ToolOutput(text: "done")
            }
            let before = action == "fill" ? controls.value(index) : nil
            let failure = action == "fill" ? controls.setValue(index, args.string("text") ?? "") : controls.press(index)
            await MainActor.run {
                self.record(JournalEntry(kind: failure == nil ? .action : .failed, did: did, why: why, result: failure ?? "", undo: before == nil || failure != nil ? nil : "Put back the earlier text",
                                         undoText: failure == nil ? before : nil, undoField: failure == nil && before != nil ? index : nil), agent)
            }
            return ToolOutput(text: failure ?? "done", ok: failure == nil)
        }
        let script = BrainTool(name: "app_script", description: "Drive your app through its own scripting, in the background: one AppleScript that starts with tell application and that app's exact name. It cannot bring the app to the front, change what the person sees or leave the app. Use it to read and change a document, by its exact title. Lists of windows and tabs come from app_windows, never from a script.", parameters: [
            "script": ["type": "string"],
            "did": ["type": "string", "description": "What this does, in plain words, for the journal."],
            "why": ["type": "string"],
            "undo": ["type": "string", "description": "How to undo it, in plain words, if it can be undone."],
        ], required: ["script", "did", "why"], effect: .read) { [weak self] args in
            guard let self, let source = args.string("script") else { return ToolOutput(text: "script is needed", ok: false) }
            if AppGuard.usesPosition(AppGuard.code(of: source)) { return ToolOutput(text: "not run: \(AppGuard.positionHint(attachment.windowTitle))", ok: false) }
            let did = args.string("did") ?? "Ran a script", why = args.string("why") ?? ""
            let refusal = await MainActor.run { self.perimeter(for: agent) }.refusal(.script(source))
            if let refusal {
                await MainActor.run { self.askToChangeWindow(agent, after: refusal) }
                await MainActor.run { self.note(.refused, did, why, refusal, agent) }
                return ToolOutput(text: "refused: \(refusal)", ok: false)
            }
            if Self.dryRun {
                await MainActor.run { self.note(.action, "Dry run: \(did)", why, source, agent) }
                return ToolOutput(text: "done")
            }
            if let problem = await Task.detached(operation: { AppActions.prepare(attachment.bundleId, name: attachment.appName) }).value {
                await MainActor.run { self.askPermission(agent, attachment: attachment, problem: problem, task: did) }
                return ToolOutput(text: "\(problem) The user is told if they can do something about it. Stop trying to change this app, and do not use anything else in its place: call finish and say what you could not do.", ok: false)
            }
            if await AppActions.savesDocumentWithoutFile(source, app: attachment.appName) {
                let text = "Nothing ran. This document has never been saved, and a save would create a file in the user's cloud folder and wait. Send the script again without save: a value you set stays in the document. In your summary say the edit is in the open document and the app may keep its own copy, for example in iCloud. Do not say it is unsaved."
                await MainActor.run { self.note(.refused, did, why, text, agent) }
                return ToolOutput(text: text, ok: false)
            }
            let outcome = await AppActions.runScript(source)
            let result = (ok: outcome.ok, output: outcome.text)
            await MainActor.run {
                self.record(JournalEntry(kind: result.ok ? .action : .failed, did: did, why: why, result: result.ok ? String(result.output.replacingOccurrences(of: "missing value, ", with: "").prefix(1200)) : "\(result.output.prefix(300))\nScript: \(source.prefix(600))", undo: result.ok ? args.string("undo") : nil), agent)
            }
            return ToolOutput(text: OffLimits.redact(result.output).text.prefix(3000).description, ok: result.ok)
        }
        let more = AppActions.tools(attachment: attachment, folder: folder, explicit: folder.mission?.explicitlyAllowed ?? [], dryRun: Self.dryRun, perimeter: { [weak self] in
            await MainActor.run { self?.perimeter(for: agent) } ?? Perimeter(folder: folder, window: attachment)
        }, journal: { [weak self] entry in
            await MainActor.run { self?.record(entry, agent) }
        })
        if sealedBy != nil { return [read] }
        let onTheWindow = Set(["window_controls", "window_act", "window_hands", "sweep"])
        return ([read, others, readOther, readTab, list, act, script] + more + senseRequests(agent, attachment: attachment, folder: folder) + handsTools(agent, attachment: attachment, folder: folder, offLimits: offLimits))
            .map { onTheWindow.contains($0.name) ? Self.endsWithItsWindow($0, attachment) : Self.endsWithItsApp($0, attachment) }
    }

    // What acts in the window it sits on needs that exact window. It never falls to the app's next document.
    nonisolated private static func endsWithItsWindow(_ tool: BrainTool, _ attachment: Attachment) -> BrainTool {
        gated(tool) {
            if WindowSnapshot.offLimitsNow(attachment) { return ToolOutput(text: "This window is off limits.", ok: false) }
            switch WindowSnapshot.presence(attachment) {
            case .open: return nil
            case .notShowing: return ToolOutput(text: "The window you sit on is in a background tab, or on another Space where reaching it would bring its app to the front, so it cannot be reached now. It works again when the user goes back to it. The rest of the app can still be read.", ok: false)
            case .closed: return ToolOutput(text: "The window you sat on has closed. Nothing was done in it. The rest of the app can still be read.", ok: false)
            }
        }
    }

    nonisolated private static func endsWithItsApp(_ tool: BrainTool, _ attachment: Attachment) -> BrainTool {
        gated(tool) {
            kill(attachment.pid, 0) != 0 ? ToolOutput(text: "\(attachment.appName) has quit, so you are off it. Finish, and say what was not done.", ok: false) : nil
        }
    }

    nonisolated private static func gated(_ tool: BrainTool, by refusal: @escaping @Sendable () -> ToolOutput?) -> BrainTool {
        let run = tool.run
        var gated = BrainTool(name: tool.name, description: tool.description, parameters: tool.parameters, required: tool.required, effect: tool.effect) { args in
            if let refused = refusal() { return refused }
            return await run(args)
        }
        gated.stepTitles = tool.stepTitles
        if let steps = tool.runSteps {
            gated.runSteps = { args, report in
                if let refused = refusal() { return refused }
                return await steps(args, report)
            }
        }
        gated.showsArguments = tool.showsArguments
        gated.runsAtOnce = tool.runsAtOnce
        return gated
    }
}
