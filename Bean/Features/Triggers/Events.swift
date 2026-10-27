import Foundation

enum Events {
    private static var sink: ((Trigger) -> Void)?

    static func connect(_ handler: @escaping (Trigger) -> Void) {
        sink = handler
    }

    static func post(_ trigger: Trigger) {
        DispatchQueue.main.async { sink?(trigger) }
    }
}
