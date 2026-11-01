import Foundation

// The report's cases, on fake window titles and a scripted model. No paid call. It runs the real former, standing answers, questions, ladder and desk.
@MainActor
final class FakeMomentHands: MomentHands {
    var actions: [String] = []
    var held: Set<Int> = []
    var entries: [GateEntry] = []
    var lastOffer: MomentOffer?
    var nextAgent = UUID()

    func show(_ offer: MomentOffer) {
        lastOffer = offer
        actions.append("\(offer.kind == .keepDoing ? "keep?" : "offer"): \(offer.result) [\(offer.because)]")
    }
    func withdraw(_ offer: MomentOffer) { actions.append("withdrawn") }
    func say(_ line: String, undoAgent: UUID?) { actions.append("line\(undoAgent == nil ? "" : "+undo"): \(line)") }
    func note(_ text: String) { actions.append("note: \(text)") }
    func remember(_ text: String) { actions.append("remembered") }
    func place(moment: Moment, result: String, needs: MomentAnswer.Needs, agent: UUID?) async -> UUID? {
        actions.append("placed on \(moment.title ?? moment.app ?? "")")
        if let window = moment.window { held.insert(window) }
        return agent ?? nextAgent
    }
    var firstWorkGoes = true
    func firstWork(agent: UUID, result: String) async -> Bool {
        actions.append("first work")
        return firstWorkGoes
    }
    func agentName(_ id: UUID) -> String? { "Ellis" }
    func delegate(moment: Moment, result: String) async { actions.append("delegated: \(result)") }
    func undo(agent: UUID) { actions.append("undone") }
    func leave(window: Int) { held.remove(window) }
    func holdsWindow(_ number: Int) -> Bool { held.contains(number) }
    func holdsApp(_ bundleId: String?) -> Bool { false }
    var look = UserSessionLook.nothing
    var allowed = false
    var sessionChecks = 0
    func sessionLook(window: Int?, alsoClosed: Bool) async -> UserSessionLook {
        sessionChecks += 1
        return look
    }
    func sessionAllowed(_ session: UserSession) -> Bool { allowed }
    func takeOver(_ session: UserSession) async -> String? {
        actions.append("took over \(session.title)")
        return nil
    }
    func decline(_ session: UserSession, forGood: Bool) { actions.append(forGood ? "declined for good" : "declined") }
    func wantsToLeave(rules: MomentRules, now: Date) {}
    func record(_ entry: GateEntry) { entries.append(entry) }
}

@MainActor
final class MomentScript {
    let hands = FakeMomentHands()
    let desk: MomentDesk
    private(set) var clock: Date
    private let folder: URL

    init(answers: @escaping (String) -> MomentAnswer? = { _ in nil }, look: @escaping (Moment) -> MomentFilter.Verdict = { _ in .pass(0.2) }, realModel: ((String) async -> MomentAnswer?)? = nil) {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("moment-table-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: JSONLog.directory.appendingPathComponent("reading-yes.json"))
        clock = ISO8601DateFormatter().date(from: "2026-11-02T09:00:00Z")!
        desk = MomentDesk(hands: hands, jobs: MomentJobs(file: folder.appendingPathComponent("standing.json")), doseFile: folder.appendingPathComponent("dose.json"),
                          brain: { text in
                              if let realModel { return await realModel(text) }
                              return answers(text)
                          }, look: { moment, knows in
                              realModel == nil ? look(moment) : await MomentFilter.look(at: moment, knows: knows)
                          })
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func on(_ app: String, _ bundle: String, _ title: String?, window: Int) async {
        await desk.sensed(SenseSignal(type: "window.focused", at: clock, app: app, bundleId: bundle, window: window, title: title))
        await settle()
    }

    func signal(_ type: String, app: String? = nil, bundle: String? = nil, title: String? = nil, window: Int? = nil, detail: String? = nil) async {
        await desk.sensed(SenseSignal(type: type, at: clock, app: app, bundleId: bundle, window: window, title: title, detail: detail))
        await settle()
    }

    func wait(_ seconds: TimeInterval, idle: TimeInterval = 0) async {
        var left = seconds
        while left > 0 {
            let step = min(left, 30)
            clock = clock.addingTimeInterval(step)
            await desk.tick(now: clock, idle: idle)
            left -= step
        }
        await settle()
    }

    func pause() async {
        clock = clock.addingTimeInterval(11)
        await desk.tick(now: clock, idle: 11)
        await settle()
    }

    func answer(_ text: String) async {
        guard let offer = hands.lastOffer else { return }
        await desk.answered(offer.id, text, now: clock)
        await settle()
    }

    func settle() async {
        for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(5)) }
    }

