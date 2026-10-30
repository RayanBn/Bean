import Foundation

struct AgentTarget: Codable, Identifiable, Equatable, Hashable {
    enum Kind: String, Codable { case repo, project, window, session }
    var kind: Kind
    var name: String
    var link: String?
    var app: String?
    var title: String?

    var id: String { "\(kind.rawValue):\(name)" }

    static func named(_ name: String) -> AgentTarget {
        AgentTarget(kind: name.contains("/") ? .repo : .project, name: name)
    }
}

struct AgentConnectorInfo: Codable, Identifiable, Equatable {
    enum Source: String, Codable { case mcp, cli, app }
    enum Status: String, Codable { case connected, toConnect, failed }
    var name: String
    var source: Source
    var status: Status
    var usedFor: [String] = []
    var url: String?
    var command: String?

    var id: String { name }
}

struct AgentAbility: Codable, Identifiable, Equatable {
    enum Risk: String, Codable { case safe, outward, irreversible }
    let id: String
    var title: String
    var detail: String
    var allowed: Bool
    var risk: Risk
    var source: String
}

extension AgentFolder {
    private var abilitiesFile: URL { url.appendingPathComponent("abilities.json") }
    private var connectorsFile: URL { url.appendingPathComponent("connectors.json") }

    var abilities: [AgentAbility] {
        (try? Data(contentsOf: abilitiesFile)).flatMap { try? JSONDecoder().decode([AgentAbility].self, from: $0) } ?? []
    }

    func save(_ abilities: [AgentAbility]) {
        write(abilities, to: abilitiesFile)
    }

    var connectors: [AgentConnectorInfo] {
        (try? Data(contentsOf: connectorsFile)).flatMap { try? JSONDecoder().decode([AgentConnectorInfo].self, from: $0) } ?? []
    }

    func save(_ connectors: [AgentConnectorInfo]) {
        write(connectors, to: connectorsFile)
    }

    private func write<T: Encodable>(_ value: T, to file: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? encoder.encode(value).write(to: file, options: .atomic)
    }
}

enum AbilityFinder {
    private static let irreversibleWords = try! NSRegularExpression(pattern: #"(^|[^a-z])(delete|remove|destroy|drop|purge|archive|transfer|revoke|merge|deploy|publish|release|force|reset|wipe)([^a-z]|$)"#, options: .caseInsensitive)
    private static let outwardVerbs: Set<String> = ["create", "save", "update", "add", "comment", "post", "set", "edit", "assign", "label", "link", "reply", "attach", "mark", "ready", "reopen", "move"]

    static func irreversible(_ text: String) -> Bool {
        irreversibleWords.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func humanized(_ name: String) -> String {
        let words = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func ability(forTool tool: BrainTool, server: String, explicit: [String]) -> AgentAbility {
        let short = tool.name.components(separatedBy: "__").last ?? tool.name
        let verb = short.split(whereSeparator: { $0 == "_" || $0 == "-" }).first.map { $0.lowercased() } ?? ""
        let risk: AgentAbility.Risk
        if tool.effect == .read {
            risk = .safe
        } else if irreversible(short) || !outwardVerbs.contains(verb) {
            risk = .irreversible
        } else {
            risk = .outward
        }
        let about = tool.description.replacingOccurrences(of: "\(server): ", with: "")
        let sentence = about.split(whereSeparator: { $0 == "." || $0 == "\n" }).first.map(String.init) ?? about
        return AgentAbility(id: tool.name, title: humanized(short), detail: String(sentence.prefix(140)), allowed: defaultAllowed(risk, id: short, explicit: explicit), risk: risk, source: server)
    }

    static func defaultAllowed(_ risk: AgentAbility.Risk, id: String, explicit: [String]) -> Bool {
        risk != .irreversible || explicit.contains { id.lowercased().contains($0.lowercased()) }
    }

    static func words(of command: String) -> [String] {
        var words: [String] = []
        for token in command.split(separator: " ").map(String.init) {
            guard !token.hasPrefix("-"), !token.contains("/"), !token.contains("."), !token.contains("="), !token.contains("$"), !token.contains("\""), !token.contains("'"), Int(token) == nil else { break }
            words.append(token)
        }
        return words
    }

    static func abilities(forGroup group: [String], agent: Agent, explicit: [String]) async -> [AgentAbility] {
        let line = group.joined(separator: " ")
        let help = await Task.detached { HiddenShell.run("\(line) --help", timeout: 15) }.value
        guard help.exit == 0, !help.output.isEmpty else { return [] }
        let system = """
        Below is the --help of a command-line tool. List the commands it offers directly under `\(line)`, at most 20.
        - command: the full command, `\(line) <word>`.
        - title: what it does, in two to five plain words.
        - detail: one short plain sentence.
        - risk: safe if it only reads. outward if it changes something that can be reversed or posts something visible. irreversible if it cannot be undone, or if it merges, deploys, publishes or deletes. If you are unsure, irreversible.
        """
        let schema: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["commands"], "properties": ["commands": ["type": "array", "items": [
            "type": "object", "additionalProperties": false, "required": ["command", "title", "detail", "risk"],
            "properties": ["command": ["type": "string"], "title": ["type": "string"], "detail": ["type": "string"], "risk": ["type": "string", "enum": ["safe", "outward", "irreversible"]]],
        ]]]]
        struct Output: Decodable {
            struct Item: Decodable { let command, title, detail, risk: String }
            let commands: [Item]
        }
        guard let reply = await CostLedger.$agent.withValue(agent.id.uuidString, operation: { try? await ModelClient().json(system: system, text: String(help.output.prefix(5000)), schema: schema, effort: "low") }),
              let body = reply.text, let output = try? JSONDecoder().decode(Output.self, from: Data(body.utf8)) else { return [] }
        return output.commands.compactMap { item in
            let parts = item.command.split(separator: " ").map(String.init)
            guard parts.count == group.count + 1, Array(parts.dropLast()) == group else { return nil }
            var risk = AgentAbility.Risk(rawValue: item.risk) ?? .irreversible
            if irreversible(parts.last ?? "") { risk = .irreversible }
            return AgentAbility(id: parts.joined(separator: " "), title: item.title, detail: item.detail, allowed: defaultAllowed(risk, id: parts.last ?? "", explicit: explicit), risk: risk, source: group[0])
        }
    }
}
