import Foundation

struct LocalServer {
    let name: String
    let source: String
    var command: String? = nil
    var args: [String] = []
    var cwd: String? = nil
    var url: URL? = nil
    var env: [String: String] = [:]

    var summary: String {
        let how = url.map { "remote \($0.absoluteString)" } ?? ([command ?? "?"] + args).joined(separator: " ")
        let keys = env.keys.sorted()
        return "\(name): \(how) [\(source)]" + (keys.isEmpty ? "" : " env keys: \(keys.joined(separator: ", "))")
    }
}

struct RegistryServer {
    let name: String
    let description: String
    let remotes: [URL]
    let official: Bool

    var summary: String {
        "\(name)\(official ? " (official)" : ""): \(description) url \(remotes.map(\.absoluteString).joined(separator: " "))"
    }
}

enum ConnectorDiscovery {
    static func local(folder: String? = nil) -> [LocalServer] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var servers: [LocalServer] = []

        if let claude = json(home.appendingPathComponent(".claude.json")) {
            servers += entries(claude["mcpServers"], source: "~/.claude.json")
            for (project, value) in (claude["projects"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                servers += entries((value as? [String: Any])?["mcpServers"], source: "~/.claude.json \(project)", cwd: project)
            }
        }
        servers += entries(json(home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"))?["mcpServers"], source: "Claude Desktop")
        servers += entries(json(home.appendingPathComponent(".cursor/mcp.json"))?["mcpServers"], source: "Cursor")
        servers += entries(json(home.appendingPathComponent("Library/Application Support/Code/User/mcp.json"))?["servers"], source: "VS Code")
        if let text = try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8) {
            servers += codex(text)
        }
        if let folder {
            servers += entries(json(URL(fileURLWithPath: folder).appendingPathComponent(".mcp.json"))?["mcpServers"], source: "\(folder)/.mcp.json", cwd: folder)
        }

        var seen = Set<String>()
        return servers.filter { seen.insert("\($0.name)|\($0.command ?? "")|\($0.args)|\($0.url?.absoluteString ?? "")").inserted }
    }

    static func registry(_ query: String) async -> [RegistryServer] {
        guard let word = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first.map(String.init),
              var components = URLComponents(string: "https://registry.modelcontextprotocol.io/v0/servers") else { return [] }
        components.queryItems = [URLQueryItem(name: "search", value: word), URLQueryItem(name: "version", value: "latest")]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = body["servers"] as? [[String: Any]] else { return [] }

        let servers: [RegistryServer] = items.compactMap { item in
            guard let server = item["server"] as? [String: Any], let name = server["name"] as? String else { return nil }
            let remotes = (server["remotes"] as? [[String: Any]] ?? [])
                .filter { ($0["type"] as? String) == "streamable-http" }
                .compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }
            guard !remotes.isEmpty else { return nil }
            let domain = name.split(separator: "/").first.map { $0.split(separator: ".").reversed().joined(separator: ".").lowercased() } ?? ""
            let hostMatches = remotes.contains { url in
                let host = url.host?.lowercased() ?? ""
                return host == domain || host.hasSuffix("." + domain)
            }
            return RegistryServer(name: name, description: server["description"] as? String ?? "", remotes: remotes,
                                  official: hostMatches && domain.split(separator: ".").contains { $0.contains(word) })
        }
        return servers.filter(\.official) + servers.filter { !$0.official }
    }

    private static func json(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static func entries(_ value: Any?, source: String, cwd: String? = nil) -> [LocalServer] {
        (value as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }).compactMap { name, raw in
            guard let entry = raw as? [String: Any] else { return nil }
            let url = (entry["url"] as? String).flatMap(URL.init(string:))
            let command = entry["command"] as? String
            guard url != nil || command != nil else { return nil }
            return LocalServer(name: name, source: source, command: command, args: entry["args"] as? [String] ?? [],
                               cwd: entry["cwd"] as? String ?? cwd, url: url, env: entry["env"] as? [String: String] ?? [:])
        }
    }

    private static func codex(_ text: String) -> [LocalServer] {
        var servers: [String: LocalServer] = [:]
        var order: [String] = []
        var current: String?
        var inEnv = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let path = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(separator: ".").map {
                    $0.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
                current = nil
                guard path.count >= 2, path[0] == "mcp_servers" else { continue }
                current = path[1]
                inEnv = path.count == 3 && path[2] == "env"
                if servers[path[1]] == nil {
                    servers[path[1]] = LocalServer(name: path[1], source: "~/.codex/config.toml")
                    order.append(path[1])
                }
                continue
            }
            guard let name = current, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if inEnv {
                servers[name]?.env[key] = tomlString(value)
                continue
            }
            switch key {
            case "command": servers[name]?.command = tomlString(value)
            case "args": servers[name]?.args = tomlStrings(value)
            case "cwd": servers[name]?.cwd = tomlString(value)
            case "url": servers[name]?.url = tomlString(value).flatMap(URL.init(string:))
            default: break
            }
        }
        return order.compactMap { servers[$0] }.filter { $0.command != nil || $0.url != nil }
    }

    private static func tomlString(_ value: String) -> String? {
        guard let first = value.first, first == "\"" || first == "'",
              let end = value.dropFirst().firstIndex(of: first) else { return nil }
        return String(value[value.index(after: value.startIndex)..<end])
    }

    private static func tomlStrings(_ value: String) -> [String] {
        guard value.hasPrefix("[") else { return [] }
        var strings: [String] = []
        var rest = Substring(value.dropFirst())
        while let start = rest.firstIndex(where: { $0 == "\"" || $0 == "'" }) {
            let quote = rest[start]
            guard let end = rest[rest.index(after: start)...].firstIndex(of: quote) else { break }
            strings.append(String(rest[rest.index(after: start)..<end]))
            rest = rest[rest.index(after: end)...]
        }
        return strings
    }
}