    var costs: Int { desk.asked }
}

@MainActor
enum MomentTable {
    private static func answer(_ verdict: MomentAnswer.Verdict, result: String = "", saw: String = "the title", needs: MomentAnswer.Needs = .readWindow, key: String = "") -> MomentAnswer {
        MomentAnswer(verdict: verdict, result: result, saw: saw, needs: needs, key: key, when: .nextPause)
    }

    private static var scenarios: [(String, () async -> Void)] = []
    private static func expect(_ name: String, _ ok: Bool, _ detail: String = "") { MomentChecks.check(name + (ok || detail.isEmpty ? "" : " -> \(detail)"), ok) }

    static func run() async {
        await claude()
        await meet()
        await freelancer()
        await traveller()
        await applicant()
        await writer()
        await pullRequest()
        await service()
        await silent()
        await rules()
    }

    private static func claude() async {
        print("-- A. On Claude: keep the session moving")
        let result = "keep this session moving and only call you for decisions"
        var firstInput = ""
        let script = MomentScript(answers: { text in
            if firstInput.isEmpty { firstInput = text }
            return answer(.offer, result: result, needs: .actInWindow, key: "Claude refactor")
        })
        await script.on("Claude", "com.example.coder", "Refactor billing", window: 10)
        await script.wait(90)
        expect("under 2 minutes: nothing, 0 calls", script.costs == 0 && script.hands.actions.isEmpty)
        await script.wait(60)
        expect("no objective and no history: the model reads only the moment", firstInput.hasPrefix("Moment:") && !firstInput.contains("nothing yet") && !firstInput.contains("What the person wants"), firstInput)
        expect("2 minutes: one model call, nothing shown while you work", script.costs == 1 && script.hands.actions.isEmpty, "\(script.hands.actions)")
        await script.pause()
        let shown = script.hands.lastOffer
        expect("at a pause the notch shows one offer with result, source and answers", shown?.result == result && shown?.because.contains("Refactor billing") == true && shown?.answers == ["Yes", "Not now", "Never here"], "\(script.hands.actions)")
        await script.answer("Yes")
        expect("yes places the agent with no second question", script.hands.actions.contains("placed on Refactor billing") && ReadingYes.covers("com.example.coder"), "\(script.hands.actions)")
        expect("yes says one line with undo, then starts work", script.hands.actions.contains { $0.hasPrefix("line+undo") } && script.hands.actions.contains("first work"))
        await script.pause()
        expect("after its first work: keep doing it?", script.hands.lastOffer?.kind == .keepDoing, "\(script.hands.actions)")
        await script.answer("Keep doing it")
        print("   cost: 1 decision call. On yes, 1 call to write the agent and its first run.")
        let failed = MomentScript(answers: { _ in answer(.offer, result: result, needs: .actInWindow, key: "Claude refactor") })
        failed.hands.firstWorkGoes = false
        await failed.on("Claude", "com.example.coder", "Refactor billing", window: 10)
        await failed.wait(130)
        await failed.pause()
        await failed.answer("Yes")
        await failed.pause()
        expect("a failed first run does not ask keep doing it", failed.hands.lastOffer?.kind == .proposal && !failed.hands.actions.contains { $0.hasPrefix("keep?") }, "\(failed.hands.actions)")
        expect("the line says who is on it, and promises nothing", failed.hands.actions.contains { $0.hasPrefix("line+undo") && $0.contains("Nothing has changed") && !$0.contains(result) }, "\(failed.hands.actions)")
        script.hands.actions = []
        await script.wait(3600)
        await script.on("Claude", "com.example.coder", "Fix auth tests", window: 11)
        await script.wait(130)
        expect("next day, new window: one call, placed, one line, no question", script.costs == 2 && script.hands.actions.contains("placed on Fix auth tests") && script.hands.lastOffer?.kind == .keepDoing && !script.hands.actions.contains { $0.hasPrefix("offer") }, "\(script.hands.actions)")
        let agent = script.hands.nextAgent
        script.desk.undo(agent: agent, words: "not this kind")
        expect("undo takes it off and keeps the words", script.hands.actions.contains("undone") && script.desk.jobs.all.contains { $0.corrections == ["not this kind"] })
        print("   cost: 1 decision call a day, 0 if a standing no applies.")
        print("-- A on a sealed app")
        let sealedApp = "com.anthropic.claudefordesktop"
        var saidLimit = false
        let promises = MomentScript(answers: { text in
            saidLimit = text.contains("What an agent can do on this window")
            return answer(.offer, result: result, needs: .actInWindow, key: "Claude refactor")
        })
        await promises.on("Claude", sealedApp, "Refactor auth", window: 12)
        await promises.wait(130)
        await promises.pause()
        expect("the card says what an agent really can do on a sealed window", saidLimit)
        let fixed = Skills.forApp(sealedApp)?.offer
        expect("no session at all: fixed true words at the pause, never the model's promise", fixed != nil && promises.hands.lastOffer?.result == fixed, "\(promises.hands.actions)")
        await promises.answer("Yes")
        expect("yes to the fixed words places the agent, starts no work and asks nothing more", promises.hands.actions.contains("placed on Refactor auth") && !promises.hands.actions.contains("first work") && promises.hands.lastOffer?.kind == .proposal, "\(promises.hands.actions)")
        expect("a yes on a sealed window gives no reading yes", !ReadingYes.covers(sealedApp))
        print("-- A on a sealed app, with a session of theirs gone idle")
        let session = UserSession(id: "abc", title: "Refactor auth", folder: "/tmp", branch: nil, lastActivity: nil)
        let words = "I'll take over your session “Refactor auth” while you're away from it?"
        func keeper() async -> MomentScript {
            let script = MomentScript(answers: { _ in answer(.offer, result: result, needs: .actInWindow, key: "Claude refactor") })
            script.hands.look = .offer(UserSessionOffer(session: session, words: words))
            await script.on("Claude", sealedApp, "Refactor auth", window: 14)
            await script.wait(130)
            return script
        }
        let yes = await keeper()
        expect("while they stay on it: nothing shown, one session check", yes.hands.lastOffer == nil && yes.hands.sessionChecks == 1)
        await yes.on("Mail", "com.apple.mail", "Inbox", window: 99)
        await yes.wait(4)
        expect("when they leave: the take-over words", yes.hands.lastOffer?.result == words, "\(yes.hands.actions)")
        await yes.answer("Yes")
        expect("yes takes over, places no agent, says one line", yes.hands.actions.contains("took over Refactor auth") && !yes.hands.actions.contains { $0.hasPrefix("placed") } && yes.hands.actions.contains { $0.hasPrefix("line") } && yes.costs == 1, "\(yes.hands.actions)")
        let notNow = await keeper()
        await notNow.on("Mail", "com.apple.mail", "Inbox", window: 99)
        await notNow.wait(4)
        await notNow.answer("Not now")
        expect("not now declines for now and quiets the key", notNow.hands.actions.contains("declined") && notNow.desk.jobs.standing(for: Moment(kind: .stayed, at: notNow.clock, bundleId: sealedApp, title: "Refactor auth"), now: notNow.clock) == .stop("not now"), "\(notNow.hands.actions)")
        let never = await keeper()
        await never.on("Mail", "com.apple.mail", "Inbox", window: 99)
        await never.wait(4)
        await never.answer("Never here")
        expect("never declines for good and closes the app", never.hands.actions.contains("declined for good") && never.desk.jobs.standing(for: Moment(kind: .stayed, at: never.clock, bundleId: sealedApp, title: "Anything"), now: never.clock) == .stop("never here"), "\(never.hands.actions)")
        let again = MomentScript(answers: { _ in answer(.offer, result: result, needs: .actInWindow, key: "Claude refactor") })
        again.hands.look = .offer(UserSessionOffer(session: session, words: words))
        again.hands.allowed = true
        await again.on("Claude", sealedApp, "Refactor auth", window: 15)
        await again.wait(130)
        await again.on("Mail", "com.apple.mail", "Inbox", window: 99)
        await again.wait(4)
        expect("a session with a yes: takes over with one line and no question", again.hands.lastOffer == nil && again.hands.actions.contains("took over Refactor auth") && again.hands.actions.contains { $0.hasPrefix("line") }, "\(again.hands.actions)")
        let busy = MomentScript(answers: { _ in answer(.offer, result: result, needs: .actInWindow, key: "Claude refactor") })
        busy.hands.look = .active
        await busy.on("Claude", sealedApp, "Refactor auth", window: 16)
        await busy.wait(130)
        await busy.on("Mail", "com.apple.mail", "Inbox", window: 99)
        await busy.wait(120)
        let checks = busy.hands.sessionChecks
        expect("session still moving after they left: it waits, and only about once a minute", busy.hands.lastOffer == nil && checks >= 2 && checks <= 5 && busy.costs == 1, "checks \(checks) \(busy.hands.actions)")
        busy.hands.look = .offer(UserSessionOffer(session: session, words: words))
        await busy.wait(70)
        expect("once it goes idle, the take-over words", busy.hands.lastOffer?.result == words, "\(busy.hands.actions)")
        let stuck = MomentScript(answers: { _ in answer(.offer, result: result, needs: .actInWindow, key: "Claude refactor") })
        stuck.hands.look = .active
        await stuck.on("Claude", sealedApp, "Refactor auth", window: 17)
        await stuck.wait(130)
        await stuck.on("Mail", "com.apple.mail", "Inbox", window: 99)
        await stuck.wait(60 * MomentRules.starting.sessionWaitMinutes + 90)
        expect("still moving after the wait: the fixed words", stuck.hands.lastOffer?.result == fixed, "\(stuck.hands.actions)")
        let held = MomentScript(answers: { _ in answer(.offer, result: result, needs: .actInWindow, key: "Claude refactor") })
        held.hands.look = .held
        await held.on("Claude", sealedApp, "Refactor auth", window: 18)
        await held.wait(130)
        await held.pause()
        expect("already taken over: nothing shown", held.hands.lastOffer == nil && held.hands.entries.last?.decision == "rejected", "\(held.hands.actions)")
        let closedOff = MomentScript(answers: { _ in answer(.offer, result: result, needs: .actInWindow, key: "Claude refactor") })
        closedOff.hands.look = .never
        await closedOff.on("Claude", sealedApp, "Refactor auth", window: 19)
        await closedOff.wait(130)
        await closedOff.pause()
        expect("never for that session: the fixed words, with no wait", closedOff.hands.lastOffer?.result == fixed, "\(closedOff.hands.actions)")
        print("-- A in a terminal, not sealed")
        let terminalApp = "com.apple.Terminal"
        var cardText = ""
        let terminal = MomentScript(answers: { text in
            cardText = text
            return answer(.offer, result: "fix the failing tests", needs: .actInWindow, key: "npm test")
        })
        terminal.hands.look = .offer(UserSessionOffer(session: session, words: words))
        await terminal.on("Terminal", terminalApp, "npm test", window: 20)
        await terminal.wait(130)
        await terminal.pause()
        expect("a session under a terminal also waits until they leave", terminal.hands.lastOffer == nil)
        await terminal.on("Mail", "com.apple.mail", "Inbox", window: 99)
        await terminal.wait(4)
        expect("then the take-over words, and the card held only the title", terminal.hands.lastOffer?.result == words && !cardText.contains("What an agent can do"), "\(terminal.hands.actions)")
        await terminal.answer("Yes")
        expect("yes takes over, with no agent on the terminal and no yes to read it", terminal.hands.actions.contains("took over Refactor auth") && !terminal.hands.actions.contains { $0.hasPrefix("placed") } && !ReadingYes.covers(terminalApp), "\(terminal.hands.actions)")
        let plainTerminal = MomentScript(answers: { _ in answer(.offer, result: "fix the failing tests", needs: .actInWindow, key: "npm test") })
        await plainTerminal.on("Terminal", terminalApp, "npm test", window: 21)
        await plainTerminal.wait(130)
        await plainTerminal.pause()
        expect("no session under a terminal: the normal offer, at a pause", plainTerminal.hands.lastOffer?.result == "fix the failing tests", "\(plainTerminal.hands.actions)")
        let cooking = MomentScript(answers: { _ in answer(.ignore, saw: "a personal question", key: "cook") })
        await cooking.on("Claude", sealedApp, "What should I cook tonight", window: 13)
        await cooking.wait(130)
        await cooking.pause()
        expect("the model can still keep a sealed window silent", cooking.hands.lastOffer == nil && cooking.costs == 1)
    }

