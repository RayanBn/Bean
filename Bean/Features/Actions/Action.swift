import Foundation

struct PlanStep: Codable {
    let title: String
    let command: String
}

struct Plan: Codable {
    let steps: [PlanStep]
    let appBundleId: String

    static let blockedPattern = try! NSRegularExpression(
        pattern: #"\bsudo\b|\brm\s+-\w*(rf|fr)\w*|\bmkfs|\bdd\s+if=|>\s*/dev/(disk|sd)|\bgit\s+push\b.*(--force|-f\b)|\bgit\s+reset\s+--hard|\bshutdown\b|\breboot\b|:\(\)\s*\{|--dangerously[\w-]*|--yolo\b|bypass[\w-]*(approvals|permissions|sandbox)"#
    )

    var blockedCommand: String? {
        steps.map(\.command).first { command in
            command.contains("\n") || Self.blockedPattern.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
        }
    }
}

struct StepResult: Codable {
    let command: String
    let ok: Bool
    let errorLine: String?
    let seconds: Double
}

struct PlanResult {
    let steps: [StepResult]
    let failure: String?
    let terminalTail: String?

    var succeeded: Bool { failure == nil && steps.allSatisfy(\.ok) }
    var failedStep: StepResult? { steps.first { !$0.ok } }
}

struct ActionRecord: Codable {
    enum Outcome: String, Codable { case proposed, blocked, declined, ran, failed }

    let at: Date
    let outcome: Outcome
    let commands: [String]
    let appBundleId: String
    let steps: [StepResult]?
    let failure: String?
}
