import AppKit

struct GateEntry: Encodable, Identifiable {
    let id = UUID()
    var at = Date()
    let event: String
    let app: String?
    let title: String?
    let decision: String
    let by: String
    var score: Double?
    var ms: Int?
    var detail: String?
    enum CodingKeys: String, CodingKey { case at, event, app, title, decision, by, score, ms, detail }
}

final class EventGate {
    static let log = JSONLog(name: "gate")
    private static let noise = try! NSRegularExpression(pattern: #"^\s*(loading|saving|saved|all changes saved|typing|.* is typing|.* is online|\d{1,2}:\d{2}( ?[ap]m)?|\d+ ?%|downloading.*|now playing.*|thanks!?|merci.*|ok)\W*$"#, options: .caseInsensitive)

    private weak var worker: AgentWorker?
    private var pending: [String: (event: SenseEvent, work: DispatchWorkItem)] = [:]
    private var waiting: [SenseEvent] = []
    private var scoring = false
    private var lastSeen: [String: (text: String, at: Date)] = [:]

    init(worker: AgentWorker) {
        self.worker = worker
    }

    func consider(_ event: SenseEvent) {
        pending[event.dedupeKey]?.work.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settled(event) }
        pending[event.dedupeKey] = (event, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + event.sense.settle, execute: work)
    }

    private func settled(_ event: SenseEvent) {
        pending[event.dedupeKey] = nil
        let text = "\(event.title ?? "")|\(event.detail ?? "")"
        if let window = event.sense.repeatWindow, let last = lastSeen[event.dedupeKey], last.text == text, Date().timeIntervalSince(last.at) < window {
            return record(entry(event, "repeat", by: "debounce"))
        }
        lastSeen[event.dedupeKey] = (text, Date())
        if worker?.isOwnChange(window: event.window) == true { return record(entry(event, "ownChange", by: "code")) }
        waiting.append(event)
        if waiting.count > 30 { waiting.removeFirst(waiting.count - 30) }
        scoreNext()
    }

    private func scoreNext() {
        guard !scoring, !waiting.isEmpty else { return }
        scoring = true
        let event = waiting.removeFirst()
        Task { @MainActor in
            await judge(event)
            scoring = false
            scoreNext()
        }
    }

    private func entry(_ event: SenseEvent, _ decision: String, by: String, score: Double? = nil, ms: Int? = nil, detail: String? = nil) -> GateEntry {
        GateEntry(at: Date(), event: event.type, app: event.app, title: event.title, decision: decision, by: by, score: score, ms: ms, detail: detail)
    }

    private func judge(_ event: SenseEvent) async {
        guard let worker else { return }
        if BeanSettings.shared.effectivePaused { return record(entry(event, "paused", by: "code")) }
        var context = worker.gateContext(window: event.window)
        if let watching = event.watching { context.goals = [context.goals, watching].compactMap { $0 }.joined(separator: "\n") }
        let started = Date()
        let judged = await Self.score(event, context: context)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let yes = judged.score > judged.quietAtOrBelow
        record(entry(event, yes ? "yes" : "quiet", by: judged.by, score: judged.score, ms: ms))
        guard yes else { return }
        let words = context.hasAgent && event.detail != nil ? "\(event.summary). New text: \(event.detail!.prefix(500))" : event.summary
        worker.wake(event.watching.map { "\(words). \($0)" } ?? words)
    }

    private struct Judged { let score: Double; let quietAtOrBelow: Double; let by: String }

    private static func score(_ event: SenseEvent, context: AgentWorker.GateContext) async -> Judged {
        let state = StrandsDecider.state(mission: context.mission, goals: context.goals, trigger: event.summary, seen: event.detail ?? "Nothing more.", journal: context.journal)
        if BeanSettings.shared.effectiveDecidesOnThisMac, StrandsServer.isAvailable, let score = await StrandsDecider.score(state: state) {
            return Judged(score: score, quietAtOrBelow: StrandsDecider.quietAtOrBelow, by: "Strands")
        }
        return Judged(score: filter(event, context: context), quietAtOrBelow: 0.5, by: "filter")
    }

    static func filter(_ event: SenseEvent, context: AgentWorker.GateContext) -> Double {
        if let score = event.emit?.whenNoModel { return score }
        let text = [event.title, event.detail].compactMap { $0 }.joined(separator: "\n")
        let changed = event.detail ?? event.title ?? ""
        if noise.firstMatch(in: changed, range: NSRange(changed.startIndex..., in: changed)) != nil { return 0.1 }
        if context.hasAgent, let score = event.emit?.onAgentWindow { return score }
        func words(_ value: String) -> Set<String> { Set(value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 3 }) }
        return words(text).isDisjoint(with: words(context.goals ?? "")) ? 0.2 : 0.9
    }

    func record(_ entry: GateEntry) {
        Self.log.append(entry)
        worker?.noteGate(entry)
    }
}