    private static func meet() async {
        print("-- B. A Meet starts")
        let script = MomentScript(answers: { _ in answer(.offer, result: "should not be asked") })
        await script.signal("call.started", app: "Google Chrome", bundle: "com.google.Chrome", title: "Meet - Weekly sync", window: 20)
        expect("a call costs no model call", script.costs == 0)
        expect("the desk leaves it to the fixed consent words", script.hands.entries.last?.decision == "fixedWords")
        await script.signal("call.ended", app: "Google Chrome", bundle: "com.google.Chrome", title: "Meet - Weekly sync", window: 20)
        let jobs = script.desk.jobs
        let moment = Moment(kind: .call, at: script.clock, app: "Google Chrome", bundleId: "com.google.Chrome", window: 20, title: "Meet - Weekly sync")
        expect("a yes for reading does not cover hearing", { ReadingYes.add("com.google.Chrome"); return jobs.standing(for: moment, hearing: true) == .goOn(nil) }())
        jobs.move(.yes, moment: moment, words: moment.titleWords.sorted(), hearing: true)
        jobs.move(.yes, moment: moment, words: moment.titleWords.sorted(), hearing: true)
        guard case let .goOn(asked?) = jobs.standing(for: moment, hearing: true), asked.yeses == 2 else { return expect("two yeses are counted", false) }
        jobs.move(.keepDoing, moment: moment, words: moment.titleWords.sorted(), hearing: true)
        let other = Moment(kind: .call, at: script.clock, app: "Google Chrome", bundleId: "com.google.Chrome", window: 21, title: "Interview with candidate")
        expect("every time covers that title", { if case let .goOn(job?) = jobs.standing(for: moment, hearing: true) { return job.step == .aloneSaying }; return false }())
        expect("an unknown call still asks", jobs.standing(for: other, hearing: true) == .goOn(nil))
        print("   cost: 0 decision calls. Recap and tasks after the call: 1 run, then 1 for Bean.")
    }

