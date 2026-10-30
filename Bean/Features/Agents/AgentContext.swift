import Foundation
import NaturalLanguage

struct UserProfile: Codable, Equatable {
    var name: String?
    var language: String?
    var detail: String?
    var notes: [String] = []

    static let file = JSONLog.directory.appendingPathComponent("user.json")

    static var current: UserProfile {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(UserProfile.self, from: $0) } ?? UserProfile()
    }

    private static func name(ofLanguage code: String) -> String? {
        Locale(identifier: "en").localizedString(forLanguageCode: code)
    }

    static var systemLanguage: String {
        Locale.preferredLanguages.first.flatMap { Locale(identifier: $0).language.languageCode?.identifier }.flatMap(name(ofLanguage:)) ?? "English"
    }

    static func noticeLanguage(of text: String) {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (found, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= 0.85, let language = name(ofLanguage: found.rawValue) else { return }
        var profile = current
        guard profile.language != language else { return }
        profile.language = language
        profile.save()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(self).write(to: Self.file, options: .atomic)
    }

    mutating func learn(name: String, language: String, detail: String, note: String) {
        if !name.isEmpty { self.name = name }
        if !language.isEmpty, self.language != language {
            self.language = language
            AgentStrings.translate(AgentStrings.known, to: language)
        }
        if !detail.isEmpty { self.detail = detail }
        if !note.isEmpty, !notes.contains(note) { notes = Array((notes + [note]).suffix(8)) }
    }
}

enum AgentContext {
    static let guide = """
    How Bean works. The notch shows status only; clicking it opens the page. The sidebar lists Bean and its agents; New Agent creates one from a sentence. Each agent's page is a chat, with an inspector: Works on (its windows and projects, each removable), Connectors (Connect), Can do without asking (one switch per ability; irreversible ones such as sending, deleting, merging start off), Budget today (warns at 80%, pauses at 100% until tomorrow), Mission, Name, Send Home, Delete. To give an agent work, drag it from the notch or the page onto any window of any app, or ask Bean. To add a repo or project, the user names it in the agent's chat and it joins Works on; you do that yourself when they name one. To allow an ability, the user asks in the chat or flips its switch. Take Over makes Bean keep things moving while the user is away; While you were away shows what it decided, what waits and the cost. The menu bar icon holds Pause, the API key and off limits. Only use these facts: if you do not know where something is, say so. A new Numbers, Pages or Keynote document goes straight to the user's iCloud Drive, and closing it without saving leaves the file there: work in the document of your window, and create one only when the user asked for it. A message drafted in a mail app syncs to the user's account even if it is never sent, so it counts as going outward: an agent needs its Prepare messages switch on, and says so when it is off.
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

enum AgentStrings {
    private static let lock = NSLock()
    private static var asked: Set<String> = []

    private static func file(_ language: String) -> URL {
        JSONLog.directory.appendingPathComponent("strings-\(language.lowercased().filter(\.isLetter)).json")
    }

    private static func cache(_ language: String) -> [String: String] {
        (try? Data(contentsOf: file(language))).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    static func local(_ english: String) -> String {
        guard let language = UserProfile.current.language, language.lowercased() != "english" else { return english }
        if let found = cache(language)[english] { return found }
        if english == paused, let found = pausedElsewhere[language] { return found }
        translate([english], to: language)
        return english
    }

    static func translate(_ sentences: [String], to language: String) {
        Task.detached { await translateNow(sentences, to: language) }
    }

    static func translateNow(_ sentences: [String], to language: String) async {
        guard language.lowercased() != "english", !BeanSettings.shared.effectivePaused else { return }
        let known = cache(language)
        let missing = lock.withLock { sentences.filter { known[$0] == nil && asked.insert(language + $0).inserted } }
        guard !missing.isEmpty else { return }
        do {
            let schema: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["translations"],
                                         "properties": ["translations": ["type": "array", "items": ["type": "string"]]]]
            let system = "Translate each sentence of this app's interface into \(language), in the same order, in a plain professional tone. Keep placeholders such as %.2f and names such as Works on, Budget today and Accessibility exactly as written."
            let text = (try? JSONSerialization.data(withJSONObject: missing)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
            struct Output: Decodable { let translations: [String] }
            guard let reply = try? await ModelClient().json(system: system, text: text, schema: schema, effort: "minimal"), let body = reply.text,
                  let output = try? JSONDecoder().decode(Output.self, from: Data(body.utf8)), output.translations.count == missing.count else { return }
            lock.withLock {
                var all = cache(language)
                for (english, translated) in zip(missing, output.translations) { all[english] = translated }
                try? JSONEncoder().encode(all).write(to: file(language), options: .atomic)
            }
        }
    }

    static let paused = "All agents are paused. Resume from Bean's page."
    private static let pausedElsewhere = [
        "French": "Tous les agents sont en pause. Reprenez depuis la barre de menus.",
        "Spanish": "Todos los agentes están en pausa. Reanúdalos desde la barra de menús.",
        "German": "Alle Agenten sind pausiert. Setze sie über die Menüleiste fort.",
        "Italian": "Tutti gli agenti sono in pausa. Riprendi dalla barra dei menu.",
        "Portuguese": "Todos os agentes estão em pausa. Retome pela barra de menus.",
    ]

    static let known = [
        "All agents are paused. Resume from Bean's page.",
        "That is off limits, so I will not touch it.",
        "Today's budget of $%.2f is spent. I resume tomorrow, or raise it in Budget today.",
        "Today's budget of $%.2f is spent, so I stopped. Raise it or I resume tomorrow.",
        "Budget warning: $%.2f of today's $%.2f is spent. I stop at 100%%.",
        "I could not read the model's answer. Please send your message again.",
        "I can't answer right now.",
        "Bean needs the Accessibility permission to read this window. Turn it on in System Settings, then drop me again.",
        "I could not read this window. It may have closed or moved to another Space.",
        "My budget for today is spent.",
        "Stopped before finishing: it ran out of steps.",
        "I need your input to continue.",
        "Your API key was refused.",
        "Your AI credits have run out.",
        "No connection to Muse Spark. Check the network.",
        "Muse Spark did not answer in time.",
    ]
}
