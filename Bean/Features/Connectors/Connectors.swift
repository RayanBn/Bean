import Foundation
import MCP
import System

actor Connectors: ToolSource {
    static let toolsPerServer = 16
    static let readsPerServer = 8
    static let readPrefixes = ["list", "get", "search", "find", "read", "query", "fetch", "describe"]
    static let destructiveWords = ["delete", "remove", "archive", "destroy", "drop", "purge", "merge"]
    enum Kind: String { case read, act, hidden }

    private struct Live {
        let connection: Connection
        let client: Client
        let process: Process?
        var tools: [MCP.Tool]
    }

    private let store: ConnectorStore
    private var live: [String: Live] = [:]
    private var failures: [String: String] = [:]
    private var reconnecting: Task<Void, Never>?
    private let log = JSONLog(name: "connectors")

    struct Record: Codable {
        let at: Date
        let server: String
        let ok: Bool
        let tools: Int
        let failure: String?
    }

    init(store: ConnectorStore = ConnectorStore(), reconnect: Bool = true) {
        self.store = store
        guard reconnect else { return }
        Task { await self.startReconnecting() }
    }

    private func startReconnecting() {
        reconnecting = Task { await self.reconnectSaved() }
    }

    func tools(for trigger: Trigger) async -> [BrainTool] {
        if let reconnecting {
            _ = try? await Self.withTimeout(10) { await reconnecting.value; return true }
        }
        let words = Self.words([trigger.summary])
        return coreTools(folder: ActiveFolder.guess(for: trigger)) + live.keys.sorted().flatMap { brainTools(server: $0, rankedBy: words) }
    }

    @discardableResult
    func attach(_ connection: Connection, interactive: Bool = true) async throws -> [BrainTool] {
        if let old = live.removeValue(forKey: connection.name) {
            await old.client.disconnect()
            old.process?.terminate()
        }
        let client = Client(name: "Bean", version: "1.0")
        let name = connection.name
        await client.onNotification(ToolListChangedNotification.self) { [weak self] _ in await self?.refresh(name) }

        var process: Process?
        let transport: any Transport
        if let url = connection.url {
            transport = HTTPClientTransport(endpoint: url, authorizer: ConnectorStore.authorizer(for: connection, interactive: interactive))
        } else {
            let spawned = try Self.spawn(connection)
            process = spawned.process
            transport = spawned.transport
        }
        do {
            let tools = try await Self.withTimeout(connection.url != nil && interactive ? 330 : 90) {
                try await client.connect(transport: transport)
                return try await Self.listTools(client)
            }
            live[name] = Live(connection: connection, client: client, process: process, tools: tools)
            failures[name] = nil
            return brainTools(server: name, rankedBy: [])
        } catch {
            process?.terminate()
            failures[name] = error.localizedDescription
            throw error
        }
    }

    func exposure(server: String) -> [(tool: String, kind: Kind)] {
        (live[server]?.tools ?? []).map { ($0.name, Self.kind(of: $0)) }
    }

    func read(server: String, tool: String, arguments: JSONArgs) async -> ToolOutput {
        guard let found = live[server]?.tools.first(where: { $0.name == tool }) else { return ToolOutput(text: "\(server) has no tool \(tool)", ok: false) }
        guard Self.kind(of: found) == .read else { return ToolOutput(text: "\(tool) is not a read tool", ok: false) }
        return await call(server: server, tool: tool, arguments: arguments)
    }

    private func reconnectSaved() async {
        for connection in store.connections where live[connection.name] == nil {
            do {
                let tools = try await attach(connection, interactive: false)
                log.append(Record(at: Date(), server: connection.name, ok: true, tools: tools.count, failure: nil))
            } catch {
                log.append(Record(at: Date(), server: connection.name, ok: false, tools: 0, failure: error.localizedDescription))
            }
        }
    }

    private func refresh(_ server: String) async {
        guard let current = live[server], let tools = try? await Self.listTools(current.client) else { return }
        live[server]?.tools = tools
    }

    private func call(server: String, tool: String, arguments: JSONArgs) async -> ToolOutput {
        guard let client = live[server]?.client else {
            return ToolOutput(text: "\(server) is not connected\(failures[server].map { ": \($0)" } ?? ""). Propose connect.", ok: false)
        }
        do {
            let result: (content: [MCP.Tool.Content], isError: Bool?) = try await client.callTool(name: tool, arguments: try Self.values(arguments))
            var text = result.content.map(Self.text).joined(separator: "\n")
            if text.count > HiddenShell.outputLimit { text = String(text.prefix(HiddenShell.outputLimit)) + "\n…" }
            return ToolOutput(text: text.isEmpty ? "ok" : text, ok: result.isError != true)
        } catch {
            return ToolOutput(text: "\(server).\(tool) failed: \(error.localizedDescription)", ok: false)
        }
    }

    private func brainTools(server: String, rankedBy words: Set<String>) -> [BrainTool] {
        guard let tools = live[server]?.tools else { return [] }
        let visible = tools.enumerated()
            .map { (tool: $0.element, kind: Self.kind(of: $0.element), score: Self.score($0.element, words), order: $0.offset) }
            .filter { $0.kind != .hidden }
            .sorted { ($0.score, -$0.order) > ($1.score, -$1.order) }
        let reads = visible.filter { $0.kind == .read }
        let acts = visible.filter { $0.kind == .act }
        var picked = Array(reads.prefix(Self.readsPerServer)) + Array(acts.prefix(Self.toolsPerServer - Self.readsPerServer))
        let rest = reads.dropFirst(Self.readsPerServer) + acts.dropFirst(Self.toolsPerServer - Self.readsPerServer)
        picked += rest.prefix(max(0, Self.toolsPerServer - picked.count))
        return picked.sorted { ($0.kind == .read ? 0 : 1, $0.order) < ($1.kind == .read ? 0 : 1, $1.order) }
            .map { brainTool(server: server, $0.tool, effect: $0.kind == .read ? .read : .act) }
    }

    private func brainTool(server: String, _ tool: MCP.Tool, effect: BrainTool.Effect) -> BrainTool {
        let schema = Self.sanitize((try? Self.any(tool.inputSchema)) ?? [String: Any]()) as? [String: Any] ?? [:]
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let required = (schema["required"] as? [String] ?? []).filter { properties[$0] != nil }
        let about = tool.description ?? tool.annotations.title ?? tool.name
        let description = "\(server): " + (about.count > 500 ? String(about.prefix(500)) + "…" : about)
        var brainTool = BrainTool(name: Self.toolName(server, tool.name), description: description, parameters: properties, required: required, effect: effect) { [weak self] args in
            guard let self else { return ToolOutput(text: "connectors are not running", ok: false) }
            return await self.call(server: server, tool: tool.name, arguments: args)
        }
        brainTool.showsArguments = true
        return brainTool
    }

    private func coreTools(folder: String?) -> [BrainTool] {
        let connected = live.mapValues(\.connection)
        let failures = failures
        return [
            BrainTool(name: "find_connectors", description: "Find MCP connectors that give Bean access to the user's apps and services: the ones already connected, the ones in the user's local AI app configs, and, for a word such as a product name, the public MCP registry.", parameters: [
                "word": ["type": "string", "description": "One word, usually a product name. Empty to list only what is connected and local."],
            ], required: [], effect: .read) { args in
                var lines = ["Connected: " + (connected.isEmpty ? "none" : connected.values.sorted { $0.name < $1.name }.map { "\($0.name) (\($0.summary))" }.joined(separator: ", "))]
                for (name, failure) in failures.sorted(by: { $0.key < $1.key }) where connected[name] == nil { lines.append("Not connected, \(name): \(failure)") }
                let local = ConnectorDiscovery.local(folder: folder)
                lines.append("In the user's local configs (connect with name, command and args):")
                lines += local.map { "- " + $0.summary + (connected[$0.name] != nil ? " (connected)" : "") }
                if let word = args.string("word") {
                    let found = await ConnectorDiscovery.registry(word)
                    lines.append("Public registry for \"\(word)\" (connect with name and url; official means the publisher's domain serves it):")
                    lines += found.isEmpty ? ["none"] : found.prefix(8).map { "- " + $0.summary }
                }
                return ToolOutput(text: lines.joined(separator: "\n"))
            },
            BrainTool(name: "connect", description: "Propose to connect an MCP server, so its tools become Bean's tools. Give url for a remote server from the registry (the user signs in in the browser if it asks), or command and args exactly as find_connectors listed them from the user's local configs.", parameters: [
                "name": ["type": "string", "description": "Short name for the server, such as the product name."],
                "url": ["type": "string", "description": "Remote server URL."],
                "command": ["type": "string", "description": "Local server command from the user's config."],
                "args": ["type": "array", "items": ["type": "string"], "description": "Local server arguments from the user's config."],
            ], required: ["name"], effect: .act) { [weak self] args in
                guard let self else { return ToolOutput(text: "connectors are not running", ok: false) }
                return await self.connect(args, folder: folder)
            },
        ]
    }

    private func connect(_ args: JSONArgs, folder: String?) async -> ToolOutput {
        let name = Self.clean(args.string("name") ?? "")
        guard !name.isEmpty else { return ToolOutput(text: "connect needs a name", ok: false) }
        let connection: Connection
        if let url = args.string("url").flatMap(URL.init(string:)), url.scheme == "https" || url.host == "127.0.0.1" || url.host == "localhost" {
            let saved = store.connections.first { $0.url == url }
            connection = Connection(name: name, url: url, redirectPort: saved?.redirectPort ?? LoopbackAuthorization.freePort())
        } else if let command = args.string("command") {
            let arguments = args["args"] as? [String] ?? []
            guard let local = ConnectorDiscovery.local(folder: folder).first(where: { $0.command == command && $0.args == arguments }) else {
                return ToolOutput(text: "refused: \(command) is not a server from the user's local configs", ok: false)
            }
            connection = Connection(name: name, command: command, args: arguments, cwd: local.cwd)
        } else {
            return ToolOutput(text: "connect needs an https url or a command from a local config", ok: false)
        }
        do {
            let tools = try await attach(connection)
            store.save(connection)
            let hidden = exposure(server: name).filter { $0.kind == .hidden }.count
            return ToolOutput(text: "Connected \(name). Tools: " + tools.map { "\($0.name) (\($0.effect.rawValue))" }.joined(separator: ", ") + (hidden > 0 ? ". \(hidden) destructive tools hidden." : ""))
        } catch {
            return ToolOutput(text: "Could not connect \(name): \(error.localizedDescription)", ok: false)
        }
    }

    static func kind(of tool: MCP.Tool) -> Kind {
        let lower = tool.name.lowercased()
        if destructiveWords.contains(where: lower.contains) { return .hidden }
        if tool.annotations.readOnlyHint == true { return .read }
        let startsWithRead = readPrefixes.contains { prefix in
            guard lower.hasPrefix(prefix) else { return false }
            let next = tool.name.dropFirst(prefix.count).first
            return next.map { !$0.isLowercase } ?? true
        }
        return startsWithRead ? .read : .act
    }

    static func toolName(_ server: String, _ tool: String) -> String {
        String(clean("\(server)__\(tool)").prefix(64))
    }

    static func clean(_ name: String) -> String {
        String(name.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" })
    }

    static func sanitize(_ node: Any, defs: [String: Any] = [:], depth: Int = 0) -> Any {
        if let array = node as? [Any] { return array.map { sanitize($0, defs: defs, depth: depth) } }
        guard var object = node as? [String: Any], depth < 12 else { return node }
        var defs = defs
        for key in ["$defs", "definitions"] {
            if let local = object.removeValue(forKey: key) as? [String: Any] { defs.merge(local) { _, new in new } }
        }
        for _ in 0..<6 {
            if let ref = object.removeValue(forKey: "$ref") as? String, let target = defs[String(ref.split(separator: "/").last ?? "")] as? [String: Any] {
                for (key, value) in target where object[key] == nil { object[key] = value }
            }
            if let parts = object.removeValue(forKey: "allOf") as? [[String: Any]] {
                for part in parts {
                    for (key, value) in part {
                        if key == "properties", let mine = object[key] as? [String: Any], let theirs = value as? [String: Any] {
                            object[key] = mine.merging(theirs) { first, _ in first }
                        } else if key == "required", let mine = object[key] as? [String], let theirs = value as? [String] {
                            object[key] = Array(Set(mine + theirs)).sorted()
                        } else if object[key] == nil {
                            object[key] = value
                        }
                    }
                }
            }
            for key in ["anyOf", "oneOf"] {
                guard let options = object.removeValue(forKey: key) as? [[String: Any]] else { continue }
                let pick = options.first { ($0["type"] as? String) != "null" } ?? options.first ?? [:]
                for (key, value) in pick where object[key] == nil { object[key] = value }
            }
            if !["$ref", "allOf", "anyOf", "oneOf"].contains(where: { object[$0] != nil }) { break }
        }
        for key in ["$schema", "$id", "$ref", "$comment", "examples", "allOf", "anyOf", "oneOf"] { object[key] = nil }
        if let value = object.removeValue(forKey: "const"), object["enum"] == nil { object["enum"] = [value] }
        if let types = object["type"] as? [String] { object["type"] = types.first { $0 != "null" } ?? "string" }
        if object["type"] as? String == "array", object["items"] == nil { object["items"] = ["type": "string"] }
        if object["type"] as? String == "object", object["properties"] == nil, object["additionalProperties"] == nil { object["additionalProperties"] = true }
        if let properties = object["properties"] as? [String: Any] {
            object["properties"] = properties.mapValues { sanitize($0, defs: defs, depth: depth + 1) }
        }
        for key in ["items", "additionalProperties"] where object[key] is [String: Any] {
            object[key] = sanitize(object[key]!, defs: defs, depth: depth + 1)
        }
        return object
    }

    private static func words(_ texts: [String?]) -> Set<String> {
        Set(texts.compactMap { $0 }.joined(separator: " ").lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 4 })
    }

    private static func score(_ tool: MCP.Tool, _ words: Set<String>) -> Int {
        guard !words.isEmpty else { return 0 }
        let name = tool.name.lowercased(), description = (tool.description ?? "").lowercased()
        return words.reduce(0) { score, word in score + (name.contains(word) ? 10 : 0) + (description.contains(word) ? 1 : 0) }
    }

    private static func text(_ content: MCP.Tool.Content) -> String {
        switch content {
        case .text(let text, _, _): return text
        case .image(_, let mimeType, _, _): return "[image \(mimeType)]"
        case .audio(_, let mimeType, _, _): return "[audio \(mimeType)]"
        case .resource(let resource, _, _): return resource.text ?? "[resource \(resource.uri)]"
        case .resourceLink(let uri, let name, _, let description, _, _): return "\(name): \(uri)" + (description.map { " \($0)" } ?? "")
        }
    }

    private static func listTools(_ client: Client) async throws -> [MCP.Tool] {
        var tools: [MCP.Tool] = []
        var cursor: String?
        repeat {
            let page = try await client.listTools(cursor: cursor)
            tools += page.tools
            cursor = page.nextCursor
        } while cursor != nil && tools.count < 1000
        return tools
    }

    private static func values(_ args: JSONArgs) throws -> [String: Value] {
        try JSONDecoder().decode([String: Value].self, from: JSONSerialization.data(withJSONObject: args))
    }

    private static func any(_ value: Value) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)
    }

    private static let loginPath = HiddenShell.capture("/bin/zsh", ["-lc", "printf %s \"$PATH\""])?.trimmingCharacters(in: .whitespacesAndNewlines)

    private static func spawn(_ connection: Connection) throws -> (process: Process, transport: StdioTransport) {
        guard let command = connection.command else { throw ConnectError.noCommand }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + connection.args
        var environment = ProcessInfo.processInfo.environment
        if let loginPath, !loginPath.isEmpty { environment["PATH"] = loginPath }
        let local = ConnectorDiscovery.local(folder: connection.cwd).first { $0.command == command && $0.args == connection.args }
        environment.merge(local?.env ?? [:]) { _, config in config }
        process.environment = environment
        if let cwd = connection.cwd, FileManager.default.fileExists(atPath: cwd) { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let toServer = Pipe(), fromServer = Pipe()
        process.standardInput = toServer
        process.standardOutput = fromServer
        process.standardError = FileHandle.nullDevice
        try process.run()
        let transport = StdioTransport(input: FileDescriptor(rawValue: dup(fromServer.fileHandleForReading.fileDescriptor)),
                                       output: FileDescriptor(rawValue: dup(toServer.fileHandleForWriting.fileDescriptor)))
        return (process, transport)
    }

    enum ConnectError: LocalizedError {
        case noCommand, timedOut
        var errorDescription: String? { self == .noCommand ? "no command to start" : "the server did not answer in time" }
    }

    private static func withTimeout<T>(_ seconds: Double, _ work: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ConnectError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ConnectError.timedOut }
            return first
        }
    }
}
