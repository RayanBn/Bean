import AppKit

// What an app computes itself, known only from its dictionary: read-only text a class keeps beside a property that can be written. No tool does this for every app, so it reaches only what the dictionary declares.
enum ComputedFields {
    struct Hit {
        let label: String
        let beside: [(name: String, text: String)]
    }

    private static let unit = "character id 31", record = "character id 30"

    private static let helpers = """
    global beanFound
    set beanFound to {}
    on beanText(x)
    try
    if x is missing value then return ""
    return x as text
    on error
    return ""
    end try
    end beanText
    on beanNote(place, source, columns)
    set head to item 1 of columns
    if class of head is not list then
    set wrapped to {}
    repeat with column in columns
    set end of wrapped to {contents of column}
    end repeat
    set columns to wrapped
    set head to item 1 of columns
    end if
    repeat with index from 1 to count of head
    set fields to {place as text, source}
    repeat with column in columns
    set end of fields to my beanText(item index of column)
    end repeat
    set AppleScript's text item delimiters to \(unit)
    set end of beanFound to fields as text
    end repeat
    end beanNote

    """
    private static let ending = "\nset AppleScript's text item delimiters to \(record)\nreturn beanFound as text"

    private static func rows(_ output: String) -> [[String]] {
        output.split(separator: "\u{1E}").map { $0.components(separatedBy: "\u{1F}") }
    }

    private static func shown(_ row: [String], _ names: [String]) -> Hit {
        let beside = zip(names, row.dropFirst(3)).filter { !$0.1.isEmpty && $0.1 != row[2] }.map { (name: $0.0, text: $0.1) }
        let label = row.count > names.count + 3 ? row[names.count + 3] : ""
        return Hit(label: label.isEmpty ? row[1] : label, beside: beside)
    }

    private static func columns(of property: String, _ place: ScriptDictionary.Place, in reference: String) -> String {
        ([property] + place.beside + (place.label.map { [$0] } ?? [])).map { "\($0) of \(reference)" }.joined(separator: ", ")
    }

    // MARK: Before a write

    private static func split(_ line: String, at word: String) -> (String, String)? {
        var depth = 0, quoted = false, index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if quoted {
                if character == "\\" { index = line.index(index, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex; continue }
                if character == "\"" { quoted = false }
            } else if character == "\"" {
                quoted = true
            } else if character == "(" || character == "{" {
                depth += 1
            } else if character == ")" || character == "}" {
                depth -= 1
            } else if depth == 0, let found = line[index...].range(of: word, options: [.anchored, .caseInsensitive]) {
                return (String(line[..<index]), String(line[found.upperBound...]))
            }
            index = line.index(after: index)
        }
        return nil
    }

