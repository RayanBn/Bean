import Foundation

// Replays recorded logs through the real rule. No model, read-only on what it replays, and it prints no window title.
enum MomentReplay {
    struct Row: Decodable {
        let at: Date
        let event: String
        var app: String?
        var title: String?
        var decision: String?
    }

    struct Result {
        var rows = 0
        var moments: [Moment] = []
        var wakes = 0
        var wakesWorked = 0
        var wakesWithMoment = 0
        var wakesWithAgentText = 0
        var wakesGone = 0
        var workedHadMoment = false
        var activeHours = 0
        var days = 0
    }

    private static let testApp = try! NSRegularExpression(pattern: #"-zq[0-9a-f]+$|^(viewer|FakeCoder|swift-frontend)$"#)

    static func isTestApp(_ app: String?) -> Bool {
        guard let app else { return false }
        return testApp.firstMatch(in: app, range: NSRange(app.startIndex..., in: app)) != nil
    }

    static func rows(in file: URL) -> [Row] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let row = try? decoder.decode(Row.self, from: Data(line.utf8)), row.decision != nil else { return nil }
            return row
        }.sorted { $0.at < $1.at }
    }

    // The old log has no focus row, so focus is an estimate: the last switch, with the last title seen for that app.
    static func replay(_ rows: [Row], realAppsOnly: Bool, rules: MomentRules = .starting) -> Result {
        var former = MomentFormer(rules: rules)
        var result = Result()
        var titles: [String: String] = [:]
        var front: String?
        var last: Date?
        var momentsSinceWake = 0, agentTextSinceWake = 0
        var hours = Set<String>(), days = Set<String>()
        let hourFormat = ISO8601DateFormatter()
        for row in rows {
            if row.event == "wake" {
                result.wakes += 1
                let worked = row.decision == "museWorked"
                if worked { result.wakesWorked += 1; result.workedHadMoment = momentsSinceWake > 0 }
                if momentsSinceWake > 0 { result.wakesWithMoment += 1 } else if agentTextSinceWake > 0 { result.wakesWithAgentText += 1 } else { result.wakesGone += 1 }
                momentsSinceWake = 0
                agentTextSinceWake = 0
                continue
            }
            if realAppsOnly, isTestApp(row.app) { continue }
            guard let app = row.app else { continue }
            result.rows += 1
            let stamp = hourFormat.string(from: row.at)
            hours.insert(String(stamp.prefix(13)))
            days.insert(String(stamp.prefix(10)))
            let gap = last.map { row.at.timeIntervalSince($0) } ?? 0
            var formed = former.advance(to: row.at, active: gap <= 1800)
            last = row.at
            if let title = row.title, row.event != "window.closed" { titles[app] = title }
            if row.event == "window.content", row.decision == "yes" { agentTextSinceWake += 1 }
            switch row.event {
            case "app.switched":
                front = app
                formed += former.observe(LoggedEvent(at: row.at, type: "window.focused", app: app, title: titles[app]))
            case "window.opened", "window.changed", "window.content":
                if front == app || front == nil {
                    front = app
                    formed += former.observe(LoggedEvent(at: row.at, type: "window.focused", app: app, title: titles[app]))
                }
            case "call.started": formed += former.observe(LoggedEvent(at: row.at, type: "call.started", app: app, title: row.title))
            default: break
            }
            result.moments += formed
            momentsSinceWake += formed.count
        }
        result.activeHours = hours.count
        result.days = days.count
        return result
    }

    static func report(_ files: [String], realAppsOnly: Bool, dump: String?) {
        let rows = files.flatMap { rows(in: URL(fileURLWithPath: $0)) }.sorted { $0.at < $1.at }
        let result = replay(rows, realAppsOnly: realAppsOnly)
        let kinds = Dictionary(grouping: result.moments, by: \.kind.rawValue).mapValues(\.count).sorted { $0.key < $1.key }
        print("rows \(result.rows) in \(result.activeHours) active hours on \(result.days) days, real apps only: \(realAppsOnly)")
        print("moments \(result.moments.count): \(kinds.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
        print(String(format: "per active hour %.1f, per day %.1f", Double(result.moments.count) / Double(max(1, result.activeHours)), Double(result.moments.count) / Double(max(1, result.days))))
        print("old wakes \(result.wakes), of which worked \(result.wakesWorked). Moment since the wake before: \(result.wakesWithMoment). Only text on an agent's window: \(result.wakesWithAgentText). Neither, so gone: \(result.wakesGone). The wake that worked had a moment: \(result.workedHadMoment)")
        if let dump {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try? encoder.encode(result.moments).write(to: URL(fileURLWithPath: dump))
        }
    }
}

