import Foundation

struct Signal: Codable {
    enum Kind: String, Codable { case appActivated, windowChanged, idleStarted, idleEnded }

    let at: Date
    let kind: Kind
    let app: String?
    let bundleId: String?
    let windowTitle: String?
    let idleSeconds: Double
}

struct Snapshot {
    let at: Date
    let app: String?
    let bundleId: String?
    let windowTitle: String?
    let idleSeconds: Double
    let focusedText: String?
}