    private static let staysOut = try! NSRegularExpression(pattern: #"\b(display|delay|say|beep)\b"#, options: .caseInsensitive)

    private static func staysHarmless(_ line: String, _ dictionary: ScriptDictionary) -> Bool {
        let code = AppGuard.code(of: line).lowercased()
        if AppGuard.writes(code) || staysOut.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil { return false }
        return !dictionary.changingCommands.contains { code.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
    }

    private static func rewrite(_ line: String, _ dictionary: ScriptDictionary, _ places: inout [(property: String, place: ScriptDictionary.Place)]) -> [String] {
        let text = line.trimmingCharacters(in: .whitespaces)
        let head = text.prefix { !$0.isWhitespace }.lowercased()
        let body = String(text.dropFirst(head.count)).trimmingCharacters(in: .whitespaces)
        switch head {
        case "tell":
            if let (target, rest) = split(body, at: " to ") {
                return staysHarmless(target, dictionary) ? ["tell \(target)"] + rewrite(rest, dictionary, &places) + ["end tell"] : []
            }
            return staysHarmless(text, dictionary) ? [text] : []
        case "if":
            if let (condition, rest) = split(body, at: " then ") {
                return staysHarmless(condition, dictionary) ? ["if \(condition) then"] + rewrite(rest, dictionary, &places) + ["end if"] : []
            }
            return staysHarmless(text, dictionary) ? [text] : []
        case "end", "else", "repeat", "try", "exit", "on", "local", "global", "property", "my":
            return staysHarmless(text, dictionary) ? [text] : []
        case "set":
            guard let (left, _) = split(body, at: " to ") else { return [] }
            var target = left.lowercased()
            for word in ["the ", "its "] where target.hasPrefix(word) { target.removeFirst(word.count) }
            let parts = split(target, at: " of ")
            let property = parts?.0 ?? target
            let reference = parts.map { String(left.suffix($0.1.count)) }
            let watched = dictionary.places(writing: property)
            guard watched.isEmpty else {
                let shape = reference.map { "(\($0))" } ?? "it"
                let source = (reference ?? property).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                var lines: [String] = []
                for place in watched {
                    places.append((property, place))
                    lines += ["try", "my beanNote(\(places.count - 1), \"\(source)\", {\(columns(of: property, place, in: shape))})", "end try"]
                }
                return lines
            }
            return reference == nil && !dictionary.holds(property) && staysHarmless(text, dictionary) ? [text] : []
        default:
            return []
        }
    }

    // The script's own tells, loops and local names work out where it writes, so what it reaches is the app's answer, not a guess from its text. Each write becomes a read, and anything else that could change the app is left out.
    static func writeCheck(_ source: String, _ dictionary: ScriptDictionary) -> (script: String, places: [(property: String, place: ScriptDictionary.Place)])? {
        var places: [(property: String, place: ScriptDictionary.Place)] = []
        let lines = AppGuard.codeKeepingStrings(of: source).components(separatedBy: .newlines).flatMap { rewrite($0, dictionary, &places) }
        guard !places.isEmpty else { return nil }
        return (script: helpers + lines.joined(separator: "\n") + ending, places: places)
    }

    static func hits(in output: String, places: [(property: String, place: ScriptDictionary.Place)]) -> [Hit] {
        rows(output).compactMap { row in
            guard let index = row.first.flatMap(Int.init), places.indices.contains(index), row.count >= 3 else { return nil }
            let place = places[index].place
            let hit = shown(row, place.beside)
            let empty = row[2].isEmpty
            let held = zip(place.beside, row.dropFirst(3)).filter { !$0.1.isEmpty }
            let computed = (empty && place.holdsAnything && !held.isEmpty) || held.contains { $0.1.hasPrefix("=") && $0.1 != row[2] }
            return computed ? Hit(label: hit.label, beside: held.map { (name: $0.0, text: $0.1) }) : nil
        }
    }

    // When the check cannot run or answer, the script runs as it would without it.
    static func check(_ source: String, bundleId: String) async -> [Hit] {
        guard AppGuard.codeKeepingStrings(of: source).lowercased().contains("set "),
              let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)?.path,
              let dictionary = ScriptDictionary.load(appAt: path),
              let check = writeCheck(source, dictionary) else { return [] }
        let outcome = await AppActions.runScript(check.script, timeout: 10)
        return outcome.ok ? hits(in: outcome.text, places: check.places) : []
    }

    static func labels(_ hits: [Hit]) -> String {
        hits.prefix(12).map(\.label).joined(separator: ", ") + (hits.count > 12 ? " and \(hits.count - 12) more" : "")
    }

    static func refusal(_ hits: [Hit]) -> String {
        let first = hits[0].beside.first { $0.text.hasPrefix("=") } ?? hits[0].beside[0]
        return "nothing ran. The app computes these itself, even when what they show is empty: \(labels(hits)) (\(hits[0].label) has \(first.name) \(first.text)). Leave them and write only the others. Only if the person or your job asks to replace these, send the script again with override set to their words."
    }

    // MARK: Reading

    static func readScript(app: String, rows reference: String, dictionary: ScriptDictionary) -> (script: String, names: [String])? {
        guard let item = dictionary.valueKinds.first else { return nil }
        let every = "every \(item.kind) of beanRow"
        return (helpers + """
        tell application "\(app)"
        set beanRows to \(reference)
        if class of beanRows is not list then set beanRows to {beanRows}
        set beanNumber to 0
        repeat with beanRow in beanRows
        set beanNumber to beanNumber + 1
        my beanNote(beanNumber, "", {\(columns(of: item.property, item.place, in: every))})
        end repeat
        end tell
        """ + ending, item.place.beside)
    }

    static func rowsText(_ output: String, names: [String]) -> String {
        var lines: [String] = [], current = "", cells: [String] = []
        for row in rows(output) where row.count >= 3 {
            if row[0] != current, !cells.isEmpty {
                lines.append(cells.joined(separator: " | "))
                cells = []
            }
            current = row[0]
            let hit = shown(row, names)
            let beside = hit.beside.map { "\($0.name): \($0.text)" }.joined(separator: "; ")
            cells.append("\(hit.label): \(row[2].isEmpty ? "(empty)" : row[2])\(beside.isEmpty ? "" : " [\(beside)]")")
        }
        if !cells.isEmpty { lines.append(cells.joined(separator: " | ")) }
        return lines.joined(separator: "\n")
    }
}
