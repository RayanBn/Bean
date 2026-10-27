import Foundation

struct ElementLocator: Codable, Hashable {
    var bundleId: String
    var role: String
    var identifier: String?
    var domId: String?
    var label: String?
    var path: [String]
    var url: String?
    var href: String?
}

struct RecordedAction: Codable {
    enum Kind: String, Codable { case press, commit, key, shell }

    let at: Date
    let kind: Kind
    let app: String
    let appName: String?
    let window: String?
    let url: String?
    var element: ElementLocator?
    var value: String?
    var effect: AXDiff?
}

struct RoutineStep: Codable {
    var step: Step
    var variable: Bool
    var path: [String]
    var href: String?
}

struct Routine: Codable {
    let id: String
    var name: String
    var tokens: [String]
    var steps: [RoutineStep]
    var instances: Int
    var days: Int
    var loops: Bool
    var scope: String?
}

struct RoutineEvent: Codable {
    let at: Date
    let event: String
    var routine: String?
    var name: String?
    var detail: String?
    var steps: [String]?
}
