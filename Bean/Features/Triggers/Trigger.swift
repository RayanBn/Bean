import Foundation

struct Trigger: Codable {
    struct Kind: RawRepresentable, Codable, Hashable, ExpressibleByStringLiteral {
        let rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }
        init(stringLiteral value: String) { rawValue = value }
    }

    enum GatePolicy: String, Codable { case judge, always, never }

    let at: Date
    let kind: Kind
    let app: String?
    let bundleId: String?
    let windowTitle: String?
    let idleSeconds: Double
    let errorLine: String?
    let errorSeconds: Double?
    let terminalTail: String?
    var command: String? = nil
    var exitCode: Int? = nil
    var cwd: String? = nil
    var failures: Int? = nil
    var failureMinutes: Double? = nil
    var searchQuery: String? = nil
    var url: String? = nil
    var inMeeting: Bool? = nil
    var awayMinutes: Double? = nil
    var waiting: [String]? = nil
    var waitingIds: [String]? = nil
    var details: String? = nil
    var notice: String? = nil
    var gate: GatePolicy? = nil
    var source: String? = nil
    var ref: String? = nil

    var gatePolicy: GatePolicy { gate ?? .judge }
}

extension Trigger.Kind {
    static let appChanged: Self = "appChanged"
    static let terminalError: Self = "terminalError"
    static let stuckOnError: Self = "stuckOnError"
    static let idle: Self = "idle"
    static let commandFailed: Self = "commandFailed"
    static let repeatedFailure: Self = "repeatedFailure"
    static let searchingError: Self = "searchingError"
    static let unseenChange: Self = "unseenChange"
    static let backFromBreak: Self = "backFromBreak"
}

extension Trigger {
    var summary: String {
        var lines: [String] = []
        switch kind {
        case .appChanged: lines.append("Event: the user switched to another app.")
        case .terminalError: lines.append("Event: an error just appeared in the terminal.")
        case .stuckOnError: lines.append("Event: the same error has stayed in the terminal for \(Self.duration(errorSeconds ?? 0)).")
        case .idle: lines.append("Event: the user has not touched the Mac for \(Self.duration(idleSeconds)).")
        case .commandFailed: lines.append("Event: a terminal command just failed.")
        case .searchingError: lines.append("Event: the user is searching the web for the error that has stayed in their terminal for \(Self.duration(errorSeconds ?? 0)).")
        case .repeatedFailure: lines.append("Event: the same terminal command has failed \(failures ?? 0) times in \(Self.duration((failureMinutes ?? 0) * 60)).")
        case .unseenChange: lines.append("Event: things the user runs in their apps (sessions, documents, jobs, agents) changed state while the user was not looking at them, and the user has not opened them since.")
        case .backFromBreak: lines.append("Event: the user is back at the Mac after \(Self.duration((awayMinutes ?? 0) * 60)) away.")
        default: lines.append("Event: \(kind.rawValue).")
        }
        if let details, !details.isEmpty { lines.append(details) }
        if let waiting, !waiting.isEmpty { lines.append("Changed and not seen by the user yet:\n" + waiting.map { "- " + $0 }.joined(separator: "\n")) }
        if let app { lines.append("App: \(app)") }
        if let windowTitle { lines.append("Window: \(windowTitle)") }
        if let command { lines.append("Command: \(command) (exit code \(exitCode ?? 0))") }
        if let cwd { lines.append("Directory: \(cwd)") }
        if let searchQuery { lines.append("Web search: \(searchQuery)") }
        if let url { lines.append("Page: \(url)") }
        if inMeeting == true { lines.append("The user is in a meeting (microphone or camera in use).") }
        if let errorLine { lines.append("Error line: \(errorLine)") }
        if let terminalTail { lines.append("Last terminal lines:\n\(terminalTail)") }
        if kind != .idle { lines.append("Seconds since the last keyboard or mouse input: \(Int(idleSeconds))") }
        return lines.joined(separator: "\n")
    }

    private static func duration(_ seconds: Double) -> String {
        seconds < 90 ? "\(Int(seconds)) seconds" : "\(Int((seconds / 60).rounded())) minutes"
    }
}
