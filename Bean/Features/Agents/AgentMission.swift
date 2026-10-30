import Foundation

struct AgentMission: Codable, Equatable {
    struct Check: Codable, Equatable {
        var command: String?
        var tool: String?
        var arguments: String?
    }

    var mission: String
    var scope: [String]
    var allowed: [String]
    var mayMerge = false
    var mayDeploy = false
    var every: TimeInterval = 300
    var check: Check?

    var isActive: Bool { !mission.isEmpty && !scope.isEmpty }
    var named: String { scope.joined(separator: ", ") }

    func covers(_ text: String) -> Bool {
        let lower = text.lowercased()
        return scope.contains { lower.contains($0.lowercased()) }
    }
}

struct JournalEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case action, refused, failed, stuck, undo, session }
    var id = UUID()
    var at = Date()
    var kind: Kind
    var did: String
    var why: String
    var result: String?
    var link: String?
    var undo: String?
    var undoCommand: String?
    var undoes: UUID?
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
    private static let dangerous = try! NSRegularExpression(pattern: #"dangerously|--yolo|bypass|--force|^-f$|--admin|^--no-verify$|^login$|^logout$|^refresh$|^secret$|^token$"#, options: .caseInsensitive)
    private static let destructive = try! NSRegularExpression(pattern: #"\b(delete|remove|destroy|drop|purge|archive|transfer|rename|revoke)\b"#, options: .caseInsensitive)
    private static let merging = try! NSRegularExpression(pattern: #"\bmerge\b"#, options: .caseInsensitive)
    private static let deploying = try! NSRegularExpression(pattern: #"\b(deploy|publish|release|workflow)\b"#, options: .caseInsensitive)
    private static let mainBranch = try! NSRegularExpression(pattern: #"(^|:)(main|master|trunk|production)$"#)

    let mission: AgentMission
    var worktree: URL?

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
        for token in bare where Self.matches(Self.dangerous, token) { return "\(token) is never allowed" }
        for token in tokens { if let refusal = reach(token.text, tool: first, mode: mode) { return refusal } }
        if mode == .read, Self.discovery.firstMatch(in: trimmed, range: whole) != nil { return nil }
        guard worktree != nil || mission.covers(trimmed) else {
            return "outside your scope: the command must name one of \(mission.named)"
        }
        switch mode {
        case .read:
            for token in bare where Self.matches(Self.readWrites, token) || Self.matches(Self.destructive, token) || Self.matches(Self.merging, token) {
                return "read tool: \(token) changes something, use your acting tool"
            }
        case .write, .undo:
            for token in bare where Self.matches(Self.destructive, token) {
                let inside = token.hasPrefix("--") || tokens.contains { token in mission.scope.contains { token.text.lowercased().contains($0.lowercased() + "/") } }
                if mode == .write || !inside { return "\(token) cannot be undone and is not allowed" }
            }
            if !mission.mayMerge { for token in bare where Self.matches(Self.merging, token) { return "merging is outside this agent's limits" } }
            if !mission.mayDeploy { for token in bare where Self.matches(Self.deploying, token) { return "deploying is outside this agent's limits" } }
            if bare.contains("push"), !mission.mayMerge, bare.contains(where: { Self.matches(Self.mainBranch, $0) }) { return "pushing to the main branch is outside this agent's limits" }
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
