import Foundation

enum AgentWriting {
    static let rule = "Everything you write is professional and precise, as from a senior engineer: plain declarative sentences, concrete facts, specific requests. No slang, jokes, metaphors, catchphrases, filler, emoji or exclamation marks. State only what your sources say: never invent facts, attendees, attachments or next steps. An agenda, a brief or a total built only from what the sources say is not invention: write it. When a document has a place for a fact that is missing, say that the source does not give it, entirely in the language you are writing in. In a summary, recap, question, ticket or message, leave out what there is nothing to say about: no empty field, no placeholder, no remark that something is missing. This overrides anything about your voice above."
}

struct AgentMission: Codable, Equatable {
    struct Check: Codable, Equatable {
        var command: String?
        var tool: String?
        var arguments: String?
    }

    var mission: String
    var targets: [AgentTarget]
    var explicitlyAllowed: [String] = []
    var question: String?
    var paused = false
    var every: TimeInterval = 300
    var dailyBudgetUSD: Double = 1
    var check: Check?

    init(mission: String, targets: [AgentTarget] = [], explicitlyAllowed: [String] = [], question: String? = nil) {
        self.mission = mission
        self.targets = targets
        self.explicitlyAllowed = explicitlyAllowed
        self.question = question
    }

    init(mission: String, scope: [String], allowed: [String] = [], mayMerge: Bool = false, mayDeploy: Bool = false, mayRunSessions: Bool = false) {
        self.init(mission: mission, targets: scope.map(AgentTarget.named), explicitlyAllowed: (mayMerge ? ["merge"] : []) + (mayDeploy ? ["deploy"] : []))
    }

    var scope: [String] {
        get { targets.filter { $0.kind == .repo || $0.kind == .project }.map(\.name) }
        set {
            let others = targets.filter { $0.kind != .repo && $0.kind != .project }
            let kept = targets.filter { newValue.contains($0.name) && ($0.kind == .repo || $0.kind == .project) }
            let added = newValue.filter { name in !kept.contains { $0.name == name } }.map(AgentTarget.named)
            targets = kept + added + others
        }
    }

    var allowed: [String] { [] }
    var mayRunSessions: Bool {
        get { true }
        set {}
    }
    var mayMerge: Bool {
        get { explicitlyAllowed.contains("merge") }
        set { setExplicit("merge", newValue) }
    }
    var mayDeploy: Bool {
        get { explicitlyAllowed.contains("deploy") }
        set { setExplicit("deploy", newValue) }
    }

    private mutating func setExplicit(_ word: String, _ on: Bool) {
        explicitlyAllowed.removeAll { $0 == word }
        if on { explicitlyAllowed.append(word) }
    }

    var isActive: Bool { !mission.isEmpty && !scope.isEmpty }
    var named: String { scope.joined(separator: ", ") }

    func covers(_ text: String) -> Bool {
        scope.contains { name in
            text.range(of: "(^|[^A-Za-z0-9_-])\(NSRegularExpression.escapedPattern(for: name))($|[^A-Za-z0-9_-])", options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case mission, targets, explicitlyAllowed, question, paused, every, dailyBudgetUSD, check, scope, mayMerge, mayDeploy
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mission = try values.decode(String.self, forKey: .mission)
        targets = try values.decodeIfPresent([AgentTarget].self, forKey: .targets)
            ?? (try values.decodeIfPresent([String].self, forKey: .scope) ?? []).map(AgentTarget.named)
        explicitlyAllowed = try values.decodeIfPresent([String].self, forKey: .explicitlyAllowed) ?? []
        if try values.decodeIfPresent(Bool.self, forKey: .mayMerge) == true, !explicitlyAllowed.contains("merge") { explicitlyAllowed.append("merge") }
        if try values.decodeIfPresent(Bool.self, forKey: .mayDeploy) == true, !explicitlyAllowed.contains("deploy") { explicitlyAllowed.append("deploy") }
        question = try values.decodeIfPresent(String.self, forKey: .question)
        paused = try values.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        every = try values.decodeIfPresent(TimeInterval.self, forKey: .every) ?? 300
        dailyBudgetUSD = try values.decodeIfPresent(Double.self, forKey: .dailyBudgetUSD) ?? 1
        check = try values.decodeIfPresent(Check.self, forKey: .check)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(mission, forKey: .mission)
        try values.encode(targets, forKey: .targets)
        try values.encode(explicitlyAllowed, forKey: .explicitlyAllowed)
        try values.encodeIfPresent(question, forKey: .question)
        try values.encode(paused, forKey: .paused)
        try values.encode(every, forKey: .every)
        try values.encode(dailyBudgetUSD, forKey: .dailyBudgetUSD)
        try values.encodeIfPresent(check, forKey: .check)
    }
}

struct JournalEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case action, refused, failed, stuck, undo, session, said, replied, handoff }
    var id = UUID()
    var at = Date()
    var kind: Kind
    var did: String
    var why: String
    var result: String?
    var link: String?
    var undo: String?
    var undoCommand: String?
    var undoText: String?
    var undoField: Int?
    var undoes: UUID?
    var claudeUSD: Double?
    var to: UUID?
}

