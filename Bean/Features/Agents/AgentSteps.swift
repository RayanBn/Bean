import Foundation

// What an agent looked at, for the person to read. It lives apart from the journal because prompts read the journal: a read must not push real work out of them.
struct AgentStep: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case began, looked, skipped, said, ended }
    var id = UUID()
    var at = Date()
    let run: UUID
    let kind: Kind
    var words: String
    var family: Family?
    var object: String?
    var reason: String?
    var detail: String?

    enum Family: String, Codable { case tab, window, service, check, learned }
}

struct LiveStep: Equatable {
    let run: UUID
    let task: String
    let began: Date
    var words: String
    var since: Date
    var thinking: Bool
}

extension AgentFolder {
    var stepsFile: URL { url.appendingPathComponent("steps.jsonl") }

    var steps: [AgentStep] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let text = (try? String(contentsOf: stepsFile, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").suffix(600).compactMap { try? decoder.decode(AgentStep.self, from: Data($0.utf8)) }
    }

    func append(_ step: AgentStep) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let line = try? encoder.encode(step) else { return }
        JSONLines.append(line, to: stepsFile)
    }
}

// The words come from the call and what it really returned. Only Bean's own tools are named here, and any other tool still gets a plain line.
struct StepWords {
    enum Outcome: Equatable {
        case hidden
        case inJournal
        case step(AgentStep.Kind, String, family: AgentStep.Family?, object: String?, reason: String?, detail: String?)
    }

    let app: String
    let window: String?
    let scope: String
    var tabs: [String: String] = [:]
    var windows: [Int: String] = [:]

    private static let plumbing: Set<String> = ["ask_user", "offer_drafts", "need_connector", "use_services", "connector_tools", "list_senses", "request_sense", "request_hearing_calls", "drop_sense"]

    private var front: String { window.map(Self.title) ?? app }

    func running(_ name: String, _ args: JSONArgs) -> String? {
        if Self.plumbing.contains(name) { return nil }
        switch name {
        case "window_read": return "Reading \(front)"
        case "app_windows": return "Looking through \(app)"
        case "app_window_read": return "Reading \(args.string("title").map(Self.title) ?? "a window")"
        case "tab_read": return "\(args["wake"] as? Bool == true ? "Waking and reading" : "Reading") \(tabTitle(args) ?? "a tab")"
        case "window_controls": return "Looking at what can be used in \(app)"
        case "window_act": return args.string("action") == "fill" ? "Filling in a field in \(app)" : "Pressing a button in \(app)"
        case "window_hands": return "Working in \(app)"
        case "sweep": return "Going through \(app) item by item"
        case "app_script", "app_shortcut": return "Working in \(app)"
        case "app_open": return "Opening a link in \(app)"
        case "app_menu": return args.string("path") == nil ? "Looking at the menus of \(app)" : "Choosing a menu item in \(app)"
        case "app_surface", "app_dictionary", "read_skill": return "Learning how \(app.isEmpty ? "this" : app) works"
        case "run_shell": return scope.isEmpty ? "Running a check" : "Checking \(scope)"
        case "act", "session_act": return "Making a change"
        case "memory": return "Making a note"
        case "tell_bean": return "Telling Bean"
        case "find_connectors": return "Looking for a service that can help"
        case "connect": return "Connecting \(args.string("name") ?? "a service")"
        case "session_drive": return "Getting code written"
        case "session_close": return "Closing the coding work"
        case "list_windows": return "Looking at your open windows"
        case "read_window": return "Reading \((args["window"] as? Int).flatMap { windows[$0] } ?? "a window")"
        case "create_agent": return "Making a new agent"
        case "attach_agent": return "Putting \(args.string("agent") ?? "an agent") on an app"
        case "detach_agent": return "Taking \(args.string("agent") ?? "an agent") off its app"
        case "hand_off": return "Waiting for \(args.string("agent") ?? "an agent")"
        default:
            let (server, leaf) = Self.parts(name)
            if args.string("did") != nil { return "Making a change\(server.map { " in \($0)" } ?? "")" }
            return server.map { "Checking \($0)" } ?? "Using \(leaf)"
        }
    }

