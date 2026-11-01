import Foundation

extension AgentWorker {
    func windowTools(_ agent: Agent, attachment: Attachment, folder: AgentFolder) -> [BrainTool] {
        let controls = WindowControls()
        let offLimits = OffLimits.match("\(attachment.appName) \(attachment.bundleId) \(attachment.windowTitle ?? "")") != nil
        let sealedBy = Skills.forApp(attachment.bundleId).flatMap { $0.sealed ? $0 : nil }
        let read = BrainTool(name: "window_read", description: "Read what your window shows now.", parameters: [:], effect: .read) { [weak self] _ in
            if offLimits { return ToolOutput(text: "This window is off limits.", ok: false) }
            if sealedBy != nil { return ToolOutput(text: "This window shows the user's own conversations, so it is not read and nothing can be sent to it. To get code written use session_drive.", ok: false) }
            guard let snapshot = await Task.detached(operation: { WindowSnapshot.read(attachment) }).value else {
                await MainActor.run { self?.note(.failed, "Could not read \(attachment.windowTitle ?? attachment.appName)", "The window did not answer", "", agent) }
                return ToolOutput(text: "I cannot read this window. If its app is scriptable, read it with app_script before you write anything: never write to a document you have not read.", ok: false) }
            if await self?.holdsBack(snapshot.text, attachment: attachment, agent: agent) == true { return ToolOutput(text: PrivateCheck.held, ok: false) }
            return ToolOutput(text: "Title: \(snapshot.title ?? "untitled")\n\(OffLimits.redact(snapshot.text).text.prefix(4000))")
        }
        let others = BrainTool(name: "app_windows", description: "See all of your window's app: the title of each of its windows and, in a browser, each tab with its title and URL. Use it when the work may be in another window or tab.", parameters: [:], effect: .read) { [weak self] _ in
            if offLimits { return ToolOutput(text: "This window is off limits.", ok: false) }
            guard ReadingYes.covers(attachment.bundleId) else { return Self.notYours }
            if AppTabs.isBrowser(attachment.bundleId), let problem = await Task.detached(operation: { AppActions.prepare(attachment.bundleId, name: attachment.appName) }).value {
                await MainActor.run { self?.askPermission(agent, attachment: attachment, problem: problem, task: "List the tabs of \(attachment.appName)") }
                return ToolOutput(text: "\(problem) The user is told if they can do something about it. Windows: \(AppTabs.windowTitles(of: attachment).joined(separator: "; "))", ok: false)
            }
            return ToolOutput(text: await AppTabs.list(attachment))
        }
        let readOther = BrainTool(name: "app_window_read", description: "Read another window of your window's app, by its exact title from app_windows.", parameters: [
            "title": ["type": "string"],
        ], required: ["title"], effect: .read) { [weak self] args in
            guard ReadingYes.covers(attachment.bundleId) else { return Self.notYours }
            guard let title = args.string("title") else { return ToolOutput(text: "title is needed", ok: false) }
            if offLimits || OffLimits.match("\(attachment.appName) \(attachment.bundleId) \(title)") != nil { return ToolOutput(text: "This window is off limits.", ok: false) }
            let other = Attachment(bundleId: attachment.bundleId, appName: attachment.appName, pid: attachment.pid, windowNumber: 0, windowTitle: title)
            guard let snapshot = await Task.detached(operation: { WindowSnapshot.read(other) }).value else {
                await MainActor.run { self?.note(.failed, "Could not read \(title)", "The window did not answer", "", agent) }
                return ToolOutput(text: "I cannot read that window.", ok: false)
            }
            if await self?.holdsBack(snapshot.text, attachment: other, agent: agent) == true { return ToolOutput(text: PrivateCheck.held, ok: false) }
            return ToolOutput(text: OffLimits.redact(snapshot.text).text.prefix(4000).description)
        }
        let readTab = BrainTool(name: "tab_read", description: "Read the text of a tab of your window's app, by its numbers from app_windows: tab 2.3 is window 2, tab 3.", parameters: [
            "window": ["type": "integer"],
            "tab": ["type": "integer"],
        ], required: ["window", "tab"], effect: .read) { [weak self] args in
            guard ReadingYes.covers(attachment.bundleId) else { return Self.notYours }
            guard AppTabs.isBrowser(attachment.bundleId) else { return ToolOutput(text: "\(attachment.appName) is not a browser this works with.", ok: false) }
            guard let window = args["window"] as? Int, let tab = args["tab"] as? Int else { return ToolOutput(text: "window and tab are needed", ok: false) }
            if offLimits { return ToolOutput(text: "This window is off limits.", ok: false) }
            if let problem = await Task.detached(operation: { AppActions.prepare(attachment.bundleId, name: attachment.appName) }).value {
                await MainActor.run { self?.askPermission(agent, attachment: attachment, problem: problem, task: "Read a tab of \(attachment.appName)") }
                return ToolOutput(text: "\(problem) The user is told if they can do something about it.", ok: false)
            }
            let page = await AppTabs.read(attachment, window: window, tab: tab)
            if !page.ok { await MainActor.run { self?.note(.failed, "Could not read tab \(window).\(tab)", "", page.text, agent) } }
            let shown = Attachment(bundleId: attachment.bundleId, appName: attachment.appName, pid: attachment.pid, windowNumber: 0, windowTitle: "tab \(window).\(tab)")
            if page.ok, await self?.holdsBack(page.text, attachment: shown, agent: agent) == true { return ToolOutput(text: PrivateCheck.held, ok: false) }
            return ToolOutput(text: page.text, ok: page.ok)
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
        let script = BrainTool(name: "app_script", description: "Drive your window's app through its own scripting, in the background: one AppleScript that starts with tell application and that app's exact name. It cannot bring the app to the front or leave the app. Use it to read and change the document of your window, by its title.", parameters: [
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
                return ToolOutput(text: "\(problem) The user is told if they can do something about it. Stop trying to change this window, and do not use anything else in its place: call finish and say what you could not do.", ok: false)
            }
            if await AppActions.savesDocumentWithoutFile(source, app: attachment.appName) {
                let text = "Nothing ran. This document has never been saved, and a save would create a file in the user's cloud folder and wait. Send the script again without save: a value you set stays in the document. In your summary say the edit is in the open document and the app may keep its own copy, for example in iCloud. Do not say it is unsaved."
                await MainActor.run { self.note(.refused, did, why, text, agent) }
                return ToolOutput(text: text, ok: false)
            }
            let outcome = await AppActions.runScript(source)
            let result = (ok: outcome.ok, output: outcome.text)
            await MainActor.run {
                self.record(JournalEntry(kind: result.ok ? .action : .failed, did: did, why: why, result: result.ok ? String(result.output.prefix(300)) : "\(result.output.prefix(300))\nScript: \(source.prefix(600))", undo: result.ok ? args.string("undo") : nil), agent)
            }
            return ToolOutput(text: OffLimits.redact(result.output).text.prefix(3000).description, ok: result.ok)
        }
        let more = AppActions.tools(attachment: attachment, folder: folder, explicit: folder.mission?.explicitlyAllowed ?? [], dryRun: Self.dryRun, perimeter: { [weak self] in
            await MainActor.run { self?.perimeter(for: agent) } ?? Perimeter(folder: folder, window: attachment)
        }, journal: { [weak self] entry in
            await MainActor.run { self?.record(entry, agent) }
        })
        if sealedBy != nil { return [read].map { Self.endsWithItsWindow($0, attachment) } }
        return ([read, others, readOther, readTab, list, act, script] + more + senseRequests(agent, attachment: attachment, folder: folder) + handsTools(agent, attachment: attachment, folder: folder, offLimits: offLimits)).map { Self.endsWithItsWindow($0, attachment) }
    }

    // The one gate for every tool of a window: once it has closed, none of them reach the rest of the app.
    nonisolated private static var notYours: ToolOutput {
        ToolOutput(text: "You read only your own window. The other windows of this app need the user's yes, which you do not have: finish, and say what you could not read.", ok: false)
    }

    nonisolated private static func endsWithItsWindow(_ tool: BrainTool, _ attachment: Attachment) -> BrainTool {
        @Sendable func refusal() -> ToolOutput? {
            switch WindowSnapshot.presence(attachment) {
            case .open: nil
            case .notShowing: ToolOutput(text: "Your window is in a background tab, or on another Space while the user is in its app, so it cannot be reached now. It works again when the user goes back to it or leaves the app. Do not act on any other window: finish, and say what was not done and why.", ok: false)
            case .closed: ToolOutput(text: "Your window has closed, so you are off it. Do not act on any other window: finish, and say what was not done.", ok: false)
            }
        }
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
