import AppKit

@available(macOS 14.2, *)
enum ScenarioProbe {
    private struct Plan: Decodable {
        let agent, role, mission, why, window: String
        let seconds, settle, timeout: Double
        let answer: String?
        let answersAnything: Bool
        let answerWhen: String?
    }

    private struct Asked: Encodable {
        let at: Date
        let agent, question, kind: String
        let options: [String]
        let answered: String?
        let permission: Bool
        let connector: Bool
    }

    private struct Busy: Encodable {
        let at: Double
        let busy: [String]
    }

    private struct Done: Encodable {
        let status: String
        let consent: Bool
        let seconds: Double
    }

    static func run(_ args: [String], store: AgentStore) {
        let environment = ProcessInfo.processInfo.environment
        guard let dir = args.first.map({ URL(fileURLWithPath: $0) }),
              let plan = (try? Data(contentsOf: dir.appendingPathComponent("plan.json"))).flatMap({ try? JSONDecoder().decode(Plan.self, from: $0) }),
              let callFile = environment["BEAN_FAKE_CALL_FILE"], environment["BEAN_WINDOW_FILTER"] != nil, environment["BEAN_DATA_DIR"] != nil else {
            print("usage: scenario <dir with plan.json>, with BEAN_FAKE_CALL_FILE, BEAN_WINDOW_FILTER and BEAN_DATA_DIR")
            exit(64)
        }
        guard let window = WindowChannels.open().first(where: { $0.title == plan.window }) else {
            print("no window titled \(plan.window)")
            exit(2)
        }
        Agents.adoptBean(in: store)
        let agent = Agent(id: UUID(), name: plan.agent, role: plan.role, personality: "Careful and brief.", look: .init(hue: 0.55, accessory: "none"),
                          connectors: [], attachment: WindowChannels.attachment(for: window), createdAt: Date())
        let folder = AgentFolder(agent, in: store)
        try? folder.create(agent: agent, voice: "Short, factual sentences.", lines: AgentLines(greeting: "Ready.", offLimits: "This window is off limits, so it was not read."))
        folder.save(AgentMission(mission: plan.mission))
        folder.requestCalls(why: plan.why)
        store.save(agent)

        let reader = WindowReader(store: store)
        let worker = reader.worker
        let hearing = CallListening(store: store, worker: worker)
        let started = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        func append(_ line: some Encodable, to name: String) {
            guard var data = try? encoder.encode(line) else { return }
            data.append(0x0A)
            let file = dir.appendingPathComponent(name)
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: file)
            }
        }
        var seen = Set<UUID>()
        var callOver = false, consent = false
        var lastBusy: [String] = []
        var lastSpend = -1, quietSince = Date()
        func finish(_ status: String) {
            try? FileManager.default.removeItem(atPath: callFile)
            append(Done(status: status, consent: consent, seconds: Date().timeIntervalSince(started)), to: "done.jsonl")
            withExtendedLifetime((reader, hearing)) { exit(0) }
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            let busy = store.agents.filter { worker.isBusy($0.id) }.map(\.name).sorted()
            if busy != lastBusy {
                lastBusy = busy
                append(Busy(at: Date().timeIntervalSince1970, busy: busy), to: "timeline.jsonl")
            }
            for who in store.agents {
                for need in AgentFolder(who, in: store).needs where need.consent == nil && seen.insert(need.id).inserted {
                    let open = need.kind == .decision && need.permission == nil && need.connector == nil
                    let meant = plan.answerWhen.map { need.question.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil } ?? true
                    let answer = open && callOver ? (meant ? plan.answer : nil) ?? (plan.answersAnything ? need.options.first : nil) : nil
                    append(Asked(at: Date(), agent: who.name, question: need.question, kind: need.kind.rawValue, options: need.options, answered: answer, permission: need.permission != nil, connector: need.connector != nil), to: "questions.jsonl")
                    if let answer { worker.answer(who.id, need: need.id, answer) }
                }
            }
            guard callOver else { return }
            let spend = CostLedger.lines.filter { $0.run == environment["BEAN_RUN_ID"] }.count
            if spend != lastSpend || !busy.isEmpty {
                lastSpend = spend
                quietSince = Date()
            }
            if Date().timeIntervalSince(quietSince) > plan.settle { finish("settled") }
            if Date().timeIntervalSince(started) > plan.timeout { finish("timeout") }
        }
        Task { @MainActor in
            try? plan.window.write(toFile: callFile, atomically: true, encoding: .utf8)
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                if let need = folder.needs.first(where: { $0.consent != nil }), let yes = need.options.first {
                    worker.answer(agent.id, need: need.id, yes)
                    consent = true
                    break
                }
            }
            guard consent else { return finish("no consent question") }
            try? await Task.sleep(for: .seconds(plan.seconds))
            try? FileManager.default.removeItem(atPath: callFile)
            callOver = true
            quietSince = Date()
        }
    }
}
