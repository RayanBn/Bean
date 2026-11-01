import Foundation

// AGENT.md: who an agent is, its job and its limits. What a person reads is what the model reads.
struct AgentCard: Equatable {
    enum BornFrom: Equatable {
        case person(String), drag(String), moment(String), bean(String)

        var kind: String {
            switch self {
            case .person: "person"
            case .drag: "drag"
            case .moment: "moment"
            case .bean: "bean"
            }
        }

        var words: String {
            switch self {
            case let .person(words), let .drag(words), let .moment(words), let .bean(words): words
            }
        }

        init(kind: String, words: String) {
            switch kind {
            case "drag": self = .drag(words)
            case "moment": self = .moment(words)
            case "bean": self = .bean(words)
            default: self = .person(words)
            }
        }
    }

    enum ParseError: Error { case noFields, wrongFormat, noId }

    static let format = 1

    var id: UUID
    var name: String
    var role: String
    var created: Date
    var look: Agent.Look
    var isBean: Bool { id == Agent.beanID }
    var targets: [AgentTarget] = []
    var allow: [String] = []
    var deny: [String] = []
    var readOnly = false
    var bornFrom: BornFrom = .person("")
    var leaveWhen = ""
    var job: AgentJob

    init(id: UUID, name: String, role: String, created: Date, look: Agent.Look, job: AgentJob) {
        self.id = id
        self.name = name
        self.role = role
        self.created = created
        self.look = look
        self.job = job
    }

    private static let dates = ISO8601DateFormatter()

