import AppKit

struct ProposalRecord: Codable {
    let tool: String
    let arguments: String
    let message: String?
    let button: String?
}

struct BrainAnswer: Codable {
    let at: Date
    let trigger: Trigger.Kind
    let attempt: Int
    let gateScore: Double?
    let sawScreen: Bool
    let repo: String?
    let tool: String?
    let message: String?
    let steps: [PlanStep]?
    var button: String? = nil
    var command: String? = nil
    var proposals: [ProposalRecord]? = nil
    var investigation: [ShellResult]? = nil
    var toolCalls: [String]? = nil
    var offered: [String]? = nil
    var rounds: Int? = nil
    let latencyMs: Int
    let model: String
    let promptTokens: Int?
    let completionTokens: Int?
    let failure: String?
}

final class Brain {
    static let system = """
    You are Bean, a discreet butler that lives in the notch of the user's Mac. Something happened that may deserve the user's attention. You get the event, then everything Bean knows about the Mac right now: open apps and windows with their text, browser tabs, what the user's apps and agents are doing, recent terminal commands, recently changed files and local servers.

    Investigate only what you need, and only what the event is about. Never read private content the event does not concern, such as other conversations, agent transcripts, mail, or notes and files of other projects, even when their path shows on screen. Call several read tools in the same turn when they do not depend on each other. Check facts instead of guessing: read the file, ask the command-line tool, read the app's state. run_shell runs a command in a hidden terminal on the user's Mac. look_at_screen gives you a screenshot when the text is not enough. While investigating, never change what is on screen and never touch anything outside the Mac: such commands are refused. Propose them instead.

    Then end with one of these:
    - Propose actions. Act tools are not run now: each one becomes a card in the notch, and Bean runs it with exactly your arguments when the user clicks. Propose the one action that moves the user forward, or, when the event leaves several things to do, one card for each, all in the same turn. Before proposing a change, check with read tools that it can work.
      Do each thing through the tool the user names or already uses for it: when they say a ticket goes in a tracker they have a connector for, use that connector, not another app. A change to code goes to an AI coding agent installed on this Mac, started in the project's folder.
      When the event leaves work to do, look for who can do it: the user's connectors (find_connectors, then connect when one fits and is missing), another AI agent installed on this Mac, or the apps themselves.
      run_command runs one command hidden. open_terminal starts a long-running command in a window the user can watch, such as another AI agent installed on this Mac doing the work, with the flags it needs to work on its own: read its --help to find them. Never use flags that turn off its safety checks or permission prompts; prefer a mode that lets it edit files in that folder. run_in_terminal types commands visibly in the terminal the event came from, to fix an error there.
    - show_message: the user should know something, and there is nothing to run.
    - stay_quiet: it is not clearly worth interrupting. The user already knows, it can wait, or you are not sure.

    How to talk: the user wants the conclusion, not the analysis. Each message is one sentence of at most 140 characters that says what is true and what to do, in the form "<the thing>: <its state>, <what to do>." Add the how in two or three words only when needed. Name the concrete thing by its own name. Never just repeat what the event said: add what you checked or what to do. No greetings, no hedging, no generic advice. Write in the language of the user's own texts on screen.
    Button labels: one to three words. Step titles: two to four words.
    Never propose sudo, rm -rf, force pushes, or anything that deletes data or touches the system.
    """
    static let finals: [BrainTool] = [
        BrainTool(name: "run_in_terminal", description: "Propose shell commands to type visibly in the terminal the event came from, in order, after the user confirms.", parameters: [
            "message": ["type": "string", "description": "The cause and what the commands do, for the notch. At most 140 characters."],
            "steps": ["type": "array", "minItems": 1, "maxItems": 4, "items": [
                "type": "object",
                "properties": ["title": ["type": "string"], "command": ["type": "string", "description": "One single-line shell command."]],
                "required": ["title", "command"],
            ]],
        ], effect: .read) { _ in ToolOutput(text: "") },
        BrainTool(name: "show_message", description: "Show a short message in the notch.", parameters: [
            "message": ["type": "string", "description": "At most 140 characters."],
        ], effect: .read) { _ in ToolOutput(text: "") },
        BrainTool(name: "stay_quiet", description: "Do not interrupt the user.", parameters: [:], effect: .read) { _ in ToolOutput(text: "") },
    ]
    static let dismissAfter: TimeInterval = 30
    static let maxAttempts = 2
    static let maxRounds = 6
    static let maxProposals = 4
    static let proactivePerHour = ProcessInfo.processInfo.environment["BEAN_PROACTIVE_PER_HOUR"].flatMap(Int.init) ?? 3

