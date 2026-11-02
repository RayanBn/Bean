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

@MainActor
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

    static func standing() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("standing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let rules = MomentRules.starting
        func moment(_ title: String, app: String = "x.app") -> Moment { Moment(kind: .stayed, at: now, app: "App", bundleId: app, window: 1, title: title, seconds: 120) }
        var jobs = MomentJobs(file: file)
        let billing = moment("Refactor billing module")
        check("no answer: go on", jobs.standing(for: billing, now: now) == .goOn(nil))
        check("a key narrows only to words in the title", MomentKey.words(modelKey: "Editor billing sessions", moment: billing) == ["billing"])
        check("a key with no title word keeps the whole title", MomentKey.words(modelKey: "Editor sessions", moment: billing) == ["billing", "module", "refactor"])
        jobs.move(.notNow, moment: billing, words: ["billing"], now: now)
        check("not now stops that key", jobs.standing(for: billing, now: now) == .stop("not now"))
        check("not now leaves other work", jobs.standing(for: moment("Weekly report"), now: now) == .goOn(nil))
        check("not now ends after 14 days", jobs.standing(for: billing, now: now.addingTimeInterval(14 * 86400 + 1)) != .stop("not now"))
        jobs.never(moment: moment("Anything"))
        check("never here covers the whole app", jobs.standing(for: moment("Weekly report"), now: now) == .stop("never here"))
        jobs = MomentJobs(file: file)
        check("answers survive a relaunch", jobs.standing(for: moment("Weekly report"), now: now) == .stop("never here"))
        check("a yes for an app does not cover hearing", jobs.standing(for: moment("Weekly report"), hearing: true, now: now) == .goOn(nil))
        var job = MomentJob(bundle: "b", words: [])
        job = job.moved(.asked, now: now, rules: rules)
        check("a result found moves silent to offer", job.step == .offer)
        job = job.moved(.yes, now: now, rules: rules)
        check("yes moves to keep doing it", job.step == .keepDoing)
        job = job.moved(.keepDoing, now: now, rules: rules)
        check("keep doing it moves to alone, saying so", job.step == .aloneSaying)
        for _ in 0..<(rules.cleanRunsForQuiet - 1) { job = job.moved(.cleanRun, now: now, rules: rules) }
        check("not quiet before 3 clean runs", job.step == .aloneSaying)
        job = job.moved(.cleanRun, now: now, rules: rules)
        check("3 clean runs move to alone and quiet", job.step == .aloneQuiet)
        job = job.moved(.undone("not this kind"), now: now, rules: rules)
        check("an undo moves down at once and keeps the words", job.step == .aloneSaying && job.cleanRuns == 0 && job.corrections == ["not this kind"])
        var ignored = MomentJob(bundle: "b", words: []).moved(.ignored, now: now, rules: rules)
        check("once ignored stays open", ignored.quietUntil == nil)
        ignored = ignored.moved(.ignored, now: now, rules: rules)
        check("twice ignored counts as not now", ignored.quietUntil != nil)
        check("a messaging app is sealed by data", SealedApps.contains(bundleId: "com.example.whatsapp", app: "WhatsApp"))
        check("a social app is sealed by its own category", SealedApps.contains(bundleId: "com.hnc.Discord", app: "Discord"))
        check("a working app is not sealed", !SealedApps.contains(bundleId: "com.apple.iWork.Numbers", app: "Numbers"))
    }

    private struct FilterCase: Decodable { let y: Int; let app: String; let title: String; let minutes: Double; let returns: Int; let known: String }
    private struct FilterRow: Encodable { let y: Int; let score: Double?; let privateTitle: Bool; let ms: Int; let app: String }

    static func filter(cases file: String, moments: Bool) async {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)) else { return print("no file") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cards: [(y: Int, moment: Moment, known: String)]
        if moments {
            cards = ((try? decoder.decode([Moment].self, from: data)) ?? []).map { (-1, $0, "nothing yet") }
        } else {
            cards = ((try? decoder.decode([FilterCase].self, from: data)) ?? []).map { item in
                (item.y, Moment(kind: .stayed, at: Date(), app: item.app, title: item.title, seconds: Int(item.minutes * 60), returns: item.returns), item.known)
            }
        }
        _ = await StrandsDecider.score(state: "warm up", question: "warm up")
        for card in cards {
            let started = Date()
            let score = await StrandsDecider.score(state: MomentFilter.card(card.moment, knows: card.known), question: MomentFilter.question)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let privateTitle = await PrivateCheck.titleIsPrivate(card.moment.title)
            let row = FilterRow(y: card.y, score: score, privateTitle: privateTitle, ms: ms, app: card.moment.app ?? "")
            print(String(decoding: (try? JSONEncoder().encode(row)) ?? Data(), as: UTF8.self))
        }
    }

    static func run() async {
        eventLog()
        former()
        standing()
        await MomentTable.run()
        print(failed == 0 ? "all checks ok" : "\(failed) FAILED")
    }
}