    private static func freelancer() async {
        print("-- Freelancer: third return to a sheet")
        let script = MomentScript(answers: { _ in answer(.offer, result: "check October's invoices against September and list what is unpaid", key: "Numbers invoices") })
        for _ in 0..<4 {
            await script.on("Numbers", "com.apple.iWork.Numbers", "Invoices October", window: 30)
            await script.wait(20)
            await script.on("Mail", "com.apple.mail", "Inbox", window: 31)
            await script.wait(20)
        }
        await script.pause()
        expect("offers once, because of the returns", script.hands.lastOffer?.because.contains("came back") == true && script.costs == 1, "\(script.hands.actions) cost \(script.costs)")
        print("   cost: 1 decision call.")
    }

    private static func traveller() async {
        print("-- Traveller: long stay on one trip in a browser")
        let script = MomentScript(answers: { _ in answer(.offer, result: "put these hotels in one comparison", key: "hotels Lisbon") })
        await script.on("Arc", "company.thebrowser.Browser", "Compare hotels Lisbon", window: 40)
        await script.wait(130)
        await script.pause()
        await script.answer("Yes")
        expect("asks once for the browser, then places", script.hands.actions.contains("placed on Compare hotels Lisbon") && script.costs == 1)
        script.hands.actions = []
        await script.wait(3600)
        await script.on("Arc", "company.thebrowser.Browser", "Book hotel Lisbon checkout", window: 41)
        await script.wait(130)
        await script.pause()
        expect("a new topic is judged again, with no new question", script.costs == 2 && script.hands.actions.contains("placed on Book hotel Lisbon checkout"), "\(script.hands.actions)")
        print("   cost: 1 decision call per new topic.")
    }

