import AppKit

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
    var investigation: [ShellResult]? = nil
    var rounds: Int? = nil
    let latencyMs: Int
    let model: String
    let promptTokens: Int?
    let completionTokens: Int?
    let failure: String?
}

final class Brain {
    static let system = """
    You are Bean, a discreet butler that lives in the notch of the user's Mac. Something happened that may deserve the user's attention. You get the event, then everything Bean knows about the Mac right now: open apps and windows with their text, browser tabs, the user's AI coding agent sessions and their state, recent terminal commands, recently changed files and local servers.

    Investigate only what you need, usually zero to three commands. For an agent session, its question and last words are already given, and its transcript path is listed if you need more. run_shell runs a command in a hidden terminal on the user's Mac (git, gh, ls, cat, grep, sqlite3, curl to read, osascript to read app state...). Check facts instead of guessing: open the PR, read the CI run, read the file. Investigate before you answer when a fact is missing. look_at_screen gives you a screenshot when the text is not enough. While investigating, never change what is on screen and never touch anything outside the Mac: pushes, merges, comments, messages and deletions are refused there. Offer them to the user instead.

    Finish by calling exactly one of:
    - offer_action: one click that Bean runs for the user in the hidden terminal, like opening the agent session or the PR, rerunning the CI, merging a green PR, or opening a file at the right line. Use open, gh, git or osascript.
    - propose_plan: shell commands typed visibly in the terminal the user is using, to fix an error there.
    - show_message: the user should know something, and there is nothing to run.
    - stay_quiet: it is not clearly worth interrupting. The user already knows, it can wait, or you are not sure.

    How to talk: the user wants the conclusion, not the analysis. Write one sentence of at most 140 characters that says what is true and what to do, like "SP-964: CI green, PR #1573 ready to merge." or "Two agents are waiting for you: waitlist asks which design." Add the how in two or three words only when needed. Name the concrete thing: the agent session by its title, the PR, the file or the command. Never just repeat what an agent said: add what you checked or what to do. No greetings, no hedging, no generic advice. Write in the language of the user's own texts on screen.
    Before offering to merge a PR, check it is not a draft and its checks pass. A draft needs "gh pr ready" first.
    Button labels: one to three words, like "Open session", "Merge PR" or "Rerun CI".
    Step titles: two to four words, like "Install requests" or "Rerun the build".
    Never propose sudo, rm -rf, force pushes, or anything that deletes data or touches the system.
    """
    static let finalTools: [[String: Any]] = [
        tool("offer_action", "Offer one action that Bean runs in a hidden terminal when the user clicks the button.", [
            "message": ["type": "string", "description": "The conclusion for the notch. At most 140 characters."],
            "button": ["type": "string", "description": "One to three words."],
            "command": ["type": "string", "description": "One single-line shell command."],
        ]),
        tool("propose_plan", "Propose shell commands to type in the user's terminal, in order, after they confirm.", [
            "message": ["type": "string", "description": "The cause and what the plan does, for the notch. At most 140 characters."],
            "steps": ["type": "array", "minItems": 1, "maxItems": 4, "items": [
                "type": "object",
                "properties": ["title": ["type": "string"], "command": ["type": "string", "description": "One single-line shell command."]],
                "required": ["title", "command"],
            ]],
        ]),
        tool("show_message", "Show a short message in the notch.", [
            "message": ["type": "string", "description": "At most 140 characters."],
        ]),
        tool("stay_quiet", "Do not interrupt the user.", [:]),
    ]
    static let tools: [[String: Any]] = [
        tool("run_shell", "Run a command in a hidden terminal on the user's Mac and get its output. Read-only investigation.", [
            "command": ["type": "string", "description": "One shell command for zsh."],
            "cwd": ["type": "string", "description": "Directory to run it in. Empty for the home folder."],
        ]),
        tool("look_at_screen", "Get a screenshot of the main display.", [:]),
    ] + finalTools
    static let dismissAfter: TimeInterval = 30
    static let maxAttempts = 2
    static let maxRounds = 5
    static let proactive: Set<Trigger.Kind> = [.agentWaiting, .backFromBreak]
    static let proactivePerHour = ProcessInfo.processInfo.environment["BEAN_PROACTIVE_PER_HOUR"].flatMap(Int.init) ?? 3

    private let client: ModelClient
    private let notch: NotchController
    private let actions: ActionRunner
    private let log: JSONLog
    private let context: () async -> MacContext?
    private var busy = false
    private var dismissal: DispatchWorkItem?
    private var proactiveShown: [Date] = []

    init(client: ModelClient, notch: NotchController, actions: ActionRunner, log: JSONLog, context: @escaping () async -> MacContext?) {
        self.client = client
        self.notch = notch
        self.actions = actions
        self.log = log
        self.context = context
    }

