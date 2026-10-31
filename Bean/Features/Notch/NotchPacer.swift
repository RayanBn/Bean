import CoreGraphics
import Foundation

// Reversible rule in code: when a question may open. It never decides whether to ask. Starting values from always-on-evidence section 9.
struct NotchPacer {
    static let typing: TimeInterval = 3
    static let idle: TimeInterval = 10
    static let afterSwitch: TimeInterval = 3
    static let sustained: TimeInterval = 30
    static let hold: TimeInterval = 14
    static let line: TimeInterval = 7
    static let away: TimeInterval = ProcessInfo.processInfo.environment["BEAN_AWAY_SECONDS"].flatMap(TimeInterval.init) ?? 600

    var sinceSwitch = TimeInterval.infinity
    var focusedBefore: TimeInterval = 0
    var fullScreen = false
    var onCall = false

    static var sinceKey: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
    }

    static var sinceInput: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    func mayOpen(urgent: Bool, sinceKey: TimeInterval = Self.sinceKey, sinceInput: TimeInterval = Self.sinceInput) -> Bool {
        if urgent { return true }
        if fullScreen || onCall || sinceKey < Self.typing { return false }
        return sinceInput >= Self.idle || (sinceSwitch < Self.afterSwitch && focusedBefore >= Self.sustained)
    }
}