    mutating func ended(_ name: String, _ args: JSONArgs, _ output: ToolOutput) -> Outcome {
        if Self.plumbing.contains(name) { return .hidden }
        switch name {
        case "window_read":
            return read(front, family: .window, output)
        case "app_windows":
            remember(tabsIn: output.text)
            return looked(output, or: "Could not look through \(app)", appWindows(output.text), detail: Self.listing(output.text))
        case "app_window_read":
            return read(args.string("title").map(Self.title) ?? "a window", family: .window, output)
        case "tab_read":
            let identity = Self.identity(output.text)
            let tab = identity ?? tabTitle(args) ?? "a tab"
            if output.ok, output.text.contains(AppTabs.wokeWords) {
                return .step(.looked, "Woke \(tab) and read it", family: .tab, object: tab, reason: nil, detail: Self.preview(output.text))
            }
            return read(tab, family: .tab, output)
        case "window_controls":
            return looked(output, or: "Could not look at \(app)", "Looked at what can be used in \(app)", family: .learned)
        case "app_menu" where args.string("path") == nil:
            return looked(output, or: "Could not look at the menus of \(app)", "Looked at the menus of \(app)", family: .learned)
        case "window_act", "window_hands", "sweep", "app_script", "app_shortcut", "app_open", "app_menu", "act", "session_act", "create_agent", "detach_agent":
            return .inJournal
        case "app_surface", "app_dictionary", "read_skill":
            return looked(output, or: "Could not work out how \(app.isEmpty ? "this" : app) works", "Learned how \(app.isEmpty ? "this" : app) works", family: .learned)
        case "run_shell":
            return looked(output, or: "A check did not work", scope.isEmpty ? "Ran a check" : "Checked \(scope)", family: .check)
        case "memory":
            return output.ok ? .step(.looked, "Made a note for later", family: nil, object: nil, reason: nil, detail: args.string("text")) : .hidden
        case "tell_bean":
            return .step(.looked, "Told Bean what it found", family: nil, object: nil, reason: nil, detail: args.string("message"))
        case "find_connectors":
            return looked(output, or: "Could not look for a service", "Looked for a service that can help")
        case "connect":
            return looked(output, or: "Could not connect \(args.string("name") ?? "a service")", "Asked to connect \(args.string("name") ?? "a service")")
        case "session_drive":
            return looked(output, or: "The coding work did not start", "Worked on the code")
        case "session_close":
            return looked(output, or: "Could not close the coding work", "Closed the coding work")
        case "list_windows":
            remember(windowsIn: output.text)
            let count = output.text.split(separator: "\n").filter { $0.first?.isNumber == true }.count
            return looked(output, or: "Could not see your windows", count == 1 ? "Looked at your open window" : "Looked at your \(count) open windows", detail: Self.clean(output.text))
        case "read_window":
            return read((args["window"] as? Int).flatMap { windows[$0] } ?? "a window", family: .window, output)
        case "attach_agent":
            return looked(output, or: "Could not put \(args.string("agent") ?? "an agent") on that app", "Put \(args.string("agent") ?? "an agent") on an app")
        case "hand_off":
            return looked(output, or: "Could not reach \(args.string("agent") ?? "an agent")", "Asked \(args.string("agent") ?? "an agent") to help", detail: args.string("task").map(JournalEntry.withoutWorkID))
        default:
            let (server, leaf) = Self.parts(name)
            if args.string("did") != nil { return .inJournal }
            guard let server else { return looked(output, or: "Could not use \(leaf)", "Used \(leaf)") }
            return looked(output, or: "Could not check \(server)", "Checked \(server): \(leaf.lowercased())", family: .service, object: server)
        }
    }

    private func read(_ what: String, family: AgentStep.Family, _ output: ToolOutput) -> Outcome {
        guard !output.ok else {
            return .step(.looked, "Read \(what)", family: family, object: what, reason: nil, detail: Self.preview(output.text))
        }
        let reason = Self.reason(output.text)
        return .step(.skipped, reason.map { "Skipped \(what): it is \($0)" } ?? "Could not read \(what)", family: family, object: what, reason: reason, detail: Self.clean(output.text))
    }

    private func looked(_ output: ToolOutput, or failed: String, _ words: String, family: AgentStep.Family? = nil, object: String? = nil, detail: String? = nil) -> Outcome {
        output.ok ? .step(.looked, words, family: family, object: object, reason: nil, detail: detail ?? Self.preview(output.text))
            : .step(.skipped, failed, family: family, object: object, reason: Self.reason(output.text), detail: Self.clean(output.text))
    }

    private func appWindows(_ text: String) -> String {
        let lines = text.split(separator: "\n")
        let tabs = lines.filter { $0.hasPrefix("Tab ") }.count
        if tabs > 0 { return tabs == 1 ? "Looked at your \(app) tab" : "Looked through your \(tabs) \(app) tabs" }
        let windows = lines.filter { $0.hasPrefix("Window: ") }.count
        return windows == 1 ? "Looked at your \(app) window" : "Looked through your \(windows) \(app) windows"
    }