    func consider(_ decision: GateDecision, _ trigger: Trigger) {
        guard decision.stepIn else {
            if trigger.kind != .appChanged, decision.rule != "paused", !busy { notch.stayedQuiet() }
            return
        }
        guard !busy else { return }
        if Self.proactive.contains(trigger.kind) {
            proactiveShown = proactiveShown.filter { Date().timeIntervalSince($0) < 3600 }
            guard proactiveShown.count < Self.proactivePerHour else { return }
            busy = true
            ask(about: trigger, gateScore: decision.score, attempt: 1)
            return
        }
        busy = true
        notch.notice(Self.noticeWord(for: trigger))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.ask(about: trigger, gateScore: decision.score, attempt: 1)
        }
    }

    private func ask(about trigger: Trigger, gateScore: Double?, attempt: Int) {
        if !Self.proactive.contains(trigger.kind) { notch.think(attempt == 1 ? "Looking into it" : "Looking again") }
        Task.detached(priority: .userInitiated) {
            let context = await self.context()
            let answer = await self.think(about: trigger, context: context, gateScore: gateScore, attempt: attempt)
            await MainActor.run { self.present(answer, for: trigger, gateScore: gateScore) }
        }
    }

    private func think(about trigger: Trigger, context: MacContext?, gateScore: Double?, attempt: Int) async -> BrainAnswer {
        let started = Date()
        var failures: [String] = []
        var sawScreen = false
        var investigation: [ShellResult] = []

        let repo = ActiveFolder.guess(for: trigger).flatMap(RepoState.read)
        var text = [trigger.summary, repo?.summary].compactMap { $0 }.joined(separator: "\n")
        if let context { text += "\n\nWhat Bean knows about the Mac right now:\n" + context.summary() }
        var messages: [[String: Any]] = [["role": "system", "content": Self.system], ["role": "user", "content": text]]

        struct Arguments: Decodable { let message: String?; let steps: [PlanStep]?; let button: String?; let command: String?; let cwd: String? }
        var final: (name: String, arguments: Arguments?)?
        var promptTokens = 0, completionTokens = 0
        var rounds = 0
        while final == nil, rounds < Self.maxRounds {
            rounds += 1
            let reply: ModelClient.Reply
            do {
                reply = try await client.chat(messages, tools: rounds == Self.maxRounds ? Self.finalTools : Self.tools)
            } catch {
                failures.append("model: \(error.localizedDescription)")
                break
            }
            promptTokens += reply.promptTokens ?? 0
            completionTokens += reply.completionTokens ?? 0
            guard let call = reply.toolCall else {
                failures.append("model: no tool call")
                break
            }
            messages.append(reply.assistantMessage)
            let arguments = try? JSONDecoder().decode(Arguments.self, from: call.arguments)
            switch call.name {
            case "run_shell":
                let command = arguments?.command ?? ""
                let result = HiddenShell.requiresConsent(command)
                    ? ShellResult(command: command, exit: -1, output: "refused: this changes something outside the Mac or deletes data. Offer it to the user with offer_action.", timedOut: false, seconds: 0)
                    : HiddenShell.run(command, in: arguments?.cwd.flatMap { $0.isEmpty ? nil : $0 })
                investigation.append(result)
                messages.append(["role": "tool", "tool_call_id": call.id, "content": "exit \(result.exit)\(result.timedOut ? " (timed out)" : "")\n\(result.output)"])
            case "look_at_screen":
                do {
                    let jpeg = try await ScreenCapture.mainDisplayJPEG()
                    sawScreen = true
                    messages.append(["role": "tool", "tool_call_id": call.id, "content": "The screenshot is in the next message."])
                    messages.append(["role": "user", "content": [["type": "text", "text": "Screenshot of the main display:"], ModelClient.image(jpeg)]])
                } catch {
                    failures.append("capture: \(error.localizedDescription)")
                    messages.append(["role": "tool", "tool_call_id": call.id, "content": "No screenshot: \(error.localizedDescription)"])
                }
            default:
                final = (call.name, arguments)
            }
        }
        if final == nil, failures.isEmpty { failures.append("no answer after \(rounds) rounds") }

        var answer = BrainAnswer(
            at: started, trigger: trigger.kind, attempt: attempt, gateScore: gateScore, sawScreen: sawScreen, repo: repo?.summary,
            tool: final?.name, message: final?.arguments?.message.flatMap { $0.isEmpty ? nil : $0 }, steps: final?.arguments?.steps,
            latencyMs: Int(Date().timeIntervalSince(started) * 1000), model: client.label,
            promptTokens: promptTokens, completionTokens: completionTokens,
            failure: failures.isEmpty ? nil : failures.joined(separator: "; ")
        )
        answer.button = final?.arguments?.button
        answer.command = final?.arguments?.command
        answer.investigation = investigation
        answer.rounds = rounds
        log.append(answer)
        return answer
    }

    private func present(_ answer: BrainAnswer, for trigger: Trigger, gateScore: Double?) {
        guard answer.tool != "stay_quiet", let text = answer.message else {
            finish()
            if answer.tool == "stay_quiet" { notch.stayedQuiet() }
            return
        }
        if Self.proactive.contains(trigger.kind) { proactiveShown.append(Date()) }
        let gotIt = NotchChoice(label: "Got it", isPrimary: true) { [weak self] in self?.finish() }

        if answer.tool == "offer_action", let command = answer.command, !command.isEmpty {
            let plan = Plan(steps: [PlanStep(title: answer.button ?? "Do it", command: command)], appBundleId: "hidden")
            if plan.blockedCommand != nil {
                actions.record(.blocked, plan)
                show(NotchMessage(text: text, choices: [gotIt]))
                return
            }
            actions.record(.proposed, plan)
            show(NotchMessage(text: text, choices: [
                NotchChoice(label: "Not now", isPrimary: false) { [weak self] in
                    self?.actions.record(.declined, plan)
                    self?.finish()
                },
                NotchChoice(label: answer.button ?? "Do it", isPrimary: true) { [weak self] in self?.perform(plan) },
            ]))
            return
        }

        guard let steps = answer.steps, !steps.isEmpty, let bundleId = trigger.bundleId, TerminalText.terminals.contains(bundleId) else {
            show(NotchMessage(text: text, choices: [gotIt]))
            return
        }
        let plan = Plan(steps: steps, appBundleId: bundleId)
        let commands = steps.map { "`\($0.command)`" }.joined(separator: " → ")
        if let blocked = plan.blockedCommand {
            actions.record(.blocked, plan)
            show(NotchMessage(text: "\(text)\nRun `\(blocked)` yourself if you are sure.", choices: [gotIt]))
            return
        }
        actions.record(.proposed, plan)
        show(NotchMessage(text: "\(text)\n\(commands)", choices: [
            NotchChoice(label: "Not now", isPrimary: false) { [weak self] in
                self?.actions.record(.declined, plan)
                self?.finish()
            },
            NotchChoice(label: steps.count == 1 ? "Run it" : "Run \(steps.count) steps", isPrimary: true) { [weak self] in
                self?.run(plan, for: trigger, gateScore: gateScore, attempt: answer.attempt)
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.finish() }
            } else if let failed = result.failedStep, attempt < Self.maxAttempts {
                let retry = Trigger(
                    at: Date(), kind: .stuckOnError, app: trigger.app, bundleId: trigger.bundleId, windowTitle: trigger.windowTitle,
                    idleSeconds: 0, errorLine: failed.errorLine, errorSeconds: trigger.errorSeconds, terminalTail: result.terminalTail,
                    command: trigger.command, exitCode: trigger.exitCode, cwd: trigger.cwd
                )
                try? await Task.sleep(nanoseconds: 900_000_000)
                ask(about: retry, gateScore: gateScore, attempt: attempt + 1)
            } else {
                show(NotchMessage(text: "Stopped: \(result.failure ?? result.failedStep?.errorLine ?? "a step failed").", choices: [
                    NotchChoice(label: "Got it", isPrimary: true) { [weak self] in self?.finish() },
                ]))
            }
        }
    }

    private func perform(_ plan: Plan) {
        dismissal?.cancel()
        notch.think(plan.steps[0].title)
        let command = plan.steps[0].command
        Task.detached(priority: .userInitiated) {
            let result = HiddenShell.run(command, timeout: 60)
            await MainActor.run {
                let ok = result.exit == 0 && !result.timedOut
                self.actions.record(ok ? .ran : .failed, plan, steps: [StepResult(command: command, ok: ok, errorLine: ok ? nil : result.output.split(separator: "\n").last.map(String.init), seconds: result.seconds)])
                if ok {
                    self.notch.done("Done")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.finish() }
                } else {
                    self.show(NotchMessage(text: "Failed: \(result.output.split(separator: "\n").last.map(String.init) ?? "exit \(result.exit)")", choices: [
                        NotchChoice(label: "Got it", isPrimary: true) { [weak self] in self?.finish() },
                    ]))
                }
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
        busy = false
        notch.rest()
    }

    private static func noticeWord(for trigger: Trigger) -> String {
        switch trigger.kind {
        case .stuckOnError: return "Stuck?"
        case .terminalError: return "Error"
        case .idle: return "Still there?"
        case .appChanged: return "Hmm"
        case .commandFailed: return "Failed"
        case .repeatedFailure: return "Again?"
        case .searchingError: return "Found it?"
        case .agentWaiting: return "Waiting"
        case .backFromBreak: return "Welcome back"
        }
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any]) -> [String: Any] {
        ["type": "function", "function": [
            "name": name, "description": description,
            "parameters": ["type": "object", "properties": properties, "required": Array(properties.keys)],
        ]]
    }
}
