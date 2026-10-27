import Foundation

/// Says what any window shows, without code for its app: Muse Spark investigates once per app in a read-only sandbox,
/// then writes a reader that Bean replays for the next windows of that app without a model call.
final class ContentReader {
    static let describeRounds = 16
    static let readerRounds = 6
    static let retryAfter: TimeInterval = 1800
    static let toolsHelp = "run_shell runs in a read-only sandbox (no writes, no open, no Apple Events: osascript fails there, and so do ps and other setuid tools; "
        + "the app's processes are already in the window facts). read_app runs a read-only AppleScript told to this window's app: write the inner script, "
        + "without tell, with get, count or exists only; its dictionary (sdef) says what it can tell, such as which tab, document or terminal a window holds."
    static let describePrompt = """
    You are Bean, an agent on the user's Mac. A window is described below with what Bean can read about any window: its app, title, \
    the app's child processes with their working directories, and files the app wrote in the last minutes (they often say what it shows: ids, paths, focus times). \
    Find out exactly what this window shows (which document, folder, page, conversation, session, command...) and the handle that would reopen exactly that later. \
    \(toolsHelp) Call describe as soon as you know: the description, and the handle (ids, absolute paths, URLs, titles: string values only). \
    When a command was running in the window, put it in the handle as running_command, and the directory it ran in as cwd, apart from what reopens the window itself.
    """
    static let readerPrompt = """
    Now write a reader so Bean can tell the same for any window of this app without you: something that prints the handle as one JSON object \
    with the same keys, from {title}, {pid} and {windowId} placeholders: either one read-only zsh command (same sandbox; python3 -c works), \
    or "applescript:" followed by a read-only inner AppleScript for this app. Test it with the placeholders filled in, then call keep_reader. \
    Call keep_reader with an empty reader if nothing can tell this app's windows apart.
    """

    private let client: ModelClient
    private let log: JSONLog
    private let readersURL: URL
    private var readers: [String: String]
    private var failed: [String: Date] = [:]

