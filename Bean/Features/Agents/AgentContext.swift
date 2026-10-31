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
    How Bean works. The notch shows status only; clicking it opens the page. The sidebar lists Bean and its agents; New Agent creates one from a sentence. Each agent's page is a chat, with an inspector: Works on (its windows and projects, each removable), Connectors (Connect), Can do without asking (one switch per ability; irreversible ones such as sending, deleting, merging start off), Budget today (warns at 80%, pauses at 100% until tomorrow), Mission, Name, Send Home, Delete. To give an agent work, drag it from the notch or the page onto any window of any app, or ask Bean. To add a repo or project, the user names it in the agent's chat and it joins Works on; you do that yourself when they name one. To allow an ability, the user asks in the chat or flips its switch. Bean is always on: it notices new things on the Mac and acts within its abilities, whether the user is there or not, and only Pause All stops it. Never promise to stop, wait or take a break: say that Pause All does that. While you were away shows what happened since the user last opened the page: what it decided, what waits and the cost. The menu bar icon holds Pause, the API key and off limits. Only use these facts: if you do not know where something is, say so. A new Numbers, Pages or Keynote document goes straight to the user's iCloud Drive, and closing it without saving leaves the file there: work in the document of your window, and create one only when the user asked for it. An agent acts only on the document of its window, by its name, never on "document 1" or the front document, which can be someone else's. Connectors come from a short catalogue, and an agent that needs one asks by name; the user connects it in one click in the browser. A message drafted in a mail app syncs to the user's account even if it is never sent, so it counts as going outward: an agent needs its Prepare messages switch on, and says so when it is off.
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
        let works = ((agent.isBean ? ["any window"] : []) + (mission?.scope ?? []) + (on.map { [$0] } ?? [])).joined(separator: "; ")
        let off = folder.abilities.filter { !$0.allowed }.map(\.title).prefix(10).joined(separator: "; ")
        return "Your state. Works on: \(works.isEmpty ? "nothing yet" : works). Turned off: \(off.isEmpty ? "only irreversible actions" : off). Spent today: \(String(format: "$%.2f of $%.2f", spent, mission?.dailyBudgetUSD ?? 1))."
    }
}

enum AgentStrings {
    private static let lock = NSLock()
    private static var asked: Set<String> = []
    private static var memory: [String: [String: String]] = [:]
    private static var language: (name: String?, read: Date)?

    private static func file(_ language: String) -> URL {
        JSONLog.directory.appendingPathComponent("strings-\(language.lowercased().filter(\.isLetter)).json")
    }

    private static func cache(_ language: String) -> [String: String] {
        lock.withLock { loaded(language) }
    }

    private static func loaded(_ language: String) -> [String: String] {
        if let found = memory[language] { return found }
        let found = (try? Data(contentsOf: file(language))).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        memory[language] = found
        return found
    }

    private static var userLanguage: String? {
        lock.withLock {
            if let language, Date().timeIntervalSince(language.read) < 5 { return language.name }
            let name = UserProfile.current.language
            language = (name, Date())
            return name
        }
    }

    static var locale: Locale {
        guard let language = userLanguage, language.lowercased() != "english",
              let code = Locale.LanguageCode.isoLanguageCodes.first(where: { Locale(identifier: "en").localizedString(forLanguageCode: $0.identifier) == language })
        else { return .current }
        return Locale(identifier: code.identifier)
    }

    static func shown(_ english: String, _ arguments: CVarArg...) -> String {
        var format = english
        if let language = userLanguage, language.lowercased() != "english", let found = cache(language)[english],
           found.filter({ $0 == "%" }).count == english.filter({ $0 == "%" }).count {
            format = found
        }
        return arguments.isEmpty ? format : String(format: format, arguments: arguments)
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
                var all = loaded(language)
                for (english, translated) in zip(missing, output.translations) { all[english] = translated }
                memory[language] = all
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

    static let allowControl = "Allow Bean to control it"
    static let onlyRead = "Only read this window"
    static let skip = "Skip this"
    static let known = [
        allowControl, onlyRead, skip,
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
    ] + conversation

    private static let conversation = [
        "Return tells Bean you mean this window.", "Bean did not read this. Allow it?", "Allow", "This window may hold private data, so its text stayed on this Mac. This check can be wrong and can miss things: Off Limits is what keeps a window out.", "Today", "Yesterday", "Details", "Hide Details", "Undo", "Send", "Later", "Skip", "Other", "Your answer", "Connect", "Open Settings…", "Answer", "Add $1",
        "%@ needs you", "%@ needs you · %d more after this", "%@ (Recommended)", "%@: %@",
        "Recording this call since %@", "%@ reached today's budget and paused. It resumes tomorrow.", "%@ has used %d%% of today's budget. It pauses at 100%%.",
        "Drag me onto a window. That window becomes my work.", "Drag me onto a window", "A mail window, a spreadsheet, a web page: that window becomes %@'s work.",
        "Setting up %@", "The agent can be used as soon as its mission is written.", "%@ is on %@", "It works there in the background. Ask or correct it below.",
        "%@ is replying", "Message %@. It reads this after the current step.", "Give Bean a goal, or ask anything", "Ask or correct %@", "%d actions · %@",
        "%@ is now on %@", "Passed to %@", "From %@", "%@ handed me the recap of a call in %@.", "%@ handed Bean the recap of a call in %@.",
        "Answered by you", "On your behalf", "Why: %@", "Corrected: %@", "Correct…", "What should the answer be?",
        "While you were away", "Since %@", "Since %@ · %@", "From the call", "Decided for you", "Passed between agents", "Done", "Stopped", "Failed, then worked", "%@ (%d)", "To %@", "To %@ · %@",
        "1 small permission answered", "%d small permissions answered", "1 decision made for you", "%d decisions made for you", "1 action done", "%d actions done", "%d waiting for you",
        "Your agents stopped on %d actions.", "Only small permissions were answered.", "Your agents passed work between them.",
        "I run your agents on your windows.", "Tell me a goal, or put an agent on a window. I decide who does what, and report once.",
        "On your Mac now", "Just decided", "I see no open windows here. Open one and I can put an agent on it.", "Put an Agent Here",
        "Nothing yet. Once an agent is on a window, you see here what it chooses to do, and when it chooses to wait.", "Nothing yet. I decide when something changes in a window.",
        "%@ acted", "%@ chose to wait", "Looked into it", "Stayed quiet", "Off limits", "Already seen", "Its own change", "Paused", "Acted", "Chose to wait",
        "Listen to this call?", "This call only", "Not now", "Always listen here", "Tell the others on the call.",
        "The sound stays on this Mac. The written transcript goes to Muse Spark (Meta).", "The call's audio and transcript go to Meta.",
        "Recording the call in %@", "Stopped recording the call in %@", "You allowed it. %@",
        "Every call here is heard without asking. %@ You can turn this off in %@'s settings.",
    ]
}
