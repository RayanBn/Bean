import Foundation

extension AgentWorker {
    private static let terminalOutputLimit = 20000
    private static let terminalOutputHead = 500

    func terminalTool(agent: Agent, folder: AgentFolder) -> BrainTool {
        BrainTool(name: "terminal", description: """
        Your terminal: a real login shell on this Mac, with the person's PATH, environment and signed-in tools. Pipes, chaining, interpreters, scripts, long-running and interactive programs all work. The session stays between your calls and your runs: its folder, its variables and whatever is still running. The person can watch it and type in it.
        Each reply gives what is new on the screen, then how things stand: the exit code when a command ended, or the program still running.
        A program still running waits for you: call with no command to look again, answer it with input or key, or end it with stop. Nothing wakes you when a program ends, so stay with long work until it is done. A server you want to leave running goes in the background with its output in a file. Do not use exit or set -e at the prompt: they end the session.
        """, parameters: [
            "command": ["type": "string", "description": "One command line for the shell, typed as it is. Several lines stay one command."],
            "input": ["type": "string", "description": "Text for the program that is running, followed by Enter."],
            "enter": ["type": "boolean", "description": "False to type input without Enter."],
            "key": ["type": "string", "description": "A key to press: C-c, C-d, C-z or any C-<letter>, ENTER, TAB, ESC, BS, UP, DOWN, LEFT, RIGHT, HOME, END, PGUP, PGDN."],
            "stop": ["type": "boolean", "description": "End the running program: Ctrl-C, then harder if it does not stop."],
            "reset": ["type": "boolean", "description": "Throw this session away and start a new shell. Only when it no longer answers: its folder, variables and programs are lost."],
            "wait": ["type": "number", "description": "How many seconds to wait at most, up to 300. It returns as soon as a command ends. By default 10 after a command, 1 after input or a key, 30 to look again."],
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
        if let command, let program = terminals.programRunning(in: tab) {
            let screen = OffLimits.redact(terminals.look(at: tab).text).text
            return ToolOutput(text: "\(screen.suffix(Self.terminalOutputLimit))\n[Not typed: \(program) is still running, and this command would go to it. Answer it with input or key, end it with stop, or call with no command to look again.]", ok: false)
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
        let seconds = min(max(args["wait"] as? Double ?? usual, 0), 300)
        await terminals.settle(tab, typed: typed, seconds: seconds) { [weak self] in
            guard let self else { return true }
            return self.runsToStop.contains(agent.id) || BeanSettings.shared.effectivePaused || self.isOverBudget(agent)
        }
        let look = terminals.look(at: tab)
        let ok = look.exit.map { $0 == 0 } ?? true
        let screen = OffLimits.redact(look.text).text
        noteTerminal(command: command, did: did, screen: screen, ok: ok, args: args, agent: agent, folder: folder)
        return ToolOutput(text: Self.reading(of: look, screen: screen, folder: folder), ok: ok)
    }

    private func noteTerminal(command: String?, did: String?, screen: String, ok: Bool, args: JSONArgs, agent: Agent, folder: AgentFolder) {
        let links = screen.split(whereSeparator: \.isWhitespace).filter { $0.hasPrefix("https://") }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)]\"'")) }
        let known = Set(folder.journal.compactMap(\.link))
        let pull = links.first { $0.contains("/pull/") && !known.contains($0) }
        guard let command else {
            if let pull { record(JournalEntry(kind: .session, did: "Seen in the terminal: \(pull)", why: "", link: pull), agent) }
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
            state = "Still running: \(program).\(look.asksForSecret ? " It is asking for a secret, hidden as it is typed: only the person can type that, in this terminal. Say so." : "")"
        } else if look.unfinished {
            state = "The shell waits for the rest of a command: finish it with input, or send the key C-c."
        } else {
            state = look.exit.map { "Exit code \($0)." } ?? "Back at the prompt."
        }
        if let folder = look.folder { state += " Folder: \(folder)." }
        return (shown.isEmpty ? "" : shown + "\n") + "[\(state)]"
    }
}
