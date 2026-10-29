import AppKit

enum RecipeLearner {
    static var client: ModelClient?
    static let maxAttempts = 2
    private static let log = JSONLog(name: "learning")

    struct Record: Codable {
        let at: Date
        let goal: String
        let bundleId: String
        let kind: Recipe.Kind
        let attempt: Int
        let saved: String?
        let failure: String?
        let rounds: Int
        let calls: [String]
        let promptTokens: Int
        let seconds: Int
    }

    static let system = """
    You are the part of Bean, a butler on the user's Mac, that learns how to do one thing in one app, so Bean can do it again later without you. You get a goal and an app. Nothing about this app is known in advance: find out.
    Read first, with read_files (a sandboxed read-only shell), read_app (read-only AppleScript in that app), app_facts, read_ui, app_dictionary and look_at_screen. Apps keep their state in files under ~/Library (Application Support, Containers, Group Containers, Preferences, Caches), in dot folders of the home directory, and in what their windows show. Prefer the most direct, stable source, and prefer the app's own channels (its URL schemes, its documents, its scripting dictionary, its command-line tool inside the bundle) over clicks.
    Call several read tools at once when they do not depend on each other. Try as soon as you have a candidate: trying is cheap, and its effect teaches more than more reading.
    When you are sure, call save_recipe. Generic values that change from one use to the next are parameters: write them {name} in the recipe and give an example. Call give_up if the goal is not reachable.
    """

    @MainActor
    static func learn(goal: String, kind: Recipe.Kind, bundleId: String, hint: String? = nil, params: [String: String] = [:], source: Recipe.Source = .discovered, verify: (() async -> Bool)? = nil) async -> (Recipe?, String) {
        guard let client else { return (nil, "no model") }
        let lessonKey = "\(bundleId) \(goal)"
        var notes: [String] = lessons[lessonKey] ?? []
        for attempt in 1...maxAttempts {
            let started = Date()
            let session = Session(kind: kind, bundleId: bundleId, verify: verify)
            var text = "Goal: \(goal)\nApp: \(bundleId)\n\(appFacts(bundleId))"
            if let hint { text += "\nHint: \(hint)" }
            if !params.isEmpty { text += "\nParameters for this use: " + params.map { "\($0.key) = \($0.value)" }.joined(separator: ", ") }
            if !notes.isEmpty { text += "\nEarlier attempts failed:\n- " + notes.joined(separator: "\n- ") }
            if kind == .read {
                text += "\nThe recipe is a read-only program, run in the same sandbox as read_files: a zsh command, or a multi-line python3 script (standard library only) for anything that needs parsing. Run it with test_recipe until its output is right, then save exactly that. Bean runs it again whenever the files it reads change: list those paths as watch."
            } else {
                text += "\nThe recipe is a list of steps. Try them with try_steps first: it runs them for real in this app only and tells you the effect. Save exactly the steps that worked, with {name} where the parameters go."
            }
            let rounds = 24
            let late = (from: rounds * 2 / 3, tools: Set(kind == .read ? ["test_recipe"] : ["try_steps"]))
            let result = await AgentLoop(client: client, maxRounds: rounds).run(system: system, text: text, tools: session.tools, finals: session.finals, late: late)
            var recipe: Recipe?
            var failure = result.failure
            if result.final == "save_recipe" {
                switch await session.verify(result.args, goal: goal, params: params, source: source) {
                case let .success(saved): recipe = saved
                case let .failure(why): failure = why
                }
            } else if result.final == "give_up" {
                failure = "gave up: \(result.args.string("reason") ?? "")"
            }
            log.append(Record(at: started, goal: goal, bundleId: bundleId, kind: kind, attempt: attempt, saved: recipe?.id, failure: failure,
                              rounds: result.rounds, calls: result.calls, promptTokens: result.promptTokens, seconds: Int(Date().timeIntervalSince(started))))
            if let recipe {
                lessons[lessonKey] = nil
                RecipeBook.shared.save(recipe)
                return (recipe, "learned in \(result.rounds) rounds")
            }
            let found = await findings(of: result, client: client)
            notes.append((failure ?? "no recipe") + (found.map { ". What it had found: \($0)" } ?? ""))
            lessons[lessonKey] = Array(notes.suffix(6))
            if result.final == "give_up" { break }
        }
        return (nil, notes.joined(separator: "; "))
    }

