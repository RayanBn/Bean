import Foundation

struct UserProfile: Codable, Equatable {
    var name: String?
    var language: String?
    var detail: String?
    var notes: [String] = []

    static let file = JSONLog.directory.appendingPathComponent("user.json")

    static var current: UserProfile {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(UserProfile.self, from: $0) } ?? UserProfile()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(self).write(to: Self.file, options: .atomic)
    }

    mutating func learn(name: String, language: String, detail: String, note: String) {
        if !name.isEmpty { self.name = name }
        if !language.isEmpty { self.language = language }
        if !detail.isEmpty { self.detail = detail }
        if !note.isEmpty, !notes.contains(note) { notes = Array((notes + [note]).suffix(8)) }
    }
}

enum AgentContext {
    static let guide = """
    How Bean works. The notch shows status only; clicking it opens the page. The sidebar lists Bean and its agents; New Agent creates one from a sentence. Each agent's page is a chat, with an inspector: Works on (its windows and projects, each removable), Connectors (Connect), Can do without asking (one switch per ability; irreversible ones such as sending, deleting, merging start off), Budget today (warns at 80%, pauses at 100% until tomorrow), Mission, Name, Send Home, Delete. To give an agent work, drag it from the notch or the page onto any window of any app, or ask Bean. To add a repo or project, the user names it in the agent's chat and it joins Works on; you do that yourself when they name one. To allow an ability, the user asks in the chat or flips its switch. Take Over makes Bean keep things moving while the user is away; While you were away shows what it decided, what waits and the cost. The menu bar icon holds Pause, the API key and off limits. Only use these facts: if you do not know where something is, say so.
    """

    static func user() -> String {
        let profile = UserProfile.current
        var lines = ["Write to the user in \(profile.language ?? "the language of their last message"), and always in the language they are using now. Anything placed in a shared document, message or ticket uses the language already used there."]
        if let name = profile.name { lines.append("The user's name is \(name).") }
        if let detail = profile.detail { lines.append("Level of detail they want: \(detail).") }
        if !profile.notes.isEmpty { lines.append("They told you: \(profile.notes.joined(separator: "; ")).") }
        return lines.joined(separator: " ")
    }

    static func state(_ agent: Agent, folder: AgentFolder, spent: Double) -> String {
        let mission = folder.mission
        let on = agent.attachment.map { "\($0.appName), \($0.windowTitle ?? "untitled")" }
        let works = ((mission?.scope ?? []) + (on.map { [$0] } ?? [])).joined(separator: "; ")
        let off = folder.abilities.filter { !$0.allowed }.map(\.title).prefix(10).joined(separator: "; ")
        return "Your state. Works on: \(works.isEmpty ? "nothing yet" : works). Turned off: \(off.isEmpty ? "only irreversible actions" : off). Spent today: \(String(format: "$%.2f of $%.2f", spent, mission?.dailyBudgetUSD ?? 1))."
    }
}
