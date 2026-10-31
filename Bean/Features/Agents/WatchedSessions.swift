import AppKit
import CryptoKit
import Foundation

// One row per coding tool that can run where the user watches. Only this value names the tool.
struct SessionDriver {
    let binary: String
    let knownFolders: String
    let terminal: String
    let events: [String]
    let answerSeconds: Int
    let toolCallLimit: Int
    let windowMarker: String
    let untrusted: String
    let limitsKept: String

    static let installed = SessionDriver(binary: "claude", knownFolders: ".claude.json", terminal: "Terminal",
                                         events: ["SessionStart", "PreToolUse", "PermissionRequest", "Stop", "StopFailure", "SessionEnd"],
                                         answerSeconds: 280, toolCallLimit: 150, windowMarker: "bean-session-",
                                         untrusted: "not trusted", limitsKept: "--settings")

    func start(name: String, settings: String, task: String) -> [String] {
        ["--bg", "--worktree", name, "--name", name, "--permission-mode", "acceptEdits", "--settings", settings] + modelChoice + [task]
    }

    // Options given here would make it a copy. The tool wakes a stopped session with the options it started with, and says so.
    func resume(id: String, text: String) -> [String] { ["--bg", "--resume", id, text] }

    func attach(_ id: String) -> [String] { ["attach", id] }
    func stop(_ id: String) -> [String] { ["stop", id] }
    func remove(_ id: String) -> [String] { ["rm", id] }
    func listing(in folder: String) -> [String] { ["agents", "--json", "--all", "--cwd", folder] }

    private var modelChoice: [String] {
        ProcessInfo.processInfo.environment["BEAN_SESSION_MODEL"].map { ["--model", $0] } ?? []
    }

    func settings(hook: String) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in events {
            var command: [String: Any] = ["type": "command", "command": "/bin/sh \"\(hook)\" \(event)"]
            if event == "PermissionRequest" { command["timeout"] = answerSeconds + 20 }
            hooks[event] = [["hooks": [command]]]
        }
        return ["hooks": hooks]
    }
}

enum SessionState: Equatable {
    case starting, working
    case waiting(String)
    case finished(String)
    case failed(String)
    case ended(String)

    var live: Bool {
        switch self {
        case .starting, .working, .waiting: return true
        default: return false
        }
    }

    var wakes: Bool { self != .starting && self != .working }

    var plain: String {
        switch self {
        case .starting: return "starting"
        case .working: return "working"
        case let .waiting(what): return "waiting for an answer: \(what)"
        case .finished: return "finished its turn"
        case let .failed(why): return "failed: \(why)"
        case let .ended(why): return "ended before finishing: \(why)"
        }
    }
}

struct SessionClaim: Codable {
    let key: String
    let session: String
    let agent: String
    let at: Date
}