extension AgentFolder {
    var missionFile: URL { url.appendingPathComponent("mission.json") }
    var journalFile: URL { url.appendingPathComponent("journal.jsonl") }

    var mission: AgentMission? {
        (try? Data(contentsOf: missionFile)).flatMap { try? JSONDecoder().decode(AgentMission.self, from: $0) }
    }

    func save(_ mission: AgentMission) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? encoder.encode(mission).write(to: missionFile, options: .atomic)
    }

    var journal: [JournalEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let text = (try? String(contentsOf: journalFile, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? decoder.decode(JournalEntry.self, from: Data($0.utf8)) }
    }

    func append(_ entry: JournalEntry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: journalFile) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: journalFile)
        }
    }
}

struct ActionGuard {
    enum Mode { case read, write, undo }

    static let bodyVariable = "BEAN_BODY_FILE"
    private static let interpreters: Set<String> = ["sudo", "su", "eval", "exec", "source", "sh", "bash", "zsh", "fish", "python", "python3", "node", "ruby", "perl", "php", "osascript", "curl", "wget", "ssh", "scp", "rsync", "nc", "open", "xargs", "env", "printenv", "security", "find", "awk", "sed", "tee", "dd", "rm", "mv", "cp", "chmod", "chown", "ln", "kill", "killall", "pkill", "launchctl", "defaults", "crontab", "claude"]
    private static let secrets = try! NSRegularExpression(pattern: #"auth\s+token|\.ssh\b|\.env\b|\.aws\b|\.netrc|keychain|credentials|id_rsa|api[_-]?key"#, options: .caseInsensitive)
    private static let discovery = try! NSRegularExpression(pattern: #"^(command -v \S+|which \S+|\S+( \S+)* (--help|-h)|\S+ (--version|-v|version)|\S+ auth status)$"#)
    private static let readWrites = try! NSRegularExpression(pattern: #"^(-X|--method|-f|-F|--field|--raw-field|--input|-m)$|^(--method|--field|--raw-field|--input)=|^(create|edit|comment|review|ready|close|reopen|lock|unlock|commit|push|checkout|switch|reset|rebase|tag|stash|add|apply|cherry-pick|revert|clean|clone|init|config|set|run|sync|rerun|cancel|enable|disable|fork)$"#)
    private static let dangerous = try! NSRegularExpression(pattern: #"dangerously|--yolo|bypass|--force|--admin|^--no-verify$|^login$|^logout$|^refresh$|^secret$|^token$"#, options: .caseInsensitive)
    private static let destructive = try! NSRegularExpression(pattern: #"\b(delete|remove|destroy|drop|purge|archive|transfer|rename|revoke)\b"#, options: .caseInsensitive)
    private static let merging = try! NSRegularExpression(pattern: #"\bmerge\b"#, options: .caseInsensitive)
    private static let deploying = try! NSRegularExpression(pattern: #"\b(deploy|publish|release|workflow)\b"#, options: .caseInsensitive)
    private static let mainBranch = try! NSRegularExpression(pattern: #"(^|:)(main|master|trunk|production)$"#)

    let mission: AgentMission
    var worktree: URL?
    var abilities: [AgentAbility]?

    func ability(for command: String) -> AgentAbility? {
        guard let tokens = Self.tokens(command.trimmingCharacters(in: .whitespacesAndNewlines))?.map(\.text) else { return nil }
        return abilities?.filter { tokens.starts(with: $0.id.split(separator: " ").map(String.init)) }.max { $0.id.count < $1.id.count }
    }

    func isUnknown(_ command: String) -> Bool {
        guard abilities != nil else { return false }
        guard let found = ability(for: command) else { return true }
        return found.id.split(separator: " ").count < AbilityFinder.words(of: command).count
    }

    func refusal(_ command: String, mode: Mode) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "empty command" }
        if let term = OffLimits.match(trimmed) { return "off limits: \(term)" }
        let whole = NSRange(trimmed.startIndex..., in: trimmed)
        if HiddenShell.blockedPattern.firstMatch(in: trimmed, range: whole) != nil { return "this command is never allowed" }
        if Self.secrets.firstMatch(in: trimmed, range: whole) != nil { return "secrets are off limits" }
        guard let tokens = Self.tokens(trimmed) else {
            return "one plain command only: no ; & | < > backticks, no $ except $\(Self.bodyVariable), no line breaks"
        }
        guard let first = tokens.first?.text, !first.contains("="), !Self.interpreters.contains(first) else {
            return "\(tokens.first?.text ?? "") is not allowed: use a command-line tool that does the job directly"
        }
        let bare = tokens.filter { !$0.quoted }.map(\.text)
        for token in bare where token == "-f" || Self.matches(Self.dangerous, token) { return "\(token) is never allowed" }
        for token in tokens where !token.text.trimmingCharacters(in: .whitespaces).contains(" ") {
            if let refusal = reach(token.text.trimmingCharacters(in: .whitespaces), tool: first, mode: mode) { return refusal }
        }
        if mode == .read, Self.discovery.firstMatch(in: trimmed, range: whole) != nil { return nil }
        guard worktree != nil || mission.covers(trimmed) else {
            return "outside your scope: the command must name one of \(mission.named)"
        }
        let matched = ability(for: trimmed)
        if let matched, !matched.allowed, mode == .write || matched.risk == .safe { return "\(matched.title) is turned off for this agent" }
        let irreversible = bare.first { Self.matches(Self.destructive, $0) || Self.matches(Self.merging, $0) || Self.matches(Self.deploying, $0) }
        switch mode {
        case .read:
            for token in bare where Self.matches(Self.readWrites, token) || Self.matches(Self.destructive, token) || Self.matches(Self.merging, token) {
                return "read tool: \(token) changes something, use your acting tool"
            }
        case .write:
            if abilities != nil, matched == nil { return "this action is not among your abilities" }
            if let irreversible, matched?.allowed != true { return "\(irreversible) cannot be undone and is turned off for this agent" }
        case .undo:
            if bare.contains(where: { Self.matches(Self.merging, $0) || Self.matches(Self.deploying, $0) }) { return "an undo cannot merge or deploy" }
            for token in bare where Self.matches(Self.destructive, token) {
                let inside = token.hasPrefix("--") || tokens.contains { token in mission.scope.contains { token.text.lowercased().contains($0.lowercased() + "/") } }
                if !inside { return "\(token) cannot be undone and is not allowed" }
            }
        }
        if mode != .read {
            if bare.contains("push"), bare.contains(where: { Self.matches(Self.mainBranch, $0) }) { return "pushing to the main branch is never allowed" }
            if bare.contains("push"), bare.first == "git", !bare.contains("HEAD") { return "git push must name HEAD, to push the current branch only" }
        }
        return nil
    }

    private func reach(_ token: String, tool: String, mode: Mode) -> String? {
        if token == "$\(Self.bodyVariable)" { return nil }
        let isAddress = token.contains("://") || token.contains("@")
        guard isAddress || token.contains("/") else { return nil }
        if mission.covers(token) { return nil }
        if let worktree, !isAddress {
            if tool == "git" { return nil }
            if !token.hasPrefix("/"), !token.contains(".."), FileManager.default.fileExists(atPath: worktree.appendingPathComponent(token).path) { return nil }
        }
        return "outside your scope: \(token)"
    }

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func tokens(_ command: String) -> [(text: String, quoted: Bool)]? {
        var tokens: [(String, Bool)] = []
        var current = "", quoted = false, quote: Character?, started = false
        func hasBody(_ rest: Substring) -> Bool { rest.hasPrefix(bodyVariable) }
        var rest = Substring(command)
        while let c = rest.first {
            rest = rest.dropFirst()
            if let open = quote {
                if c == open { quote = nil; continue }
                if open == "\"" {
                    if c == "`" || c == "\\" { return nil }
                    if c == "$" { guard hasBody(rest) else { return nil } }
                }
                current.append(c)
                continue
            }
            switch c {
            case "'", "\"":
                quote = c; quoted = true; started = true
            case " ", "\t":
                if started { tokens.append((current, quoted)) }
                current = ""; quoted = false; started = false
            case ";", "&", "|", "<", ">", "`", "\n", "\r", "(", ")", "{", "}", "\\", "*", "?", "~", "#", "!":
                return nil
            case "$":
                guard hasBody(rest) else { return nil }
                current.append(c); started = true
            default:
                current.append(c); started = true
            }
        }
        guard quote == nil else { return nil }
        if started { tokens.append((current, quoted)) }
        return tokens.map { (text: $0.0, quoted: $0.1) }
    }
}
