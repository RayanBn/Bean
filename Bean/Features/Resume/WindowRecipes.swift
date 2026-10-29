import Foundation

/// What a window shows and how to reopen it, for any app, through the core's learned recipes: learned once per app, then replayed.
enum WindowRecipes {
    static let describeGoal = "Print one JSON object that identifies exactly what one window of this app shows: the window titled {title}, with window id {windowId}, of the app process {pid}. "
        + "String values only: ids, absolute paths, URLs; when a command runs in the window, also running_command and the cwd it runs in. Use the same keys for every window of this app."
    static let reopenGoal = "Reopen exactly the content one window of this app showed, from the handle that identifies it, without running any command in it"

    @MainActor
    static func describe(_ facts: WindowFacts) async -> WindowContent? {
        let params = ["title": facts.title, "pid": String(facts.pid), "windowId": String(facts.windowId)]
        if let recipe = recipe(describeGoal, .read, facts.bundleId), let handle = await read(recipe, params) {
            return WindowContent(description: "\(facts.appName): \(facts.title)", handle: handle)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let hint = "What Bean reads about any window of this app right now: " + String(decoding: (try? encoder.encode(facts)) ?? Data(), as: UTF8.self)
        guard let learned = await RecipeLearner.learn(goal: describeGoal, kind: .read, bundleId: facts.bundleId, hint: hint, params: params).0,
              let handle = await read(learned, params) else { return nil }
        return WindowContent(description: "\(facts.appName): \(facts.title)", handle: handle)
    }

    @MainActor
    static func reopen(_ saved: SavedWindow, verify: @escaping () async -> Bool) async -> Bool {
        var params = saved.content?.handle ?? [:]
        params["title"] = params["title"] ?? saved.facts.title
        params[Resumer.commandKey] = nil
        if let recipe = recipe(reopenGoal, .act, saved.facts.bundleId), await Recipes.replay(recipe, params: params, verify: verify).ok { return true }
        let hint = "The window showed: \(saved.content?.description ?? saved.facts.title). Its parameters are its handle. "
            + "Put the content back in the same place inside the app when the handle names one (its space, profile, folder, group or tab position). "
            + "When the app declares a URL scheme, its routes and their parameters are in its own code (an Electron app keeps it in Contents/Resources/app.asar; read it with strings or python3): "
            + "search it for the scheme followed by a path, and for code that reads a parameter shaped like one of the handle's ids. "
            + "Bean checks the result itself: the window \"\(saved.facts.title)\" (or, for a window that ran a command, a new window in its cwd) must be back. "
            + "Never run the command that ran there: Bean relaunches it itself once the user agreed."
        return await RecipeLearner.learn(goal: reopenGoal, kind: .act, bundleId: saved.facts.bundleId, hint: hint, params: params, verify: verify).0 != nil
    }

    private static func recipe(_ goal: String, _ kind: Recipe.Kind, _ bundleId: String) -> Recipe? {
        RecipeBook.shared.recipes(bundleId: bundleId, kind: kind).filter { $0.goal == goal }.max { ($0.successes - $0.failures) < ($1.successes - $1.failures) }
    }

    @MainActor
    private static func read(_ recipe: Recipe, _ params: [String: String]) async -> [String: String]? {
        let output = await Recipes.replay(recipe, params: params).note
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"),
              let object = try? JSONSerialization.jsonObject(with: Data(output[start ... end].utf8)) as? [String: Any] else { return nil }
        let handle = object.compactMapValues { ($0 as? String) ?? ($0 as? NSNumber)?.stringValue }.filter { !$0.value.isEmpty }
        return handle.isEmpty ? nil : handle
    }
}