    private static let lessonsFile = JSONLog.directory.appendingPathComponent("lessons.json")
    private static var lessons: [String: [String]] = (try? Data(contentsOf: lessonsFile)).flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:] {
        didSet { try? JSONEncoder().encode(lessons).write(to: lessonsFile, options: .atomic) }
    }

    private static func findings(of result: AgentLoop.Result, client: ModelClient) async -> String? {
        guard !result.messages.isEmpty else { return nil }
        let schema: [String: Any] = ["type": "object", "properties": ["findings": ["type": "string"]], "required": ["findings"], "additionalProperties": false]
        let ask = result.messages + [["role": "user", "content": "This attempt ends here. In at most 3 sentences, write what you found that the next attempt should start from: exact paths, routes, ids, commands, and what you tried with what effect."]]
        guard let reply = try? await client.json(messages: ask, schema: schema, effort: "low"), let text = reply.text,
              let answer = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        return (answer["findings"] as? String).map { String($0.prefix(600)) }
    }

    static func appFacts(_ bundleId: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId), let bundle = Bundle(url: url) else { return "The app is not installed." }
        var lines = ["Bundle: \(url.path)", "Name: \(FileManager.default.displayName(atPath: url.path))"]
        let schemes = (bundle.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] ?? []).flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        if !schemes.isEmpty { lines.append("URL schemes it declares: " + schemes.joined(separator: ", ")) }
        let documents = (bundle.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]] ?? []).compactMap { $0["CFBundleTypeName"] as? String }
        if !documents.isEmpty { lines.append("Document types: " + documents.prefix(12).joined(separator: ", ")) }
        if bundle.infoDictionary?["NSAppleScriptEnabled"] as? Bool == true || bundle.infoDictionary?["OSAScriptingDefinition"] != nil { lines.append("Scriptable: yes (see app_dictionary)") }
        let tools = executables(in: url)
        if !tools.isEmpty { lines.append("Executables inside the bundle: " + tools.prefix(12).joined(separator: ", ")) }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            let titles = AXTree.windows(of: app.processIdentifier).compactMap { Accessibility.attribute(kAXTitleAttribute, of: $0) as? String }
            lines.append("Running, windows: " + (titles.isEmpty ? "none on this Space" : titles.map { "\"\($0)\"" }.joined(separator: ", ")))
        } else {
            lines.append("Not running.")
        }
        return lines.joined(separator: "\n")
    }

    static func executables(in app: URL) -> [String] {
        let enumerator = FileManager.default.enumerator(at: app.appendingPathComponent("Contents"), includingPropertiesForKeys: [.isExecutableKey, .isRegularFileKey], options: [.skipsPackageDescendants])
        var found: [String] = []
        while let file = enumerator?.nextObject() as? URL, found.count < 40 {
            let path = file.path
            guard path.contains("/bin/") || path.hasSuffix("/MacOS/" + file.lastPathComponent),
                  let values = try? file.resourceValues(forKeys: [.isExecutableKey, .isRegularFileKey]), values.isExecutable == true, values.isRegularFile == true else { continue }
            found.append(path)
        }
        return found
    }

    @MainActor
    final class Session {
        let kind: Recipe.Kind
        let bundleId: String
        private var lastWorking: [Step]?
        private let verify: (() async -> Bool)?

        init(kind: Recipe.Kind, bundleId: String, verify: (() async -> Bool)? = nil) {
            self.kind = kind
            self.bundleId = bundleId
            self.verify = verify
        }

        var tools: [BrainTool] {
            var tools = Sandbox.readTools + ActionTools.all.filter { $0.name == "read_ui" || $0.name == "app_dictionary" } + CoreTools.all.filter { $0.name == "look_at_screen" }
            let bundleId = bundleId
            tools.append(BrainTool(name: "app_facts", description: "What Bean knows about an app: bundle path, URL schemes, document types, executables, windows.", parameters: ["bundleId": ["type": "string"]], effect: .read) { args in
                ToolOutput(text: await MainActor.run { RecipeLearner.appFacts(args.string("bundleId") ?? bundleId) })
            })
            if kind == .read {
                tools.append(BrainTool(name: "test_recipe", description: "Run a candidate read program exactly as Bean will run it, in the sandbox, and see its output.", parameters: [
                    "interpreter": ["type": "string", "enum": ["zsh", "python3"]], "program": ["type": "string"],
                ], effect: .read) { args in
                    let program = args.string("program") ?? "", interpreter = args.string("interpreter")
                    let result = await Task.detached { Sandbox.read(program, interpreter: interpreter) }.value
                    return ToolOutput(text: "exit \(result.exit)\(result.timedOut ? " (timed out)" : "")\n\(result.output)", ok: result.exit == 0)
                })
            }
            if kind == .act {
                tools.append(BrainTool(name: "try_steps", description: "Run steps for real, only in this app and through its own channels: open a URL with a scheme the app declares, a document or the app itself; AppleScript told to this app; an executable inside its bundle; or UI steps in its windows. Returns what each step changed.", parameters: [
                    "steps": ["type": "array", "minItems": 1, "maxItems": 10, "items": Step.schema],
                ], effect: .read) { [weak self] args in
                    guard let self else { return ToolOutput(text: "learning ended", ok: false) }
                    return await self.tryStepsNow(ActionTools.steps(args))
                })
            }
            return tools
        }

        var finals: [BrainTool] {
            var parameters: [String: Any] = [
                "whenToUse": ["type": "string", "description": "One sentence: when this recipe applies."],
                "params": ["type": "object", "description": "Parameter name → example value.", "additionalProperties": ["type": "string"]],
            ]
            if kind == .read {
                parameters["interpreter"] = ["type": "string", "enum": ["zsh", "python3"]]
                parameters["program"] = ["type": "string", "description": "The program that test_recipe ran."]
                parameters["watch"] = ["type": "array", "items": ["type": "string"], "description": "Files or folders the command reads."]
            } else {
                parameters["steps"] = ["type": "array", "items": Step.schema]
                parameters["check"] = Check.schema
            }
            return [
                BrainTool(name: "save_recipe", description: "Save the recipe once it is proven.", parameters: parameters, required: kind == .read ? ["interpreter", "program", "watch"] : ["steps"], effect: .read) { _ in ToolOutput(text: "") },
                BrainTool(name: "give_up", description: "The goal cannot be reached in this app.", parameters: ["reason": ["type": "string"]], effect: .read) { _ in ToolOutput(text: "") },
            ]
        }

        func tryStepsNow(_ steps: [Step]) async -> ToolOutput {
            guard !steps.isEmpty else { return ToolOutput(text: "no valid steps: check the JSON", ok: false) }
            if let refused = steps.lazy.compactMap({ self.refusal($0) }).first { return ToolOutput(text: "refused: \(refused)", ok: false) }
            var output = await ActionTools.run(steps, mode: .takeover) { _, _ in }
            if output.ok, let verify {
                let passed = await verify()
                output.ok = passed
                output.text += passed ? "\nBean's check of the goal: passed." : "\nBean's check of the goal: FAILED, the expected result is not there. Do not trust the screenshot over this."
            }
            if output.ok { lastWorking = steps }
            return output
        }

        private func refusal(_ step: Step) -> String? {
            if step.runsCode { return "scripts that run code (do script, do shell script, do JavaScript, execute) are never tried while learning: use the app's own verbs" }
            if step.irreversible == true { return "irreversible steps are never tried while learning" }
            switch step.kind {
            case .open:
                if let url = step.url, let scheme = URL(string: url)?.scheme?.lowercased() {
                    let declared = (Bundle(url: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) ?? URL(fileURLWithPath: "/"))?
                        .infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] ?? []).flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }.map { $0.lowercased() }
                    let webForApp = ["http", "https", "file"].contains(scheme) && step.bundleId == bundleId
                    return declared.contains(scheme) || webForApp ? nil : "\(scheme): is not a scheme this app declares"
                }
                return step.bundleId == bundleId || step.bundleId == nil ? nil : "open only this app or its documents"
            case .script:
                return step.bundleId == bundleId && !(step.text ?? "").lowercased().contains("tell application") ? nil : "scripts tell only this app, without a nested tell"
            case .shell:
                guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)?.path, let command = step.text else { return "no command" }
                let first = command.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                return first.hasPrefix(app + "/") && !command.contains(";") && !command.contains("&&") && !command.contains("|") ? nil : "shell steps run only one executable inside the app bundle"
            case .terminal, .keys:
                return step.kind == .terminal ? "no terminal while learning" : (step.bundleId == bundleId ? nil : "keys go only to this app")
            case .each:
                if let target = step.target?.bundleId ?? step.bundleId, target != bundleId { return "only this app's windows" }
                return (step.steps ?? []).lazy.compactMap { self.refusal($0) }.first
            case .press, .setValue, .typeText, .window, .menu, .wait:
                let target = step.target?.bundleId ?? step.bundleId
                return target == nil || target == bundleId ? nil : "only this app's windows"
            }
        }

        enum Verification { case success(Recipe), failure(String) }

        nonisolated static func templatize(_ steps: [Step], _ params: [String: String]) -> [Step] {
            guard let data = try? JSONEncoder().encode(steps), var json = String(data: data, encoding: .utf8) else { return steps }
            for (name, value) in params.sorted(by: { $0.value.count > $1.value.count }) where value.count >= 3 {
                let forms = [value, value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value]
                for form in Set(forms) {
                    let escaped = String(data: (try? JSONEncoder().encode(form)) ?? Data(), encoding: .utf8)?.dropFirst().dropLast() ?? ""
                    json = json.replacingOccurrences(of: String(escaped), with: "{\(name)}")
                }
            }
            return (try? JSONDecoder().decode([Step].self, from: Data(json.utf8))) ?? steps
        }

        func verify(_ args: JSONArgs, goal: String, params: [String: String], source: Recipe.Source) async -> Verification {
            let examples = (args["params"] as? [String: String]) ?? params
            var recipe = Recipe(kind: kind, bundleId: bundleId, goal: goal, whenToUse: args.string("whenToUse"), params: examples, source: source)
            if kind == .read {
                guard let command = args.string("program") else { return .failure("save_recipe without a program") }
                let filled = Recipes.fill(command, examples), interpreter = args.string("interpreter")
                let result = await Task.detached { Sandbox.read(filled, interpreter: interpreter) }.value
                guard result.exit == 0, !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .failure("the saved command failed when Bean ran it: exit \(result.exit) \(result.output.prefix(300))")
                }
                if goal == Watches.goal, Watches.parse(result.output, bundleId: bundleId, app: bundleId)?.isEmpty != false {
                    return .failure("the output is not JSON lines with id and title: \(result.output.prefix(200))")
                }
                recipe.command = command
                recipe.interpreter = interpreter
                if goal == Watches.goal { recipe.purpose = Watches.purpose }
                recipe.watch = (args["watch"] as? [String])?.map { ($0 as NSString).expandingTildeInPath }
                recipe.state = .confirmed
                recipe.notes = ["verified output: \(result.output.prefix(300))"]
                return .success(recipe)
            }
            guard let worked = lastWorking else { return .failure("nothing worked in try_steps yet: try before saving") }
            let steps = ActionTools.steps(args)
            let matches = !steps.isEmpty && steps.map({ $0.filled(examples) }).map(\.kind) == worked.map(\.kind)
                && zip(steps.map { $0.filled(examples) }, worked).allSatisfy({ $0.text == $1.text && $0.url == $1.url && $0.path == $1.path && $0.target == $1.target })
            recipe.params = examples.merging(params) { model, _ in model }
            recipe.steps = matches ? steps : Self.templatize(worked, recipe.params)
            if let check = args["check"], let data = try? JSONSerialization.data(withJSONObject: check) { recipe.check = try? JSONDecoder().decode(Check.self, from: data) }
            recipe.state = .confirmed
            recipe.successes = 1
            return .success(recipe)
        }
    }
}
