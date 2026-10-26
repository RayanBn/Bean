import Foundation

struct TerminalCommand: Codable {
    let command: String
    let appBundleId: String

    static let blockedPattern = try! NSRegularExpression(
        pattern: #"\bsudo\b|\brm\s+-\w*(rf|fr)\w*|\bmkfs|\bdd\s+if=|>\s*/dev/(disk|sd)|\bgit\s+push\b.*(--force|-f\b)|\bgit\s+reset\s+--hard|\bshutdown\b|\breboot\b|:\(\)\s*\{"#
    )

    var isBlocked: Bool {
        command.contains("\n") || Self.blockedPattern.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
    }
}

struct ActionRecord: Codable {
    enum Outcome: String, Codable { case proposed, blocked, declined, ran, failed }

    let at: Date
    let outcome: Outcome
    let command: String
    let appBundleId: String
    let failure: String?
}
