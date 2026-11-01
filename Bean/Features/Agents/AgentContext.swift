import AppKit

struct UserProfile: Codable, Equatable {
    var name: String?
    var detail: String?

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

    mutating func learn(name: String, detail: String) {
        if !name.isEmpty { self.name = name }
        if !detail.isEmpty { self.detail = detail }
    }
}

enum AgentContext {
    static func user() -> String {
        let profile = UserProfile.current
        var lines = ["The user reads your replies in English, whatever language they write in."]
        if let name = profile.name { lines.append("The user's name is \(name).") }
        if let detail = profile.detail { lines.append("Level of detail they want: \(detail).") }
        return lines.joined(separator: " ")
    }

    static var accessibilityOff: String { "\(WindowAccess.paneName) is off for Bean, so window names are hidden and you can neither read nor change any window. Windows you cannot see may be open. If the work needs a window, call stuck and say exactly that: the user turns it on with the Allow button on Bean's page." }

    static func state(_ agent: Agent, folder: AgentFolder) -> String {
        let mission = folder.mission
        let on = agent.attachment.map { "\($0.appName), \($0.windowTitle ?? "untitled")" }
        let works = ((agent.isBean ? ["any window"] : []) + (mission?.scope ?? []) + (on.map { [$0] } ?? [])).joined(separator: "; ")
        return (WindowAccess.isOn ? "" : "\(accessibilityOff)\n") + "Your state. Works on: \(works.isEmpty ? "nothing yet" : works). \(Perimeter(folder: folder).promptLine)"
    }
}

enum AgentStrings {
    static let locale = Locale(identifier: "en_US")
    static let paused = "All agents are paused. Resume from Bean's page."
    static let needsSwitch = "To read this window I need one switch in System Settings, Privacy & Security: %@. Once it is on, I carry on by myself."
    static let stoppedToday = "I reached today's limit, so I stopped. I resume tomorrow."
    static let allowControl = "Allow Bean to control it"
    static let onlyRead = "Only read this window"
    static let skip = "Skip this"
}
