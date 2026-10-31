import AppKit
import NaturalLanguage

struct UserProfile: Codable, Equatable {
    var name: String?
    var language: String?
    var languageChosen: Bool?
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
        guard profile.languageChosen != true else { return }
        guard profile.language != language else { return }
        profile.language = language
        profile.save()
    }

    static func choose(language: String?) {
        var profile = current
        profile.language = language
        profile.languageChosen = language != nil
        profile.save()
        if let language { AgentStrings.translate(AgentStrings.known, to: language) }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(self).write(to: Self.file, options: .atomic)
    }

    mutating func learn(name: String, language: String, detail: String) {
        if !name.isEmpty { self.name = name }
        if !language.isEmpty, self.language != language {
            self.language = language
            AgentStrings.translate(AgentStrings.known, to: language)
        }
        if !detail.isEmpty { self.detail = detail }
    }
}

enum AgentContext {
    static func user() -> String {
        let profile = UserProfile.current
        var lines = ["Write to the user in \(profile.language ?? "the language of their last message"), and always in the language they are using now. Anything placed in a shared document, message or ticket uses the language already used there."]
        if let name = profile.name { lines.append("The user's name is \(name).") }
        if let detail = profile.detail { lines.append("Level of detail they want: \(detail).") }
        return lines.joined(separator: " ")
    }

    static let accessibilityOff = "Accessibility is off for Bean, so window names are hidden and you can neither read nor change any window. Windows you cannot see may be open. If the work needs a window, call stuck and say exactly that: the user turns it on with the Allow button on Bean's page."

    static func state(_ agent: Agent, folder: AgentFolder) -> String {
        let mission = folder.mission
        let on = agent.attachment.map { "\($0.appName), \($0.windowTitle ?? "untitled")" }
        let works = ((agent.isBean ? ["any window"] : []) + (mission?.scope ?? []) + (on.map { [$0] } ?? [])).joined(separator: "; ")
        return (AXIsProcessTrusted() ? "" : "\(accessibilityOff)\n") + "Your state. Works on: \(works.isEmpty ? "nothing yet" : works). \(Perimeter(folder: folder).promptLine)"
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
            let system = "Translate each sentence of this app's interface into \(language), in the same order, in a plain professional tone. Keep placeholders such as %.2f and names such as Works on and Accessibility exactly as written."
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

    static let stoppedToday = "I did too much today, so I stopped. I resume tomorrow."
    static let allowControl = "Allow Bean to control it"
    static let onlyRead = "Only read this window"
    static let skip = "Skip this"
    static let known = [
        allowControl, onlyRead, skip,
        "All agents are paused. Resume from Bean's page.",
        "That is off limits, so I will not touch it.",
        stoppedToday,
        "I could not read the model's answer. Please send your message again.",
        "I can't answer right now.",
        "Bean needs the Accessibility permission to read this window. Turn it on in System Settings, then drop me again.",
        "I could not read this window. It may have closed or moved to another Space.",
        "Stopped before finishing: it ran out of steps.",
        "I need your input to continue.",
        "Your API key was refused.",
        "Your AI account has nothing left to use.",
        "No connection to Muse Spark. Check the network.",
        "Muse Spark did not answer in time.",
    ] + conversation

    private static let conversation = [
        "Bean did not read this. Allow it?", "Allow", "This window may hold private data, so its text stayed on this Mac. This check can be wrong and can miss things: Off Limits is what keeps a window out.", "Today", "Yesterday", "Details", "Hide Details", "Undo", "Send", "Later", "Skip", "Other", "Your answer", "Connect", "Open Settings…", "Answer",
        "%@ needs you", "%@ needs you · %d more after this", "%@ (Recommended)", "%@: %@",
        "Recording this call since %@", "%@ did too much today and stopped. It resumes tomorrow.",
        "Drag me onto a window. That window becomes my work.", "Drag me onto a window", "A mail window, a spreadsheet, a web page: that window becomes %@'s work.",
        "Setting up %@", "The agent can be used as soon as its mission is written.", "%@ is on %@", "It works there in the background. Ask or correct it below.",
        "%@ is replying", "Message %@. It reads this after the current step.", "Give Bean a goal, or ask anything", "Ask or correct %@", "%d actions · %@",
        "%@ is now on %@", "Passed to %@", "From %@", "%@ handed me the recap of a call in %@.", "%@ handed Bean the recap of a call in %@.",
        "Answered by you", "On your behalf", "Why: %@", "Corrected: %@", "Correct…", "What should the answer be?",
        "While you were away", "Since %@", "From the call", "Decided for you", "Passed between agents", "Done", "Stopped", "Failed, then worked", "%@ (%d)", "To %@", "To %@ · %@",
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
        "Needs you", "Working", "Done", "Stop", "Read", "Edited", "Refused: %@", "Its work was refused", "Stopped for today", "Running a command", "Changes", "Take Over", "Close", "Action", "Terminal", "More", "%@ needs one answer", "This window is closed, or off limits.", "Put an Agent On", "History", "Open Windows", "No windows are open.", "All agents", "Add", "Agent Settings…", "No agents yet", "Tell Bean a goal in the chat, and its agents appear here.", "Plan", "Changes", "GitHub", "Linear", "App", "Service", "Window", "Services", "Draft", "Reading the changes…", "Nothing changed yet.", "No checks on this pull request.", "GitHub did not answer.", "Reading the pull request…", "Reading %@…", "Linear is not connected.", "This window cannot be read, or it closed.", "Reading the window…", "Tell %@ something", "Tell Bean what you want done", "Nothing to do yet", "It will not send anything without you.", "%d more", "%d need you", "%d working", "New terminal", "New terminal in this session's folder", "This session cannot be taken over yet.", "This session's folder is gone.",
        "Take Over stops Bean's work on this session. Here you drive it yourself, and Bean's limits no longer apply. Claude may first ask you to trust its folder: only you can answer that.",
    ]
}
