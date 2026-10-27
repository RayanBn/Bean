import Foundation

struct RoutineMiner {
    static let sessionGap: TimeInterval = 300
    static let minLength = 3
    static let maxLength = 12

    let actions: [RecordedAction]
    let tokens: [String]
    let vocabulary: Vocabulary
    private let sessions: [Range<Int>]
    private let lineCounts: [String: Int]

    init(actions: [RecordedAction]) {
        self.actions = actions
        vocabulary = Vocabulary(actions)
        tokens = actions.map(vocabulary.token)
        lineCounts = actions.compactMap(\.effect).flatMap(\.added).reduce(into: [:]) { $0[$1, default: 0] += 1 }
        var sessions: [Range<Int>] = [], start = 0
        for index in actions.indices.dropFirst() where actions[index].at.timeIntervalSince(actions[index - 1].at) > Self.sessionGap {
            sessions.append(start..<index)
            start = index
        }
        if !actions.isEmpty { sessions.append(start..<actions.count) }
        self.sessions = sessions
    }

    static func all(_ actions: [RecordedAction]) -> [Routine] {
        var found = RoutineMiner(actions: actions).routines()
        let apps = Dictionary(grouping: actions, by: \.app).filter { $0.value.count >= 6 && $0.value.count < actions.count }
        for (app, own) in apps.sorted(by: { $0.key < $1.key }) {
            for var routine in RoutineMiner(actions: own).routines() where !found.contains(where: { $0.tokens == routine.tokens }) {
                routine.scope = app
                found.append(routine)
            }
        }
        return found
    }

    var currentSession: Range<Int>? { sessions.last.flatMap { $0.upperBound == actions.count ? $0 : nil } }

    func routines() -> [Routine] {
        var kept: [(gram: [String], starts: [Int])] = []
        for length in stride(from: Self.maxLength, through: Self.minLength, by: -1) {
            for (gram, starts) in occurrences(length: length).sorted(by: { $0.value[0] < $1.value[0] }) where starts.count >= 2 && Set(gram).count >= 2 {
                if kept.contains(where: { Self.contains($0.gram, gram) && $0.starts.count >= starts.count }) { continue }
                if kept.contains(where: { $0.gram.count == gram.count && Self.isRotation($0.gram, gram) }) { continue }
                kept.append((gram, starts))
            }
        }
        return kept.map { compile($0.gram, starts: $0.starts) }
            .sorted { $0.instances * $0.steps.count > $1.instances * $1.steps.count }
    }

    func completionOdds(of target: [String], prefixLength: Int) -> Double {
        let prefix = Array(target.prefix(prefixLength))
        var seen = 0, completed = 0
        for session in sessions {
            var index = session.lowerBound
            while index + prefix.count <= session.upperBound {
                guard Array(tokens[index..<index + prefix.count]) == prefix else { index += 1; continue }
                if index + target.count <= session.upperBound {
                    seen += 1
                    if Array(tokens[index..<index + target.count]) == target { completed += 1 }
                }
                index += prefix.count
            }
        }
        return Double(completed + 1) / Double(seen + 2)
    }

    private func occurrences(length: Int) -> [[String]: [Int]] {
        var found: [[String]: [Int]] = [:]
        for session in sessions where session.count >= length {
            var lastEnd: [[String]: Int] = [:]
            for start in session.lowerBound...(session.upperBound - length) {
                let gram = Array(tokens[start..<start + length])
                if let end = lastEnd[gram], start < end { continue }
                found[gram, default: []].append(start)
                lastEnd[gram] = start + length
            }
        }
        return found
    }

    private func compile(_ gram: [String], starts: [Int]) -> Routine {
        let instances = starts.map { Array(actions[$0..<$0 + gram.count]) }
        let items = Set(gram.indices.flatMap { position in
            Set(instances.compactMap { $0[position].element?.label }).count > 1 ? instances.compactMap { $0[position].element?.label } : []
        })
        let steps = gram.indices.map { position -> RoutineStep in
            let samples = instances.map { $0[position] }
            let latest = samples.last!
            let variable = Set(samples.compactMap { $0.element?.label }).count > 1 || gram[position].hasSuffix("{x}")
            let changing = Set(samples.compactMap(\.value)).count > 1
            let next = starts.compactMap { start in start + position + 1 < actions.count ? actions[start + position + 1] : nil }
            var step = Self.step(latest, variable: variable, changing: changing, post: nil, vocabulary: vocabulary)
            step.post = Self.learnedCheck(samples.compactMap(\.effect), clicked: variable ? nil : latest.element, target: step.target, items: items,
                                          nextURLs: next.compactMap { $0.element?.url ?? $0.url }, vocabulary: vocabulary, lineCounts: lineCounts)
            return RoutineStep(step: step, variable: variable, path: latest.element?.path ?? [], href: latest.element?.href.map(vocabulary.template))
        }
        let loops = zip(starts, starts.dropFirst()).contains { $0 + gram.count == $1 }
        let days = Set(starts.map { Calendar.current.startOfDay(for: actions[$0].at) }).count
        return Routine(id: Self.identifier(gram), name: steps.map(\.step.intent).joined(separator: ", "), tokens: gram, steps: steps, instances: starts.count, days: days, loops: loops, scope: nil)
    }

