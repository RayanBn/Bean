import Foundation

enum AgentAction {
    case connector(name: String, arguments: String, ability: AgentAbility?)
    case press(AppControl)
    case fill(AppControl)
    case script(String)
    case menu([String])
    case url(String, schemes: [String])
    case shortcut(String)
    case rememberAboutUser(runFromUser: Bool)
}

// One check before every action, and one rule for what is on. The guards below it stay as they were: this is the only way to reach them.
struct Perimeter {
    let card: AgentCard?
    let abilities: [AgentAbility]
    var mission: AgentMission
    var window: Attachment?
    var paused: Bool
    var stopped: Bool
    var onlyReading: Bool

    init(card: AgentCard?, abilities: [AgentAbility], window: Attachment? = nil, paused: Bool = BeanSettings.shared.effectivePaused, stopped: Bool = false, onlyReading: Bool = false) {
        self.card = card
        self.abilities = abilities.map { ability in
            var ability = ability
            ability.allowed = Self.isAllowed(ability, card: card)
            return ability
        }
        mission = AgentMission(mission: card?.job.goal ?? "", targets: card?.targets ?? [], explicitlyAllowed: card?.allow ?? [])
        self.window = window
        self.paused = paused
        self.stopped = stopped
        self.onlyReading = onlyReading
    }

    init(folder: AgentFolder, window: Attachment? = nil, stopped: Bool = false, onlyReading: Bool = false) {
        var card = folder.card
        if let app = window?.bundleId, folder.state.appsAllowedToChange.contains(app) { card?.readOnly = false }
        self.init(card: card, abilities: folder.rawAbilities, window: window, stopped: stopped, onlyReading: onlyReading)
    }

    static let mergeRefusal = "merging or marking ready is the user's call"

    // In deny means off, in allow means on, otherwise safe and outward actions are on and irreversible ones off. The never list wins over all of this.
    static func isAllowed(_ ability: AgentAbility, card: AgentCard?) -> Bool {
        if AbilityFinder.opensMerge(ability.id) { return false }
        guard let card else { return ability.risk != .irreversible }
        if card.deny.contains(ability.id) { return false }
        if card.allow.contains(where: { $0 == ability.id || (!$0.contains(" ") && ability.id.lowercased().contains($0.lowercased())) }) { return true }
        if card.bornFrom.kind == "moment", ability.risk == .outward, !ability.id.hasPrefix("window ") { return false }
        return ability.risk != .irreversible
    }

    func isAllowed(_ ability: AgentAbility) -> Bool { Self.isAllowed(ability, card: card) }

    var turnedOff: [AgentAbility] { abilities.filter { !$0.allowed } }

    var readOnly: Bool { (card?.readOnly ?? false) || onlyReading }

    var promptLine: String {
        let off = turnedOff.map(\.title).prefix(10).joined(separator: "; ")
        return "Turned off: \(off.isEmpty ? "only irreversible actions" : off).\(readOnly ? " You only read here." : "")"
    }

    // The limit is this agent's, never the document's, so a report built on this line cannot blame the file.
    static let cardReadOnly = "you may only read this app until the user allows more, and this limit is yours, not the document's. The user has been asked. Say that plainly in your summary, with what you read"

    static let rewriteAsRead = "Bean cannot tell this script only reads, so nothing ran. A list of windows or tabs comes from app_windows, and a tab's text from tab_read. To read a document, send lines that only ask for values, with no set, repeat or if, such as: tell application \"its name\" to get value of every cell of table 1 of sheet 1 of document \"its name\""

    var readOnlyRefusal: String? {
        if card?.readOnly == true { return Self.cardReadOnly }
        return onlyReading ? "the user asked you to only read this app: finish with what you read" : nil
    }

    var halted: String? {
        if paused { return "all agents are paused" }
        return stopped ? "you have stopped for today" : nil
    }

    private var windowOffLimits: Bool {
        guard let window else { return false }
        return OffLimits.match("\(window.appName) \(window.bundleId) \(window.windowTitle ?? "")") != nil
    }

    func refusal(_ action: AgentAction) -> String? {
        switch action {
        case let .rememberAboutUser(runFromUser):
            return runFromUser ? nil : "only a run the person started can write to what is kept about them. Use notes for what you read"
        case let .connector(name, arguments, ability):
            if let term = OffLimits.match(arguments) { return "off limits: \(term)" }
            if AbilityFinder.opensMerge(name) { return Self.mergeRefusal }
            if let halted { return halted }
            if readOnly, ability?.risk != .safe { return readOnlyRefusal }
            guard let ability, isAllowed(ability) else { return "\(ability?.title ?? name) is turned off for this agent" }
            let namesThisService = mission.covers(name.components(separatedBy: "__").first ?? name)
            if ability.risk != .safe, !namesThisService, !mission.scope.isEmpty, !mission.covers(arguments) { return "outside your targets: name one of \(mission.named)" }
            return nil
        default:
            break
        }
        if let halted { return halted }
        if windowOffLimits { return "this window is off limits" }
        if let readOnlyRefusal {
            guard case let .script(source) = action else { return readOnlyRefusal }
            if !AppGuard.onlyReads(source) { return AppGuard.looksLikeARead(source) ? Self.rewriteAsRead : readOnlyRefusal }
        }
        switch action {
        case let .press(control):
            if abilities.first(where: { $0.id == "window press" })?.allowed == false { return "Pressing buttons is turned off for this agent" }
            return AppGuard.refusal(control: control, action: "press") ?? AppGuard.pressRefusal(role: control.role, label: control.label, abilities: abilities)
        case let .fill(control):
            if abilities.first(where: { $0.id == "window fill" })?.allowed == false { return "Filling fields is turned off for this agent" }
            return AppGuard.refusal(control: control, action: "fill")
        case let .script(source):
            return WindowChannels.refusal(script: source, app: window?.appName ?? "", abilities: abilities)
        case let .menu(path):
            if let term = OffLimits.match(path.joined(separator: " > ")) { return "off limits: \(term)" }
            return AppGuard.refusal(menu: path, abilities: abilities)
        case let .url(text, schemes):
            if let term = OffLimits.match(text) { return "off limits: \(term)" }
            return AppGuard.refusal(url: text, schemes: schemes, app: window?.appName ?? "", abilities: abilities)
        case let .shortcut(name):
            if let term = OffLimits.match(name) { return "off limits: \(term)" }
            return abilities.first { $0.id == AppGuard.shortcutAbility }?.allowed == true ? nil : "Running the user's shortcuts is turned off for this agent"
        default:
            return nil
        }
    }
}

extension AgentWorker {
    func perimeter(for agent: Agent, on app: Attachment? = nil) -> Perimeter {
        let attachment = app ?? storeForBrain.agents.first { $0.id == agent.id }?.attachment
        return Perimeter(folder: AgentFolder(agent, in: storeForBrain), window: attachment, stopped: isOverBudget(agent), onlyReading: onlyReading.contains(agent.id))
    }
}