@MainActor
enum MomentLive {
    static func run(_ args: [String], store: AgentStore) {
        guard let seconds = args.first.flatMap(Double.init) else { print("usage: moment-live <seconds>, after adopt-bean"); exit(64) }
        let answerWith = args.dropFirst().first
        let reader = WindowReader(store: store)
        let worker = reader.worker
        if args.contains("--slow-attach") {
            worker.onAttach = { id, number in
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    guard let window = WindowChannels.open().first(where: { $0.number == number }) else { return }
                    store.attach(id, to: WindowChannels.attachment(for: window))
                }
            }
        }
        var calls: AnyObject?
        if #available(macOS 14.2, *), ProcessInfo.processInfo.environment["BEAN_FAKE_CALL_FILE"] != nil { calls = CallListening(store: store, worker: worker) }
        var shown = 0, lines: [String] = [], answered = Set<UUID>()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                for entry in worker.gateDecisions.suffix(max(0, worker.gateDecisions.count - shown)) {
                    print("gate \(entry.event) [\(entry.title ?? entry.app ?? "")] \(entry.decision) by \(entry.by) score \(entry.score.map { String(format: "%.3f", $0) } ?? "-") \(entry.detail ?? "")")
                }
                shown = worker.gateDecisions.count
                if let line = worker.momentLine?.text, !lines.contains(line) {
                    lines.append(line)
                    print("line: \(line)")
                    if args.contains("--undo"), let agent = worker.momentLine?.undoAgent {
                        print("undo pressed")
                        worker.moments?.undo(agent: agent)
                    }
                }
                guard let bean = store.agents.first(where: \.isBean) else { return }
                for need in AgentFolder(bean, in: store).needs where (need.moment != nil || need.consent != nil) && !answered.contains(need.id) {
                    answered.insert(need.id)
                    print("need: \(need.question) | \(need.detail ?? "") | \(need.options)")
                    if let answerWith {
                        let reply = need.options.contains(answerWith) ? answerWith : (need.options.first ?? answerWith)
                        print("answer: \(reply)")
                        worker.answer(bean.id, need: need.id, reply)
                    }
                }
                fflush(stdout)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            for agent in store.agents where !agent.isBean {
                let folder = AgentFolder(agent, in: store)
                print("agent \(agent.name) window \(agent.attachment?.windowTitle ?? "none") born \(folder.card?.bornFrom.kind ?? "") \(folder.card?.bornFrom.words ?? "") leave \(folder.card?.leaveWhen ?? "") readOnly \(folder.card?.readOnly ?? false) quiet \(folder.card?.job.quiet ?? "")")
            }
            print("reading yes: \((try? String(contentsOf: JSONLog.directory.appendingPathComponent("reading-yes.json"), encoding: .utf8)) ?? "none")")
            print("standing: \((try? String(contentsOf: JSONLog.directory.appendingPathComponent("standing.json"), encoding: .utf8)) ?? "none")")
            withExtendedLifetime((reader, calls)) { exit(0) }
        }
    }
}

// One paid call per card, stopped by a spend limit. Fake cards only.
@MainActor
enum MomentPaid {
    private struct Card: Decodable { let expect, app, bundle, title: String; let minutes: Double; let returns: Int; var detail: String?; var goals: String?; var jobs: String?; var next: String? }

    static func run(_ args: [String]) async {
        let run = ProcessInfo.processInfo.environment["BEAN_RUN_ID"] ?? ""
        guard let file = args.first, let limit = args.dropFirst().first.flatMap(Double.init), !run.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: file)), let cards = try? JSONDecoder().decode([Card].self, from: data) else {
            return print("usage: moment-paid <cards.json> <dollars>, with BEAN_RUN_ID")
        }
        func spent() -> Double { CostLedger.lines.filter { $0.run == run }.reduce(0) { $0 + $1.usd } }
        for card in cards {
            guard spent() < limit else { print("stopped at the limit"); break }
            let kind: Moment.Kind = card.detail != nil ? .service : card.returns >= 3 ? .returned : .stayed
            let moment = Moment(kind: kind, at: Date(), app: card.app, bundleId: card.bundle, window: 1, title: card.title, seconds: Int(card.minutes * 60), returns: card.returns, detail: card.detail)
            let oldInput = args.contains("--old-input")
            let input = oldInput ? "What the person wants: nothing yet\nWhat Bean noticed before:\n\nWhat they answered before:\nnothing yet\n\n\(moment.card)\nAgent on this window: none."
                : MomentDesk.text(for: moment, goals: card.goals, noticed: "", jobs: card.jobs ?? "")
            let answer = await MomentAnswer.ask(about: input)
            let outcome: String
            if let answer {
                switch MomentDecision.decide(moment, answer: answer, job: nil, readingYes: false) {
                case .quiet: outcome = "silent"
                case .remember: outcome = "remember"
                case .rejected(let why): outcome = "rejected: \(why)"
                case .ask: outcome = "ask"
                case .act: outcome = "act"
                }
            } else { outcome = "no usable answer" }
            print("CARD expect=\(card.expect) | \(card.app), \(card.title), \(Int(card.minutes)) min | verdict=\(answer?.verdict.rawValue ?? "-") needs=\(answer?.needs.rawValue ?? "-") when=\(answer?.when.rawValue ?? "-") key=\(answer?.key ?? "-") | result=\(answer?.result ?? "-") | saw=\(answer?.saw ?? "-") | code=\(outcome) | words=\(answer.map { MomentKey.words(modelKey: $0.key, moment: moment).joined(separator: ",") } ?? "-") | nextCovered=\(card.next.map { next in answer.map { Set(MomentKey.words(modelKey: $0.key, moment: moment)).isSubset(of: Moment.words(next)) } ?? false }.map(String.init) ?? "-")")
            fflush(stdout)
        }
        print(String(format: "spent $%.4f on %d calls", spent(), CostLedger.lines.filter { $0.run == run }.count))
    }
}

