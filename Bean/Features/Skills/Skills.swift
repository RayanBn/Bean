import Foundation

struct Skill {
    let name: String
    let when: String
    let forBean: Bool
    let always: Bool
    let understanding: Bool
    let body: String

    init?(text: String) {
        let parts = text.components(separatedBy: "\n---\n")
        guard parts.count >= 2 else { return nil }
        var fields: [String: String] = [:]
        for line in parts[0].split(separator: "\n") {
            let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        guard let name = fields["name"], let when = fields["when"] else { return nil }
        self.name = name
        self.when = when
        forBean = fields["for"] == "Bean"
        always = fields["always"] == "yes"
        understanding = fields["understanding"] == "yes"
        body = parts.dropFirst().joined(separator: "\n---\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum Skills {
    static func all(in folder: AgentFolder? = nil) -> [Skill] {
        let bundled = Bundle.main.urls(forResourcesWithExtension: "md", subdirectory: nil) ?? []
        let places = [JSONLog.directory.appendingPathComponent("Skills"), folder?.url.appendingPathComponent("skills")].compactMap { $0 }
        let added = places.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }.filter { $0.pathExtension == "md" }
        var byName: [String: Skill] = [:]
        for file in bundled + added {
            if let text = try? String(contentsOf: file, encoding: .utf8), let skill = Skill(text: text) { byName[skill.name] = skill }
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    static var leading: String {
        all().filter { $0.forBean && $0.always && !$0.understanding }.map(\.body).joined(separator: "\n")
    }

    static var understanding: String {
        all().filter(\.understanding).map(\.body).joined(separator: "\n")
    }

    static func index(bean: Bool, folder: AgentFolder?) -> String {
        let lines = all(in: folder).filter { $0.forBean == bean && !$0.always }.map { "- \($0.name): \($0.when)" }
        return lines.isEmpty ? "" : "Skills you can read with read_skill, before the work they fit:\n\(lines.joined(separator: "\n"))"
    }

    static var agentSkills: [String] {
        all().filter { !$0.forBean }.map { "\($0.name) (\($0.when))" }
    }

    static func tool(folder: AgentFolder) -> BrainTool {
        BrainTool(name: "read_skill", description: "Read one of your skills: know-how for a kind of work.", parameters: ["name": ["type": "string"]], required: ["name"], effect: .read) { args in
            guard let name = args.string("name"), let skill = all(in: folder).first(where: { $0.name == name }) else { return ToolOutput(text: "no skill with that name", ok: false) }
            return ToolOutput(text: skill.body)
        }
    }
}
