import AppKit

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
            guard let snapshot = await Task.detached(operation: { WindowSnapshot.read(attachment, now: true) }).value else {
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
            guard let snapshot = await Task.detached(operation: { WindowSnapshot.read(other, now: true) }).value else {
                return ToolOutput(text: "I cannot read that window.", ok: false)
            }
            return ToolOutput(text: snapshot.shown(limit: 4000))
        }
        let readTab = BrainTool(name: "tab_read", description: AppTabs.readDescription, parameters: [
            "window": ["type": "integer"],
            "tab": ["type": "integer"],
            "wake": ["type": "boolean", "description": AppTabs.wakeDescription],
            "from": ["type": "integer", "description": "Where to go on from, when a page is longer than one read."],
        ], required: ["window", "tab"], effect: .read) { args in
            guard AppTabs.isBrowser(attachment.bundleId) else { return ToolOutput(text: "\(attachment.appName) is not a browser this works with.", ok: false) }
            guard let window = args["window"] as? Int, let tab = args["tab"] as? Int else { return ToolOutput(text: "window and tab are needed", ok: false) }
            if appOffLimits { return ToolOutput(text: offLimitsText, ok: false) }
            if let problem = await Task.detached(operation: { AppActions.prepare(attachment.bundleId, name: attachment.appName) }).value {
                return ToolOutput(text: "\(problem) What the tab holds is unknown.", ok: false)
            }
            let page = await AppTabs.read(attachment, window: window, tab: tab, from: args["from"] as? Int ?? 0, mayWake: args["wake"] as? Bool ?? false)
            if page.waitsForTheView { await MainActor.run { self.wakeLater(agent, attachment: attachment, identity: String(page.text.prefix { $0 != "\n" })) } }
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
            let limits = await MainActor.run { self.perimeter(for: agent, on: attachment) }
            let refusal = controls.refusal(index, action: action, perimeter: limits)
            if let refusal {
                await MainActor.run { self.askToChangeWindow(agent, after: refusal, on: attachment) }
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
                                         undoText: failure == nil ? before : nil, undoField: failure == nil && before != nil ? index : nil, undoApp: attachment.key), agent)
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
            let refusal = await MainActor.run { self.perimeter(for: agent, on: attachment) }.refusal(.script(source))
            if let refusal {
                await MainActor.run { self.askToChangeWindow(agent, after: refusal, on: attachment) }
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
                let text = "Nothing ran. This document has never been saved, and a save would create a file in the user's cloud folder and wait. Send the script again without save: a value you set stays in the document. The edit then stays in the open document, and the app may keep its own copy."
                await MainActor.run { self.note(.refused, did, why, text, agent) }
                return ToolOutput(text: text, ok: false)
            }
            let outcome = await AppActions.runScript(source)
            let received = OffLimits.redact(outcome.text).text.prefix(3000).description
            await MainActor.run {
                self.record(JournalEntry(kind: outcome.ok ? .action : .failed, did: did, why: why, result: received, script: OffLimits.redact(source).text, undo: outcome.ok ? args.string("undo") : nil), agent)
            }
            return ToolOutput(text: received, ok: outcome.ok)
        }
        let more = AppActions.tools(attachment: attachment, folder: folder, explicit: folder.mission?.explicitlyAllowed ?? [], dryRun: Self.dryRun, perimeter: { [weak self] in
            await MainActor.run { self?.perimeter(for: agent, on: attachment) } ?? Perimeter(folder: folder, window: attachment)
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
            kill(attachment.pid, 0) != 0 ? ToolOutput(text: Self.closedText(attachment.appName), ok: false) : nil
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

// One app's tools live as long as its process and the window the agent sits on, so the numbers window_controls gave stay good for window_act.
private final class AppToolShelf: @unchecked Sendable {
    private var kept: [String: (place: String, tools: [BrainTool])] = [:]

    @MainActor
    func tools(for app: Attachment, build: () -> [BrainTool]) -> [BrainTool] {
        let place = "\(app.pid) \(app.windowNumber)"
        if let held = kept[app.key], held.place == place { return held.tools }
        let tools = build()
        kept[app.key] = (place, tools)
        return tools
    }
}

private struct AppToolChoice: @unchecked Sendable {
    var tool: BrainTool?
    var app: String?
    var refusal: ToolOutput?
}

extension AgentWorker {
    nonisolated static func closedText(_ app: String) -> String {
        "\(app) has quit, and it is still yours. If the work needs it, choose: reopen_app opens it in the background, or use_services may reach the same work another way. If neither fits, finish and say what was not done."
    }

    static func appsLine(_ apps: [Attachment], passages: [String: AppPassage] = [:]) -> String {
        if apps.count == 1, let app = apps.first, app.runningPid != nil { return "Your app is \(app.appName): all of it is your work. You sit on its window \(app.windowTitle ?? "untitled"). \(AppPassage.line(passages[app.key]))" }
        let lines = apps.map { "- \($0.runningPid == nil ? "\($0.appName), closed now" : "\($0.appName), where you sit on its window \($0.windowTitle ?? "untitled")"). \(AppPassage.line(passages[$0.key]))" }
        return lines.isEmpty ? "" : "Your apps, each with all of it your work:\n\(lines.joined(separator: "\n"))"
    }

    // Each call reaches the app as it is at that moment, so an app that quit and came back mid-run still works. With several apps, the model names which one.
    func appTools(_ agent: Agent, held: [Attachment], folder: AgentFolder) -> [BrainTool] {
        guard !held.isEmpty else { return [] }
        let names = held.map(\.appName), several = held.count > 1, shelf = AppToolShelf()
        let choice: @Sendable (String, JSONArgs) async -> AppToolChoice = { [weak self] name, args in
            guard let self else { return AppToolChoice(refusal: ToolOutput(text: "Bean is closing.", ok: false)) }
            return await MainActor.run {
                let apps = self.storeForBrain.agents.first { $0.id == agent.id }?.attachments ?? []
                guard var app = several ? apps.first(where: { $0.appName == args.string("app") }) : apps.first else {
                    return AppToolChoice(refusal: ToolOutput(text: several ? "Name one of your apps: \(names.joined(separator: ", "))." : "You are no longer on this app.", ok: false))
                }
                guard let pid = app.runningPid else { return AppToolChoice(refusal: ToolOutput(text: Self.closedText(app.appName), ok: false)) }
                app.pid = pid
                let tools = shelf.tools(for: app) { self.windowTools(agent, attachment: app, folder: folder) }
                guard let tool = tools.first(where: { $0.name == name }) else { return AppToolChoice(refusal: ToolOutput(text: "\(app.appName) does not offer this.", ok: false)) }
                return AppToolChoice(tool: tool, app: app.key)
            }
        }
        var seen = Set<String>()
        let forms = held.flatMap { windowTools(agent, attachment: $0, folder: folder) }.filter { seen.insert($0.name).inserted }
        let which: [String: Any] = ["type": "string", "enum": names, "description": "Which of your apps."]
        let tools = forms.map { [weak self] form -> BrainTool in
            let name = form.name
            var tool = BrainTool(name: name, description: form.description, parameters: several ? form.parameters.merging(["app": which]) { $1 } : form.parameters,
                                 required: several ? form.required.map { $0 + ["app"] } : form.required, effect: form.effect) { args in
                let chosen = await choice(name, args)
                guard let run = chosen.tool?.run, let app = chosen.app else { return chosen.refusal ?? ToolOutput(text: "This cannot be done now.", ok: false) }
                let changes = Self.changesItsApp(name, args)
                if changes { await self?.noteOwnChange(agent.id, app: app) }
                let output = await run(args)
                if changes { await self?.noteOwnChange(agent.id, app: app) }
                if output.ok, let what = AppPassage.whatWasRead(by: name, args: args, output: output.text) { folder.noteRead(what, in: app) }
                return output
            }
            tool.stepTitles = form.stepTitles
            if form.runSteps != nil {
                tool.runSteps = { args, report in
                    let chosen = await choice(name, args)
                    guard let run = chosen.tool?.runSteps, let app = chosen.app else { return chosen.refusal ?? ToolOutput(text: "This cannot be done now.", ok: false) }
                    let changes = Self.changesItsApp(name, args)
                    if changes { await self?.noteOwnChange(agent.id, app: app) }
                    let output = await run(args, report)
                    if changes { await self?.noteOwnChange(agent.id, app: app) }
                    return output
                }
            }
            tool.showsArguments = form.showsArguments
            tool.runsAtOnce = form.runsAtOnce
            return tool
        }
        return tools + [reopenTool(agent, names: names)]
    }

    private func reopenTool(_ agent: Agent, names: [String]) -> BrainTool {
        BrainTool(name: "reopen_app", description: "Open one of your apps that has quit, hidden in the background, with the document you were on when there is one: it stays off the person's screen and you read it the same way. Only for one of your own apps, when your work needs it open.", parameters: [
            "app": ["type": "string", "enum": names],
            "why": ["type": "string"],
        ], required: ["app", "why"], effect: .read) { [weak self] args in
            guard let self, let name = args.string("app") else { return ToolOutput(text: "app is needed", ok: false) }
            return await self.reopen(name, why: args.string("why") ?? "", agent: agent)
        }
    }

    @MainActor
    private func reopen(_ name: String, why: String, agent: Agent) async -> ToolOutput {
        guard let app = storeForBrain.agents.first(where: { $0.id == agent.id })?.attachments.first(where: { $0.appName == name }) else { return ToolOutput(text: "\(name) is not one of your apps.", ok: false) }
        if OffLimits.match("\(app.appName) \(app.bundleId)") != nil { return ToolOutput(text: "This is off limits.", ok: false) }
        if app.runningPid != nil { return ToolOutput(text: "\(name) is already open.") }
        if let halted = perimeter(for: agent, on: app).halted { return ToolOutput(text: "refused: \(halted)", ok: false) }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleId) else { return ToolOutput(text: "\(name) is no longer on this Mac.", ok: false) }
        if Self.dryRun {
            note(.action, "Dry run: reopened \(name)", why, "", agent)
            return ToolOutput(text: "done")
        }
        let document = app.document.map { URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let opening: BackgroundOpen
        do {
            opening = try await BackgroundOpen.start(url, bundleId: app.bundleId, document: document)
        } catch {
            note(.failed, "Could not reopen \(name)", why, error.localizedDescription, agent)
            return ToolOutput(text: "\(name) did not open: \(error.localizedDescription)", ok: false)
        }
        let opened = opening.app
        storeForBrain.sit(agent.id, app: app.key, pid: opened.processIdentifier, windowNumber: 0, windowTitle: app.windowTitle)
        var hasWindow = false
        for tick in 0..<24 {
            try? await Task.sleep(for: .milliseconds(250))
            hasWindow = hasWindow || WindowChannels.open().contains { $0.pid == opened.processIdentifier } || !SpaceWindows.known(of: opened.processIdentifier).isEmpty
            if tick >= 8, hasWindow, opened.isFinishedLaunching, NSWorkspace.shared.frontmostApplication != opened { break }
        }
        // A window on another Space or of a hidden app never reaches the bar's watch, and the tools still need it.
        let shown = WindowChannels.open().filter { $0.pid == opened.processIdentifier }
        if let window = shown.first(where: { $0.title == app.windowTitle }) ?? shown.first { storeForBrain.sit(agent.id, app: app.key, pid: opened.processIdentifier, windowNumber: window.number, windowTitle: window.title) }
        let stayedInFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == opened.processIdentifier
        Self.log.append(Entry(agent: agent.name, event: "reopened", detail: "\(app.bundleId) sentBack=\(opening.sentBack) inFront=\(stayedInFront) window=\(hasWindow) document=\(document != nil)"))
        if stayedInFront {
            note(.failed, "\(name) came to the front by itself when I reopened it in the background", why, "", agent)
            return ToolOutput(text: "\(name) is open, but it stayed in front of what the person was doing. Say so in your answer, and next time prefer another way than reopening it.")
        }
        note(.action, "Reopened \(name) in the background", why, "", agent)
        let holds = document.map { " It holds your document \($0.lastPathComponent)." } ?? (app.document == nil ? "" : " The document you were on is no longer there.")
        return ToolOutput(text: "\(name) is open again, hidden in the background.\(holds)\(hasWindow ? "" : " It shows no window yet.")")
    }
}

struct WaitingTab {
    let attachment: Attachment
    let identity: String
}

extension AgentWorker {
    func wakeLater(_ agent: Agent, attachment: Attachment, identity: String) {
        guard tabsToWake[agent.id]?.contains(where: { $0.identity == identity }) != true else { return }
        tabsToWake[agent.id, default: []].append(WaitingTab(attachment: attachment, identity: identity))
    }

    func wakeWaitingTabs() {
        guard !BeanSettings.shared.effectivePaused else { return }
        for (id, tabs) in tabsToWake where !isBusy(id) && !AppTabs.hasWindowOnScreen(pid: tabs[0].attachment.pid) {
            tabsToWake[id] = nil
            guard let agent = storeForBrain.agents.first(where: { $0.id == id }), agent.holds(tabs[0].attachment.bundleId) else { continue }
            Task { @MainActor in
                var awake: [String] = []
                for waiting in tabs {
                    if let place = await AppTabs.locate(waiting.identity, in: waiting.attachment), await AppTabs.wake(waiting.attachment, window: place.window, tab: place.tab) {
                        awake.append("tab \(place.window).\(place.tab): \(waiting.identity)")
                        note(.action, "Woke a sleeping tab to read it, after you left \(waiting.attachment.appName): \(waiting.identity)", "", "", agent)
                    }
                }
                guard !awake.isEmpty else { return }
                _ = await run(agent, trigger: "The tabs you could not read before are awake now:\n\(awake.joined(separator: "\n"))\nNobody asked you anything.")
            }
        }
    }
}
