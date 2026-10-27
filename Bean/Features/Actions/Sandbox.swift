import Foundation

enum Sandbox {
    static let readOnlyProfile = """
    (version 1)
    (allow default)
    (deny file-write*)
    (allow file-write* (literal "/dev/null") (literal "/dev/stdout") (literal "/dev/stderr") (literal "/dev/tty") (subpath "/private/var/folders") (subpath "/private/tmp"))
    (deny network*)
    (allow network* (local unix))
    (deny signal (target others))
    (deny appleevent-send)
    (deny process-exec (literal "/usr/bin/open") (literal "/usr/bin/osascript") (literal "/usr/bin/killall") (literal "/bin/kill"))
    """
    static let scriptWritePattern = try! NSRegularExpression(pattern: #"(?i)\b(set|make|delete|close|quit|open|activate|launch|reopen|save|print|move|duplicate|do\s+script|do\s+javascript|execute|click|keystroke|key\s+code|select|focus|run|log\s+out|restart|shut\s+down|empty)\b"#)

    static func read(_ command: String, in directory: String? = nil) -> ShellResult {
        let quotedProfile = VisibleTerminal.quoted(readOnlyProfile)
        let quotedCommand = VisibleTerminal.quoted(command)
        var result = HiddenShell.run("/usr/bin/sandbox-exec -p \(quotedProfile) /bin/zsh -c \(quotedCommand)", in: directory, timeout: 20)
        result = ShellResult(command: command, exit: result.exit, output: result.output, timedOut: result.timedOut, seconds: result.seconds)
        return result
    }

    static func readApp(_ source: String, bundleId: String) -> ToolOutput {
        let range = NSRange(source.startIndex..., in: source)
        if scriptWritePattern.firstMatch(in: source, range: range) != nil || source.lowercased().contains("tell application") {
            return ToolOutput(text: "refused: read_app only gets, counts and checks properties of the app it is given; write the inner script without tell, set, make, open, close or other changing verbs.", ok: false)
        }
        let result = Scripting.run(source, tellingApp: bundleId)
        return ToolOutput(text: result.note, ok: result.ok)
    }

    static let readTools: [BrainTool] = [
        BrainTool(name: "read_files", description: "Run a read-only shell command in a sandbox: no file writes, no network, no signals, no Apple Events. Use it to find and read the files where an app keeps its state (ls, find, cat, head, grep, plutil -p, sqlite3 'file:<path>?immutable=1', jq, python3 -I).", parameters: [
            "command": ["type": "string"],
        ], effect: .read) { args in
            let result = await Task.detached { read(args.string("command") ?? "") }.value
            return ToolOutput(text: "exit \(result.exit)\(result.timedOut ? " (timed out)" : "")\n\(result.output)", ok: result.exit == 0)
        },
        BrainTool(name: "read_app", description: "Run a read-only AppleScript inside one app (get, count, exists), for apps with a scripting dictionary.", parameters: [
            "bundleId": ["type": "string"], "script": ["type": "string", "description": "The inner script, without tell application."],
        ], effect: .read) { args in
            readApp(args.string("script") ?? "", bundleId: args.string("bundleId") ?? "")
        },
    ]
}
