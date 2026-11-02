import Foundation

extension AgentWorker {
    private static let terminalOutputLimit = 20000
    private static let terminalOutputHead = 500
    private static let secretWords = " It is asking for a secret, hidden as it is typed: only the person can type that, in this terminal. Say so."
    private static let quietBeforeWaking: TimeInterval = 300
    private static let quietWakesAllowed = 2
    private static let backgroundBeforeWaking: TimeInterval = 1800

    func terminalTool(agent: Agent, folder: AgentFolder) -> BrainTool {
        BrainTool(name: "terminal", description: """
        Your terminal: a real login shell on this Mac, with the person's PATH, environment and signed-in tools. Pipes, chaining, interpreters, scripts, long-running and interactive programs all work. The session stays between your calls and your runs: its folder, its variables and whatever is still running. The person can watch it and type in it.
        Each reply gives what is new on the screen, then how things stand: the exit code when a command ended, or the program still running.
        A program still running waits for you: call with no command to look again, answer it with input or key, or end it with stop. Run long work in the foreground, with no & or nohup, so the person watches it. Do not sit polling it and never sleep to wait: if your run ends with it still running, you get a new run with its result when it ends, so you can finish now and say it is under way. Only a server you mean to leave on goes in the background, with its output in a file. Do not use exit or set -e at the prompt: they end the session.
        """, parameters: [
            "command": ["type": "string", "description": "One command line for the shell, typed as it is. Several lines stay one command."],
            "input": ["type": "string", "description": "Text for the program that is running, followed by Enter."],
            "enter": ["type": "boolean", "description": "False to type input without Enter."],
            "key": ["type": "string", "description": "A key to press: C-c, C-d, C-z or any C-<letter>, ENTER, TAB, ESC, BS, UP, DOWN, LEFT, RIGHT, HOME, END, PGUP, PGDN."],
            "stop": ["type": "boolean", "description": "End the running program: Ctrl-C, then harder if it does not stop."],
            "reset": ["type": "boolean", "description": "Throw this session away and start a new shell. Only when it no longer answers: its folder, variables and programs are lost."],
            "wait": ["type": "number", "description": "How many seconds to wait at most, up to 3600. It returns as soon as a command ends. By default 10 after a command, 1 after input or a key, 30 to look again."],
            "did": ["type": "string", "description": "What this command does, in plain words, for the person. Like \"Listed the open pull requests\"."],
            "changes": ["type": "boolean", "description": "True when this command changes something, so it shows among your changes."],
            "undo": ["type": "string", "description": "How to undo it, in plain words, if it can be undone."],
            "undo_command": ["type": "string", "description": "The one command that undoes it, if there is one."],
        ], effect: .read) { [weak self] args in
            guard let self else { return ToolOutput(text: "not running", ok: false) }
            return await self.useTerminal(args, agent: agent, folder: folder)
        }
    }

    private func useTerminal(_ args: JSONArgs, agent: Agent, folder: AgentFolder) async -> ToolOutput {
        if let halted = perimeter(for: agent).halted { return ToolOutput(text: "\(halted): call finish now", ok: false) }
        let command = args.string("command"), input = args.string("input"), key = args.string("key")
        let did = args.string("did")
        if Self.dryRun, command != nil {
            record(JournalEntry(kind: .action, did: "Dry run: \(did ?? command ?? "")", why: "", result: "not executed: \(command ?? "")", undoCommand: args.string("undo_command")), agent)
            return ToolOutput(text: "[Exit code 0]")
        }
        let terminals = SessionTerminals.shared
        if args["reset"] as? Bool == true { terminals.reset(agent: agent.id) }
        let tab = await terminals.agentTab(of: agent.id, folder: folder.url.path)
        if command != nil {
            let look = terminals.look(at: tab)
            if look.foreground != nil || look.unfinished {
                let screen = OffLimits.redact(look.text).text
                return ToolOutput(text: "\(screen.suffix(Self.terminalOutputLimit))\n[Not typed: this command would go to what is waiting there, which is \(look.foreground ?? "the shell"). Answer it with input or key, end it with stop, or call with no command to look again.]", ok: false)
            }
        }
        let typed = Date()
        var usual = 30.0
        if args["stop"] as? Bool == true {
            await terminals.stop(tab)
            usual = 1
        }
        if let key, !terminals.press(key, in: tab) { return ToolOutput(text: "No key called \(key).", ok: false) }
        if key != nil { usual = 1 }
        if let input {
            terminals.enter(input, in: tab, newline: args["enter"] as? Bool ?? true)
            usual = 1
        }
        if let command {
            terminals.enter(command, in: tab)
            usual = 10
        }
        let seconds = min(max((args["wait"] as? NSNumber)?.doubleValue ?? usual, 0), 3600)
        await terminals.settle(tab, typed: typed, seconds: seconds) { [weak self] in
            guard let self else { return true }
            return self.runsToStop.contains(agent.id) || BeanSettings.shared.effectivePaused || self.isOverBudget(agent)
        }
        let look = terminals.look(at: tab)
        let ok = look.exit.map { $0 == 0 } ?? true
        let screen = OffLimits.redact(look.text).text
        noteTerminal(command: command, did: did, look: look, screen: screen, ok: ok, args: args, agent: agent, folder: folder)
        return ToolOutput(text: Self.reading(of: look, screen: screen, folder: folder), ok: ok)
    }

