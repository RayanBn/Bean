import AppKit

struct Recipe: Codable, Identifiable {
    enum Kind: String, Codable { case act, read }
    enum State: String, Codable { case candidate, confirmed, trusted }
    enum Source: String, Codable { case demonstrated, discovered }

    var id = UUID().uuidString
    var kind: Kind
    var bundleId: String?
    var goal: String
    var purpose: String?
    var whenToUse: String?
    var params: [String: String] = [:]
    var steps: [Step] = []
    var command: String?
    var interpreter: String?
    var watch: [String]?
    var check: Check?
    var state: State = .candidate
    var source: Source
    var successes = 0
    var failures = 0
    var notes: [String] = []
    var updatedAt = Date()

    var line: String {
        var line = "[\(id.prefix(8))] \(kind.rawValue) \(state.rawValue): \(goal)"
        if !params.isEmpty { line += " params: " + params.map { "\($0.key) (e.g. \($0.value))" }.sorted().joined(separator: ", ") }
        if let command { line += "\n    command: \(command.prefix(300))" }
        if !steps.isEmpty { line += "\n    steps: " + steps.map(\.intent).joined(separator: " → ") }
        if let note = notes.last { line += "\n    last note: \(note)" }
        return line
    }
}

final class RecipeBook {
    static let shared = RecipeBook()

    private let file = JSONLog.directory.appendingPathComponent("recipes.json")
    private(set) var all: [Recipe] = []
    var onChange: (() -> Void)?

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        all = (try? Data(contentsOf: file)).flatMap { try? decoder.decode([Recipe].self, from: $0) } ?? []
    }

    func recipes(bundleId: String? = nil, kind: Recipe.Kind? = nil) -> [Recipe] {
        all.filter { (bundleId == nil || $0.bundleId == bundleId) && (kind == nil || $0.kind == kind) }
    }

    func recipe(_ id: String) -> Recipe? {
        all.first { $0.id == id || $0.id.hasPrefix(id) }
    }

    func save(_ recipe: Recipe) {
        var recipe = recipe
        recipe.updatedAt = Date()
        if let index = all.firstIndex(where: { $0.id == recipe.id }) { all[index] = recipe } else { all.append(recipe) }
        write()
    }

    func record(_ id: String, ok: Bool, note: String? = nil) {
        guard var recipe = recipe(id) else { return }
        if ok {
            recipe.successes += 1
            if recipe.state == .candidate { recipe.state = .confirmed }
            if recipe.successes >= 2 { recipe.state = .trusted }
        } else {
            recipe.failures += 1
            recipe.state = .candidate
        }
        if let note { recipe.notes = Array((recipe.notes + [note]).suffix(5)) }
        save(recipe)
    }

    func delete(_ id: String) {
        all.removeAll { $0.id == id }
        write()
    }

    private func write() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(all).write(to: file, options: .atomic)
        onChange?()
    }
}

enum Recipes {
    struct Replay {
        let ok: Bool
        let outcomes: [StepOutcome]
        let note: String
    }

    @MainActor
    static func replay(_ recipe: Recipe, params: [String: String] = [:], mode: Channels.Mode = .takeover, verify: (() async -> Bool)? = nil, onStep: @escaping (Int, Bool) -> Void = { _, _ in }) async -> Replay {
        if recipe.kind == .read {
            let command = fill(recipe.command ?? "", params), interpreter = recipe.interpreter
            let result = await Task.detached { Sandbox.read(command, interpreter: interpreter) }.value
            let ok = result.exit == 0 && !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            RecipeBook.shared.record(recipe.id, ok: ok, note: ok ? nil : "exit \(result.exit): \(result.output.prefix(200))")
            return Replay(ok: ok, outcomes: [], note: result.output)
        }
        var outcomes: [StepOutcome] = []
        for (index, step) in recipe.steps.enumerated() {
            var step = step.filled(params)
            if verify != nil { step.post = nil }
            let outcome = await Channels.shared.perform(step, mode: mode)
            outcomes.append(outcome)
            onStep(index, outcome.ok)
            if !outcome.ok {
                let note = "step \(index + 1) \"\(step.intent)\" failed: \(outcome.note)"
                RecipeBook.shared.record(recipe.id, ok: false, note: note)
                return Replay(ok: false, outcomes: outcomes, note: note)
            }
        }
        if let verify, !(await verify()) {
            RecipeBook.shared.record(recipe.id, ok: false, note: "the caller's check failed after the steps")
            return Replay(ok: false, outcomes: outcomes, note: "the steps ran but the expected result is not there")
        }
        if let check = recipe.check, !(await Channels.shared.poll(check, seconds: 8)) {
            RecipeBook.shared.record(recipe.id, ok: false, note: "end check failed")
            return Replay(ok: false, outcomes: outcomes, note: "the steps ran but the end check failed")
        }
        var learned = recipe
        for (index, outcome) in outcomes.enumerated() where learned.steps[index].post == nil && verify == nil {
            learned.steps[index].post = outcome.learnedPost
        }
        RecipeBook.shared.save(learned)
        RecipeBook.shared.record(recipe.id, ok: true)
        return Replay(ok: true, outcomes: outcomes, note: outcomes.map { "\($0.intent): \($0.channel ?? "")" }.joined(separator: ", "))
    }

    static func fill(_ text: String, _ params: [String: String]) -> String {
        params.reduce(text) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }
}