    struct Proposal {
        let tool: BrainTool?
        let name: String
        let args: JSONArgs
        var message: String? { args.string(BrainTool.messageKey) ?? args.string("message") }
        var button: String { args.string(BrainTool.buttonKey) ?? "Do it" }
        var steps: [PlanStep] {
            (args["steps"] as? [[String: Any]] ?? []).compactMap { step in
                guard let title = step["title"] as? String, let command = step["command"] as? String else { return nil }
                return PlanStep(title: title, command: command)
            }
        }
        var detail: String {
            if let titles = tool?.stepTitles?(args), !titles.isEmpty { return titles.joined(separator: " → ") }
            return String(args.shown.prefix(200))
        }
        var record: ProposalRecord { ProposalRecord(tool: name, arguments: args.withoutNotch.json, message: message, button: args.string(BrainTool.buttonKey)) }
    }

    private let client: ModelClient
    private let notch: NotchController
    private let actions: ActionRunner
    private let log: JSONLog
    private let context: () async -> MacContext?
    private var busy = false
    private var dismissal: DispatchWorkItem?
    private var proactiveShown: [Date] = []
    private var queue: [Proposal] = []
    private var confirmed = false

    init(client: ModelClient, notch: NotchController, actions: ActionRunner, log: JSONLog, context: @escaping () async -> MacContext?) {
        self.client = client
        self.notch = notch
        self.actions = actions
        self.log = log
        self.context = context
    }

