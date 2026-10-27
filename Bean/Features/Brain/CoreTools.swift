import Foundation

enum ScreenShare {
    private typealias Present = @convention(c) () -> Bool
    private static let present: Present? = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        .flatMap { dlsym($0, "SLSIsScreenWatcherPresent") }
        .map { unsafeBitCast($0, to: Present.self) }

    static var isActive: Bool { present?() ?? false }
}

final class CoreTools: ToolSource {
    func tools(for trigger: Trigger) async -> [BrainTool] { Self.all }

    static func named(_ name: String) -> BrainTool? { all.first { $0.name == name } }

    static let all: [BrainTool] = [
        BrainTool(name: "run_shell", description: "Run a command in a hidden terminal on the user's Mac and get its output. Read-only investigation: commands that change something outside the Mac or delete data are refused.", parameters: [
            "command": ["type": "string", "description": "One shell command for zsh."],
            "cwd": ["type": "string", "description": "Directory to run it in. Empty for the home folder."],
            "reason": ["type": "string", "description": "Which part of the event this checks, quoting it. Without a link to the event, do not run it."],
        ], effect: .read) { args in
            let command = args.string("command") ?? ""
            guard args.string("reason") != nil else { return ToolOutput(text: "refused: say which part of the event this checks, in reason.", ok: false) }
            if HiddenShell.requiresConsent(command) {
                return ToolOutput(text: "refused: this changes something outside the Mac or deletes data. Propose it to the user with run_command instead.", ok: false)
            }
            let result = await Task.detached { HiddenShell.run(command, in: args.string("cwd")) }.value
            return ToolOutput(text: "exit \(result.exit)\(result.timedOut ? " (timed out)" : "")\n\(result.output)", ok: result.exit == 0)
        },
        BrainTool(name: "look_at_screen", description: "Get a screenshot of the main display.", parameters: [:], effect: .read) { _ in
            if ScreenShare.isActive { return ToolOutput(text: "No screenshot: the screen is being shared or recorded, and its content never leaves the Mac then.", ok: false) }
            do {
                return ToolOutput(text: "The screenshot is in the next message.", image: try await ScreenCapture.mainDisplayJPEG())
            } catch {
                return ToolOutput(text: "No screenshot: \(error.localizedDescription)", ok: false)
            }
        },
        BrainTool(name: "run_command", description: "Propose one command that Bean runs in a hidden terminal when the user clicks the button: opening something, or a change the user should approve.", parameters: [
            "command": ["type": "string", "description": "One single-line shell command."],
            "cwd": ["type": "string", "description": "Directory to run it in. Empty for the home folder."],
        ], required: ["command"], effect: .act) { args in
            let command = args.string("command") ?? ""
            if let blocked = Plan(steps: [PlanStep(title: "", command: command)], appBundleId: "hidden").blockedCommand {
                return ToolOutput(text: "blocked: \(blocked)", ok: false)
            }
            let result = await Task.detached { HiddenShell.run(command, in: args.string("cwd"), timeout: 60) }.value
            let ok = result.exit == 0 && !result.timedOut
            return ToolOutput(text: ok ? result.output : (result.output.split(separator: "\n").last.map(String.init) ?? "exit \(result.exit)"), ok: ok)
        },
        BrainTool(name: "open_terminal", description: "Propose to start a long-running command in a new terminal window the user can watch, for example another AI agent installed on this Mac working on a task, or a server. Bean does not wait for it to finish.", parameters: [
            "command": ["type": "string", "description": "One single-line shell command."],
            "cwd": ["type": "string", "description": "Directory to run it in."],
        ], required: ["command"], effect: .act) { args in
            VisibleTerminal.start(args.string("command") ?? "", in: args.string("cwd"))
        },
    ]
}
