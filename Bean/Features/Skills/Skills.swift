import Foundation

struct Skill {
    let name: String
    let when: String
    let body: String

    init?(text: String, bundled: Bool) {
        let parts = text.components(separatedBy: "\n---\n")
        guard parts.count >= 2 else { return nil }
        var fields: [String: String] = [:]
        for line in parts[0].split(separator: "\n") {
            let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        if !bundled { fields = fields.filter { ["name", "when"].contains($0.key) } }
        guard let name = fields["name"], let when = fields["when"] else { return nil }
        self.name = name
        self.when = when
        body = parts.dropFirst().joined(separator: "\n---\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum Skills {
    static func all(in folder: AgentFolder? = nil) -> [Skill] {
        let bundled = Bundle.main.urls(forResourcesWithExtension: "md", subdirectory: nil) ?? []
        let added = ((try? FileManager.default.contentsOfDirectory(at: JSONLog.directory.appendingPathComponent("Skills"), includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "md" }
        var byName: [String: Skill] = [:]
        func read(_ file: URL, bundled: Bool) -> Skill? {
            (try? String(contentsOf: file, encoding: .utf8)).flatMap { Skill(text: $0, bundled: bundled) }
        }
        for skill in bundled.compactMap({ read($0, bundled: true) }) { byName[skill.name] = skill }
        let own = Set(byName.keys)
        for skill in added.compactMap({ read($0, bundled: false) }) where !own.contains(skill.name) { byName[skill.name] = skill }
        return byName.values.sorted { $0.name < $1.name }
    }

    static func index(folder: AgentFolder?) -> String {
        let lines = all(in: folder).map { "- \($0.name): \($0.when)" }
        return lines.isEmpty ? "" : "Skills you can read with read_skill, before the work they fit:\n\(lines.joined(separator: "\n"))"
    }

    static var agentSkills: [String] {
        all().map { "\($0.name) (\($0.when))" }
    }

    static func tool(folder: AgentFolder) -> BrainTool {
        BrainTool(name: "read_skill", description: "Read one of your skills: know-how for a kind of work.", parameters: ["name": ["type": "string"]], required: ["name"], effect: .read) { args in
            guard let name = args.string("name"), let skill = all(in: folder).first(where: { $0.name == name }) else { return ToolOutput(text: "no skill with that name", ok: false) }
            return ToolOutput(text: skill.body)
        }
    }
}