// The real filter and the model client, against a fake model. Each row says what reached the model.
@MainActor
enum LocalFilterProof {
    private static var failed = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failed += 1 }
        print("check \(ok ? "ok" : "FAIL") \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    private static func moment(_ app: String, _ title: String, filter on: Bool) async -> (sent: [String], decision: String, entries: Int) {
        BeanSettings.shared.filtersWhatBeanSees = on
        var sent: [String] = []
        let script = MomentScript(realModel: { text in
            sent.append(text)
            return await MomentAnswer.ask(about: text)
        })
        await script.on(app, "x.\(app.lowercased())", title, window: 7)
        await script.wait(130)
        for _ in 0..<400 where script.hands.entries.isEmpty && !OffLimitsProbe.matches(title) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        await script.settle()
        return (sent, script.hands.entries.last?.decision ?? "none", script.hands.entries.count)
    }

    static func run(_ part: String) async {
        let open = OpenWindow(number: 7, pid: 0, app: "Pages", bundleId: "x.pages", title: "Therapy session notes")
        switch part {
        case "strands":
            let blockedOn = await moment("Netflix", "Episode 4", filter: true)
            check("filter on: a moment the filter blocks does not reach the model", blockedOn.sent.isEmpty && blockedOn.decision == "filtered", blockedOn.decision)
            let blockedOff = await moment("Netflix", "Episode 4", filter: false)
            check("filter off: the same moment reaches the model, once, with its title", blockedOff.sent.count == 1 && blockedOff.sent[0].contains("Episode 4"), "\(blockedOff.sent.count) sent, \(blockedOff.decision)")
            let privateOn = await moment("Pages", "Therapy session notes", filter: true)
            check("filter on: a private-looking title does not reach the model", privateOn.sent.isEmpty && privateOn.decision == "keptPrivate", privateOn.decision)
            let lineOn = await WindowChannels.line(for: open)
            check("filter on: Bean's window list keeps it private", lineOn.contains("title kept private"), lineOn)
            let privateOff = await moment("Pages", "Therapy session notes", filter: false)
            check("filter off: it reaches the model, once, with its title", privateOff.sent.count == 1 && privateOff.sent[0].contains("Therapy session notes"), "\(privateOff.sent.count) sent, \(privateOff.decision)")
            let lineOff = await WindowChannels.line(for: open)
            check("filter off: Bean's window list shows it", lineOff.contains("Therapy session notes"), lineOff)
            let limits = await moment("Pages", "topsecret plan", filter: false)
            check("filter off: an off-limits window still reaches nothing", limits.sent.isEmpty && limits.entries == 0, "\(limits.sent.count) sent, \(limits.entries) rows")
            let sealed = await moment("WhatsApp", "A private chat", filter: false)
            check("filter off: a sealed app still reaches nothing", sealed.sent.isEmpty && sealed.entries == 0, "\(sealed.sent.count) sent")
            let backOn = await moment("Netflix", "Episode 4", filter: true)
            check("back on, with no relaunch: blocked again", backOn.sent.isEmpty && backOn.decision == "filtered", backOn.decision)
        case "missing", "broken":
            let onNow = await moment("Pages", "Quarterly report", filter: true)
            check("\(part), filter on: nothing reaches the model", onNow.sent.isEmpty && onNow.decision == "noLocalCheck", "\(onNow.sent.count) sent, \(onNow.decision)")
            let lineOn = await WindowChannels.line(for: open)
            check("\(part), filter on: Bean's window list holds the title", lineOn.contains("title kept private"), lineOn)
            let offNow = await moment("Pages", "Quarterly report", filter: false)
            check("\(part), filter off by choice: it reaches the model", offNow.sent.count == 1 && offNow.sent[0].contains("Quarterly report"), "\(offNow.sent.count) sent")
        default: print("usage: strands|missing|broken")
        }
        print(failed == 0 ? "all ok" : "\(failed) FAILED")
    }
}

enum OffLimitsProbe {
    static func matches(_ title: String) -> Bool { OffLimits.match(title) != nil || title == "A private chat" }
}
