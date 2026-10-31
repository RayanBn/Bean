import Foundation

enum AgentAction {
    case shell(String, ActionGuard.Mode)
    case connector(name: String, arguments: String, ability: AgentAbility?)
    case press(AppControl)
    case fill(AppControl)
    case script(String)
    case menu([String])
    case url(String, schemes: [String])
    case shortcut(String)
    case startSession(repo: String, url: String, known: Bool)
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
    var worktree: URL?
    var unknownAllowed = false

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
        self.init(card: folder.card, abilities: folder.rawAbilities, window: window, stopped: stopped, onlyReading: onlyReading)
    }

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

    var readOnlyRefusal: String? { readOnly ? "the user asked you to only read this window: finish with what you read" : nil }

    var halted: String? {
        if paused { return "all agents are paused" }
        return stopped ? "you have stopped for today" : nil
    }

    private var windowOffLimits: Bool {
        guard let window else { return false }
        return OffLimits.match("\(window.appName) \(window.bundleId) \(window.windowTitle ?? "")") != nil
    }

    func reaching(_ repo: String, worktree: URL, unknownAllowed: Bool = false) -> Perimeter {
        var wider = self
        wider.mission = mission.reaching(repo)
        wider.worktree = worktree
        wider.unknownAllowed = unknownAllowed
        return wider
    }

    private var shellGuard: ActionGuard { ActionGuard(mission: mission, worktree: worktree, abilities: abilities, unknownAllowed: unknownAllowed) }

    func ability(for command: String) -> AgentAbility? { shellGuard.ability(for: command) }
    func isUnknown(_ command: String) -> Bool { shellGuard.isUnknown(command) }
    func inWorkingCopy(_ command: String) -> String? { shellGuard.inWorkingCopy(command) }

    func refusal(_ action: AgentAction) -> String? {
        switch action {
        case let .rememberAboutUser(runFromUser):
            return runFromUser ? nil : "only a run the person started can write to what is kept about them. Use notes for what you read"
        case let .shell(command, mode):
            if let halted { return halted }
            if card?.readOnly == true, mode != .read { return "the user asked you to only read: finish with what you read" }
            return ActionGuard(mission: mission, worktree: worktree, abilities: mode == .undo ? nil : abilities, unknownAllowed: unknownAllowed).refusal(command, mode: mode)
        case let .connector(name, arguments, ability):
            if let term = OffLimits.match(arguments) { return "off limits: \(term)" }
            if AbilityFinder.opensMerge(name) { return ActionGuard.mergeRefusal }
            if let halted { return halted }
            if card?.readOnly == true, ability?.risk != .safe { return "the user asked you to only read: finish with what you read" }
            guard let ability, isAllowed(ability) else { return "\(ability?.title ?? name) is turned off for this agent" }
            let namesThisService = mission.covers(name.components(separatedBy: "__").first ?? name)
            if ability.risk != .safe, !namesThisService, !mission.scope.isEmpty, !mission.covers(arguments) { return "outside your targets: name one of \(mission.named)" }
            return nil
        case let .startSession(repo, url, known):
            if let halted { return halted + ": call finish now" }
            if card?.readOnly == true { return "the user asked you to only read: finish with what you read" }
            let targeted = repo.contains("/") && mission.scope.contains { $0.caseInsensitiveCompare(repo) == .orderedSame } && mission.covers(url)
            guard targeted || known, url.hasPrefix("https://"), OffLimits.match(repo + " " + url) == nil else {
                return "\(repo) is not a repo you can work in. Choose one of these by its owner/name: \(CodeRepos.described). If you cannot tell which, ask_user with the likely ones as options"
            }
            return nil
        default:
            break
        }
        if let halted { return halted }
        if windowOffLimits { return "this window is off limits" }
        if let readOnlyRefusal { return readOnlyRefusal }
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
    func perimeter(for agent: Agent) -> Perimeter {
        let attachment = storeForBrain.agents.first { $0.id == agent.id }?.attachment
        return Perimeter(folder: AgentFolder(agent, in: storeForBrain), window: attachment, stopped: isOverBudget(agent), onlyReading: onlyReading.contains(agent.id))
    }
}