enum MomentChecks {
    static var failed = 0

    static func check(_ name: String, _ ok: Bool) {
        if !ok { failed += 1 }
        print("check \(ok ? "ok" : "FAIL") \(name)")
    }

    static func eventLog() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("eventlog-\(UUID().uuidString)")
        let log = EventLog(folder: folder)
        log.add(SenseSignal(type: "window.content", app: "Private", bundleId: "a.b", window: 1, title: "Secret title", detail: "text in the window"), offLimits: true, sealed: false)
        log.add(SenseSignal(type: "window.content", app: "Sealed", bundleId: "a.c", window: 2, title: "Sealed title", detail: "text in the window"), offLimits: false, sealed: true)
        log.add(SenseSignal(type: "window.focused", app: "Open", bundleId: "a.d", window: 3, title: "Open title", detail: "text in the window"), offLimits: false, sealed: false)
        log.flush()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let text = names.compactMap { try? String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) }.joined()
        check("log holds no text from inside a window", !text.contains("text in the window"))
        check("off limits keeps no app or title", !text.contains("Private") && !text.contains("Secret title"))
        check("sealed keeps no title", !text.contains("Sealed title") && text.contains("Sealed"))
        check("open window keeps app and title", text.contains("Open title"))
        let old = folder.appendingPathComponent("2020-01-01.jsonl"), recent = folder.appendingPathComponent("2026-10-30.jsonl")
        FileManager.default.createFile(atPath: old.path, contents: Data())
        FileManager.default.createFile(atPath: recent.path, contents: Data())
        log.prune(now: ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z")!)
        check("older than 30 days goes", !FileManager.default.fileExists(atPath: old.path))
        check("recent days stay", FileManager.default.fileExists(atPath: recent.path))
        try? FileManager.default.removeItem(at: folder)
    }

    static func former() {
        func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_000_000 + seconds) }
        func focus(_ title: String, _ time: Double) -> LoggedEvent { LoggedEvent(at: at(time), type: "window.focused", app: "AnyApp", bundleId: "x.y", window: title.count, title: title) }
        var former = MomentFormer()
        _ = former.observe(focus("Report", 0))
        check("stays under 2 minutes: nothing", former.advance(to: at(0), active: true).isEmpty && former.advance(to: at(119), active: true).isEmpty)
        check("idle time does not count", former.advance(to: at(600), active: false).isEmpty)
        let settled = former.advance(to: at(601), active: true)
        check("2 minutes active makes one moment", settled.map(\.kind) == [.stayed])
        check("same place stays one moment for an hour", former.advance(to: at(1500), active: true).isEmpty)
        check("a moment past the hour", former.advance(to: at(4300), active: true).map(\.kind) == [.stayed])
        var flips = MomentFormer()
        var kinds: [Moment.Kind] = []
        for index in 0..<4 {
            kinds += flips.observe(focus("Sheet", Double(index) * 60)).map(\.kind)
            _ = flips.observe(focus("Other", Double(index) * 60 + 20))
        }
        check("third return in an hour makes one moment", kinds == [.returned])
        var spin = MomentFormer()
        _ = spin.observe(focus("⠂ Fix tests", 0))
        _ = spin.advance(to: at(0), active: true)
        _ = spin.observe(focus("✳ Fix tests", 60))
        check("a spinner in a title is the same place", spin.advance(to: at(120), active: true).map(\.kind) == [.stayed])
        check("an unread count is the same place", Moment.place(app: "a", title: "(3) Inbox") == Moment.place(app: "a", title: "Inbox"))
        var call = MomentFormer()
        check("a call is a moment at once", call.observe(LoggedEvent(at: at(0), type: "call.started", app: "Any")).map(\.kind) == [.call])
    }

    static func run() {
        eventLog()
        former()
        print(failed == 0 ? "all checks ok" : "\(failed) FAILED")
    }
}
