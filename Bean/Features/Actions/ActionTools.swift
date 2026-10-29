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

    static func installedBundle(_ bundleId: String) -> String? {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil { return bundleId }
        let words = bundleId.lowercased().split(separator: ".").map(String.init).filter { $0.count >= 3 && !["com", "app", "dev", "org"].contains($0) }
        let candidates = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap { app -> String? in
            let haystack = ((app.bundleIdentifier ?? "") + " " + (app.localizedName ?? "")).lowercased()
            return words.contains(where: haystack.contains) ? app.bundleIdentifier : nil
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    @MainActor
    static func achieve(_ args: JSONArgs, onStep: @escaping (Int, Bool) -> Void) async -> ToolOutput {
        let goal = args.string("goal") ?? ""
        let named = args.string("recipe").flatMap(RecipeBook.shared.recipe)
        guard let bundleId = named?.bundleId ?? args.string("bundleId").flatMap(installedBundle) else {
            return ToolOutput(text: "achieve needs the bundleId of an installed app; \(args.string("bundleId") ?? "none") is not one. Running apps: " + NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier).joined(separator: ", "), ok: false)
        }
        let params = args["params"] as? [String: String] ?? [:]
        let known = named
            ?? RecipeBook.shared.recipes(bundleId: bundleId, kind: .act).first { $0.goal.caseInsensitiveCompare(goal) == .orderedSame && $0.failures < 3 }
        if let known {
            let replay = await Recipes.replay(known, params: params, onStep: onStep)
            if replay.ok { return ToolOutput(text: "done with the saved recipe: \(replay.note)") }
            let (relearned, note) = await RecipeLearner.learn(goal: known.goal, kind: .act, bundleId: bundleId, hint: "The saved recipe failed: \(replay.note)", params: params)
            return relearned != nil ? ToolOutput(text: "the saved recipe failed, relearned and done: \(note)") : ToolOutput(text: "failed: \(replay.note); relearning failed: \(note)", ok: false)
        }
        let (learned, note) = await RecipeLearner.learn(goal: goal, kind: .act, bundleId: bundleId, hint: args.string("hint"), params: params)
        return learned != nil ? ToolOutput(text: "learned and done: \(note)") : ToolOutput(text: "could not learn it: \(note)", ok: false)
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
        BrainTool(name: "recall", description: "List the recipes Bean learned: how to do things in each app (act) and how to read an app's state (read), with their parameters and how reliable they are.", parameters: [
            "bundleId": ["type": "string", "description": "Empty for every app."],
        ], required: [], effect: .read) { args in
            let recipes = RecipeBook.shared.recipes(bundleId: args.string("bundleId"))
            return ToolOutput(text: recipes.isEmpty ? "No recipe yet for this app." : recipes.prefix(30).map { "\($0.bundleId ?? "any app"): \($0.line)" }.joined(separator: "\n"))
        },
        BrainTool(name: "achieve", description: "Propose to get something done in one app after the click: Bean replays its saved recipe for this goal, or learns one by trying the app's own channels, verifies it, and keeps it for next time. Use a short generic goal, like the ones recall lists, and put the specifics in params.", parameters: [
            "goal": ["type": "string", "description": "Generic, without the specific values: they go in params."],
            "bundleId": ["type": "string"],
            "params": ["type": "object", "additionalProperties": ["type": "string"]],
            "recipe": ["type": "string", "description": "The id of a recipe from recall, when one fits."],
            "hint": ["type": "string", "description": "What you already know about how to do it."],
        ], required: ["goal", "bundleId"], effect: .act, run: { args in
            await achieve(args) { _, _ in }
        }),
        BrainTool(name: "do_steps", description: "Propose typed steps that Bean performs in the user's apps after the click, each through the most reliable channel the app exposes (its scripting, accessibility actions, focus and keys, a click, vision last) and each checked by its effect. Bean takes control visibly.", parameters: [
            "steps": ["type": "array", "minItems": 1, "maxItems": 12, "items": Step.schema],
        ], effect: .act, run: { args in
            await run(steps(args), mode: .takeover) { _, _ in }
        }, stepTitles: { args in steps(args).map(\.intent) }, runSteps: { args, onStep in
            await run(steps(args), mode: .takeover, onStep: onStep)
        }),
    ]
}