// A claim is an exact id and nothing else. Whether two tasks are the same work is the model's call.
enum SessionClaims {
    private static func file(_ key: String, in root: URL) -> URL {
        let name = SHA256.hash(data: Data(key.lowercased().utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("claims").appendingPathComponent("\(name).json")
    }

    static func take(_ claim: SessionClaim, in root: URL) -> SessionClaim? {
        let target = file(claim.key, in: root)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(claim) else { return nil }
        let handle = open(target.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard handle >= 0 else { return holder(claim.key, in: root) }
        _ = data.withUnsafeBytes { write(handle, $0.baseAddress, $0.count) }
        close(handle)
        return nil
    }

    static func holder(_ key: String, in root: URL) -> SessionClaim? {
        (try? Data(contentsOf: file(key, in: root))).flatMap { try? JSONDecoder().decode(SessionClaim.self, from: $0) }
    }

    static func release(_ key: String, in root: URL) {
        try? FileManager.default.removeItem(at: file(key, in: root))
    }
}

extension ActionGuard {
    private static let wrappers: Set<String> = ["sudo", "env", "command", "exec", "nohup", "time", "xargs", "bash", "sh", "zsh", "eval", "-c", "-lc", "-l"]
    private static let mergeCalls = try! NSRegularExpression(pattern: #"mergePullRequest|markPullRequestReadyForReview|enablePullRequestAutoMerge|/pulls/[0-9]+/merge|/repos/[^ ]+/merges\b"#)
    private static let mainNames: Set<String> = ["main", "master", "trunk", "production"]

    // A watched session runs freely. Only what cannot be taken back stops here, whatever shell wraps it.
    static func stops(_ command: String, branch: () -> String?) -> String? {
        if let term = OffLimits.match(command) { return "off limits: \(term)" }
        let whole = NSRange(command.startIndex..., in: command)
        if HiddenShell.blockedPattern.firstMatch(in: command, range: whole) != nil { return "this command is never allowed" }
        if secretsPattern.firstMatch(in: command, range: whole) != nil { return "secrets are off limits" }
        if mergeCalls.firstMatch(in: command, range: whole) != nil { return "merging or marking ready is the user's call" }
        let separators = CharacterSet(charactersIn: "&|;\n`(){}")
        for part in command.components(separatedBy: separators) {
            var words = part.replacingOccurrences(of: "\"", with: " ").replacingOccurrences(of: "'", with: " ").split(whereSeparator: \.isWhitespace).map(String.init)
            while let first = words.first, wrappers.contains(first) || first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil { words.removeFirst() }
            if let refusal = stops(words: words, branch: branch) { return refusal }
        }
        return nil
    }

    private static func stops(words: [String], branch: () -> String?) -> String? {
        guard let tool = words.first else { return nil }
        let rest = Array(words.dropFirst())
        if tool == "git" {
            var plain = rest[...]
            while let first = plain.first, first.hasPrefix("-") {
                plain = plain.dropFirst(["-C", "-c", "--git-dir", "--work-tree"].contains(first) ? 2 : 1)
            }
            switch plain.first {
            case "merge": return "a merge is the user's call. To bring in main's changes, rebase your own branch"
            case "push":
                let args = plain.dropFirst()
                if args.contains(where: { $0.hasPrefix("--force") || $0 == "-f" || $0 == "--mirror" || $0 == "--all" || $0 == "--delete" || $0 == "-d" || $0.hasPrefix(":") }) { return "that push rewrites or removes what others see: it is the user's call" }
                let names = args.filter { !$0.hasPrefix("-") }.dropFirst().flatMap { $0.components(separatedBy: ":") }
                if names.contains(where: { mainNames.contains($0.replacingOccurrences(of: "refs/heads/", with: "")) }) { return "pushing to the main branch is never allowed" }
                if names.isEmpty || names.contains("HEAD"), let current = branch(), mainNames.contains(current) { return "you are on \(current), and pushing to the main branch is never allowed" }
            default: break
            }
            return nil
        }
        if tool == "gh" {
            let place = rest.prefix(2)
            if place.first == "pr" {
                switch place.dropFirst().first {
                case "merge", "ready": return "a pull request stays a draft and merging is the user's call"
                case "close": return "closing a pull request is the user's call"
                case "create" where !rest.contains("--draft") && !rest.contains("-d"): return "a pull request stays a draft: add --draft"
                case "review" where rest.contains("--approve") || rest.contains("-a"): return "approving is the user's call"
                default: break
                }
            }
            if place.first == "repo", let what = place.dropFirst().first, ["delete", "archive", "rename", "edit", "transfer"].contains(what) { return "changing the repo itself is the user's call" }
            if place.first == "release" || (place.first == "workflow" && place.dropFirst().first == "run") { return "releases and deployments are the user's call" }
            return nil
        }
        if rest.prefix(2).contains(where: { ["publish", "deploy"].contains($0) }) { return "publishing and deploying are the user's call" }
        return nil
    }
}

enum SessionHook {
    private static let flag = "--session-hook"

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return }
        let folder = URL(fileURLWithPath: args[index + 1])
        let driver = SessionDriver.installed
        guard let input = (try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile())) as? [String: Any], let event = input["hook_event_name"] as? String else { exit(1) }
        let tool = input["tool_name"] as? String
        let toolInput = input["tool_input"] as? [String: Any]
        let command = toolInput?["command"] as? String
        var line: [String: Any] = ["event": event, "at": Date().timeIntervalSince1970]
        for key in ["session_id", "cwd", "reason", "error", "error_details", "message", "notification_type"] { if let value = input[key] { line[key] = value } }
        if let tool { line["tool"] = tool }
        if let shown = command ?? toolInput.flatMap({ $0.json }) { line["shown"] = String(shown.prefix(600)) }
        if let last = input["last_assistant_message"] as? String { line["last"] = String(last.prefix(4000)) }
        var answer: [String: Any]?
        if event == "PreToolUse" {
            var refusal = BeanSettings.shared.effectivePaused ? "The user paused all agents. Stop here." : nil
            if refusal == nil { refusal = OffLimits.match(toolInput?.json ?? "").map { "off limits: \($0)" } }
            if refusal == nil, let command {
                refusal = ActionGuard.stops(command) {
                    (input["cwd"] as? String).map { HiddenShell.run("/usr/bin/git branch --show-current", in: $0, timeout: 5).output.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
            }
            if refusal == nil, count(of: "PreToolUse", in: folder) >= driver.toolCallLimit { refusal = "This session used its \(driver.toolCallLimit) tool calls. Stop and say where the work stands." }
            if let refusal {
                line["denied"] = refusal
                answer = ["hookEventName": event, "permissionDecision": "deny", "permissionDecisionReason": refusal]
            }
            else if let command, args.indices.contains(index + 2), allowed(command, repo: args[index + 2], cwd: input["cwd"] as? String) {
                answer = ["hookEventName": event, "permissionDecision": "allow", "permissionDecisionReason": "Inside this session's work."]
            }
        }
        append(line, to: folder)
        if event == "PermissionRequest" {
            let file = folder.appendingPathComponent("answer.json")
            try? FileManager.default.removeItem(at: file)
            let deadline = Date().addingTimeInterval(TimeInterval(driver.answerSeconds))
            while Date() < deadline {
                if let data = try? Data(contentsOf: file), let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    try? FileManager.default.removeItem(at: file)
                    var decision: [String: Any] = ["behavior": reply["allow"] as? Bool == true ? "allow" : "deny"]
                    if reply["allow"] as? Bool == true {
                        var updated = toolInput ?? [:]
                        if tool == "AskUserQuestion", let text = reply["text"] as? String, let questions = updated["questions"] as? [[String: Any]] {
                            updated["answers"] = Dictionary(uniqueKeysWithValues: questions.compactMap { ($0["question"] as? String).map { ($0, text) } })
                        }
                        decision["updatedInput"] = updated
                    } else {
                        decision["message"] = reply["text"] as? String ?? "Refused."
                    }
                    answer = ["hookEventName": event, "decision": decision]
                    break
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        if let answer, let data = try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": answer]) {
            FileHandle.standardOutput.write(data)
        }
        exit(0)
    }

    // The plain steps of the job need no one's answer: each part passes the same rule the unseen route uses.
    private static func allowed(_ command: String, repo: String, cwd: String?) -> Bool {
        guard let cwd else { return false }
        let check = ActionGuard(mission: AgentMission(mission: "", scope: [repo]), worktree: URL(fileURLWithPath: cwd), abilities: nil, unknownAllowed: true)
        return (ActionGuard.chain(command) ?? [command]).allSatisfy { check.refusal($0, mode: .write) == nil }
    }

    private static func count(of event: String, in folder: URL) -> Int {
        ((try? String(contentsOf: folder.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.contains("\"event\":\"\(event)\"") }.count
    }

    static func append(_ line: [String: Any], to folder: URL) {
        guard var data = try? JSONSerialization.data(withJSONObject: line) else { return }
        data.append(0x0A)
        let handle = open(folder.appendingPathComponent("events.jsonl").path, O_CREAT | O_APPEND | O_WRONLY, 0o600)
        guard handle >= 0 else { return }
        _ = data.withUnsafeBytes { write(handle, $0.baseAddress, $0.count) }
        close(handle)
    }

    static func script(for folder: URL, repo: String) -> String {
        let binary = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return """
        #!/bin/sh
        "\(binary)" \(flag) "\(folder.path)" "\(repo)"
        code=$?
        [ $code = 0 ] && exit 0
        [ "$1" = "PreToolUse" ] || exit 0
        echo "Bean's guard could not run, so this is refused." >&2
        exit 2
        """
    }
}

extension CodingSessions {
    private var driver: SessionDriver { .installed }

    func folder(of session: CodingSession) -> URL { sessionsRoot.appendingPathComponent(session.id) }

    static func checkout(of repo: String, driver: SessionDriver = .installed) -> String? {
        guard ProcessInfo.processInfo.environment["BEAN_NO_TRUSTED_CHECKOUT"] == nil else { return nil }
        let wanted = repo.lowercased()
        guard let data = try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(driver.knownFolders)),
              let projects = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["projects"] as? [String: Any] else { return nil }
        return projects.keys.filter { path in
            guard !path.contains("/.claude/worktrees/"), let config = try? String(contentsOfFile: "\(path)/.git/config", encoding: .utf8) else { return false }
            return config.lowercased().split(separator: "\n").contains { $0.contains("url =") && ($0.contains("/\(wanted)") || $0.contains(":\(wanted)")) }
        }.min { $0.count < $1.count }
    }

    private func tool(_ arguments: [String], in directory: URL) -> (exit: Int32, output: String) {
        let binary = HiddenShell.run("command -v \(driver.binary)", timeout: 10).output.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.run("/bin/zsh", ["-lc", "exec \"$0\" \"$@\"", binary] + arguments, in: directory)
    }

    func startWatched(repo: String, checkout: String, task: String, workId: String) -> Result<CodingSession, ToolFailure> {
        Self.creating.lock()
        defer { Self.creating.unlock() }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        var session = CodingSession(id: id, repo: repo, branch: "", worktree: "")
        session.watched = true
        session.task = task
        session.workId = workId
        session.startedAt = Date()
        session.checkout = checkout
        let place = URL(fileURLWithPath: checkout)
        session.mainAt = Self.remoteHead(in: place)
        session.localMainAt = Self.localMain(in: place)
        let home = folder(of: session)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let name = "bean-\(id)"
        let hook = home.appendingPathComponent("hook.sh")
        let settings = home.appendingPathComponent("settings.json")
        try? SessionHook.script(for: home, repo: repo).write(to: hook, atomically: true, encoding: .utf8)
        try? JSONSerialization.data(withJSONObject: driver.settings(hook: hook.path)).write(to: settings)
        let started = tool(driver.start(name: name, settings: settings.path, task: task), in: place)
        guard started.exit == 0, let short = started.output.firstMatch(of: /backgrounded\s+·\s+(\w+)/)?.1 else {
            try? FileManager.default.removeItem(at: home)
            return .failure(ToolFailure(started.output.isEmpty ? "the session did not start" : String(started.output.prefix(500))))
        }
        session.toolId = String(short)
        session.worktree = "\(checkout)/.claude/worktrees/\(name)"
        session.branch = Self.run("/usr/bin/git", ["branch", "--show-current"], in: URL(fileURLWithPath: session.worktree)).output.trimmingCharacters(in: .whitespacesAndNewlines)
        session.claudeSession = listed(in: checkout)?[String(short)]?["sessionId"] as? String
        session.window = openWindow(for: session, in: home)?.number
        save(session)
        return .success(session)
    }

    private func openWindow(for session: CodingSession, in home: URL) -> OpenWindow? {
        guard let id = session.toolId else { return nil }
        let binary = HiddenShell.run("command -v \(driver.binary)", timeout: 10).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let script = home.appendingPathComponent("\(driver.windowMarker)\(session.id).command")
        let attach = driver.attach(id).map { "\"\($0)\"" }.joined(separator: " ")
        let text = """
        #!/bin/zsh -l
        cd "\(session.worktree)"
        while :; do
          "\(binary)" \(attach)
          until [ -e "\(home.path)/go" ] || [ -e "\(home.path)/end" ]; do sleep 1; done
          [ -e "\(home.path)/end" ] && exit 0
          rm -f "\(home.path)/go"
        done
        """
        try? text.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let before = Set(WindowChannels.open().map(\.number))
        _ = Self.run("/usr/bin/open", ["-g", "-a", driver.terminal, script.path], in: home)
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.25)
            let now = WindowChannels.open()
            if let found = now.first(where: { ($0.title ?? "").contains(script.lastPathComponent) }) ?? now.first(where: { $0.app == driver.terminal && !before.contains($0.number) }) { return found }
        }
        return nil
    }

    func window(of session: CodingSession) -> OpenWindow? {
        guard let number = session.window else { return nil }
        return WindowChannels.open().first { $0.number == number }
    }

    func listed(in checkout: String) -> [String: [String: Any]]? {
        let result = tool(driver.listing(in: checkout), in: URL(fileURLWithPath: checkout))
        guard result.exit == 0, let rows = (try? JSONSerialization.jsonObject(with: Data(result.output.utf8))) as? [[String: Any]] else { return nil }
        return Dictionary(rows.compactMap { row in (row["id"] as? String).map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
    }

    func events(of session: CodingSession) -> [[String: Any]] {
        ((try? String(contentsOf: folder(of: session).appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? "").split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    // Events say what happened; the tool's own list only fills what events cannot say. Silence is never a verdict.
    func state(of session: CodingSession, rows: [String: [String: Any]]?) -> SessionState { reading(of: session, rows: rows).state }

    // `event` is the line that decides, so the same happening reads the same on every look.
    func reading(of session: CodingSession, rows: [String: [String: Any]]?) -> (state: SessionState, event: Int) {
        let events = events(of: session)
        let row = session.toolId.flatMap { rows?[$0] }
        var endedBecause: String?
        var endedAt = 0
        for (index, event) in events.enumerated().reversed() {
            switch event["event"] as? String {
            case "Stop": return (.finished(event["last"] as? String ?? ""), index)
            case "StopFailure": return (.failed(event["error"] as? String ?? event["error_details"] as? String ?? "the tool reported a failure"), index)
            case "SessionEnd":
                if endedBecause == nil { endedBecause = event["reason"] as? String ?? "it was stopped"; endedAt = index }
            case "PermissionRequest":
                if let endedBecause { return (.ended(endedBecause), endedAt) }
                if let row, row["state"] as? String != "blocked" { return (.working, index) }
                return (.waiting("\(event["tool"] as? String ?? "a tool"): \(event["shown"] as? String ?? "")"), index)
            case "SessionStart", "PreToolUse", "Told":
                if let endedBecause { return (.ended(endedBecause), endedAt) }
                if let row, row["state"] as? String == "blocked" { return (.waiting(row["waitingFor"] as? String ?? "something in the terminal"), index) }
                if rows != nil, row == nil { return (.ended("the tool no longer lists it"), index) }
                if let row, row["pid"] == nil || row["pid"] is NSNull { return (.ended("its process is gone"), index) }
                return (.working, index)
            default: continue
            }
        }
        if let endedBecause { return (.ended(endedBecause), endedAt) }
        if rows != nil, row == nil { return (.ended("the tool no longer lists it"), 0) }
        return (.starting, 0)
    }

    func quietSeconds(_ session: CodingSession) -> Int {
        let events = events(of: session)
        return Int(Date().timeIntervalSince1970 - (events.last?["at"] as? Double ?? Date().timeIntervalSince1970))
    }

    var pendingQuestion: (CodingSession) -> Bool {
        { session in
            guard let last = self.events(of: session).last, last["event"] as? String == "PermissionRequest", let at = last["at"] as? Double else { return false }
            return Date().timeIntervalSince1970 - at < Double(self.driver.answerSeconds) - 5
        }
    }

    func answer(_ session: CodingSession, allow: Bool, text: String?) {
        var reply: [String: Any] = ["allow": allow]
        if let text { reply["text"] = text }
        try? JSONSerialization.data(withJSONObject: reply).write(to: folder(of: session).appendingPathComponent("answer.json"), options: .atomic)
        SessionHook.append(["event": "Told", "at": Date().timeIntervalSince1970], to: folder(of: session))
    }

    // Same id, same folder, Bean's limits passed again. Only an id the tool does not know starts over.
    func tell(_ session: CodingSession, text: String) -> Result<CodingSession, ToolFailure> {
        guard let id = session.claudeSession ?? session.toolId else { return .failure(ToolFailure("this session has no id to resume")) }
        guard FileManager.default.fileExists(atPath: session.worktree) else { return .failure(ToolFailure("its folder \(session.worktree) is gone, so it cannot resume there")) }
        let place = URL(fileURLWithPath: session.worktree)
        if let short = session.toolId, let checkout = session.checkout, let rows = listed(in: checkout), rows[short] == nil {
            var ended = session
            ended.open = false
            save(ended)
            return startWatched(repo: session.repo, checkout: checkout, task: "\(session.task ?? "")\n\n\(text)", workId: session.workId ?? session.id)
        }
        if let short = session.toolId {
            _ = tool(driver.stop(short), in: place)
            for _ in 0..<20 where session.checkout.flatMap({ listed(in: $0)?[short]?["pid"] as? Int }) != nil { Thread.sleep(forTimeInterval: 0.5) }
        }
        let home = folder(of: session)
        let resumed = tool(driver.resume(id: id, text: text), in: place)
        guard resumed.exit == 0, resumed.output.contains("backgrounded") else { return .failure(ToolFailure(String(resumed.output.prefix(500)))) }
        if !resumed.output.contains(driver.limitsKept) {
            if let short = session.toolId { _ = tool(driver.stop(short), in: place) }
            return .failure(ToolFailure("it woke without Bean's limits, so it was stopped again: \(resumed.output.prefix(300))"))
        }
        var told = session
        if let short = resumed.output.firstMatch(of: /backgrounded\s+·\s+(\w+)/)?.1, String(short) != session.toolId {
            _ = tool(driver.stop(String(short)), in: place)
            _ = tool(driver.remove(String(short)), in: place)
            return .failure(ToolFailure("the session was still stopping, so nothing was told. Try again"))
        }
        if let short = session.toolId, let checkout = session.checkout, let cwd = listed(in: checkout)?[short]?["cwd"] as? String, cwd != session.worktree {
            _ = tool(driver.stop(short), in: place)
            return .failure(ToolFailure("it woke in \(cwd), not in its own folder \(session.worktree), so it was stopped again"))
        }
        told.open = true
        told.wokenFor = nil
        save(told)
        SessionHook.append(["event": "Told", "at": Date().timeIntervalSince1970], to: home)
        FileManager.default.createFile(atPath: home.appendingPathComponent("go").path, contents: nil)
        return .success(told)
    }

    func endWatched(_ session: CodingSession) -> String? {
        var ended = session
        ended.open = false
        save(ended)
        let home = folder(of: session)
        FileManager.default.createFile(atPath: home.appendingPathComponent("end").path, contents: nil)
        guard let short = session.toolId else { return nil }
        let place = URL(fileURLWithPath: session.checkout ?? NSHomeDirectory())
        let removed = tool(driver.remove(short), in: place)
        return removed.exit == 0 ? nil : String(removed.output.prefix(400))
    }

    func facts(_ session: CodingSession, state: SessionState) -> String {
        var session = self.session(session.id) ?? session
        let events = events(of: session)
        if !session.worktree.isEmpty {
            let current = Self.run("/usr/bin/git", ["branch", "--show-current"], in: URL(fileURLWithPath: session.worktree)).output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !current.isEmpty { session.branch = current }
        }
        save(session)
        let pull = pullRequest(session)
        let denied = events.compactMap { $0["denied"] as? String }.suffix(5)
        var lines = ["Session \(session.id) \(state.plain). It ran in \(session.worktree), on branch \(session.branch)."]
        if case let .finished(last) = state { lines.append("Its last message:\n\(last.prefix(1500))") }
        lines.append("Pull request: \(pull?.facts ?? "none on that branch").")
        if !denied.isEmpty { lines.append("Refused in the session: \(denied.joined(separator: "; "))") }
        lines.append("Quiet for \(quietSeconds(session)) seconds. Silence alone says nothing about a session.")
        if let moved = mainMoved(session) { lines.append("WARNING: \(moved)") }
        lines.append(changes(session))
        return lines.joined(separator: "\n")
    }
}

extension AgentWorker {
    func watchedTools(_ agent: Agent, _ mission: AgentMission, _ folder: AgentFolder, sessions: CodingSessions, refusal: @escaping (String, String) -> String?) -> [BrainTool] {
        let reposHere = CodeRepos.known.filter { CodingSessions.checkout(of: $0.name) != nil }.map(\.name).joined(separator: ", ")
        var watch = BrainTool(name: "session_watch", description: "Get code written where the user can watch it: start a coding session in its own terminal window, on its own branch of the repo's folder on this Mac. Repos with a folder here: \(reposHere.isEmpty ? "none" : reposHere). The session does the whole job: it works on its own branch, commits, pushes it and opens a draft pull request. This returns at once. Then finish your run: you are woken with the facts when the session stops or asks something, with nothing to wait for.", parameters: [
            "repo": ["type": "string", "description": "The repo's owner/name."],
            "work_id": ["type": "string", "description": "The exact id of this work: the one you were given, or its ticket id. The same id can only run once at a time."],
            "task": ["type": "string", "description": "The full task, for a colleague who knows nothing yet: what to change, why, what done looks like. Say that it works on its own branch, commits and pushes that branch, opens a draft pull request and gives the link, and that it merges nothing. It leaves trackers and other connected services alone."],
            "why": ["type": "string", "description": "Why, in one sentence."],
        ], required: ["repo", "work_id", "task", "why"], effect: .read) { [weak self] args in
            guard let self, let repo = args.string("repo"), let task = args.string("task"), let workId = args.string("work_id") else { return ToolOutput(text: "repo, work_id and task are needed", ok: false) }
            let why = args.string("why") ?? ""
            if await MainActor.run(body: { self.isOverBudget(agent) }) { return ToolOutput(text: "your budget for today is spent: call finish now", ok: false) }
            if let refused = refusal(repo, "https://github.com/\(repo).git") {
                await MainActor.run { self.note(.refused, "Start a watched session on \(repo): \(task.prefix(240))", why, refused, agent) }
                return ToolOutput(text: "refused: \(refused)", ok: false)
            }
            guard let checkout = await Task.detached(operation: { CodingSessions.checkout(of: repo) }).value else {
                return ToolOutput(text: "\(repo) has no folder on this Mac, so it cannot run where the user watches. session_drive works from a fresh copy, unseen. If the user asked to watch it, ask_user.", ok: false)
            }
            let root = await MainActor.run { self.storeForBrain.root }
            if let held = await self.claim(workId, session: "pending", agent: agent, root: root) { return ToolOutput(text: held, ok: false) }
            let outcome = await Task.detached { sessions.startWatched(repo: repo, checkout: checkout, task: task, workId: workId) }.value
            switch outcome {
            case let .failure(failure):
                SessionClaims.release(workId, in: root)
                if failure.message.localizedCaseInsensitiveContains(SessionDriver.installed.untrusted) {
                    await MainActor.run {
                        self.raise(AgentNeed(kind: .decision, question: "To work in \(checkout) where you can watch, the folder must be trusted first. Open it once with \(SessionDriver.installed.binary) in a terminal and accept, then answer here.", options: ["Done, it is trusted", "Run it unseen instead"], task: self.doing[agent.id]), agent: agent)
                    }
                    return ToolOutput(text: "The folder is not trusted, and only the user can trust it. Bean asked them. Stop this task and call finish.", ok: false)
                }
                await MainActor.run { self.note(.failed, "Start a watched session on \(repo)", why, failure.message, agent) }
                return ToolOutput(text: failure.message, ok: false)
            case let .success(session):
                SessionClaims.release(workId, in: root)
                _ = SessionClaims.take(SessionClaim(key: workId, session: session.id, agent: agent.name, at: Date()), in: root)
                let window = await Task.detached { sessions.window(of: session) }.value
                await MainActor.run {
                    self.note(.session, "Started a session on \(session.repo) in a terminal window: \(task.prefix(120))", why, "", agent)
                    self.markUsed(SessionDriver.installed.binary, by: agent)
                    if let window, self.storeForBrain.agents.first(where: { $0.id == agent.id })?.attachment == nil || self.placedForWork(agent.id) || self.placedWithoutTheUser(agent.id) { self.place(agent, on: window) }
                    self.sessionWindows.formUnion(session.window.map { [$0] } ?? [])
                }
                return ToolOutput(text: "Session \(session.id) started on branch \(session.branch), in \(window.map { "terminal window \($0.number)" } ?? "the background: its window did not open, so say so in your summary"). Do not start this work again. Finish your run now: you are woken with the facts when it stops or asks something.")
            }
        }
        watch.runsAtOnce = true
        var tell = BrainTool(name: "session_tell", description: "Answer or continue a watched session, by its id: it stays the same session on the same branch. Use text to tell it something, whether it is waiting or has stopped. If it waits on a permission, set allow as well. Only what your mission covers: anything that cannot be undone goes to the user with ask_user instead.", parameters: [
            "session": ["type": "string"],
            "text": ["type": "string", "description": "What to tell it, or your answer to its question."],
            "allow": ["type": "boolean", "description": "If it waits on a permission or a question: true to go ahead, with text as the answer to a question; false to refuse, with text as the reason."],
            "why": ["type": "string", "description": "Why, in one sentence."],
        ], required: ["session", "text", "why"], effect: .read) { [weak self] args in
            guard let self, let id = args.string("session"), let text = args.string("text"), let session = sessions.session(id), session.watched == true else { return ToolOutput(text: "no watched session with that id", ok: false) }
            let why = args.string("why") ?? ""
            if await MainActor.run(body: { self.isOverBudget(agent) }) { return ToolOutput(text: "your budget for today is spent: call finish now", ok: false) }
            if sessions.pendingQuestion(session), let allow = args["allow"] as? Bool {
                sessions.answer(session, allow: allow, text: text)
                await MainActor.run { self.note(.session, "\(allow ? "Allowed" : "Refused") what session \(id) asked: \(text.prefix(160))", why, "", agent) }
                return ToolOutput(text: "Told. Finish your run: you are woken when it stops or asks again.")
            }
            await MainActor.run { self.telling.insert(id) }
            let outcome = await Task.detached { sessions.tell(session, text: text) }.value
            await MainActor.run { self.telling.remove(id) }
            switch outcome {
            case let .failure(failure):
                await MainActor.run { self.note(.failed, "Could not tell session \(id)", why, failure.message, agent) }
                return ToolOutput(text: failure.message, ok: false)
            case let .success(told):
                await MainActor.run {
                    self.note(.session, told.id == id ? "Told session \(id): \(text.prefix(160))" : "The tool no longer knew session \(id), so \(told.id) started over", why, "", agent)
                    self.sessionWindows.formUnion(told.window.map { [$0] } ?? [])
                }
                return ToolOutput(text: "\(told.id == id ? "Told" : "Started over as \(told.id)"). Finish your run: you are woken when it stops or asks again.")
            }
        }
        tell.runsAtOnce = true
        let look = BrainTool(name: "session_look", description: "See where a watched session stands now: its state, branch, pull request and changes.", parameters: ["session": ["type": "string"]], required: ["session"], effect: .read) { args in
            guard let id = args.string("session"), let session = sessions.session(id), session.watched == true else { return ToolOutput(text: "no watched session with that id", ok: false) }
            return await Task.detached {
                let rows = session.checkout.flatMap { sessions.listed(in: $0) }
                return ToolOutput(text: sessions.facts(session, state: sessions.state(of: session, rows: rows)))
            }.value
        }
        return [watch, tell, look]
    }

    func claim(_ workId: String, session: String, agent: Agent, root: URL) async -> String? {
        let mine = SessionClaim(key: workId, session: session, agent: agent.name, at: Date())
        guard let held = SessionClaims.take(mine, in: root) else {
            await MainActor.run { note(.session, "Took work \(workId)", "", "", agent) }
            return nil
        }
        let holder = await MainActor.run { self.storeForBrain.agents.first { $0.name == held.agent } }
        let found = await MainActor.run { holder.map { CodingSessions(folder: AgentFolder($0, in: self.storeForBrain)) } }
        let session = found?.session(held.session)
        let stale = held.session != "pending" && (session == nil || session?.open == false)
        let old = held.session == "pending" && Date().timeIntervalSince(held.at) > 120
        if stale || old {
            await MainActor.run { note(.session, "Released work \(workId), which session \(held.session) no longer holds", "", "", agent) }
            SessionClaims.release(workId, in: root)
            return await claim(workId, session: mine.session, agent: agent, root: root)
        }
        await MainActor.run { note(.refused, "Work \(workId) is already held", "", "\(held.agent), session \(held.session)", agent) }
        return "Not started: work id \(workId) is held by \(held.agent), session \(held.session), since \(held.at.formatted(date: .omitted, time: .shortened)). Do not do it again: use that session's result, or tell \(held.agent) through Bean. If you judge this is really different work, give it its own id."
    }

    func releaseClaim(of session: CodingSession, agent: Agent, why: String) {
        guard let workId = session.workId, SessionClaims.holder(workId, in: storeForBrain.root)?.session == session.id else { return }
        SessionClaims.release(workId, in: storeForBrain.root)
        note(.session, "Released work \(workId)", why, "", agent)
    }

    var liveWatchedSessions: [(agent: Agent, session: CodingSession)] {
        storeForBrain.agents.flatMap { agent -> [(Agent, CodingSession)] in
            let folder = AgentFolder(agent, in: storeForBrain)
            guard !folder.needs.contains(where: \.blocksRuns) else { return [] }
            let sessions = CodingSessions(folder: folder)
            return sessions.all.filter { $0.watched == true && $0.open && sessions.state(of: $0, rows: nil).live }.map { (agent, $0) }
        }
    }

    var sessionsStillMoving: Bool { heldPlan != nil || settlingPlan || movingSessions > 0 || !liveWatchedSessions.isEmpty || storeForBrain.agents.contains { isBusy($0.id) } }

    func startWatchingSessions() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.lookAtSessions() }
        }
    }

    private static let listEvery: TimeInterval = 15

    @MainActor
    private func lookAtSessions() async {
        guard !lookingAtSessions else { return }
        let found = storeForBrain.agents.flatMap { agent -> [(Agent, AgentFolder, CodingSession)] in
            let folder = AgentFolder(agent, in: storeForBrain)
            return CodingSessions(folder: folder).all.filter { $0.watched == true && $0.open }.map { (agent, folder, $0) }
        }
        guard !found.isEmpty else { return }
        lookingAtSessions = true
        defer { lookingAtSessions = false }
        sessionWindows.formUnion(found.compactMap(\.2.window))
        let list = Date().timeIntervalSince(listedSessionsAt) >= Self.listEvery
        if list { listedSessionsAt = Date() }
        let quiet = telling
        let moved = await Task.detached { () -> [(Agent, AgentFolder, CodingSession, SessionState, String)] in
            var rowsByFolder: [String: [String: [String: Any]]] = [:]
            return found.compactMap { agent, folder, session in
                guard !quiet.contains(session.id) else { return nil }
                let sessions = CodingSessions(folder: folder)
                var rows: [String: [String: Any]]?
                if list, let checkout = session.checkout {
                    rows = rowsByFolder[checkout] ?? sessions.listed(in: checkout)
                    rowsByFolder[checkout] = rows
                }
                let (state, event) = sessions.reading(of: session, rows: rows)
                let key = "\(event) \(state.plain.prefix(60))"
                guard state.wakes, session.wokenFor != key, !quiet.contains(session.id) else { return nil }
                return (agent, folder, session, state, key)
            }
        }.value
        for (agent, folder, session, state, key) in moved {
            var woken = session
            woken.wokenFor = key
            CodingSessions(folder: folder).save(woken)
            Self.log.append(Entry(agent: agent.name, event: "sessionMoved", detail: "\(session.id) \(state.plain.prefix(120))"))
            Task { @MainActor in await self.sessionMoved(agent, folder: folder, session: woken, state: state) }
        }
    }

    @MainActor
    private func sessionMoved(_ agent: Agent, folder: AgentFolder, session: CodingSession, state: SessionState) async {
        movingSessions += 1
        defer { movingSessions -= 1 }
        let sessions = CodingSessions(folder: folder)
        let facts = await Task.detached { sessions.facts(session, state: state) }.value
        let current = sessions.session(session.id) ?? session
        if let pull = await Task.detached(operation: { sessions.pullRequest(current) }).value, !folder.journal.contains(where: { $0.link == pull.link }) {
            record(JournalEntry(kind: .session, did: "The session opened a pull request", why: "", result: pull.facts, link: pull.link), agent)
        }
        if let moved = await Task.detached(operation: { sessions.mainMoved(current) }).value { note(.failed, "Main moved during a session on \(current.repo)", "", moved, agent) }
        if case .ended = state { releaseClaim(of: current, agent: agent, why: state.plain) }
        if case .failed = state { releaseClaim(of: current, agent: agent, why: state.plain) }
        let ask: String
        switch state {
        case .waiting: ask = "It waits for an answer. If your mission covers it, answer with session_tell. If it cannot be undone or only the user can say, ask_user once and stop."
        case .finished: ask = "Check this against what you asked. If it stopped short, tell it what is missing with session_tell, the same session on the same branch. If it asks something your mission covers, answer the same way. If the job is done, finish and give the pull request link."
        default: ask = "Decide: continue it with session_tell, the same session on the same branch, or say plainly what could not be done."
        }
        let result = await runHandedOff(agent, task: "What it was asked: \(current.task?.prefix(1200) ?? "")\n\n\(facts)\n\n\(ask)", trigger: "Your coding session moved")
        Self.log.append(Entry(agent: agent.name, event: "sessionAnswered", detail: "\(session.id) \(result.prefix(200))"))
        guard !state.live else { return await planMayBeSettled() }
        teamResults.append("\(agent.name), session \(session.id): \(result.prefix(600))")
        heardFromSession = "\(agent.name), session \(session.id): \(result.prefix(600))"
        await planMayBeSettled()
    }

    @MainActor
    func planMayBeSettled() async {
        guard movingSessions == 1, liveWatchedSessions.isEmpty, !settlingPlan else { return }
        guard let bean = storeForBrain.agents.first(where: \.isBean) else { return }
        guard let held = heldPlan else {
            if !isBusy(bean.id), let heard = heardFromSession { wake("\(heard)") }
            heardFromSession = nil
            return
        }
        settlingPlan = true
        defer { settlingPlan = false }
        while isBusy(bean.id) { try? await Task.sleep(for: .seconds(1)) }
        heldPlan = nil
        heardFromSession = nil
        await reportHeldPlan(held, bean: bean)
    }
}