    private mutating func remember(tabsIn text: String) {
        for line in text.split(separator: "\n") where line.hasPrefix("Tab ") {
            let parts = line.dropFirst(4).components(separatedBy: " | ")
            if parts.count >= 2, parts[1] != "off limits" { tabs[parts[0]] = Self.title(parts[1]) }
        }
    }

    private mutating func remember(windowsIn text: String) {
        for line in text.split(separator: "\n") {
            let parts = line.components(separatedBy: ": ")
            guard parts.count >= 2, let number = Int(parts[0]) else { continue }
            let place = parts[1...].joined(separator: ": ").components(separatedBy: ", ")
            let named = place.dropFirst().joined(separator: ", ")
            windows[number] = Self.title(named.isEmpty || named == "untitled" || named == "title kept private" ? place[0] : named)
        }
    }

    private func tabTitle(_ args: JSONArgs) -> String? {
        guard let window = args["window"] as? Int, let tab = args["tab"] as? Int else { return nil }
        return tabs["\(window).\(tab)"]
    }

    private static func parts(_ name: String) -> (server: String?, leaf: String) {
        let pieces = name.components(separatedBy: "__")
        guard pieces.count > 1 else { return (nil, AbilityFinder.humanized(name)) }
        return (AbilityFinder.humanized(pieces[0]), AbilityFinder.humanized(pieces[pieces.count - 1]))
    }

    // Tab reads start with "title address". A tab named after its own address reads better as the site.
    private static func identity(_ text: String) -> String? {
        guard let first = text.split(separator: "\n").first else { return nil }
        let words = first.split(separator: " ")
        guard words.count >= 2, words.last?.contains("://") == true else { return nil }
        return title(words.dropLast().joined(separator: " "))
    }

    static func title(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains(" "), text.contains("/"), let host = URL(string: text.contains("://") ? text : "https://\(text)")?.host { return host }
        return text.count > 60 ? String(text.prefix(58)) + "…" : text
    }

    private static func reason(_ text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("is asleep") || lower.contains("did not wake up") { return "asleep" }
        if lower.contains("off limits") { return "off limits" }
        if lower.contains("own conversations") { return "private" }
        if lower.contains("has closed") { return "closed" }
        if lower.contains("another space") || lower.contains("no way to read") { return "out of reach" }
        if lower.contains("did not answer") { return "not answering" }
        return nil
    }

