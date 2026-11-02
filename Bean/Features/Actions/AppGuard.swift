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
    // A person's tab, page and view stay as they left them. execute also runs anything at all on a page, so a tab is read only through tab_read.
    private static let movesTheirView = pattern(#"\bselect\b|\bfocus\b|\bgo\s+(back|forward)\b|\breload\b|\bset\s+url\b|\bset\s+active\s+tab\b|\bexecute\b"#)
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

    static func code(of script: String) -> String { scan(script) { _ in "\"\"" } }

    static func codeKeepingStrings(of script: String) -> String { scan(script) { "\"\($0)\"" } }

    // AppleScript's own token rules, so spacing, a line continuation, a comment mark inside |...| or a comment that only looks like code cannot change what the checks read. A piece that never closes reads as raw code, which is refused.
    private static func scan(_ script: String, literal: (String) -> String) -> String {
        var out = "", index = script.startIndex
        func at(_ prefix: String) -> Bool { script[index...].hasPrefix(prefix) }
        while index < script.endIndex {
            let character = script[index]
            if at("--") || character == "#" {
                index = script[index...].firstIndex(where: \.isNewline) ?? script.endIndex
            } else if at("(*") {
                guard let end = script[index...].range(of: "*)")?.upperBound else {
                    out += "«"
                    break
                }
                if out.last != " " { out += " " }
                index = end
            } else if character == "\"" || character == "|" {
                index = script.index(after: index)
                let start = index
                while index < script.endIndex, script[index] != character {
                    if script[index] == "\\" { index = script.index(index, offsetBy: 2, limitedBy: script.endIndex) ?? script.endIndex } else { index = script.index(after: index) }
                }
                guard index < script.endIndex else {
                    out += "«"
                    break
                }
                out += character == "|" ? "|x|" : literal(String(script[start..<index]))
                index = script.index(after: index)
            } else if character == "¬" {
                if out.last != " " { out += " " }
                index = script.index(after: index)
                if index < script.endIndex, script[index].isNewline { index = script.index(after: index) }
            } else if character.isNewline {
                out += "\n"
                index = script.index(after: index)
            } else if character.isWhitespace {
                if out.last != " " { out += " " }
                index = script.index(after: index)
            } else {
                out.append(character)
                index = script.index(after: index)
            }
        }
        return out
    }

    private static let changesSomething = pattern(#"\b(set|make|delete|remove|close|save|open|quit|move|duplicate|import|export|print|send|reply|forward|redirect|activate|launch|reopen|run|do|click|keystroke|key|perform|press|select|add|clear|sort|merge|transpose|reveal|empty|eject|store|copy|paste|cut|write|create|update|insert|replace|load|repeat|if|with|shell|using)\b"#)
    private static let readHeads: Set<String> = ["get", "return", "count", "exists"]
    // Only words that name things: a command word, a parenthesis or the clipboard is not here, so it cannot be mistaken for a value.
    private static let readWords: Set<String> = ["of", "in", "every", "the", "whose", "where", "is", "it", "its", "not", "and", "or", "contains", "contain", "equal", "equals", "than", "greater", "less", "begins", "ends", "first", "last", "middle", "thru", "through",
        "value", "values", "formatted", "name", "names", "title", "class", "id", "index", "count", "number", "row", "rows", "column", "columns", "cell", "cells", "range", "ranges", "table", "tables", "sheet", "sheets", "document", "slide", "slides", "page", "pages", "section", "sections", "paragraph", "paragraphs", "word", "words", "character", "characters", "line", "lines", "text", "body", "contents", "content", "formula", "header", "footer", "properties", "modified", "size"]

    private static func namesValues(_ words: ArraySlice<Substring>, application: Bool) -> Bool {
        var rest = words
        while let word = rest.popFirst() {
            if word == "\"\"" || word.allSatisfy(\.isNumber) || readWords.contains(String(word)) { continue }
            guard application, word == "application" || word == "app", rest.first == "\"\"" else { return false }
        }
        return true
    }

    // A read is a form Bean can prove: lines that open or close a tell on a plain reference, or ask for a value named only with words that name things. Anything else stays a change, so the person is still asked.
    static func onlyReads(_ script: String) -> Bool {
        var asked = false
        for raw in code(of: script).lowercased().components(separatedBy: .newlines) {
            var words = raw.split(separator: " ")[...]
            if words.isEmpty || words == ["end", "tell"] || words == ["end"] { continue }
            var opensBlock = false
            while words.first == "tell" {
                words = words.dropFirst()
                guard let to = words.firstIndex(of: "to") else {
                    guard namesValues(words, application: true) else { return false }
                    opensBlock = true
                    break
                }
                guard namesValues(words[..<to], application: true) else { return false }
                words = words[words.index(after: to)...]
            }
            if opensBlock { continue }
            guard let head = words.first, readHeads.contains(String(head)), namesValues(words.dropFirst(), application: false) else { return false }
            asked = true
        }
        return asked
    }

    private static let writesForSure = pattern(#"\bset\s+\S+\s+of\b|\b(make|delete|remove|close|save|open|quit|move|duplicate|import|export|print|send|reply|forward|redirect|activate|launch|reopen|run|do|click|keystroke|key|perform|press|select|add|clear|sort|merge|transpose|reveal|empty|eject|store|copy|paste|cut|write|create|update|insert|replace|load|shell|using)\b"#)

    // Loops and local names can hide a change, so Bean cannot call this a read, but nothing in it writes. It gets a way to ask again instead of a question to the person.
    static func looksLikeARead(_ script: String) -> Bool { !has(writesForSure, code(of: script)) }

    static func writes(_ code: String) -> Bool { has(writesForSure, code) }

    enum ScriptTarget: Equatable { case noDocument, own, other(String), unclear }

    private static let thing = "document|window|note|message|file|alias|workbook|presentation|spreadsheet"
    private static let noThingNamed = pattern(#"\b(new|active|selected)\s+(\#(thing))s?\b"#)
    private static let thingReference = pattern(#"\b(?:\#(thing))s?\b(?:\s+named)?(?:\s*"(\d+)")?|\bopen\s+"(\d+)""#)

    // Which document a script reaches, read from the words in its code and never from text inside its strings.
    static func target(of script: String, ownTitles: [String]) -> ScriptTarget {
        var literals: [String] = []
        let scanned = scan(script) { literals.append($0); return "\"\(literals.count - 1)\"" }
        let code = noThingNamed.stringByReplacingMatches(in: scanned, range: NSRange(scanned.startIndex..., in: scanned), withTemplate: " ")
        var found = ScriptTarget.noDocument
        for match in thingReference.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let range = Range(match.range(at: 1), in: code) ?? Range(match.range(at: 2), in: code), let index = Int(code[range]) else { return .unclear }
            let name = literals[index].replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            guard ownTitles.contains(where: { names(name, title: $0) }) else { return .other(name) }
            found = .own
        }
        return found
    }

    private static func names(_ name: String, title: String) -> Bool {
        func withoutExtension(_ text: String) -> String {
            let found = (text as NSString).pathExtension
            return found.isEmpty || found.count > 8 || found.contains(" ") ? text : (text as NSString).deletingPathExtension
        }
        // A window can show its state after the name, as in "Notes.txt — Edited".
        let shown = title.lowercased(), wanted = (name.lowercased().components(separatedBy: CharacterSet(charactersIn: "/:")).last ?? name.lowercased())
        let bare = shown.components(separatedBy: " — ").first ?? shown
        return [shown, bare, withoutExtension(bare)].contains(wanted) || withoutExtension(wanted) == bare
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
        "name a document by its exact title\(title.map { ", such as \"\($0)\"" } ?? ""): a position can change under you. The list of windows and tabs comes from app_windows, and a tab's text from tab_read"
    }

    static func refusal(script: String, app: String) -> String? {
        let code = code(of: script)
        if let match = never.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)), let found = Range(match.range, in: code) {
            return "\(code[found]) is never allowed: agents never take over the Mac or leave their app"
        }
        if has(movesTheirView, code) { return "an agent never moves the person's view or runs code on a page. app_windows lists the tabs, and tab_read reads one in the background" }
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