    private static func line(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func item(_ text: String) -> String {
        line(text).replacingOccurrences(of: ";", with: ",")
    }

    var text: String {
        let lookLine = "\(look.accessory), \(look.hue)\(look.chosen == true ? ", chosen" : "")"
        let fields = [
            "format: \(Self.format)",
            "template: \(isBean ? "bean" : "agent")",
            "id: \(id.uuidString)",
            "name: \(Self.line(name))",
            "role: \(Self.line(role))",
            "created: \(Self.dates.string(from: created))",
            "look: \(lookLine)",
            "targets: \(targets.map { "\($0.kind.rawValue):\(Self.item($0.name))" }.joined(separator: "; "))",
            "allow: \(allow.map(Self.item).joined(separator: "; "))",
            "deny: \(deny.map(Self.item).joined(separator: "; "))",
            "read_only: \(readOnly ? "yes" : "no")",
            "born_from: \(bornFrom.kind): \(Self.line(bornFrom.words))",
            "leave_when: \(Self.line(leaveWhen))",
        ]
        return "---\n" + fields.joined(separator: "\n") + "\n---\n" + body + "\n"
    }

    var body: String {
        let lines = [("Goal", job.goal), ("What the person gets", job.output), ("Done means", job.done), ("First move", job.first), ("Stay quiet when", job.quiet)].filter { $0.0 != "First move" || !$0.1.isEmpty }
        return "## Job\n" + lines.map { "\($0.0): \(Self.line($0.1))" }.joined(separator: "\n")
    }

    // What the model reads about this agent: the same words a person reads.
    var forPrompt: String {
        "# \(name)\n\(role)\n\n\(body)"
    }

    init(text: String) throws {
        let parts = text.components(separatedBy: "\n---\n")
        guard text.hasPrefix("---\n"), parts.count >= 2 else { throw ParseError.noFields }
        var fields: [String: String] = [:]
        for row in parts[0].dropFirst(4).split(separator: "\n") {
            let pair = row.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        guard fields["format"].flatMap(Int.init) == Self.format else { throw ParseError.wrongFormat }
        guard let id = fields["id"].flatMap(UUID.init(uuidString:)) else { throw ParseError.noId }
        func list(_ key: String) -> [String] { (fields[key] ?? "").components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        let lookParts = (fields["look"] ?? "").components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var job = AgentJob(goal: "", output: "", done: "", first: "", quiet: "")
        for row in parts.dropFirst().joined(separator: "\n---\n").components(separatedBy: .newlines) {
            let pair = row.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2 else { continue }
            switch pair[0] {
            case "Goal": job.goal = pair[1]
            case "What the person gets": job.output = pair[1]
            case "Done means": job.done = pair[1]
            case "First move": job.first = pair[1]
            case "Stay quiet when": job.quiet = pair[1]
            default: break
            }
        }
        self.id = id
        name = fields["name"] ?? ""
        role = fields["role"] ?? ""
        created = fields["created"].flatMap { Self.dates.date(from: $0) } ?? Date()
        look = Agent.Look(hue: lookParts.count > 1 ? Double(lookParts[1]) ?? 0.6 : 0.6, accessory: lookParts.first.flatMap { $0.isEmpty ? nil : $0 } ?? "none", chosen: lookParts.contains("chosen") ? true : nil)
        targets = list("targets").map { entry in
            let pair = entry.split(separator: ":", maxSplits: 1).map(String.init)
            guard pair.count == 2, let kind = AgentTarget.Kind(rawValue: pair[0]) else { return AgentTarget.named(entry) }
            return AgentTarget(kind: kind, name: pair[1])
        }
        allow = list("allow")
        deny = list("deny")
        readOnly = fields["read_only"] == "yes"
        let born = (fields["born_from"] ?? "").split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        bornFrom = BornFrom(kind: born.first ?? "person", words: born.count > 1 ? born[1] : "")
        leaveWhen = fields["leave_when"] ?? ""
        self.job = job
    }

    func agent(attachment: Attachment?) -> Agent {
        Agent(id: id, name: name, role: role, look: look, attachment: attachment, createdAt: created)
    }
}

// What changes while Bean runs. Code writes it, and it never reaches a person as a definition.
struct AgentState: Codable, Equatable {
    var attachment: Attachment?
    var every: TimeInterval?
    var check: AgentMission.Check?
    var stoppedTask: String?
    var runningTask: String?
    var allowedApp: String?
    var notDone: String?
}

extension AgentFolder {
    var cardFile: URL { url.appendingPathComponent("AGENT.md") }
    private var goodCardFile: URL { url.appendingPathComponent(".AGENT.good") }
    private var stateFile: URL { url.appendingPathComponent("state.json") }

    private static let writing = NSLock()

    // A hand edit that does not parse keeps the last good version: only the person's own file stays broken.
    var card: AgentCard? {
        if let text = try? String(contentsOf: cardFile, encoding: .utf8), let card = try? AgentCard(text: text) { return card }
        return (try? String(contentsOf: goodCardFile, encoding: .utf8)).flatMap { try? AgentCard(text: $0) }
    }

    var cardIsBroken: Bool {
        guard let text = try? String(contentsOf: cardFile, encoding: .utf8) else { return false }
        return (try? AgentCard(text: text)) == nil
    }

    func write(_ card: AgentCard) {
        Self.writing.withLock {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? card.text.write(to: cardFile, atomically: true, encoding: .utf8)
            try? card.text.write(to: goodCardFile, atomically: true, encoding: .utf8)
        }
    }

    func updateCard(_ change: (inout AgentCard) -> Void) {
        guard var current = card else { return }
        change(&current)
        write(current)
    }

    var state: AgentState {
        (try? Data(contentsOf: stateFile)).flatMap { try? JSONDecoder().decode(AgentState.self, from: $0) } ?? AgentState()
    }

    func updateState(_ change: (inout AgentState) -> Void) {
        Self.writing.withLock {
            var current = state
            change(&current)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? encoder.encode(current).write(to: stateFile, options: .atomic)
        }
    }

    var job: AgentJob? { card?.job }
    var personaText: String { card?.forPrompt ?? "" }

    var mission: AgentMission? {
        guard let card else { return nil }
        var mission = AgentMission(mission: card.job.goal, targets: card.targets, explicitlyAllowed: card.allow)
        mission.every = state.every ?? 300
        mission.check = state.check
        return mission
    }

    func save(_ mission: AgentMission) {
        updateCard { card in
            if card.role == card.job.goal { card.role = mission.mission }
            card.job.goal = mission.mission
            card.targets = mission.targets.filter { $0.kind == .repo || $0.kind == .project }
        }
        updateState {
            $0.every = mission.every
            $0.check = mission.check
        }
    }

    // Reads the files from before the card once, then removes them. Safe to run on every launch.
    func importOldFiles() {
        struct Old: Decodable {
            let id: UUID
            let name: String
            let role: String
            let look: Agent.Look
            let attachment: Attachment?
            let createdAt: Date
        }
        struct OldJob: Decodable { let goal, output, done, first, quiet: String }
        struct OldMission: Decodable {
            let mission: String
            let targets: [AgentTarget]?
            let scope: [String]?
            let explicitlyAllowed: [String]?
            let every: TimeInterval?
            let check: AgentMission.Check?
        }
        let agentFile = url.appendingPathComponent("agent.json")
        guard let data = try? Data(contentsOf: agentFile) else { return }
        if !FileManager.default.fileExists(atPath: cardFile.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let old = try? decoder.decode(Old.self, from: data) else { return }
            let mission = (try? Data(contentsOf: url.appendingPathComponent("mission.json"))).flatMap { try? JSONDecoder().decode(OldMission.self, from: $0) }
            let job = (try? Data(contentsOf: url.appendingPathComponent("job.json"))).flatMap { try? JSONDecoder().decode(OldJob.self, from: $0) }
            var card = AgentCard(id: old.id, name: old.name, role: old.role, created: old.createdAt, look: old.look,
                                 job: AgentJob(goal: mission?.mission ?? job?.goal ?? old.role, output: job?.output ?? "", done: job?.done ?? "", first: job?.first ?? "", quiet: job?.quiet ?? ""))
            card.targets = (mission?.targets ?? (mission?.scope ?? []).map(AgentTarget.named)).filter { $0.kind == .repo || $0.kind == .project }
            card.allow = (mission?.explicitlyAllowed ?? []).filter { $0 != "merge" }
            write(card)
            updateState {
                $0.attachment = old.attachment
                $0.every = mission?.every
                $0.check = mission?.check
            }
        }
        for name in ["agent.json", "persona.md", "job.json", "lines.json", "mission.json"] {
            try? FileManager.default.removeItem(at: url.appendingPathComponent(name))
        }
    }

    // Writes a new card when the folder has none yet, for agents code makes without a sentence.
    func create(agent: Agent, job: AgentJob? = nil, bornFrom: AgentCard.BornFrom = .person("")) {
        var card = AgentCard(id: agent.id, name: agent.name, role: agent.role, created: agent.createdAt, look: agent.look, job: job ?? AgentJob(goal: agent.role, output: "", done: "", first: "", quiet: ""))
        card.bornFrom = bornFrom
        write(card)
    }
}
