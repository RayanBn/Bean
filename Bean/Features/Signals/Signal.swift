import Foundation

struct Signal: Codable {
    enum Kind: String, Codable { case launched, appActivated, windowChanged, idleStarted, idleEnded }

    let at: Date
    let kind: Kind
    let app: String?
    let bundleId: String?
    let windowTitle: String?
    let idleSeconds: Double
    var accessibility: Bool? = nil
    var screenRecording: Bool? = nil
}

struct Snapshot {
    let at: Date
    let app: String?
    let bundleId: String?
    let windowTitle: String?
    let idleSeconds: Double
    let focusedText: String?
    var browser: BrowserPage? = nil
    var presence: PresenceState? = nil
}