    private static func applicant() async {
        print("-- Applicant: a long official form")
        let script = MomentScript(answers: { _ in answer(.offer, result: "list what this form needs") }, look: { _ in .keptPrivate })
        await script.on("Safari", "com.apple.Safari", "Tax return 2025", window: 50)
        await script.wait(130)
        await script.pause()
        expect("a private title stays on the Mac: 0 calls, nothing shown", script.costs == 0 && script.hands.actions.isEmpty && script.hands.entries.last?.decision == "keptPrivate", "\(script.hands.entries.last?.decision ?? "")")
        let open = MomentScript(answers: { _ in answer(.offer, result: "list what this form needs") })
        await open.on("Safari", "com.apple.Safari", "Visa form instructions", window: 51)
        await open.wait(130)
        await open.pause()
        expect("an open title gets an offer", open.hands.lastOffer != nil && open.costs == 1)
        let submit = MomentScript(answers: { _ in answer(.offer, result: "submit this form for you") })
        ReadingYes.add("com.apple.Safari")
        await submit.on("Safari", "com.apple.Safari", "Visa form", window: 52)
        await submit.wait(130)
        await submit.pause()
        expect("submit always asks, even with a yes for reading", submit.hands.lastOffer != nil && !submit.hands.actions.contains { $0.hasPrefix("placed") }, "\(submit.hands.actions)")
        print("   cost: 0 if private, else 1 decision call.")
    }

