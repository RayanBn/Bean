import Foundation

struct PageChange {
    let app: String?
    let title: String?
    let url: String?
    var newText: String

    // The address is not in every read of a page, so it cannot tell pages apart.
    var page: String { "\(app ?? "")|\(title ?? "")" }
    var place: String { "\(app ?? "An app"), now on \"\(title ?? "untitled")\"\(url.map { " at \($0)" } ?? "")" }
}

// What an agent last heard, per page or document, so only content that differs from it is news. Focus, a title that appears and a window that returns are not. A read from a picture is only compared with another: its words never match the same page's text.
struct HeardPages {
    private var lines: [String: Set<String>] = [:]
    private var started: Set<Bool> = []

    private func keys(_ snapshot: WindowSnapshot, window: Int) -> [String] {
        let address = snapshot.url.map { $0.components(separatedBy: "#")[0] }
        return [address, snapshot.title, "window \(window)"].compactMap { $0 }.map { "\(snapshot.isPicture) \($0)" }
    }

    func knows(_ snapshot: WindowSnapshot) -> Bool { started.contains(snapshot.isPicture) }

    // The first read of its kind is where the agent starts from, so it says nothing. Text with no words falls back on its title.
    mutating func news(in snapshot: WindowSnapshot, window: Int) -> String? {
        let now = snapshot.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let shown = now.isEmpty ? [snapshot.title].compactMap { $0 } : now
        let keys = keys(snapshot, window: window)
        let first = started.insert(snapshot.isPicture).inserted
        let before = keys.compactMap { lines[$0] }.first
        let added = shown.filter { !(before ?? []).contains($0) }
        if !added.isEmpty || before == nil {
            for key in keys { lines[key] = Set(shown) }
        } else {
            for key in keys where lines[key] == nil { lines[key] = before }
        }
        guard !first, !added.isEmpty, before != nil || !snapshot.isPicture else { return nil }
        return added.joined(separator: "\n")
    }
}

extension AgentWorker {
    var strandsDecides: Bool { BeanSettings.shared.effectiveDecidesOnThisMac && StrandsServer.isAvailable }

    // Each agent on an app has its own watch, so each is scored with its own job.
    func heard(_ change: PageChange, signal: SenseSignal, agent: Agent, bundleId: String?) async {
        func note(_ decision: String, by: String, score: Double? = nil, ms: Int? = nil) {
            let entry = GateEntry(event: "window.content", app: change.app, title: change.title, decision: decision, by: by, score: score, ms: ms, detail: agent.name)
            EventGate.log.append(entry)
            noteGate(entry)
        }
        if OffLimits.match("\(change.app ?? "") \(bundleId ?? "") \(change.title ?? "")") != nil { return note("offLimits", by: "code") }
        let started = Date()
        guard let score = await StrandsDecider.score(change, agent: agent, folder: AgentFolder(agent, in: storeForBrain)) else {
            note("strandsDown", by: "code")
            senses?.toGate(signal, sense: "windows")
            return
        }
        let yes = score > StrandsDecider.changeIsWorkAbove
        note(yes ? "yes" : "quiet", by: "Strands", score: score, ms: Int(Date().timeIntervalSince(started) * 1000))
        guard yes else { return }
        keep(change, for: agent.id)
        wakeForChanges(agent.id)
    }

    private func keep(_ change: PageChange, for id: UUID) {
        var list = heardChanges[id] ?? []
        guard let index = list.firstIndex(where: { $0.page == change.page }) else {
            heardChanges[id] = list + [change]
            return
        }
        let known = Set(list[index].newText.split(separator: "\n"))
        let more = change.newText.split(separator: "\n").filter { !known.contains($0) }
        var merged = change
        merged.newText = ([list[index].newText] + more.map(String.init)).filter { !$0.isEmpty }.joined(separator: "\n")
        list[index] = merged
        heardChanges[id] = list
    }

    func wakeForChanges(_ id: UUID) {
        changeRetry[id]?.cancel()
        guard let changes = heardChanges[id], !changes.isEmpty, let agent = storeForBrain.agents.first(where: { $0.id == id }) else { return }
        if stopHeld(agent) {
            heardChanges[id] = nil
            return
        }
        let waitingOnPerson = AgentFolder(agent, in: storeForBrain).needs.contains { $0.kind == .budget || $0.kind == .problem }
        guard !Onboarding.holding, !BeanSettings.shared.effectivePaused, !isBusy(id), !replying.contains(id), !waitingOnPerson else {
            let retry = DispatchWorkItem { [weak self] in self?.wakeForChanges(id) }
            changeRetry[id] = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: retry)
            return
        }
        heardChanges[id] = nil
        let trigger = "Strands read what changed in your apps and judged it as work for your job, so you now do that work:\n" + changes.map { "- \($0.place)" }.joined(separator: "\n") + "\nWhat changed is under What you see. What the work takes, and whether your todo list changes, you judge from your job."
        let share = Self.changeTextLimit / changes.count
        let seeing = changes.map { "\($0.title ?? "untitled"):\n\($0.newText.isEmpty ? "Only the title changed." : String($0.newText.prefix(share)))" }.joined(separator: "\n\n")
        Self.log.append(Entry(agent: agent.name, event: "changesGiven", detail: changes.map(\.place).joined(separator: "; ")))
        Task { @MainActor in
            let outcome = await run(agent, trigger: trigger, changed: true, seeing: seeing)
            logBareEnd(of: outcome, agent: agent)
            let worked = outcome.summary?.isEmpty == false || !outcome.calls.isEmpty
            let entry = GateEntry(event: "wake", app: nil, title: agent.name, decision: worked ? "museWorked" : "museQuiet", by: "Muse Spark", detail: outcome.summary ?? outcome.failure)
            EventGate.log.append(entry)
            noteGate(entry)
            wakeForChanges(id)
        }
    }

    private func logBareEnd(of outcome: Outcome, agent: Agent) {
        let noTool = outcome.calls.allSatisfy { $0 == "finish" || $0 == "stuck" }
        let noMessage = outcome.summary?.isEmpty != false
        guard outcome.decided != nil, noTool || noMessage else { return }
        let ended = [noTool ? "no tool" : nil, noMessage ? "no message" : nil].compactMap { $0 }.joined(separator: ", ")
        let detail = "\(ended). Calls: \(outcome.calls.joined(separator: ", ")). Failure: \(outcome.failure ?? "none"). Final text: \(outcome.lastWords)"
        Self.log.append(Entry(agent: agent.name, event: "changeRunEndedBare", detail: OffLimits.redact(detail).text))
    }

    private static let changeTextLimit = 6000

    // A tool that changes an app changes what its watch sees next, and that is no news to the agent.
    nonisolated static func changesItsApp(_ tool: String, _ args: JSONArgs) -> Bool {
        if tool == "app_script" { return !AppGuard.onlyReads(args.string("script") ?? "") }
        return args["did"] != nil || tool == "window_hands" || tool == "sweep"
    }
}