    static func step(_ action: RecordedAction, variable: Bool, changing: Bool, post: Check?, vocabulary: Vocabulary) -> Step {
        let app = action.appName ?? action.app.components(separatedBy: ".").last ?? action.app
        let element = action.element
        let target = element.map { element -> Locator in
            if !variable, let href = element.href {
                return Locator(bundleId: element.bundleId, role: element.role, urlPattern: Vocabulary.anchored(vocabulary.template(href)),
                               ancestors: element.path.isEmpty ? nil : element.path.reversed(), index: 0)
            }
            return Locator(bundleId: element.bundleId, role: element.role, title: variable ? nil : element.label,
                           identifier: variable ? nil : element.identifier, domId: variable ? nil : element.domId)
        }
        let irreversible = Self.irreversible(action)
        switch action.kind {
        case .press:
            let what = variable ? "the next \(Vocabulary.roleName(element?.role))" : "“\(element?.label ?? Vocabulary.roleName(element?.role))”"
            return Step(intent: "Click \(what) in \(app)", kind: .press, target: target, bundleId: action.app, post: post, irreversible: irreversible)
        case .commit:
            return Step(intent: "Fill “\(element?.label ?? "the field")” in \(app)", kind: .setValue, target: target, text: changing ? nil : action.value, bundleId: action.app, post: post)
        case .key:
            return Step(intent: "Press \(action.value ?? "a key") in \(app)", kind: .keys, text: action.value, bundleId: action.app, post: post, irreversible: irreversible)
        case .shell:
            return Step(intent: "Run `\(action.value ?? "")`", kind: .shell, text: action.value, cwd: action.window, post: post, irreversible: irreversible)
        }
    }

    static func irreversible(_ action: RecordedAction) -> Bool {
        switch action.kind {
        case .shell: return HiddenShell.requiresConsent(action.value ?? "")
        case .press:
            let label = (action.element?.label ?? "").lowercased()
            return label.range(of: #"\b(send|delete|remove|merge|publish|post|pay|buy|order|submit|confirm|transfer|archive|trash)\b"#, options: .regularExpression) != nil
        case .key: return action.value == "cmd+delete" || action.value == "cmd+backspace"
        case .commit: return false
        }
    }

    private static func isControl(_ line: String) -> Int {
        ["AXStaticText", "AXHeading", "AXCell", "AXTextField", "AXTextArea"].contains { line.hasPrefix($0 + " ") } ? 0 : 1
    }

    static func learnedCheck(_ effects: [AXDiff], clicked: ElementLocator?, target: Locator?, items: Set<String>, nextURLs: [String], vocabulary: Vocabulary, lineCounts: [String: Int]) -> Check? {
        guard let first = effects.first, effects.count >= 2 else { return nil }
        if let clicked, let label = clicked.label, let target, effects.allSatisfy({ $0.removed.contains("\(clicked.role) \(label)") && !$0.added.contains("\(clicked.role) \(label)") }) {
            return Check(kind: .absent, target: target)
        }
        var added = Set(first.added)
        for effect in effects.dropFirst() { added.formIntersection(effect.added) }
        let text = first.added.filter({ line in added.contains(line) && !line.contains("<") && line.rangeOfCharacter(from: .decimalDigits) == nil && !items.contains { line.contains($0) } && line.split(separator: " ", maxSplits: 1).last.map { $0.count >= 6 } == true })
            .min(by: { (lineCounts[$0, default: 0], Self.isControl($0), -$0.count) < (lineCounts[$1, default: 0], Self.isControl($1), -$1.count) })
            .flatMap { $0.split(separator: " ", maxSplits: 1).last.map { Check(kind: .textAppears, value: String($0)) } }
        let templates = Set(nextURLs.map(vocabulary.template))
        if effects.allSatisfy({ $0.titleBefore != $0.titleAfter }), templates.count == 1, let template = templates.first, nextURLs.count == effects.count {
            let url = Check(kind: .urlMatches, value: Vocabulary.pattern(template))
            return text.map { Check(kind: .all, checks: [url, $0]) } ?? url
        }
        if let text { return text }
        let titles = Set(effects.compactMap(\.titleAfter))
        if titles.count == 1, let title = titles.first, !title.isEmpty, effects.allSatisfy({ $0.titleBefore != $0.titleAfter }) {
            return Check(kind: .titleContains, value: title)
        }
        return nil
    }

    static func identifier(_ gram: [String]) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in gram.joined(separator: "\n").utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 36)
    }

    static func contains(_ outer: [String], _ inner: [String]) -> Bool {
        guard outer.count > inner.count else { return false }
        return (0...(outer.count - inner.count)).contains { Array(outer[$0..<$0 + inner.count]) == inner }
    }

    static func isRotation(_ a: [String], _ b: [String]) -> Bool {
        (1..<a.count).contains { Array(a[$0...] + a[..<$0]) == b }
    }
}