    private static func writer() async {
        print("-- Writer: nothing to offer without reading")
        let script = MomentScript(answers: { _ in answer(.remember, saw: "a long stay on one draft", key: "grant draft") })
        await script.on("Pages", "com.apple.iWork.Pages", "Grant draft", window: 60)
        await script.wait(130)
        await script.pause()
        expect("remembers, says nothing", script.hands.actions == ["remembered"] && script.costs == 1, "\(script.hands.actions)")
        await script.wait(3600)
        await script.pause()
        expect("the same draft later costs nothing", script.costs == 1)
        print("   cost: 1 decision call, then 0.")
    }

    private static func pullRequest() async {
        print("-- Developer: 8 minutes on a pull request page")
        let script = MomentScript(answers: { _ in answer(.offer, result: "summarise this pull request and flag risks", key: "pull request") })
        await script.on("Arc", "company.thebrowser.Browser", "Pull request 412 Fix login race", window: 70)
        await script.wait(130)
        await script.pause()
        await script.answer("Not now")
        expect("not now is quiet for that key", script.desk.jobs.standing(for: Moment(kind: .stayed, at: script.clock, bundleId: "company.thebrowser.Browser", title: "Pull request 413"), now: script.clock) == .stop("not now"))
        expect("other work in that app stays open", script.desk.jobs.standing(for: Moment(kind: .stayed, at: script.clock, bundleId: "company.thebrowser.Browser", title: "Weather"), now: script.clock) == .goOn(nil))
        print("   cost: 1 decision call. Reading happens only after a yes.")
    }

    private static func service() async {
        print("-- Developer: a ticket assigned in a connected service")
        let script = MomentScript(answers: { text in
            text.contains("ticket 212") ? answer(.place, result: "start a draft for this ticket", saw: "a ticket was assigned", needs: .nothing, key: "tickets") : nil
        })
        await script.signal("service.changed", app: "tracker", title: "tracker__list_issues", detail: "ticket 212 assigned to you")
        await script.settle()
        expect("connected service: acts alone, says one line, no question", script.hands.actions.contains("delegated: start a draft for this ticket") && script.hands.actions.contains { $0.hasPrefix("line") } && script.hands.lastOffer == nil, "\(script.hands.actions)")
        print("   cost: 1 decision call, then Bean's understanding call.")
    }

    private static func silent() async {
        print("-- Silent cases")
        let sealed = MomentScript(answers: { _ in answer(.offer, result: "must not be asked") })
        for (app, bundle) in [("WhatsApp", "net.whatsapp.WhatsApp"), ("Beeper Desktop", "com.automattic.beeper.desktop"), ("Messages", "com.apple.MobileSMS"), ("My Bank", "com.example.mybank")] {
            await sealed.on(app, bundle, "Private chat", window: 80)
            await sealed.wait(200)
        }
        expect("messages and banks: no moment, 0 calls, nothing logged about them", sealed.costs == 0 && sealed.hands.entries.isEmpty, "\(sealed.hands.entries.map(\.decision))")
        let shows = MomentScript(answers: { _ in answer(.ignore, saw: "watching a show", key: "Episode") })
        await shows.on("Netflix", "com.netflix.Netflix", "Episode 4", window: 90)
        await shows.wait(130)
        await shows.wait(3700)
        await shows.pause()
        expect("a show: 1 call, then a remembered ignore costs 0", shows.costs == 1 && shows.hands.actions.isEmpty, "cost \(shows.costs)")
        let quick = MomentScript(answers: { _ in answer(.offer, result: "must not be asked") })
        await quick.on("Calculator", "com.apple.calculator", "Calculator", window: 91)
        await quick.wait(20)
        await quick.on("Finder", "com.apple.finder", "Downloads", window: 92)
        await quick.wait(20)
        expect("20 seconds: no moment, 0 calls", quick.costs == 0 && quick.hands.entries.isEmpty)
    }