    func consider(_ decision: GateDecision, _ trigger: Trigger) {
        guard decision.stepIn else {
            if trigger.gatePolicy != .never, decision.rule != "paused", !busy { notch.stayedQuiet() }
            return
        }
        guard !busy else { return }
        guard let notice = trigger.notice else {
            proactiveShown = proactiveShown.filter { Date().timeIntervalSince($0) < 3600 }
            guard proactiveShown.count < Self.proactivePerHour else { return }
            busy = true
            ask(about: trigger, gateScore: decision.score, attempt: 1)
            return
        }
        busy = true
        notch.notice(notice)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.ask(about: trigger, gateScore: decision.score, attempt: 1)
        }
    }

    private func ask(about trigger: Trigger, gateScore: Double?, attempt: Int) {
        if trigger.notice != nil { notch.think(attempt == 1 ? "Looking into it" : "Looking again") }
        Task.detached(priority: .userInitiated) {
            let context = await self.context()
            let tools = await Tools.shared.all(for: trigger)
            let (answer, proposals) = await self.think(about: trigger, context: context, tools: tools, gateScore: gateScore, attempt: attempt)
            await MainActor.run { self.present(answer, proposals, for: trigger, gateScore: gateScore) }
        }
    }

    private func think(about trigger: Trigger, context: MacContext?, tools: [BrainTool], gateScore: Double?, attempt: Int) async -> (BrainAnswer, [Proposal]) {
        let started = Date()
        var failures: [String] = []
        var sawScreen = false
        var investigation: [ShellResult] = []
        var called: [String] = []

        let repo = ActiveFolder.guess(for: trigger).flatMap(RepoState.read)
        var text = [trigger.summary, repo?.summary].compactMap { $0 }.joined(separator: "\n")
        if let context { text += "\n\nWhat Bean knows about the Mac right now:\n" + context.summary() }
        var messages: [[String: Any]] = [["role": "system", "content": Self.system], ["role": "user", "content": text]]

        let byName = Dictionary((tools + Self.finals).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let lastRoundTools = (tools.filter { $0.effect == .act } + Self.finals).map(\.schema)
        let allTools = (tools + Self.finals).map(\.schema)

        var final: (name: String, args: JSONArgs)?
        var proposals: [Proposal] = []
        var promptTokens = 0, completionTokens = 0
        var rounds = 0
        while final == nil, proposals.isEmpty, rounds < Self.maxRounds {
            rounds += 1
            let reply: ModelClient.Reply
            do {
                reply = try await client.chat(messages, tools: rounds == Self.maxRounds ? lastRoundTools : allTools)
            } catch {
                failures.append("model: \(error.localizedDescription)")
                break
            }
            promptTokens += reply.promptTokens ?? 0
            completionTokens += reply.completionTokens ?? 0
            guard !reply.toolCalls.isEmpty else {
                failures.append("model: no tool call")
                break
            }
            messages.append(reply.assistantMessage)
            let calls = reply.toolCalls.map { call in
                (call, (try? JSONSerialization.jsonObject(with: call.arguments)) as? JSONArgs ?? [:])
            }
            called += calls.map(\.0.name)

            let outputs = await withTaskGroup(of: (Int, ToolOutput).self) { group in
                for (index, (call, args)) in calls.enumerated() {
                    guard let tool = byName[call.name], tool.effect == .read, !Self.finals.contains(where: { $0.name == call.name }) else { continue }
                    group.addTask { (index, await tool.run(args)) }
                }
                var outputs: [Int: ToolOutput] = [:]
                for await (index, output) in group { outputs[index] = output }
                return outputs
            }

            var images: [Data] = []
            for (index, (call, args)) in calls.enumerated() {
                let content: String
                if let output = outputs[index] {
                    content = output.text
                    if let image = output.image { images.append(image) }
                    if call.name == "run_shell", let command = args.string("command") {
                        investigation.append(ShellResult(command: command, exit: output.ok ? 0 : 1, output: String(output.text.prefix(2000)), timedOut: false, seconds: 0, reason: args.string("reason")))
                    }
                } else if Self.finals.contains(where: { $0.name == call.name }) {
                    if call.name == "run_in_terminal" {
                        proposals.append(Proposal(tool: nil, name: call.name, args: args))
                    } else if final == nil {
                        final = (call.name, args)
                    }
                    content = "ok"
                } else if let tool = byName[call.name] {
                    if let command = args.string("command"), let blocked = Plan(steps: [PlanStep(title: "", command: command)], appBundleId: call.name).blockedCommand {
                        content = "refused: \(blocked) is never run by Bean (it deletes data, touches the system or turns off an agent's safety checks). Propose it without that."
                    } else {
                        if proposals.count < Self.maxProposals { proposals.append(Proposal(tool: tool, name: call.name, args: args)) }
                        content = "Queued as a card for the user's confirmation. It runs only if the user clicks."
                    }
                } else {
                    content = "unknown tool \(call.name)"
                }
                messages.append(["role": "tool", "tool_call_id": call.id, "content": content])
            }
            if !images.isEmpty {
                sawScreen = true
                messages.append(["role": "user", "content": [["type": "text", "text": "Screenshot of the main display:"]] + images.map(ModelClient.image)])
            }
        }
        if !proposals.isEmpty, final?.name == "stay_quiet" { final = nil }
        if final == nil, proposals.isEmpty, failures.isEmpty { failures.append("no answer after \(rounds) rounds") }

        let first = proposals.first
        var answer = BrainAnswer(
            at: started, trigger: trigger.kind, attempt: attempt, gateScore: gateScore, sawScreen: sawScreen, repo: repo?.summary,
            tool: final?.name ?? first?.name, message: final?.args.string("message") ?? first?.message, steps: first?.steps.isEmpty == false ? first?.steps : nil,
            latencyMs: Int(Date().timeIntervalSince(started) * 1000), model: client.label,
            promptTokens: promptTokens, completionTokens: completionTokens,
            failure: failures.isEmpty ? nil : failures.joined(separator: "; ")
        )
        answer.button = first?.args.string(BrainTool.buttonKey)
        answer.command = first?.args.string("command")
        answer.proposals = proposals.map(\.record)
        answer.investigation = investigation
        answer.toolCalls = called
        answer.offered = tools.map(\.name)
        answer.rounds = rounds
        log.append(answer)
        return (answer, proposals)
    }

    private func present(_ answer: BrainAnswer, _ proposals: [Proposal], for trigger: Trigger, gateScore: Double?) {
        if proposals.isEmpty {
            guard answer.tool == "show_message", let text = answer.message else {
                finish()
                if answer.tool == "stay_quiet" { notch.stayedQuiet() }
                return
            }
            if trigger.notice == nil { proactiveShown.append(Date()) }
            show(NotchMessage(text: text, choices: [NotchChoice(label: "Got it", isPrimary: true) { [weak self] in self?.finish() }]))
            return
        }
        if trigger.notice == nil { proactiveShown.append(Date()) }
        queue = proposals
        guard proposals.count > 1, proposals.allSatisfy({ $0.tool != nil }) else { return next(for: trigger, gateScore: gateScore, attempt: answer.attempt) }
        let cards = proposals.map { proposal in
            NotchCard(title: proposal.message ?? proposal.button, detail: proposal.detail, symbol: Self.symbol(proposal.name))
        }
        proposals.forEach { record(.proposed, Self.plan($0), trigger) }
        let byCard = Dictionary(uniqueKeysWithValues: zip(cards.map(\.id), proposals.indices))
        notch.review(NotchReview(text: answer.message ?? "", cards: cards, confirm: "Do it", onConfirm: { [weak self] ids in
            guard let self else { return }
            let chosen = Set(ids.compactMap { byCard[$0] })
            for index in proposals.indices where !chosen.contains(index) { record(.declined, Self.plan(proposals[index]), trigger) }
            confirmed = true
            queue = proposals.indices.filter(chosen.contains).map { proposals[$0] }
            next(for: trigger, gateScore: gateScore, attempt: answer.attempt)
        }, onDismiss: { [weak self] in
            guard let self else { return }
            proposals.forEach { self.record(.declined, Self.plan($0), trigger) }
            finish()
        }))
    }

    private func record(_ outcome: ActionRecord.Outcome, _ plan: Plan, _ trigger: Trigger, steps: [StepResult]? = nil) {
        actions.record(outcome, plan, steps: steps)
        Events.report(Events.Outcome(trigger: trigger, outcome: outcome, action: plan.steps.first?.command ?? ""))
    }

    private static func plan(_ proposal: Proposal) -> Plan {
        Plan(steps: [PlanStep(title: proposal.button, command: "\(proposal.name) \(proposal.args.withoutNotch.json)")], appBundleId: proposal.name)
    }

    private static func symbol(_ tool: String) -> String {
        switch tool {
        case "open_terminal", "run_command": return "terminal"
        case "do_steps", "achieve": return "cursorarrow.click"
        case "connect": return "link"
        default: return tool.contains("__") ? "square.and.arrow.up" : "bolt"
        }
    }

    private func next(for trigger: Trigger, gateScore: Double?, attempt: Int) {
        guard !queue.isEmpty else { return finish() }
        let proposal = queue.removeFirst()
        let gotIt = NotchChoice(label: "Got it", isPrimary: true) { [weak self] in self?.next(for: trigger, gateScore: gateScore, attempt: attempt) }
        var text = proposal.message ?? proposal.button
        if proposal.tool?.showsArguments == true, !proposal.args.shown.isEmpty { text += "\n" + proposal.args.shown.prefix(200) }

        if proposal.name == "run_in_terminal" {
            return propose(plan: proposal.steps, text: text, for: trigger, gateScore: gateScore, attempt: attempt, gotIt: gotIt)
        }
        guard let tool = proposal.tool else { return show(NotchMessage(text: text, choices: [gotIt])) }
        let plan = Self.plan(proposal)
        if confirmed { return perform(tool, proposal, plan, for: trigger, gateScore: gateScore, attempt: attempt) }
        record(.proposed, plan, trigger)
        show(NotchMessage(text: text, choices: [
            NotchChoice(label: "Not now", isPrimary: false) { [weak self] in
                self?.record(.declined, plan, trigger)
                self?.next(for: trigger, gateScore: gateScore, attempt: attempt)
            },
            NotchChoice(label: proposal.button, isPrimary: true) { [weak self] in
                self?.perform(tool, proposal, plan, for: trigger, gateScore: gateScore, attempt: attempt)
            },
        ]))
    }

    private func propose(plan steps: [PlanStep], text: String, for trigger: Trigger, gateScore: Double?, attempt: Int, gotIt: NotchChoice) {
        guard !steps.isEmpty else { return show(NotchMessage(text: text, choices: [gotIt])) }
        guard let bundleId = trigger.bundleId, TerminalText.terminals.contains(bundleId) else {
            let command = steps.map(\.command).joined(separator: " && ")
            let tool = CoreTools.named("open_terminal")
            let proposal = Proposal(tool: tool, name: "open_terminal", args: ["command": command, "cwd": trigger.cwd ?? "", BrainTool.messageKey: text, BrainTool.buttonKey: steps.count == 1 ? "Run it" : "Run \(steps.count) steps"])
            queue.insert(proposal, at: 0)
            return next(for: trigger, gateScore: gateScore, attempt: attempt)
        }
        let plan = Plan(steps: steps, appBundleId: bundleId)
        let commands = steps.map { "`\($0.command)`" }.joined(separator: " → ")
        if let blocked = plan.blockedCommand {
            record(.blocked, plan, trigger)
            return show(NotchMessage(text: "\(text)\nRun `\(blocked)` yourself if you are sure.", choices: [gotIt]))
        }
        record(.proposed, plan, trigger)
        show(NotchMessage(text: "\(text)\n\(commands)", choices: [
            NotchChoice(label: "Not now", isPrimary: false) { [weak self] in
                self?.record(.declined, plan, trigger)
                self?.next(for: trigger, gateScore: gateScore, attempt: attempt)
            },
            NotchChoice(label: steps.count == 1 ? "Run it" : "Run \(steps.count) steps", isPrimary: true) { [weak self] in
                self?.run(plan, for: trigger, gateScore: gateScore, attempt: attempt)
            },
        ]))
    }

    private func run(_ plan: Plan, for trigger: Trigger, gateScore: Double?, attempt: Int) {
        dismissal?.cancel()
        notch.act(steps: plan.steps.map(\.title))
        notch.highlight(actions.terminalFrame(of: plan))
        Task { @MainActor in
            let result = await actions.run(plan) { [weak self] index, ok in
                if ok { self?.notch.advance() } else { self?.notch.step(index, .failed) }
            }
            notch.highlight(nil)
            if result.succeeded {
                notch.done("Fixed")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.next(for: trigger, gateScore: gateScore, attempt: attempt) }
            } else if let failed = result.failedStep, attempt < Self.maxAttempts {
                var retry = Trigger(
                    at: Date(), kind: .stuckOnError, app: trigger.app, bundleId: trigger.bundleId, windowTitle: trigger.windowTitle,
                    idleSeconds: 0, errorLine: failed.errorLine, errorSeconds: trigger.errorSeconds, terminalTail: result.terminalTail,
                    command: trigger.command, exitCode: trigger.exitCode, cwd: trigger.cwd
                )
                retry.notice = trigger.notice
                queue = []
                try? await Task.sleep(nanoseconds: 900_000_000)
                ask(about: retry, gateScore: gateScore, attempt: attempt + 1)
            } else {
                show(NotchMessage(text: "Stopped: \(result.failure ?? result.failedStep?.errorLine ?? "a step failed").", choices: [
                    NotchChoice(label: "Got it", isPrimary: true) { [weak self] in self?.next(for: trigger, gateScore: gateScore, attempt: attempt) },
                ]))
            }
        }
    }

    private func perform(_ tool: BrainTool, _ proposal: Proposal, _ plan: Plan, for trigger: Trigger, gateScore: Double?, attempt: Int) {
        dismissal?.cancel()
        let started = Date()
        let titles = tool.stepTitles?(proposal.args) ?? []
        if tool.runSteps != nil, !titles.isEmpty { notch.act(steps: titles) } else { notch.think(proposal.button) }
        Task { @MainActor in
            let output: ToolOutput
            if let runSteps = tool.runSteps, !titles.isEmpty {
                output = await runSteps(proposal.args.withoutNotch) { [weak self] index, ok in
                    if ok { self?.notch.advance() } else { self?.notch.step(index, .failed) }
                }
            } else {
                output = await tool.run(proposal.args.withoutNotch)
            }
            let result = StepResult(command: plan.steps[0].command, ok: output.ok, errorLine: output.ok ? nil : output.text, seconds: Date().timeIntervalSince(started).rounded())
            record(output.ok ? .ran : .failed, plan, trigger, steps: [result])
            if output.ok {
                notch.done("Done")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.next(for: trigger, gateScore: gateScore, attempt: attempt) }
            } else {
                show(NotchMessage(text: "Failed: \(output.text.prefix(120))", choices: [
                    NotchChoice(label: "Got it", isPrimary: true) { [weak self] in self?.next(for: trigger, gateScore: gateScore, attempt: attempt) },
                ]))
            }
        }
    }

    private func show(_ message: NotchMessage) {
        notch.show(message)
        dismissal?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finish() }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dismissAfter, execute: work)
    }

    private func finish() {
        dismissal?.cancel()
        queue = []
        confirmed = false
        busy = false
        notch.rest()
    }
}