struct Vocabulary {
    private var labelCounts: [String: [String: Int]] = [:]
    private var segmentValues: [String: [String: Int]] = [:]

    init(_ actions: [RecordedAction]) {
        for action in actions {
            for url in [action.element?.url ?? action.url, action.element?.href].compactMap({ $0 }) { record(url: url) }
        }
        for action in actions where action.kind == .press {
            guard let element = action.element, let label = element.label else { continue }
            labelCounts[slot(element), default: [:]][label, default: 0] += 1
        }
    }

    func token(_ action: RecordedAction) -> String {
        switch action.kind {
        case .shell: return "shell|" + Self.command(action.value ?? "")
        case .key: return "key|\(action.app)|\(action.value ?? "")"
        case .commit: return "commit|" + (action.element.map { slot($0) + "|" + (Self.normalize($0.domId ?? $0.identifier ?? $0.label ?? "")) } ?? action.app)
        case .press:
            guard let element = action.element else { return "press|\(action.app)" }
            let key: String
            if let id = element.domId ?? element.identifier { key = Self.normalize(id) }
            else if let label = element.label, labelCounts[slot(element)]?[label, default: 0] ?? 0 >= 2 { key = Self.normalize(label) }
            else { key = "{x}" }
            return "press|" + slot(element) + "|" + key
        }
    }

    private func slot(_ element: ElementLocator) -> String {
        [element.bundleId, element.role, element.path.joined(separator: "<"), element.url.map(template) ?? "", element.href.map(template) ?? ""].joined(separator: "|")
    }

    private mutating func record(url: String) {
        guard let parts = Self.parts(url) else { return }
        for (index, segment) in parts.segments.enumerated() {
            segmentValues["\(parts.host)#\(index)", default: [:]][segment, default: 0] += 1
        }
    }

    func template(_ url: String) -> String {
        guard let parts = Self.parts(url) else { return url }
        let segments = parts.segments.enumerated().map { index, segment -> String in
            if Self.looksLikeId(segment) { return "{x}" }
            let values = segmentValues["\(parts.host)#\(index)"] ?? [:]
            let total = values.values.reduce(0, +)
            return values.count >= 8 && Double(values[segment] ?? 0) / Double(max(total, 1)) < 0.2 ? "{x}" : segment
        }
        return parts.host + "/" + segments.joined(separator: "/")
    }

    private static func parts(_ url: String) -> (host: String, segments: [String])? {
        guard let components = URLComponents(string: url) else { return nil }
        let host = components.host ?? components.scheme ?? ""
        return (host + (components.port.map { ":\($0)" } ?? ""), components.path.split(separator: "/").prefix(5).map(String.init))
    }

    private static func looksLikeId(_ segment: String) -> Bool {
        segment.range(of: #"^(\d+|[0-9a-f]{8,}|[0-9a-f-]{32,36}|[A-Za-z0-9_-]{24,})$"#, options: .regularExpression) != nil
    }

    static func anchored(_ template: String) -> String {
        "^[a-z]+://" + pattern(template) + "/?([?#].*)?$"
    }

    static func pattern(_ template: String) -> String {
        NSRegularExpression.escapedPattern(for: template).replacingOccurrences(of: #"\{x\}"#, with: "[^/?#]+")
    }

    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression).lowercased()
    }

    static func command(_ line: String) -> String {
        let words = line.split(separator: " ").map(String.init)
        guard let first = words.first.map({ ($0 as NSString).lastPathComponent }), !first.isEmpty else { return "{x}" }
        var kept = [first]
        for word in words.dropFirst().prefix(2) {
            guard word.range(of: #"^[a-z][a-z0-9:_.-]*$"#, options: .regularExpression) != nil else { break }
            kept.append(word)
        }
        return kept.joined(separator: " ")
    }

    static func roleName(_ role: String?) -> String {
        switch role {
        case "AXLink": "link"
        case "AXButton": "button"
        case "AXRow", "AXCell": "row"
        case "AXMenuItem": "menu item"
        case "AXTab": "tab"
        default: "item"
        }
    }
}