    private static func rules() async {
        print("-- Rules in code")
        let empty = MomentScript(answers: { _ in answer(.offer, result: "  ", saw: "x") })
        await empty.on("App", "x.a", "Report", window: 1)
        await empty.wait(130)
        await empty.pause()
        expect("an offer with an empty result is rejected", empty.hands.lastOffer == nil && empty.hands.entries.last?.decision == "rejected")
        let unseen = MomentScript(answers: { _ in answer(.offer, result: "a real result", saw: "") })
        await unseen.on("App", "x.a", "Report", window: 1)
        await unseen.wait(130)
        await unseen.pause()
        expect("an offer with empty saw is rejected", unseen.hands.lastOffer == nil && unseen.hands.entries.last?.decision == "rejected")
        let place = MomentScript(answers: { _ in answer(.place, result: "tidy this sheet", needs: .nothing) })
        await place.on("App", "x.b", "Sheet", window: 2)
        await place.wait(130)
        await place.pause()
        expect("the model saying place and needing nothing cannot skip the yes", place.hands.lastOffer != nil && !place.hands.actions.contains { $0.hasPrefix("placed") }, "\(place.hands.actions)")
        let held = MomentScript(answers: { _ in answer(.offer, result: "must not be asked") })
        held.hands.held = [3]
        await held.on("App", "x.c", "Doc", window: 3)
        await held.wait(130)
        expect("a window with an agent: 0 calls", held.costs == 0)
        let dose = MomentScript(answers: { _ in answer(.offer, result: "do a thing") })
        await dose.on("App", "x.d", "One", window: 4)
        await dose.wait(130)
        await dose.pause()
        await dose.on("App", "x.d", "Two", window: 5)
        await dose.wait(130)
        expect("while an offer is out, the next moment costs 0", dose.costs == 1 && dose.hands.entries.last?.decision == "dose", "cost \(dose.costs)")
        await dose.answer("Not now")
        await dose.wait(600)
        await dose.on("App", "x.d", "Three", window: 6)
        await dose.wait(130)
        expect("at most one offer in 30 minutes", dose.costs == 1 && dose.hands.entries.last?.decision == "dose", "cost \(dose.costs)")
        let ignored = MomentScript(answers: { _ in answer(.offer, result: "do a thing", key: "Report") })
        await ignored.on("App", "x.e", "Report", window: 7)
        await ignored.wait(130)
        await ignored.pause()
        await ignored.wait(1900)
        expect("an ignored offer expires by itself", ignored.hands.actions.contains("withdrawn"), "\(ignored.hands.actions)")
        let quiet = MomentAnswer(verdict: .offer, result: "delete the old invoices", saw: "x", needs: .actInWindow, key: "", when: .nextPause)
        var top = MomentJob(bundle: "x.f", words: [])
        top.step = .aloneQuiet
        let moment = Moment(kind: .stayed, at: Date(), bundleId: "x.f", title: "Invoices")
        if case .ask = MomentDecision.decide(moment, answer: quiet, job: top, readingYes: true) {
            expect("what cannot be undone always asks, at the top of the ladder", true)
        } else {
            expect("what cannot be undone always asks, at the top of the ladder", false)
        }
        let plain = MomentAnswer(verdict: .offer, result: "sort the notes", saw: "x", needs: .readWindow, key: "", when: .nextPause)
        if case let .act(_, _, _, sayIt) = MomentDecision.decide(moment, answer: plain, job: top, readingYes: true) {
            expect("alone and quiet says nothing", !sayIt)
        } else {
            expect("alone and quiet says nothing", false)
        }
    }
}