    init(client: ModelClient, log: JSONLog) {
        self.client = client
        self.log = log
        readersURL = log.url.deletingLastPathComponent().appendingPathComponent("readers.json")
        readers = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: readersURL))) ?? [:]
    }

    func describe(_ facts: WindowFacts) async -> WindowContent? {
        if let reader = readers[facts.bundleId], let handle = replay(reader, facts) {
            log.append(Entry(at: Date(), bundleId: facts.bundleId, title: facts.title, how: "reader", handle: handle, rounds: 0, seconds: 0))
            return WindowContent(description: "\(facts.appName): \(facts.title)", handle: handle)
        }
        if let last = failed[facts.bundleId], Date().timeIntervalSince(last) < Self.retryAfter { return nil }
        guard client.isReady else { return nil }
        let started = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        var messages: [[String: Any]] = [["role": "system", "content": Self.describePrompt],
                                         ["role": "user", "content": "Window:\n" + String(decoding: (try? encoder.encode(facts)) ?? Data(), as: UTF8.self)]]
        guard let (described, rounds) = await converse(&messages, finish: Self.describeTool, rounds: Self.describeRounds, facts: facts),
              !Self.strings(described["handle"]).isEmpty else {
            failed[facts.bundleId] = Date()
            log.append(Entry(at: Date(), bundleId: facts.bundleId, title: facts.title, how: "gave up", handle: [:], rounds: Self.describeRounds, seconds: Self.since(started)))
            return nil
        }
        let handle = Self.strings(described["handle"])
        log.append(Entry(at: Date(), bundleId: facts.bundleId, title: facts.title, how: "investigated", handle: handle, rounds: rounds, seconds: Self.since(started)))
        let conversation = messages
        Task { await learnReader(conversation, facts: facts, handle: handle) }
        return WindowContent(description: described["description"] as? String ?? facts.title, handle: handle)
    }

    private func learnReader(_ conversation: [[String: Any]], facts: WindowFacts, handle: [String: String]) async {
        var messages = conversation
        messages.append(["role": "user", "content": Self.readerPrompt])
        guard let (answer, _) = await converse(&messages, finish: Self.readerTool, rounds: Self.readerRounds, facts: facts),
              let reader = answer["reader"] as? String, !reader.isEmpty else { return }
        let replayed = replay(reader, facts)
        let anchors = handle.values.filter { $0 != facts.title && $0.count >= 4 }
        let kept = replayed.map { anchors.isEmpty ? $0 == handle : anchors.allSatisfy($0.values.contains) } ?? false
        log.append(["reader": reader, "replayed": replayed.map { "\($0)" } ?? "failed", "kept": kept ? "yes" : "no"])
        guard kept else { return }
        readers[facts.bundleId] = reader
        try? JSONEncoder().encode(readers).write(to: readersURL, options: .atomic)
    }

    private func converse(_ messages: inout [[String: Any]], finish: [String: Any], rounds: Int, facts: WindowFacts) async -> ([String: Any], Int)? {
        let finishName = (finish["function"] as? [String: Any])?["name"] as? String ?? ""
        for round in 1 ... rounds {
            let tools = round == rounds ? [finish] : Self.investigation + [finish]
            guard let reply = try? await client.chat(messages, tools: tools), !reply.toolCalls.isEmpty else {
                messages.append(["role": "user", "content": "Call one of the tools."])
                continue
            }
            messages.append(reply.assistantMessage)
            for call in reply.toolCalls {
                let args = (try? JSONSerialization.jsonObject(with: call.arguments) as? [String: Any]) ?? [:]
                if call.name == finishName {
                    messages.append(["role": "tool", "tool_call_id": call.id, "content": "noted"])
                    return (args, round)
                }
                let output = call.name == "read_app"
                    ? Self.readApp(args["script"] as? String ?? "", bundleId: facts.bundleId)
                    : Self.sandboxed(args["command"] as? String ?? "")
                messages.append(["role": "tool", "tool_call_id": call.id, "content": output])
            }
        }
        return nil
    }

    private func replay(_ reader: String, _ facts: WindowFacts) -> [String: String]? {
        let command = reader.replacingOccurrences(of: "{title}", with: facts.title.replacingOccurrences(of: "'", with: "'\\''"))
            .replacingOccurrences(of: "{pid}", with: String(facts.pid)).replacingOccurrences(of: "{windowId}", with: String(facts.windowId))
        let output = command.hasPrefix("applescript:") ? Self.readApp(String(command.dropFirst(12)), bundleId: facts.bundleId) : Self.sandboxed(command)
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"),
              let object = try? JSONSerialization.jsonObject(with: Data(output[start ... end].utf8)) as? [String: Any] else { return nil }
        let handle = Self.strings(object)
        return handle.isEmpty ? nil : handle
    }

    static func sandboxed(_ command: String) -> String {
        let result = Sandbox.read(command)
        return result.output.isEmpty ? "(no output, exit \(result.exit))" : result.output
    }

    static func readApp(_ script: String, bundleId: String) -> String {
        Sandbox.readApp(script, bundleId: bundleId).text
    }

    private static func strings(_ value: Any?) -> [String: String] {
        (value as? [String: Any] ?? [:]).compactMapValues { ($0 as? String) ?? ($0 as? NSNumber)?.stringValue }
    }

    private static func since(_ date: Date) -> Double { (Date().timeIntervalSince(date) * 10).rounded() / 10 }

    private struct Entry: Encodable {
        let at: Date
        let bundleId: String
        let title: String
        let how: String
        let handle: [String: String]
        let rounds: Int
        let seconds: Double
    }

    static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "function", "function": ["name": name, "description": description, "parameters": ["type": "object", "properties": properties, "required": required]]]
    }

    static let investigation: [[String: Any]] = [
        tool("run_shell", "Run one zsh command in a read-only sandbox on the user's Mac and get its output.", ["command": ["type": "string"]], required: ["command"]),
        tool("read_app", "Run a read-only AppleScript told to this window's app: the inner script only, without tell (get, count, exists).", ["script": ["type": "string"]], required: ["script"]),
    ]
    static let describeTool = tool("describe", "Say what the window shows and the handle that reopens exactly that.", [
        "description": ["type": "string", "description": "One sentence."],
        "handle": ["type": "object", "description": "String values only: ids, absolute paths, URLs, commands, titles."],
    ], required: ["description", "handle"])
    static let readerTool = tool("keep_reader", "Give the tested reader, or an empty one.", [
        "reader": ["type": "string", "description": "A read-only zsh command, or applescript: then an inner AppleScript, with {title} {pid} {windowId}, printing the handle as JSON."],
    ], required: ["reader"])
}
