import AppKit

final class ActionTools: ToolSource {
    func tools(for trigger: Trigger) async -> [BrainTool] { Self.all }

    static func steps(_ args: JSONArgs) -> [Step] {
        guard let list = args["steps"], let data = try? JSONSerialization.data(withJSONObject: list) else { return [] }
        return (try? JSONDecoder().decode([Step].self, from: data)) ?? []
    }

    @MainActor
    static func run(_ steps: [Step], mode: Channels.Mode, onStep: @escaping (Int, Bool) -> Void) async -> ToolOutput {
        var lines: [String] = []
        for (index, step) in steps.enumerated() {
            let outcome = await Channels.shared.perform(step, mode: mode)
            onStep(index, outcome.ok)
            lines.append("\(index + 1). \(step.intent): \(outcome.ok ? "ok" : "FAILED") via \(outcome.channel ?? "none"), \(outcome.note); effect: \(outcome.effect?.summary ?? "unknown")")
            if !outcome.ok { return ToolOutput(text: lines.joined(separator: "\n"), ok: false) }
        }
        return ToolOutput(text: lines.joined(separator: "\n"))
    }

    static let all: [BrainTool] = [
        BrainTool(name: "read_ui", description: "List the UI elements of an app's window that can be acted on (role, title, label, identifiers, URL, advertised actions), to build step targets. The frontmost app's focused window by default.", parameters: [
            "bundleId": ["type": "string"], "window": ["type": "string", "description": "Part of the window title."],
        ], required: [], effect: .read) { args in
            let locator = Locator(bundleId: args.string("bundleId"), window: args.string("window"))
            return ToolOutput(text: await MainActor.run { AXTree.describe(locator) })
        },
        BrainTool(name: "app_dictionary", description: "Read an app's AppleScript dictionary (commands and classes), to find the app's own channel for a script step.", parameters: [
            "bundleId": ["type": "string"],
        ], effect: .read) { args in
            let bundleId = args.string("bundleId") ?? ""
            return ToolOutput(text: await Task.detached { Scripting.dictionary(bundleId) }.value)
        },
        BrainTool(name: "do_steps", description: "Propose typed steps that Bean performs in the user's apps after the click, each through the most reliable channel the app exposes (its scripting, accessibility actions, focus and keys, a click, vision last) and each checked by its effect. Bean takes control visibly.", parameters: [
            "steps": ["type": "array", "minItems": 1, "maxItems": 12, "items": Step.schema],
        ], effect: .act, run: { args in
            await run(steps(args), mode: .takeover) { _, _ in }
        }, stepTitles: { args in steps(args).map(\.intent) }, runSteps: { args, onStep in
            await run(steps(args), mode: .takeover, onStep: onStep)
        }),
    ]
}
