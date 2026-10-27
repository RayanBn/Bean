import AppKit

struct Activity: Codable, Equatable {
    let bundleId: String
    let app: String
    let id: String
    let title: String
    let state: String
    let needsUser: Bool
    let detail: String?
    var changedAt: Date
    var seen: Bool

    var unseen: Bool { !seen }

    var line: String {
        var line = "\"\(title)\" (\(app)): \(state), changed \(Activity.ago(changedAt))"
        if needsUser { line += ", waits for the user" }
        line += unseen ? ", not seen by the user since it changed" : ", seen"
        if let detail, !detail.isEmpty { line += "\n    \(detail.prefix(400))" }
        return line
    }

    static func ago(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        switch seconds {
        case ..<90: return "\(Int(seconds)) s ago"
        case ..<5400: return "\(Int(seconds / 60)) min ago"
        case ..<172_800: return "\(Int(seconds / 3600)) h ago"
        default: return "\(Int(seconds / 86400)) days ago"
        }
    }
}

final class Watches {
    static let goal = """
    Tell what this app is working on for the user right now. Print JSON lines, one per item the app works on (a document, a session, a task, a conversation, a job), most recent first, at most 20, only items active in the last 24 hours: {"id": stable id, "title": its name as the user sees it, "state": "working" | "waiting" | "done" | "idle", "needsUser": true when the item waits for the user's answer, decision or review, "detail": its question or last words, at most 300 characters}.
    """
    static let purpose = "activity"
    static let learnAfter = ProcessInfo.processInfo.environment["BEAN_WATCH_LEARN_MINUTES"].flatMap(Double.init).map { $0 * 60 } ?? 600
    static let learningsPerDay = 4

    var onChange: (([Activity]) -> Void)?

    private let log: JSONLog
    private var items: [String: [Activity]] = [:]
    private var streams: [String: FileEvents] = [:]
    private var pending: [String: DispatchWorkItem] = [:]
    private var usedSeconds: [String: TimeInterval] = [:]
    private var frontSince: (bundleId: String, at: Date)?
    private var attempted: [String: Date]
    private var learning = false
    private let attemptsFile = JSONLog.directory.appendingPathComponent("watch-attempts.json")

    init(log: JSONLog) {
        self.log = log
        attempted = (try? Data(contentsOf: attemptsFile)).flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
    }

    var all: [Activity] { items.values.flatMap { $0 }.sorted { $0.changedAt > $1.changedAt } }

    func start() {
        rewatch()
        RecipeBook.shared.onChange = { [weak self] in DispatchQueue.main.async { self?.rewatch() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, let bundleId = app.bundleIdentifier else { return }
            self?.activated(bundleId)
        }
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier { frontSince = (front, Date()) }
    }

    private var recipes: [Recipe] {
        RecipeBook.shared.recipes(kind: .read).filter { $0.purpose == Self.purpose && $0.bundleId != nil && $0.failures < 5 }
    }

    private func rewatch() {
        let current = recipes
        for bundleId in streams.keys where !current.contains(where: { $0.bundleId == bundleId }) { streams[bundleId] = nil }
        for recipe in current {
            guard let bundleId = recipe.bundleId, streams[bundleId] == nil else { continue }
            let paths = (recipe.watch ?? []).map { ($0 as NSString).expandingTildeInPath }.filter { FileManager.default.fileExists(atPath: $0) }
            guard !paths.isEmpty else { continue }
            streams[bundleId] = FileEvents(paths: paths, latency: 2) { [weak self] _ in self?.schedule(recipe.id) }
            schedule(recipe.id)
        }
    }

    private func schedule(_ recipeId: String) {
        pending[recipeId]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh(recipeId) }
        pending[recipeId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func refresh(_ recipeId: String) {
        guard let recipe = RecipeBook.shared.recipe(recipeId), let bundleId = recipe.bundleId, let command = recipe.command else { return }
        let interpreter = recipe.interpreter
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleId
        DispatchQueue.global(qos: .utility).async {
            let result = Sandbox.read(command, interpreter: interpreter)
            let parsed = Self.parse(result.output, bundleId: bundleId, app: app)
            DispatchQueue.main.async {
                guard result.exit == 0, parsed != nil else {
                    RecipeBook.shared.record(recipeId, ok: false, note: "watch read failed: exit \(result.exit) \(result.output.prefix(200))")
                    return
                }
                self.update(bundleId, parsed ?? [])
            }
        }
    }

    static func parse(_ output: String, bundleId: String, app: String) -> [Activity]? {
        struct Line: Decodable { let id: String?; let title: String?; let state: String?; let needsUser: Bool?; let detail: String? }
        let lines = output.split(separator: "\n").compactMap { try? JSONDecoder().decode(Line.self, from: Data($0.utf8)) }
        guard !lines.isEmpty || output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return lines.prefix(20).compactMap { line in
            guard let id = line.id ?? line.title else { return nil }
            return Activity(bundleId: bundleId, app: app, id: id, title: line.title ?? id, state: line.state ?? "idle", needsUser: line.needsUser ?? false,
                            detail: line.detail, changedAt: Date(), seen: true)
        }
    }

    private func update(_ bundleId: String, _ fresh: [Activity]) {
        let before = Dictionary((items[bundleId] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let isFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId
        let first = items[bundleId] == nil
        var changed = false
        let merged: [Activity] = fresh.map { item in
            guard let old = before[item.id] else {
                changed = true
                var item = item
                item.seen = first || isFront
                return item
            }
            guard old.state != item.state || old.needsUser != item.needsUser || old.detail != item.detail else { return old }
            changed = true
            var item = item
            item.seen = isFront || (old.state == item.state && old.needsUser == item.needsUser && old.seen)
            return item
        }
        items[bundleId] = merged
        guard changed else { return }
        for item in merged where item.unseen && before[item.id]?.unseen != true { log.append(item) }
        onChange?(all)
    }

    private func activated(_ bundleId: String) {
        if let (previous, since) = frontSince { usedSeconds[previous, default: 0] += Date().timeIntervalSince(since) }
        frontSince = (bundleId, Date())
        if var list = items[bundleId], list.contains(where: \.unseen) {
            for index in list.indices { list[index].seen = true }
            items[bundleId] = list
            onChange?(all)
        }
        learnIfUseful()
    }

    private func learnIfUseful() {
        let today = attempted.values.filter { Date().timeIntervalSince($0) < 86400 }.count
        guard !learning, today < Self.learningsPerDay, RecipeLearner.client?.isReady == true else { return }
        let known = Set(RecipeBook.shared.recipes(kind: .read).filter { $0.purpose == Self.purpose }.compactMap(\.bundleId))
        guard let (bundleId, _) = usedSeconds.filter({ $0.value >= Self.learnAfter && !known.contains($0.key) && attempted[$0.key].map { Date().timeIntervalSince($0) > 7 * 86400 } ?? true && $0.key != Bundle.main.bundleIdentifier })
            .max(by: { $0.value < $1.value }) else { return }
        learning = true
        attempted[bundleId] = Date()
        try? JSONEncoder().encode(attempted).write(to: attemptsFile, options: .atomic)
        Task { @MainActor in
            _ = await RecipeLearner.learn(goal: Self.goal, kind: .read, bundleId: bundleId)
            self.learning = false
        }
    }
}
