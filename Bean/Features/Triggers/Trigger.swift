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
