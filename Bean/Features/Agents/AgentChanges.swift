import Foundation

struct PageChange {
    let app: String?
    let title: String?
    let url: String?
    var newText: String

    var page: String { url ?? "\(app ?? "")|\(title ?? "")" }
    var place: String { "\(app ?? "An app"), now on \"\(title ?? "untitled")\"\(url.map { " at \($0)" } ?? "")" }
    var seen: String { newText.isEmpty ? "Nothing more." : newText }
}

extension AgentWorker {
    nonisolated static func changeState(_ change: PageChange, folder: AgentFolder) -> String {
        let job = folder.job
        let mission = job.map { "\($0.goal) Done means: \($0.done) Stay quiet when: \($0.quiet)" } ?? folder.mission?.mission ?? ""
        return StrandsDecider.state(mission: mission, goals: folder.unfinishedTodos, trigger: change.place, seen: change.seen,
                                    journal: folder.journal.suffix(6).map { "- \($0.kind.rawValue): \($0.did.prefix(120))" })
    }

    // Each agent on an app has its own watch, so each is scored with its own job.
    func heard(_ change: PageChange, agent: Agent, bundleId: String?) async {
        func note(_ decision: String, by: String, score: Double? = nil, ms: Int? = nil) {
            let entry = GateEntry(event: "window.content", app: change.app, title: change.title, decision: decision, by: by, score: score, ms: ms, detail: agent.name)
            EventGate.log.append(entry)
            noteGate(entry)
        }
        if Skills.forApp(bundleId)?.sealed == true { return note("noContent", by: "code") }
        if OffLimits.match("\(change.app ?? "") \(bundleId ?? "") \(change.title ?? "")") != nil { return note("offLimits", by: "code") }
        let started = Date()
        let local = strandsDecides ? await StrandsDecider.score(state: Self.changeState(change, folder: AgentFolder(agent, in: storeForBrain))) : nil
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if let local {
            let yes = local > StrandsDecider.changeQuietAtOrBelow
            note(yes ? "yes" : "quiet", by: "Strands", score: local, ms: ms)
            guard yes else { return }
        } else {
            if EventGate.isNoise(change.seen) { return note("quiet", by: "filter") }
            note("yes", by: "filter")
        }
        keep(change, for: agent.id)
        wakeForChanges(agent.id)
    }

    private var strandsDecides: Bool { BeanSettings.shared.effectiveDecidesOnThisMac && StrandsServer.isAvailable }

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
        // With no Strands every wake costs a model call, so these keep Bean's own spacing.
        guard !Onboarding.holding, !BeanSettings.shared.effectivePaused, !isBusy(id), !replying.contains(id), !waitingOnPerson, strandsDecides || spaced(id) else {
            let retry = DispatchWorkItem { [weak self] in self?.wakeForChanges(id) }
            changeRetry[id] = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: retry)
            return
        }
        heardChanges[id] = nil
        let todos = AgentFolder(agent, in: storeForBrain).unfinishedTodos.map { "\n\($0)" } ?? ""
        let trigger = "What changed in your apps, and nobody asked you anything. Judge from your job whether it is work for you: do it if it is, and stay silent if it is not.\n" + changes.map { "- \($0.place)" }.joined(separator: "\n") + todos
        let seeing = changes.map { "\($0.title ?? "untitled"):\n\($0.seen.prefix(1500))" }.joined(separator: "\n\n")
        Self.log.append(Entry(agent: agent.name, event: "changesGiven", detail: changes.map(\.place).joined(separator: "; ")))
        Task { @MainActor in
            let outcome = await run(agent, trigger: trigger, changed: true, scored: true, seeing: seeing)
            let entry = GateEntry(event: "wake", app: nil, title: agent.name, decision: outcome.decided?.help == true ? "museWorked" : "museQuiet", by: "Muse Spark", detail: outcome.decided?.what ?? outcome.failure)
            EventGate.log.append(entry)
            noteGate(entry)
            wakeForChanges(id)
        }
    }

    // A tool that changes an app changes what its watch sees next, and that is no news to the agent.
    nonisolated static func changesItsApp(_ tool: String, _ args: JSONArgs) -> Bool {
        if tool == "app_script" { return !AppGuard.onlyReads(args.string("script") ?? "") }
        return args["did"] != nil || tool == "window_hands" || tool == "sweep"
    }
}