    func terminalLine(_ agent: Agent) -> String {
        guard let tab = SessionTerminals.shared.agentTab(of: agent.id), let program = SessionTerminals.shared.programRunning(in: tab) ?? SessionTerminals.shared.background(in: tab).first else { return "" }
        return "Your terminal is still running \(program)."
    }

    // What the agent left running comes back to it as a new run when it ends, so nothing has to poll. It keeps showing as work under way, and the person can stop it.
    func watchTerminal(of agent: Agent, work: String) {
        guard !runsToStop.contains(agent.id), let tab = SessionTerminals.shared.agentTab(of: agent.id), SessionTerminals.shared.programRunning(in: tab) != nil || !SessionTerminals.shared.background(in: tab).isEmpty, terminalWatches.insert(agent.id).inserted else { return }
        Self.log.append(Entry(agent: agent.name, event: "terminalWatch", detail: work.prefix(120).description))
        Task { @MainActor in
            let ended = await waitForTerminal(tab, agent: agent, work: work)
            terminalWatches.remove(agent.id)
            guard let ended else { return await planMayBeSettled() }
            await wake(agent, work: work, about: ended, tab: tab)
        }
    }

    private enum TerminalWait { case ended, quiet }

    private func waitForTerminal(_ tab: SessionTerminals.Tab, agent: Agent, work: String) async -> TerminalWait? {
        let terminals = SessionTerminals.shared
        let began = Date()
        var shown = false
        defer { if shown { clearDoing(agent, ifStill: work) } }
        func stopped() -> Bool {
            guard runsToStop.contains(agent.id) || stopHeld(agent) else { return false }
            runsToStop.remove(agent.id)
            return true
        }
        while tab.running, let program = terminals.programRunning(in: tab) ?? terminals.background(in: tab).first {
            if stopped() { return nil }
            if !isBusy(agent.id) {
                if doing[agent.id] == nil {
                    shown = true
                    setDoing(agent, work, bubble: "Waiting for \(program) in the terminal")
                }
                // What runs in the background prints elsewhere, so only time says it may be a server left on.
                let silent = terminals.programRunning(in: tab) == nil ? Date().timeIntervalSince(began) >= Self.backgroundBeforeWaking : Date().timeIntervalSince(tab.view.lastOutput) >= Self.quietBeforeWaking
                if silent {
                    if quietWakes[agent.id, default: 0] >= Self.quietWakesAllowed { return nil }
                    quietWakes[agent.id, default: 0] += 1
                    return .quiet
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
        quietWakes[agent.id] = nil
        // Stop itself ends the program. A run under way has the terminal in hand and sees how it ended.
        return stopped() || isBusy(agent.id) ? nil : .ended
    }

    private func wake(_ agent: Agent, work: String, about wait: TerminalWait, tab: SessionTerminals.Tab) async {
        wakingTerminals += 1
        while BeanSettings.shared.effectivePaused { try? await Task.sleep(for: .seconds(2)) }
        let folder = AgentFolder(agent, in: storeForBrain)
        let look = SessionTerminals.shared.look(at: tab)
        let screen = OffLimits.redact(look.text).text
        let reading = Self.reading(of: look, screen: screen, folder: folder)
        noteTerminal(command: nil, did: nil, look: look, screen: screen, ok: true, args: [:], agent: agent, folder: folder)
        let news = wait == .ended ? "What you left running in your terminal has ended." : "What you left running in your terminal has been quiet for a long time, so it may be waiting for input. Answer it, stop it, or leave it and finish."
        let task = "\(news)\nYou were doing: \(work.prefix(600))\nThe terminal now:\n\(reading)\nCarry on from here, and do not start it again. Your summary says how it came out."
        Self.log.append(Entry(agent: agent.name, event: "terminalWoke", detail: news))
        let result = await runHandedOff(agent, task: task, trigger: "Your terminal")
        Self.log.append(Entry(agent: agent.name, event: "terminalAnswered", detail: "\(task)\n=> \(result.prefix(400))"))
        refresh()
        if !result.isEmpty, !agent.isBean {
            teamResults.append("\(agent.name): \(result.prefix(600))")
            if heldPlan == nil, !settlingPlan, storeForBrain.agents.first(where: \.isBean).map({ !isBusy($0.id) }) != false {
                record(JournalEntry(kind: .replied, did: result, why: ""), agent)
            }
        }
        wakingTerminals -= 1
        await planMayBeSettled()
    }

    // How a command came out is what later checks read, so it reaches the journal however the agent came to see it.
    private func noteTerminal(command: String?, did: String?, look: TerminalLook, screen: String, ok: Bool, args: JSONArgs, agent: Agent, folder: AgentFolder) {
        let links = screen.split(whereSeparator: \.isWhitespace).filter { $0.hasPrefix("https://") }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)]\"'")) }
        let known = Set(folder.journal.compactMap(\.link))
        let pull = links.first { $0.contains("/pull/") && !known.contains($0) }
        guard let command else {
            let ended = look.foreground == nil && look.exit != nil && !screen.isEmpty
            if ended || pull != nil { record(JournalEntry(kind: .session, did: ended ? "The terminal command ended, exit \(look.exit ?? 0)" : "Seen in the terminal: \(pull ?? "")", why: "", result: String(screen.suffix(1000)), link: pull), agent) }
            return
        }
        let changes = args["changes"] as? Bool == true
        record(JournalEntry(kind: changes ? (ok ? .action : .failed) : .session, did: did ?? "Ran \(command.prefix(120))", why: "$ \(command.prefix(400))", result: String(screen.suffix(1000)), link: pull ?? (changes ? links.first : nil),
                            undo: ok ? args.string("undo") : nil, undoCommand: ok ? args.string("undo_command") : nil), agent)
    }

    private static func reading(of look: TerminalLook, screen: String, folder: AgentFolder) -> String {
        var shown = screen
        if screen.count > terminalOutputLimit {
            let file = folder.url.appendingPathComponent("terminal-output.txt")
            try? screen.write(to: file, atomically: true, encoding: .utf8)
            shown = "\(screen.prefix(terminalOutputHead))\n[\(screen.count - terminalOutputLimit) characters cut here. All of it is in \(file.path).]\n\(screen.suffix(terminalOutputLimit - terminalOutputHead))"
        }
        var state: String
        if look.ended {
            state = "The shell has ended. Your next call opens a new one."
        } else if let program = look.foreground {
            state = "Still running: \(program).\(look.asksForSecret ? Self.secretWords : "")"
        } else if look.unfinished {
            state = "The shell has not come back: it waits for the rest of a command, or for input.\(look.asksForSecret ? Self.secretWords : "") Answer with input, send the key C-c, or start over with reset."
        } else {
            state = look.exit.map { "Exit code \($0)." } ?? "Back at the prompt."
        }
        if !look.background.isEmpty { state += " In the background: \(look.background.joined(separator: ", "))." }
        if let folder = look.folder { state += " Folder: \(folder)." }
        return (shown.isEmpty ? "" : shown + "\n") + "[\(state)]"
    }
}
