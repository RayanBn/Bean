import ApplicationServices
import Foundation

enum AppRisk: String, CaseIterable {
    case send, delete, buy, consent
}

enum AppGuard {
    static let shortcutAbility = "app shortcut"
    static let riskyAbility = "window press risky"

    private static func pattern(_ text: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: text, options: .caseInsensitive)
    }

    private static let words: [(AppRisk, NSRegularExpression)] = [
        (.send, pattern(#"(^|[^\p{L}])(send|submit|post|publish|reply|forward|redirect|bounce|email|deliver|share|compose|new message|nouveau message|rédiger|envoyer|envoi|publier|répondre|soumettre|partager|transférer|enviar|senden)([^\p{L}]|$)"#)),
        (.delete, pattern(#"(^|[^\p{L}])(delete|remove|trash|erase|discard|empty|purge|destroy|wipe|supprimer|effacer|corbeille|vider|retirer|eliminar|löschen)([^\p{L}]|$)"#)),
        (.consent, pattern(#"(^|[^\p{L}])(trust|allow|authorize|authorise|grant|accept|faire confiance|autoriser|accepter)([^\p{L}]|$)"#)),
        (.buy, pattern(#"(^|[^\p{L}])(buy|pay|purchase|checkout|order|subscribe|acheter|payer|achat|commander|abonner|comprar|kaufen)([^\p{L}]|$)"#)),
    ]
    private static let never = pattern(#"\bset\s+frontmost\b|\bfrontmost\s+to\b|\bquit\b|«|»|<<|\bchoose\s+(file|folder|from|color|application)\b|\bread\s+file\b|\bmount\s+volume\b|\bsystem\s+(settings|preferences)\b"#)
    private static let unnamed = pattern(#"\b(?:application|app)\s+(?!id\s+"|")\S"#)
    private static let secret = pattern(#"password|passcode|mot de passe|card number|numéro de carte|cvv|cvc|one-time code|\bssn\b"#)
    private static let makingMessage = pattern(#"\b(make|new)\s+(new\s+)?(outgoing\s+)?(message|email|e-mail|draft)\b|\bmailto\b"#)
    static let messageRefusal = "Preparing a message is turned off for this agent: a draft syncs to the user's account, even if it is never sent"
    private static let byPosition = pattern(#"\b(document|window)\s+\d+\b|\b(front|first|last)\s+(document|window)\b|\b(every|all)\s+(document|window)s?\b|\b(documents|windows)\b"#)
    private static let leaving = pattern(#"(^|[^\p{L}])(quit|quitter|log out|sign out|déconnexion|hide|masquer)([^\p{L}]|$)"#)

    private static let services = pattern(#"^services$"#)

    private static func has(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // "By post" and "Order by date" name how, not an action. "Send by email" still matches on its verb.
    private static let harmlessUse = pattern(#"(^|[^\p{L}])((by|via|par)\s+\p{L}+|order\s+by)([^\p{L}]|$)"#)

    private static func withoutHarmlessUse(_ text: String) -> String {
        harmlessUse.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
    }

    static func risk(in text: String) -> AppRisk? {
        let plain = withoutHarmlessUse(text)
        return words.first { has($0.1, plain) }?.0
    }

    // These hold a choice that a second press takes back, or only open a list whose items are judged on their own. Nothing leaves or is lost until a button says so.
    private static let holdsAChoice: Set<String> = ["AXCheckBox", "AXRadioButton", "AXPopUpButton"]

    static func pressRefusal(role: String, label: String, abilities: [AgentAbility]) -> String? {
        if holdsAChoice.contains(role), risk(in: label) != .buy { return nil }
        if AbilityFinder.opensMerge(label) { return ActionGuard.mergeRefusal }
        if WindowChannels.isIrreversible(withoutHarmlessUse(label)), abilities.first(where: { $0.id == riskyAbility })?.allowed != true { return "\"\(label)\" cannot be taken back, and that is turned off for this agent" }
        return risky(label, abilities)
    }

    static func code(of script: String) -> String {
        var out = "", index = script.startIndex
        func at(_ prefix: String) -> Bool { script[index...].hasPrefix(prefix) }
        while index < script.endIndex {
            if at("--") || at("#") {
                index = script[index...].firstIndex(where: \.isNewline) ?? script.endIndex
            } else if at("(*") {
                index = script[index...].range(of: "*)")?.upperBound ?? script.endIndex
            } else if script[index] == "\"" {
                out += "\"\""
                index = script.index(after: index)
                while index < script.endIndex, script[index] != "\"" {
                    if script[index] == "\\" { index = script.index(index, offsetBy: 2, limitedBy: script.endIndex) ?? script.endIndex } else { index = script.index(after: index) }
                }
                if index < script.endIndex { index = script.index(after: index) }
            } else {
                out.append(script[index])
                index = script.index(after: index)
            }
        }
        return out
    }

    static func messageAbility(_ app: String) -> String { "\(app): prepare messages" }

    static func prepares(message code: String) -> Bool { has(makingMessage, code) }

    static func holdsMessages(_ dictionary: ScriptDictionary) -> Bool {
        dictionary.kinds.contains { has(pattern(#"\b(message|email|mail|draft)\b"#), $0.name) }
    }

    static func refusal(message code: String, app: String, abilities: [AgentAbility]) -> String? {
        guard prepares(message: code), abilities.first(where: { $0.id == messageAbility(app) })?.allowed != true else { return nil }
        return messageRefusal
    }

    static func usesPosition(_ code: String) -> Bool { has(byPosition, code) }

    static func positionHint(_ title: String?) -> String {
        "name the document of your window\(title.map { ", \"\($0)\"" } ?? ""): you act only on it, and a position can be someone else's document"
    }

    static func refusal(script: String, app: String) -> String? {
        let code = code(of: script)
        if let match = never.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)), let found = Range(match.range, in: code) {
            return "\(code[found]) is never allowed: agents never take over the Mac or leave their app"
        }
        if has(secret, code) { return "secrets are off limits" }
        if usesPosition(code) { return positionHint(nil) }
        if has(unnamed, code) { return "name the application literally, as \"\(app)\"" }
        if has(pattern(#"\bsaving\s+no\b"#), code) { return "closing without saving throws away work, and that is not allowed" }
        return nil
    }

    static func refusal(control: AppControl, action: String) -> String? {
        if control.secure || has(secret, control.label) { return "secret fields are never filled" }
        guard action == "press" else { return nil }
        return control.label.isEmpty ? "this control has no name, so Bean cannot tell what it does" : nil
    }

    static func refusal(menu path: [String], abilities: [AgentAbility]) -> String? {
        guard let leaf = path.last, !has(leaving, leaf), !path.contains(where: { has(services, $0) }) else { return "\(path.last ?? "") is never allowed" }
        if AbilityFinder.opensMerge(leaf) { return ActionGuard.mergeRefusal }
        return risky(leaf, abilities)
    }

    static func refusal(url text: String, schemes: [String], app: String, abilities: [AgentAbility]) -> String? {
        guard let scheme = URL(string: text)?.scheme?.lowercased() else { return "not a valid URL" }
        guard scheme != "file" else { return "opening a local file by URL stops on a macOS confirmation panel" }
        guard schemes.contains(where: { $0.lowercased() == scheme }) else { return "\(app) does not handle \(scheme): links" }
        if scheme == "mailto" || scheme == "sms", abilities.first(where: { $0.id == messageAbility(app) })?.allowed != true { return messageRefusal }
        let web = scheme == "http" || scheme == "https"
        let parts = URLComponents(string: text)
        let checked = web ? parts?.query ?? "" : [parts?.host ?? "", parts?.path ?? "", (parts?.queryItems ?? []).map(\.name).joined(separator: " ")].joined(separator: " ")
        return risky(checked.removingPercentEncoding ?? checked, abilities)
    }

    static func risky(_ text: String, _ abilities: [AgentAbility]) -> String? {
        guard risk(in: text) != nil, abilities.first(where: { $0.id == riskyAbility })?.allowed != true else { return nil }
        return "\"\(text.prefix(60))\" cannot be taken back, and that is turned off for this agent"
    }
}
