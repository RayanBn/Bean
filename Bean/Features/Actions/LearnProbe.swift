import Foundation

enum LearnProbe {
    static func runIfRequested() -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-learn"), index + 3 < CommandLine.arguments.count else { return false }
        let arguments = CommandLine.arguments
        let bundleId = arguments[index + 1], kind = Recipe.Kind(rawValue: arguments[index + 2]) ?? .read, goal = arguments[index + 3]
        let hint = index + 4 < arguments.count ? arguments[index + 4] : nil
        RecipeLearner.client = ModelClient()
        Task { @MainActor in
            let started = Date()
            let (recipe, note) = await RecipeLearner.learn(goal: goal == "watch" ? Watches.goal : goal, kind: kind, bundleId: bundleId, hint: hint)
            print("--- \(recipe == nil ? "FAILED" : "learned") in \(Int(Date().timeIntervalSince(started))) s: \(note)")
            guard let recipe else { exit(1) }
            print(recipe.line)
            if let watch = recipe.watch { print("watch: \(watch.joined(separator: ", "))") }
            if recipe.kind == .read {
                let replay = await Recipes.replay(recipe)
                print("--- replay \(replay.ok ? "ok" : "FAILED"):\n\(replay.note.prefix(3000))")
            }
            exit(0)
        }
        return true
    }
}
