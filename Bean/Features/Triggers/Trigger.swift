import Foundation

struct Trigger: Codable {
    enum Kind: String, Codable { case appChanged, terminalError, stuckOnError, idle }

    let at: Date
    let kind: Kind
    let app: String?
    let bundleId: String?
    let windowTitle: String?
    let idleSeconds: Double
    let errorLine: String?
    let errorSeconds: Double?
    let terminalTail: String?
}

extension Trigger {
    var summary: String {
        var lines: [String] = []
        switch kind {
        case .appChanged: lines.append("Event: the user switched to another app.")
        case .terminalError: lines.append("Event: an error just appeared in the terminal.")
        case .stuckOnError: lines.append("Event: the same error has stayed in the terminal for \(Self.duration(errorSeconds ?? 0)).")
        case .idle: lines.append("Event: the user has not touched the Mac for \(Self.duration(idleSeconds)).")
        }
        if let app { lines.append("App: \(app)") }
        if let windowTitle { lines.append("Window: \(windowTitle)") }
        if let errorLine { lines.append("Error line: \(errorLine)") }
        if let terminalTail { lines.append("Last terminal lines:\n\(terminalTail)") }
        if kind != .idle { lines.append("Seconds since the last keyboard or mouse input: \(Int(idleSeconds))") }
        return lines.joined(separator: "\n")
    }

    private static func duration(_ seconds: Double) -> String {
        seconds < 90 ? "\(Int(seconds)) seconds" : "\(Int((seconds / 60).rounded())) minutes"
    }
}
