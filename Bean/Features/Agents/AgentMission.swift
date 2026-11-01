import Foundation

struct AgentMission: Equatable {
    struct Check: Codable, Equatable {
        var command: String?
        var tool: String?
        var arguments: String?
    }

    var mission: String
    var targets: [AgentTarget]
    var explicitlyAllowed: [String] = []
    var every: TimeInterval = 300
    var check: Check?

    init(mission: String, targets: [AgentTarget] = [], explicitlyAllowed: [String] = []) {
        self.mission = mission
        self.targets = targets
        self.explicitlyAllowed = explicitlyAllowed
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

    var isActive: Bool { !mission.isEmpty && !scope.isEmpty }
    var named: String { scope.joined(separator: ", ") }

    func covers(_ text: String) -> Bool {
        scope.contains { name in
            text.range(of: "(^|[^A-Za-z0-9_-])\(NSRegularExpression.escapedPattern(for: name))($|[^A-Za-z0-9_-])", options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}

struct JournalEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case action, refused, failed, stuck, undo, session, said, replied, handoff, notice }
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
    var to: UUID?
    // The person's own words, as against a click on a card.
    var typed: Bool?
}

extension AgentFolder {
    var journalFile: URL { url.appendingPathComponent("journal.jsonl") }

    var journal: [JournalEntry] { JournalReads.entries(of: journalFile) }

    func append(_ entry: JournalEntry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let line = try? encoder.encode(entry) else { return }
        JSONLines.append(line, to: journalFile)
    }
}

// A journal only grows, and it is read again and again on the main thread, so only what was added since the last read is decoded.
private enum JournalReads {
    private static let lock = NSLock()
    private static var known: [URL: (size: UInt64, entries: [JournalEntry])] = [:]

    static func entries(of file: URL) -> [JournalEntry] {
        guard let handle = try? FileHandle(forReadingFrom: file), let size = try? handle.seekToEnd() else {
            lock.withLock { known[file] = nil }
            return []
        }
        defer { try? handle.close() }
        let before = lock.withLock { known[file] }.flatMap { $0.size <= size ? $0 : nil }
        let start = before?.size ?? 0
        guard start < size else { return before?.entries ?? [] }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let end = data.lastIndex(of: 0x0A) else { return before?.entries ?? [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let added = data[..<end].split(separator: 0x0A).compactMap { try? decoder.decode(JournalEntry.self, from: Data($0)) }
        let entries = (before?.entries ?? []) + added
        lock.withLock { known[file] = (start + UInt64(end - data.startIndex + 1), entries) }
        return entries
    }
}

// O_APPEND, because several tasks and sessions write one file at the same time, and none may overwrite another.
enum JSONLines {
    static func append(_ line: Data, to file: URL) {
        let descriptor = open(file.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        (line + [0x0A]).withUnsafeBytes { _ = write(descriptor, $0.baseAddress, $0.count) }
    }
}

struct ActionGuard {
    enum Mode { case read, write, undo }

    static let bodyVariable = "BEAN_BODY_FILE"
    private static let runners: Set<String> = ["python", "python3", "node", "ruby", "perl", "php", "pytest", "npm", "npx", "yarn", "pnpm", "make", "cargo", "go", "swift", "bundle", "rake", "deno", "bun", "tsc", "jest", "mvn", "gradle"]
    private static let interpreters: Set<String> = ["sudo", "su", "eval", "exec", "source", "sh", "bash", "zsh", "fish", "python", "python3", "node", "ruby", "perl", "php", "osascript", "curl", "wget", "ssh", "scp", "rsync", "nc", "open", "xargs", "env", "printenv", "security", "find", "awk", "sed", "tee", "dd", "rm", "mv", "cp", "chmod", "chown", "ln", "kill", "killall", "pkill", "launchctl", "defaults", "crontab", "claude"]
    private static let secrets = try! NSRegularExpression(pattern: #"auth\s+token|\.ssh\b|\.env\b|\.aws\b|\.netrc|keychain|credentials|id_rsa|api[_-]?key"#, options: .caseInsensitive)
    private static let discovery = try! NSRegularExpression(pattern: #"^(command -v \S+|which \S+|\S+( \S+)* (--help|-h)|\S+ (--version|-v|version)|\S+ auth status)$"#)
    private static let readWrites = try! NSRegularExpression(pattern: #"^(-X|--method|-f|-F|--field|--raw-field|--input|-m)$|^(--method|--field|--raw-field|--input)=|^(create|edit|comment|review|ready|close|reopen|lock|unlock|commit|push|checkout|switch|reset|rebase|tag|stash|add|apply|cherry-pick|revert|clean|clone|init|config|set|run|sync|rerun|cancel|enable|disable|fork)$"#)
    private static let dangerous = try! NSRegularExpression(pattern: #"dangerously|--yolo|bypass|--force|--admin|^--no-verify$|^login$|^logout$|^refresh$|^secret$|^token$"#, options: .caseInsensitive)
    private static let destructive = try! NSRegularExpression(pattern: #"\b(delete|remove|destroy|drop|purge|archive|transfer|rename|revoke)\b"#, options: .caseInsensitive)
    private static let merging = try! NSRegularExpression(pattern: #"\bmerge\b"#, options: .caseInsensitive)
    private static let deploying = try! NSRegularExpression(pattern: #"\b(deploy|publish|release|workflow)\b"#, options: .caseInsensitive)
    static let mergeRefusal = "merging or marking ready is the user's call"
    private static let mergeCalls = try! NSRegularExpression(pattern: #"mergePullRequest|markPullRequestReadyForReview|enablePullRequestAutoMerge|/pulls/[0-9]+/merge|/repos/[^ ]+/merges\b"#)
    private static let mainBranch = try! NSRegularExpression(pattern: #"(^|:)(main|master|trunk|production)$"#)

    let mission: AgentMission
    var worktree: URL?
    var abilities: [AgentAbility]?
    var unknownAllowed = false

    func inWorkingCopy(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let whole = NSRange(trimmed.startIndex..., in: trimmed)
        guard let worktree, !worktree.path.contains("'"), OffLimits.match(trimmed) == nil, HiddenShell.blockedPattern.firstMatch(in: trimmed, range: whole) == nil,
              Self.secrets.firstMatch(in: trimmed, range: whole) == nil, let tokens = Self.tokens(trimmed) else { return nil }
        let unquoted = tokens.filter { !$0.quoted }.map(\.text)
        let assignments = unquoted.prefix { $0.range(of: #"^[A-Z_][A-Z0-9_]*="#, options: .regularExpression) != nil }
        guard let first = unquoted.dropFirst(assignments.count).first, Self.runners.contains(first) else { return nil }
        var line = trimmed
        if first.hasPrefix("python") { line = line.replacingOccurrences(of: "\(first) -I ", with: "\(first) ") }
        let home = NSHomeDirectory()
        let toolchains = [".nvm", ".pyenv", ".rbenv", ".cargo", ".rustup", ".swiftpm", ".npm", ".cache", "go", ".local/bin", ".local/lib", ".volta", ".bun", ".deno"].map { "(subpath \"\(home)/\($0)\")" }.joined(separator: " ")
        let profile = "(version 1)(allow default)(deny network*)(allow network* (local ip \"localhost:*\"))(deny file-write*)(allow file-write* (subpath \"\(worktree.path)\") (subpath \"/private/tmp\") (subpath \"/private/var/folders\") (subpath \"/dev\"))(deny file-read-data (subpath \"\(home)\"))(allow file-read-data (subpath \"\(worktree.path)\") \(toolchains))(deny file-read-data (regex #\"/\\.env(\\.[^/]*)?$\"))"
        return "/usr/bin/sandbox-exec -p '\(profile)' \(assignments.isEmpty ? "" : "/usr/bin/env ")\(line)"
    }

    static func chain(_ command: String) -> [String]? {
        var parts: [String] = [], current = "", quote: Character?
        var rest = Substring(command)
        while let c = rest.first {
            if let open = quote {
                if c == open { quote = nil }
            } else if c == "'" || c == "\"" {
                quote = c
            } else if rest.hasPrefix("&&") || c == ";" {
                parts.append(current)
                current = ""
                rest = rest.dropFirst(c == ";" ? 1 : 2)
                continue
            }
            current.append(c)
            rest = rest.dropFirst()
        }
        parts.append(current)
        let clean = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return clean.count > 1 ? clean : nil
    }

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
        if mode != .read, Self.mergeCalls.firstMatch(in: trimmed, range: whole) != nil { return Self.mergeRefusal }
        guard let tokens = Self.tokens(trimmed) else {
            return "one plain command only: no ; & | < > backticks, no $ except $\(Self.bodyVariable), no line breaks"
        }
        guard let first = tokens.first?.text, !first.contains("="), !Self.interpreters.contains(first) else {
            return "\(tokens.first?.text ?? "") is not allowed: use a command-line tool that does the job directly"
        }
        let bare = tokens.filter { !$0.quoted }.map(\.text)
        for token in bare where token == "-f" || Self.matches(Self.dangerous, token) { return "\(token) is never allowed" }
        if mode == .write, bare.contains(where: { Self.matches(Self.merging, $0) }) { return Self.mergeRefusal }
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
            if abilities != nil, matched == nil, !unknownAllowed { return "this action is not among your abilities" }
            if let irreversible, matched?.allowed != true { return "\(irreversible) cannot be undone and is turned off for this agent" }
        case .undo:
            if bare.contains(where: { Self.matches(Self.merging, $0) || Self.matches(Self.deploying, $0) }) { return "an undo cannot merge or deploy" }
            for token in bare where Self.matches(Self.destructive, token) {
                let inside = token.hasPrefix("--") || tokens.contains { token in mission.scope.contains { token.text.lowercased().contains($0.lowercased() + "/") } }
                if !inside { return "\(token) cannot be undone and is not allowed" }
            }
        }
        if mode != .read {
            if bare.starts(with: ["gh", "pr", "ready"]) || (bare.starts(with: ["gh", "pr", "create"]) && !bare.contains("--draft") && !bare.contains("-d")) { return "a pull request stays a draft" }
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
