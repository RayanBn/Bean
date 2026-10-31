import CryptoKit
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
                let names = await MainActor.run { self.storeForBrain.agents.map(\.name) }
                var created = try await AgentMaker().write(sentence, avoiding: names)
                if names.contains(created.agent.name) {
                    var number = 2
                    while names.contains("\(created.agent.name) \(number)") { number += 1 }
                    created.agent.name = "\(created.agent.name) \(number)"
                }
                await MainActor.run {
                    created.agent.look.hue = Agent.Look.nextHue(taken: self.storeForBrain.agents.filter { !$0.isBean }.map(\.look.hue))
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
            if await MainActor.run(body: { self.agent(named: name)?.attachment?.windowNumber == number }) {
                return ToolOutput(text: "\(name) is already on that window.")
            }
            if let other = await MainActor.run(body: { self.storeForBrain.agents.first { $0.attachment?.windowNumber == number && $0.name.caseInsensitiveCompare(name) != .orderedSame } }) {
                return ToolOutput(text: "refused: \(other.name) is already on that window, and each window has one agent. Hand off to \(other.name), or detach it first.", ok: false)
            }
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
            return ToolOutput(text: "\(placed.name) is on \(window.app), \(window.title ?? "untitled"). It has done nothing yet and will not start alone: hand_off its first task, even if it only has to set up what its mission needs, such as asking to hear calls. Until it has, promise nothing about what it will do.")
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
        var hand = BrainTool(name: "hand_off", description: "Give an agent one concrete task in its window and get its result back. Agents act only when you ask them. Put everything it needs in the task, including results from other agents.", parameters: [
            "agent": ["type": "string"],
            "task": ["type": "string"],
            "why": ["type": "string", "description": "Why this agent, in one sentence."],
        ], effect: .read) { [weak self] args in
            guard let self, let name = args.string("agent"), let task = args.string("task") else { return ToolOutput(text: "agent and task are needed", ok: false) }
            let why = args.string("why") ?? ""
            return await self.handOff(task, to: name, why: why, from: bean)
        }
        hand.waitsForResult = true
        let read = BrainTool(name: "read_window", description: "Read what a window shows now, by its number from list_windows, without any agent.", parameters: [
            "window": ["type": "integer"],
        ], effect: .read) { [weak self] args in
            guard let number = args["window"] as? Int else { return ToolOutput(text: "window is needed", ok: false) }
            let text: String? = await Task.detached {
                guard let window = WindowChannels.open().first(where: { $0.number == number }),
                      OffLimits.match("\(window.app) \(window.bundleId) \(window.title ?? "")") == nil else { return nil }
                var snapshot = WindowSnapshot.read(WindowChannels.attachment(for: window))
                if snapshot == nil {
                    try? await Task.sleep(for: .seconds(1))
                    snapshot = WindowSnapshot.read(WindowChannels.attachment(for: window))
                }
                guard let snapshot else { return nil }
                return "Title: \(snapshot.title ?? "untitled")\n\(OffLimits.redact(snapshot.text).text.prefix(3000))"
            }.value
            if text == nil { await MainActor.run { self?.note(.failed, "Could not read window \(number)", "It cannot be read, or it is off limits", "", bean) } }
            return text.map { ToolOutput(text: $0) } ?? ToolOutput(text: "This window cannot be read, or it is off limits.", ok: false)
        }
        return [list, read, create, attach, detach, hand]
    }

    @MainActor
    private func agent(named name: String) -> Agent? {
        storeForBrain.agents.first { $0.name.caseInsensitiveCompare(name) == .orderedSame && !$0.isBean }
    }

    @MainActor
    private func handOff(_ task: String, to name: String, why: String, from bean: Agent) async -> ToolOutput {
        guard let agent = agent(named: name) else { return ToolOutput(text: "no agent named \(name)", ok: false) }
        let folder = AgentFolder(agent, in: storeForBrain)
        guard agent.attachment != nil else { return ToolOutput(text: "\(agent.name) has no window: attach it first", ok: false) }
        let state = await Task.detached(operation: { HandedOffWork.state(of: agent.attachment) }).value
        if let done = folder.handedOff.last(where: { $0.state != nil && $0.state == state && AgentNeed.similar($0.task, task) }) {
            teamResults.append("\(agent.name), on \(agent.attachment?.windowTitle ?? "its window"): \(done.result.prefix(400))")
            return ToolOutput(text: "Not done again: \(agent.name) already did this at \(done.at.formatted(date: .omitted, time: .shortened)) and its window has not changed since. Its result: \(done.result)")
        }
        recordHandoff(task, why: why, from: bean, to: agent)
        if let attachment = agent.attachment, await Task.detached(operation: { WindowSnapshot.read(attachment) == nil }).value {
            return ToolOutput(text: "\(agent.name) cannot reach that window right now: it may be hidden, closed or on another Space. Say exactly that, and do not call it read-only.")
        }
        if let attachment = agent.attachment, let reason = await Task.detached(operation: { AppSurface.read(attachment).reason }).value {
            await sayIfNotDrivable(agent)
            return ToolOutput(text: "\(agent.name) cannot act in \(attachment.appName): \(reason) It can only read that window.")
        }
        let others = teamResults.isEmpty ? "" : "\n\nWhat the other agents did for this goal:\n" + teamResults.map { "- \($0)" }.joined(separator: "\n")
        let result = await runHandedOff(agent, task: task + others)
        teamResults.append("\(agent.name), on \(agent.attachment?.windowTitle ?? "its window"): \(result.prefix(400))")
        if folder.needs.contains(where: \.blocksRuns) {
            return ToolOutput(text: "\(agent.name) could not do this and now waits for the user: \(result) Stop this part. Do not do it another way, and report it.")
        }
        let after = await Task.detached(operation: { HandedOffWork.state(of: agent.attachment) }).value
        folder.remember(HandedOffWork(task: task, result: result, at: Date(), state: after))
        return ToolOutput(text: "\(agent.name) says: \(result)\(after == state ? " Its window did not change." : "")")
    }

    func beanTeam() -> String {
        beanRoster(connected: [])
    }

    var beanPrompt: String {
        """
        You are the brain. Your agents act only when you hand_off to them, and they talk to each other through you. Carry out your plan if you have one, and change it when what you read shows it is wrong.
        Work that needs no window, such as in a connected service, you do yourself: call use_services. A document the user names is in a window: if list_windows does not show it, ask_user at once to open it, and do not search for it with commands.
        For a window that needs work: one agent, reuse one if its role fits, otherwise create_agent, attach_agent, then hand_off with everything it needs. Hand off one at a time, the step others depend on first. Each next task states the results it needs. A first task may be setting up its own watching. Otherwise a hand_off asks for a change: to read or report, use read_window. Write tasks in plain words, because the user reads them: name a window by its title, never its number, and never name a tool.
        If a hand_off that asked for a change says the window did not change, hand_off again to the same agent, once, with the exact text to write and where. Before you finish, read_window each window you changed: your one short report says what those windows hold now, and what you could not do.
        Carry facts between windows only when they serve the same subject. To fill or total something in a window, its agent works from what that window holds. Write only in the windows the plan is about, and never move an agent off a window unasked. If an agent's result falls short, hand_off to the same agent again with what it lacked: never replace it.
        """
    }
}

struct HandedOffWork: Codable {
    let task: String
    let result: String
    let at: Date
    let state: String?

    static func state(of attachment: Attachment?) -> String? {
        guard let attachment, let snapshot = WindowSnapshot.read(attachment) else { return nil }
        return SHA256.hash(data: Data(((snapshot.title ?? "") + snapshot.text).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension AgentFolder {
    private var handedOffFile: URL { url.appendingPathComponent("handed-off.json") }

    var handedOff: [HandedOffWork] {
        (try? Data(contentsOf: handedOffFile)).flatMap { try? JSONDecoder().decode([HandedOffWork].self, from: $0) } ?? []
    }

    func remember(_ work: HandedOffWork) {
        let all = Array((handedOff + [work]).suffix(20))
        try? JSONEncoder().encode(all).write(to: handedOffFile, options: .atomic)
    }
}
