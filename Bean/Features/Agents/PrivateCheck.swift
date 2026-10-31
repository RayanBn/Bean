import Foundation

enum PrivateCheck {
    static let id = "privateRead"
    static let question = "Bean did not read this. Allow it?"
    static let allow = "Allow"
    static let notNow = "Not now"
    static let detail = "This window may hold private data, so its text stayed on this Mac. This check can be wrong and can miss things: Off Limits is what keeps a window out."
    static let held = "Bean did not read this window because it may hold private data. The user was asked."

    private static let threshold = 0.4
    private static let instructions = "Does this contain secrets or personal data about someone?"
    private static let piece = 800
    private static let overlap = 200

    @MainActor private static var allowed: Set<String> = []
    @MainActor private static var waiting: Set<String> = []
    @MainActor private static var heldText: [String: Int] = [:]

    static func key(_ attachment: Attachment) -> String {
        attachment.windowNumber != 0 ? String(attachment.windowNumber) : "\(attachment.bundleId) \(attachment.windowTitle ?? "")"
    }

    @MainActor static func needsAsking(_ key: String) -> Bool { waiting.insert(key).inserted }
    @MainActor static func isHeld(_ text: String, _ attachment: Attachment) -> Bool {
        let key = key(attachment)
        return !allowed.contains(key) && heldText[key] == text.hashValue
    }
    @MainActor static func hold(_ text: String, _ key: String) { heldText[key] = text.hashValue }
    @MainActor static func isAllowed(_ key: String) -> Bool { allowed.contains(key) }
    @MainActor static func answer(_ key: String, yes: Bool) {
        if yes { allowed.insert(key) }
    }

    private static let titleThreshold = 0.3
    private static let titleInstructions = "Is this window title about someone's health, money, legal matters, passwords or private life?"
    private static let titles = NSLock()
    private static var checkedTitles: [String: Bool] = [:]

    static func titleIsPrivate(_ title: String?) async -> Bool {
        guard let title, !title.isEmpty else { return false }
        if let known = titles.withLock({ checkedTitles[title] }) { return known }
        guard BeanSettings.shared.effectiveDecidesOnThisMac, StrandsServer.isAvailable else { return false }
        let found = (await StrandsDecider.score(state: String(title.prefix(300)), question: titleInstructions) ?? 0) >= titleThreshold
        titles.withLock { checkedTitles[title] = found }
        return found
    }

    static func suspects(_ text: String) async -> Bool {
        guard BeanSettings.shared.effectiveDecidesOnThisMac, StrandsServer.isAvailable, !text.isEmpty else { return false }
        let characters = Array(text.prefix(3000))
        var start = 0
        repeat {
            let slice = String(characters[start..<min(start + piece, characters.count)])
            if let score = await StrandsDecider.score(state: slice, question: instructions), score >= threshold { return true }
            start += piece - overlap
        } while start + overlap < characters.count
        return false
    }
}

// A yes for reading covers that app. Bean reads inside a window only if an agent holds it or its app has a yes.
enum ReadingYes {
    private static var file: URL { JSONLog.directory.appendingPathComponent("reading-yes.json") }
    private static var apps: Set<String> { (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? [] }

    static func covers(_ bundleId: String?) -> Bool { bundleId.map(apps.contains) ?? false }

    static func add(_ bundleId: String) {
        try? JSONEncoder().encode(apps.union([bundleId])).write(to: file, options: .atomic)
    }
}

extension AgentWorker {
    @MainActor func holdsBack(_ text: String, attachment: Attachment, agent: Agent) async -> Bool {
        let key = PrivateCheck.key(attachment)
        guard !PrivateCheck.isAllowed(key), await PrivateCheck.suspects(text) else { return false }
        PrivateCheck.hold(text, key)
        if PrivateCheck.needsAsking(key) {
            raise(AgentNeed(kind: .decision, question: PrivateCheck.question, options: [PrivateCheck.allow, PrivateCheck.notNow],
                            recommended: PrivateCheck.notNow, consent: "\(PrivateCheck.id) \(key)", detail: PrivateCheck.detail), agent: agent)
        }
        return true
    }

    func answerPrivateCheck(_ need: AgentNeed, agent: Agent, text: String) -> Bool {
        guard let consent = need.consent, consent.hasPrefix("\(PrivateCheck.id) ") else { return false }
        close(need, agent: agent, answer: text)
        record(JournalEntry(kind: .said, did: text, why: ""), agent)
        MainActor.assumeIsolated { PrivateCheck.answer(String(consent.dropFirst(PrivateCheck.id.count + 1)), yes: text == PrivateCheck.allow) }
        return true
    }
}
