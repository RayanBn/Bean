import Foundation

enum Events {
    struct Outcome {
        let trigger: Trigger
        let outcome: ActionRecord.Outcome
        let action: String
    }

    private static var sink: ((Trigger) -> Void)?
    private static var outcomeHandlers: [(Outcome) -> Void] = []

    static func onOutcome(_ handler: @escaping (Outcome) -> Void) {
        DispatchQueue.main.async { outcomeHandlers.append(handler) }
    }

    static func report(_ outcome: Outcome) {
        DispatchQueue.main.async { outcomeHandlers.forEach { $0(outcome) } }
    }

    static func connect(_ handler: @escaping (Trigger) -> Void) {
        sink = handler
    }

    static func post(_ trigger: Trigger) {
        DispatchQueue.main.async { sink?(trigger) }
    }
}