    private static let toolNames = try! NSRegularExpression(pattern: #"\b[a-z]+_[a-z_]+\b"#)

    // What the tools tell the model can name other tools or give it orders. The person gets the rest.
    static func clean(_ text: String) -> String {
        toThePerson(text).components(separatedBy: "\n").map { line in
            line.components(separatedBy: ". ").filter { sentence in
                toolNames.firstMatch(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)) == nil && !sentence.hasPrefix("(The page goes on")
            }.joined(separator: ". ")
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func toThePerson(_ text: String) -> String {
        [("the person sees", "you see"), ("the user's", "your"), ("the person's", "your"), ("the user", "you"), ("the person", "you")].reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    private static func preview(_ text: String) -> String? {
        let shown = clean(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shown.isEmpty else { return nil }
        return shown.count > 700 ? String(shown.prefix(700)) + "…" : shown
    }

    private static func listing(_ text: String) -> String {
        text.split(separator: "\n").prefix(200).map { line in
            let parts = line.components(separatedBy: " | ")
            return parts.count >= 2 && line.hasPrefix("Tab ") ? "\(title(parts[1]))" : line.replacingOccurrences(of: "Window: ", with: "")
        }.joined(separator: "\n")
    }
}

// One run of an agent, from the first thought to the last call. The loop reports through it and knows nothing of the screen.
@MainActor
final class RunWatch {
    private weak var worker: AgentWorker?
    private let agent: Agent
    private let task: String
    private let run = UUID()
    private let began = Date()
    private var words: StepWords
    private var running: [(id: UUID, words: String)] = []
    private var thinkingAfter: Task<Void, Never>?

    init(worker: AgentWorker, agent: Agent, task: String, app: String, window: String?, scope: String) {
        self.worker = worker
        self.agent = agent
        self.task = String((task.split(separator: "\n").first.map(String.init) ?? task).prefix(160))
        words = StepWords(app: app, window: window, scope: scope)
    }

    func begin() {
        worker?.add(AgentStep(run: run, kind: .began, words: task), of: agent)
        worker?.setLive(LiveStep(run: run, task: task, began: began, words: "Thinking", since: began, thinking: true), of: agent)
    }

    func end() {
        thinkingAfter?.cancel()
        worker?.add(AgentStep(run: run, kind: .ended, words: ""), of: agent)
        worker?.setLive(nil, of: agent)
    }

    func said(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        worker?.add(AgentStep(run: run, kind: .said, words: String(line.prefix(400))), of: agent)
    }

    func call(_ name: String, _ args: JSONArgs, _ body: () async -> ToolOutput) async -> ToolOutput {
        let id = UUID()
        if let line = words.running(name, args) {
            running.append((id, line))
            show(line)
        }
        let output = await body()
        running.removeAll { $0.id == id }
        if case .step(let kind, let line, let family, let object, let reason, let detail) = words.ended(name, args, output) {
            worker?.add(AgentStep(run: run, kind: kind, words: line, family: family, object: object, reason: reason, detail: detail), of: agent)
        }
        if let next = running.last { show(next.words) } else { thinkSoon() }
        return output
    }

    private func show(_ line: String) {
        thinkingAfter?.cancel()
        worker?.setLive(LiveStep(run: run, task: task, began: began, words: line, since: Date(), thinking: false), of: agent)
    }

    // A short wait, so the line does not flicker to Thinking and back between quick calls.
    private func thinkSoon() {
        thinkingAfter?.cancel()
        thinkingAfter = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, !Task.isCancelled else { return }
            self.worker?.setLive(LiveStep(run: self.run, task: self.task, began: self.began, words: "Thinking", since: Date(), thinking: true), of: self.agent)
        }
    }
}

// How a run reads on screen: its steps and the changes the journal holds, folded by kind. Changes never fold in with reads, so a write cannot pass for a look.
struct StepRun: Identifiable {
    enum Row: Identifiable {
        case steps([AgentStep])
        case said(AgentStep)
        case change(JournalEntry)

        var id: UUID {
            switch self {
            case .steps(let list): list[0].id
            case .said(let step): step.id
            case .change(let entry): entry.id
            }
        }
    }

    let id: UUID
    let task: String
    let began: Date
    let ended: Date?
    let rows: [Row]
    let live: LiveStep?

    var isLive: Bool { live != nil }
    var isEmpty: Bool { rows.isEmpty && live == nil }
    var seconds: TimeInterval? { ended.map { $0.timeIntervalSince(began) } }

    var changes: [JournalEntry] {
        rows.compactMap { if case .change(let entry) = $0 { entry } else { nil } }
    }

    static func isChange(_ entry: JournalEntry) -> Bool { [.action, .refused, .failed, .undo].contains(entry.kind) }

    static func all(steps: [AgentStep], journal: [JournalEntry], live: LiveStep?) -> [StepRun] {
        var order: [UUID] = []
        var byRun: [UUID: [AgentStep]] = [:]
        for step in steps {
            if byRun[step.run] == nil { order.append(step.run) }
            byRun[step.run, default: []].append(step)
        }
        if let live, byRun[live.run] == nil { order.append(live.run) }
        let starts = order.compactMap { byRun[$0]?.first?.at ?? live?.began }
        return order.enumerated().map { index, run in
            let list = byRun[run] ?? []
            let isLive = live?.run == run
            let began = list.first?.at ?? live?.began ?? Date()
            let closed = list.last { $0.kind == .ended }?.at
            let last = closed ?? (isLive ? nil : list.last?.at)
            let until = last ?? (index + 1 < starts.count ? starts[index + 1] : Date.distantFuture)
            let changes = journal.filter { isChange($0) && $0.at >= began && $0.at <= until }
            return StepRun(id: run, task: list.first { $0.kind == .began }?.words ?? live?.task ?? "", began: began, ended: last,
                           rows: rows(list, changes), live: isLive ? live : nil)
        }
    }

    private static func rows(_ steps: [AgentStep], _ changes: [JournalEntry]) -> [Row] {
        enum Moment { case step(AgentStep), change(JournalEntry) }
        func date(_ moment: Moment) -> Date {
            switch moment {
            case .step(let step): step.at
            case .change(let entry): entry.at
            }
        }
        let moments = (steps.filter { $0.kind == .looked || $0.kind == .skipped || $0.kind == .said }.map(Moment.step) + changes.map(Moment.change)).enumerated()
            .sorted { date($0.element) == date($1.element) ? $0.offset < $1.offset : date($0.element) < date($1.element) }.map(\.element)
        var rows: [Row] = [], run: [AgentStep] = []
        func flush() {
            guard !run.isEmpty else { return }
            rows += groups(run).map(Row.steps)
            run = []
        }
        for moment in moments {
            switch moment {
            case .step(let step) where step.kind == .said:
                flush()
                rows.append(.said(step))
            case .step(let step):
                run.append(step)
            case .change(let entry):
                flush()
                rows.append(.change(entry))
            }
        }
        flush()
        return rows
    }

    private static func groups(_ steps: [AgentStep]) -> [[AgentStep]] {
        var result: [[AgentStep]] = []
        for step in steps {
            if let family = step.family, result.last?[0].family == family {
                result[result.count - 1].append(step)
            } else {
                result.append([step])
            }
        }
        return result
    }

    static func label(_ steps: [AgentStep]) -> String {
        guard steps.count > 1 else { return steps[0].words }
        let done = steps.filter { $0.kind == .looked }, skipped = steps.filter { $0.kind == .skipped }
        switch steps[0].family {
        case .tab, .window:
            let noun = steps[0].family == .tab ? "tab" : "window"
            let reasons = Set(skipped.map { $0.reason ?? "" })
            let why = reasons.count == 1 ? reasons.first.flatMap { $0.isEmpty ? nil : $0 } : nil
            let held = many(skipped)
            if done.isEmpty {
                let names = named(skipped)
                return why.map { "\(held) \(noun)\(held == 1 ? " was" : "s were") \($0): \(names)" } ?? "Could not read \(held) \(noun)\(held == 1 ? "" : "s"): \(names)"
            }
            let reading = many(done) == 1 ? "Read \(named(done))" : "Read \(many(done)) \(noun)s: \(named(done))"
            return skipped.isEmpty ? reading : "\(reading) · \(held) \(why ?? "out of reach")"
        case .service:
            return "Checked \(steps[0].object ?? "a service") \(steps.count) times" + (skipped.isEmpty ? "" : " · \(skipped.count) did not work")
        case .check:
            return "Ran \(steps.count) checks"
        case .learned, nil:
            return steps[steps.count - 1].words
        }
    }

    // Reading a long page in parts, or the same window twice, is one thing read. Two sleeping tabs of one site are two tabs.
    private static func many(_ steps: [AgentStep]) -> Int {
        guard let first = steps.first, first.kind == .looked || first.family == .window else { return steps.count }
        return Set(steps.map { $0.object ?? $0.words }).count
    }

    // A count alone hides what people look for, so a group names what it holds.
    private static func named(_ steps: [AgentStep]) -> String {
        var names: [String] = []
        for step in steps { if let object = step.object, !names.contains(object) { names.append(object) } }
        let extra = many(steps) - min(names.count, 2)
        return names.prefix(2).joined(separator: ", ") + (extra > 0 ? ", +\(extra)" : "")
    }

    // One line for a folded run: what was looked at, and how much went nowhere. Working out how an app works is not news.
    var summary: String {
        let steps = rows.flatMap { row -> [AgentStep] in if case .steps(let list) = row { list } else { [] } }
        var parts: [String] = []
        for step in steps where step.family == nil && step.kind == .looked && !parts.contains(step.words) { parts.append(step.words) }
        for family in [AgentStep.Family.tab, .window] {
            let same = steps.filter { $0.family == family }, done = same.filter { $0.kind == .looked }, skipped = same.filter { $0.kind == .skipped }
            let noun = family == .tab ? "tab" : "window"
            if !done.isEmpty { parts.append(Self.many(done) == 1 ? done[0].words : "read \(Self.many(done)) \(noun)s") }
            let held = Self.many(skipped)
            if let reason = skipped.first?.reason, skipped.allSatisfy({ $0.reason == reason }) {
                parts.append("\(held) \(noun)\(held == 1 ? " was" : "s were") \(reason)")
            } else if !skipped.isEmpty {
                parts.append("\(held) \(noun)\(held == 1 ? "" : "s") could not be read")
            }
        }
        for name in Set(steps.filter { $0.family == .service }.compactMap(\.object)).sorted() { parts.append("checked \(name)") }
        let checks = steps.filter { $0.family == .check }.count
        if checks > 0 { parts.append(checks == 1 ? "ran a check" : "ran \(checks) checks") }
        guard let first = parts.first else {
            let count = changes.count
            return count == 0 ? "Thought it over" : count == 1 ? "Made 1 change" : "Made \(count) changes"
        }
        return ([first] + parts.dropFirst().prefix(3).map(\.lowercasedFirst)).joined(separator: ", ")
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return whole < 60 ? "\(whole)s" : "\(whole / 60)m \(whole % 60)s"
    }
}
