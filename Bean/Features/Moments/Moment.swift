import Foundation

struct MomentRules: Decodable {
    let stayMinutes: Double
    let returnsInAnHour: Int
    let samePlaceAgainMinutes: Double
    let awayAfterSeconds: Double
    let filterAtLeast: Double
    let notNowDays: Double
    let ignoredDays: Double
    let rememberedDays: Double
    let offerExpiresMinutes: Double
    let ignoredCountsAsNotNow: Int
    let cleanRunsForQuiet: Int
    let offerEveryMinutes: Double
    let offersPerDay: Int
    let questionsPerDay: Int
    let pauseIdleSeconds: Double
    let quietDaysToLeave: Double
    let sessionWaitMinutes: Double
    let agentsBeanMakes: Int
    let stablePageSeconds: Double
    let sealedNames: [String]
    let sealedCategories: [String]

    static let starting: MomentRules = {
        guard let url = Bundle.main.url(forResource: "moments", withExtension: "json"), let data = try? Data(contentsOf: url),
              let rules = try? JSONDecoder().decode(MomentRules.self, from: data) else { fatalError("moments.json is missing from the app") }
        return rules
    }()
}

// A moment names no app in its rule. Its words come from the log, so "how did you know?" never depends on a model.
struct Moment: Codable, Equatable {
    enum Kind: String, Codable { case call = "call.started", stayed = "attention.settled", returned = "attention.returned", service = "service.changed" }

    let kind: Kind
    let at: Date
    var app: String?
    var bundleId: String?
    var window: Int?
    var title: String?
    var seconds = 0
    var returns = 0
    var detail: String?

    var titleWords: Set<String> { Moment.words(title) }
    var place: String { Moment.place(app: bundleId.flatMap { $0.isEmpty ? nil : $0 } ?? app, title: title) }
    private var minutes: Int { max(1, seconds / 60) }
    private var named: String { title ?? app ?? "this window" }

    var because: String {
        switch kind {
        case .call: String(format: "Because a call started in %@.", app ?? "an app")
        case .stayed: String(format: "Because you were on %@ for %@ minutes.", named, String(minutes))
        case .returned: String(format: "Because you came back to %@ %@ times in an hour.", named, String(returns))
        case .service: String(format: "Because %@ changed.", named)
        }
    }

    var card: String {
        switch kind {
        case .call: "Moment: a call started in \(app ?? "an app")\(title.map { ", \($0)" } ?? "")."
        case .service: "Moment: \(title ?? app ?? "a connected service") changed.\(detail.map { "\nWhat changed:\n\($0.prefix(1000))" } ?? "")"
        case .stayed, .returned: "Moment: \(app ?? "an app"), \(title ?? "untitled"). In it for \(minutes) minutes. Came back \(returns) times in the last hour."
        }
    }

    static func place(app: String?, title: String?) -> String {
        "\(app ?? "")|\(cleaned(title))"
    }

    static func words(_ title: String?) -> Set<String> {
        Set(cleaned(title).split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 && !$0.allSatisfy(\.isNumber) })
    }

    private static let counter = try! NSRegularExpression(pattern: #"^\(\d+\)\s*"#)

    // Spinners and unread counts change a title without changing the place.
    static func cleaned(_ title: String?) -> String {
        var text = (title ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = text.first, !first.isLetter, !first.isNumber, first != "(" { text.removeFirst() }
        text = counter.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// Pure and clocked by what it is given, so a recorded log and the live Mac run the same rule.
struct MomentFormer {
    private struct Focus {
        let event: LoggedEvent
        let place: String
        var seconds: TimeInterval = 0
    }

    let rules: MomentRules
    private var focus: Focus?
    private var clock: Date?
    private var entered: [String: [Date]] = [:]
    private var made: [String: Date] = [:]

    init(rules: MomentRules = .starting) { self.rules = rules }

    mutating func observe(_ event: LoggedEvent, detail: String? = nil) -> [Moment] {
        switch event.type {
        case "window.focused": return enter(event)
        case "window.unfocused":
            focus = nil
            return []
        case "window.closed":
            if focus?.event.window == event.window, event.window != nil { focus = nil }
            return []
        case "call.started":
            return [Moment(kind: .call, at: event.at, app: event.app, bundleId: event.bundleId, window: event.window, title: event.title)]
        case "service.changed":
            let moment = Moment(kind: .service, at: event.at, app: event.app, bundleId: event.bundleId, title: event.title, detail: detail)
            return mark(moment) ? [moment] : []
        default: return []
        }
    }

    mutating func advance(to now: Date, active: Bool) -> [Moment] {
        defer { clock = now }
        guard let last = clock, active, var current = focus else { return [] }
        current.seconds += max(0, now.timeIntervalSince(last))
        focus = current
        guard current.seconds >= rules.stayMinutes * 60 else { return [] }
        let moment = moment(.stayed, current, at: now)
        return mark(moment) ? [moment] : []
    }

    private mutating func enter(_ event: LoggedEvent) -> [Moment] {
        let place = Moment.place(app: event.bundleId.flatMap { $0.isEmpty ? nil : $0 } ?? event.app, title: event.title)
        guard focus?.place != place else {
            if let seconds = focus?.seconds { focus = Focus(event: event, place: place, seconds: seconds) }
            return []
        }
        clock = event.at
        let hour = event.at.addingTimeInterval(-3600)
        let earlier = (entered[place] ?? []).filter { $0 > hour }
        entered[place] = earlier + [event.at]
        let current = Focus(event: event, place: place)
        focus = current
        guard earlier.count >= rules.returnsInAnHour else { return [] }
        let moment = moment(.returned, current, at: event.at)
        return mark(moment) ? [moment] : []
    }

    private func moment(_ kind: Moment.Kind, _ focus: Focus, at: Date) -> Moment {
        Moment(kind: kind, at: at, app: focus.event.app, bundleId: focus.event.bundleId, window: focus.event.window, title: focus.event.title,
               seconds: Int(focus.seconds), returns: max(0, (entered[focus.place]?.count ?? 1) - 1))
    }

    private mutating func mark(_ moment: Moment) -> Bool {
        if let last = made[moment.place], moment.at.timeIntervalSince(last) < rules.samePlaceAgainMinutes * 60 { return false }
        made[moment.place] = moment.at
        if made.count > 500 {
            let hour = moment.at.addingTimeInterval(-3600)
            made = made.filter { $0.value > hour }
            entered = entered.filter { $0.value.contains { $0 > hour } }
        }
        return true
    }
}
