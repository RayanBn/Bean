import AppKit
import os

final class FocusWatch {
    private let moves = OSAllocatedUnfairLock(initialState: [String]())
    private let running = OSAllocatedUnfairLock(initialState: true)
    private let typed = OSAllocatedUnfairLock(initialState: (sent: 0, held: 0))

    init(typing: Bool = false) {
        if typing { startTyping() }
        Thread.detachNewThread { [self] in
            var last = ""
            while running.withLock({ $0 }) {
                let now = Self.focus()
                if now != last {
                    if !last.isEmpty { moves.withLock { $0.append(now) } }
                    last = now
                }
                Thread.sleep(forTimeInterval: 0.04)
            }
        }
    }

    // Real keys, only while the app the run began in has the focus, so that a key can never land anywhere else. A tick without the focus is counted, not typed.
    private func startTyping() {
        Thread.detachNewThread { [self] in
            guard let first = Self.focusedApp() else { return }
            while running.withLock({ $0 }) {
                if Self.focusedApp() == first {
                    let source = CGEventSource(stateID: .hidSystemState)
                    CGEvent(keyboardEventSource: source, virtualKey: 7, keyDown: true)?.post(tap: .cghidEventTap)
                    CGEvent(keyboardEventSource: source, virtualKey: 7, keyDown: false)?.post(tap: .cghidEventTap)
                    typed.withLock { $0.sent += 1 }
                } else {
                    typed.withLock { $0.held += 1 }
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    private static func focusedApp() -> pid_t? {
        guard let element = Accessibility.attribute(kAXFocusedUIElementAttribute, of: AXUIElementCreateSystemWide()) else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element as! AXUIElement, &pid)
        return pid
    }

    func stop() -> String {
        running.withLock { $0 = false }
        Thread.sleep(forTimeInterval: 0.2)
        let keys = typed.withLock { $0 }
        if keys.sent + keys.held > 0 { print("typed sent=\(keys.sent) held=\(keys.held)") }
        let seen = moves.withLock { $0 }
        return "\(seen.count) \(seen.prefix(6))"
    }

    private static func focus() -> String {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let top = windows.first { $0[kCGWindowLayer as String] as? Int == 0 }?[kCGWindowOwnerName as String] as? String ?? "?"
        guard let element = Accessibility.attribute(kAXFocusedUIElementAttribute, of: AXUIElementCreateSystemWide()) else { return "\(top)/none" }
        return "\(top)/\(Accessibility.attribute(kAXRoleAttribute, of: element as! AXUIElement) as? String ?? "?")/\(CFHash(element))"
    }
}

enum HandsProbe {
    private static let guardCases: [(role: String, label: String, refused: Bool)] = [
        ("AXCheckBox", "Share usage data", false), ("AXRadioButton", "By post", false), ("AXCheckBox", "Send me a copy", false), ("AXCheckBox", "Delete after 30 days", false),
        ("AXPopUpButton", "Order by", false), ("AXPopUpButton", "Post as", false), ("AXRadioButton", "Envoyer par courrier", false),
        ("AXCheckBox", "Subscribe", true), ("AXRadioButton", "Pay with card", true), ("AXCheckBox", "Buy now", true),
        ("AXButton", "By post", false), ("AXButton", "Order by date", false), ("AXLink", "Via email", false), ("AXButton", "Sort", false), ("AXButton", "Add Green tea", false),
        ("AXButton", "Share", true), ("AXButton", "Share usage data", true), ("AXButton", "Send", true), ("AXButton", "Send by email", true), ("AXButton", "Reply by email", true), ("AXButton", "Send to everyone", true),
        ("AXButton", "Delete account", true), ("AXButton", "Delete Sheet", true), ("AXButton", "Post", true), ("AXButton", "Publish", true), ("AXButton", "Buy now", true), ("AXButton", "Pay by card", true),
        ("AXButton", "Place order", true), ("AXButton", "Empty trash", true), ("AXButton", "Move to trash", true), ("AXButton", "Supprimer", true), ("AXButton", "Envoyer", true), ("AXMenuItem", "Delete", true), ("AXMenuItem", "Email this page", true), ("AXMenuButton", "Share", true), ("AXLink", "Delete", true),
    ]

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        if args.contains("--probe-hands-guard") {
            var wrong = 0
            for item in guardCases where (AppGuard.pressRefusal(role: item.role, label: item.label, abilities: []) != nil) != item.refused {
                wrong += 1
                print("WRONG \(item.role) \"\(item.label)\" should \(item.refused ? "be refused" : "pass")")
            }
            print("guard cases \(guardCases.count), wrong \(wrong)")
            exit(wrong == 0 ? 0 : 1)
        }
        if let index = args.firstIndex(of: "--probe-done"), args.indices.contains(index + 1) {
            Task { @MainActor in
                await DoneProbe.table(args[index + 1])
                await StrandsServer.shared.stop()
                exit(0)
            }
            return true
        }
        guard let index = args.firstIndex(of: "--probe-hands"), args.indices.contains(index + 3) else { return false }
        guard ProcessInfo.processInfo.environment["BEAN_DATA_DIR"] != nil else {
            print("refusing: set BEAN_DATA_DIR")
            exit(2)
        }
        let target = ActionsProbe.attachment(args[index + 2]), goal = args[index + 3]
        Task { @MainActor in
            switch args[index + 1] {
            case "run": await hands(target, goal)
            case "agent": await agent(target, goal)
            case "chat": await chat(target, goal)
            case "wake": await wake(target, goal)
            case "create": await create(goal)
            case "sweep": await sweep(target, goal)
            default: print("usage: --probe-hands run|agent|sweep <bundle#title|bundle|pid:n> <goal or arguments file>")
            }
            await StrandsServer.shared.stop()
            exit(0)
        }
        return true
    }

    private static func hands(_ target: Attachment, _ goal: String) async {
        guard Strands.isOn else { print("Strands is off"); return }
        _ = await StrandsServer.shared.ready()
        let hands = InstantHands(attachment: target, abilities: { [] }, blocked: { nil }, journal: { _ in })
        hands.onStep = { print(String(format: "step %.3f s %@ %.2f %@", $0.seconds, $0.chosenBy, $0.confidence, $0.did)) }
        hands.onDecide = { print("strands \($0) for: \($1)") }
        let mouse = NSEvent.mouseLocation
        let watch = FocusWatch(typing: ProcessInfo.processInfo.environment["BEAN_HANDS_TYPE"] == "1")
        let report = await hands.run(goal: goal)
        print("background focus_moves=\(watch.stop()) mouse_same=\(mouse == NSEvent.mouseLocation)")
        let median = report.steps.map(\.seconds).sorted().dropFirst(report.steps.count / 2).first ?? 0
        print(String(format: "RESULT finished=%@ actions=%d seconds=%.1f median_step=%.3f muse=%d strands=%d by_muse=%d guard_removed=%d", String(report.finished), report.steps.count, report.seconds, median, report.museCalls, report.strandsCalls, report.steps.filter { $0.chosenBy == "muse" }.count, report.removedByGuard))
        print("SUMMARY \(report.summary)")
    }

    private static func sweep(_ target: Attachment, _ file: String) async {
        guard Strands.isOn, let data = FileManager.default.contents(atPath: file), let args = (try? JSONSerialization.jsonObject(with: data)) as? JSONArgs else { print("Strands is off, or no arguments"); return }
        _ = await StrandsServer.shared.ready()
        let store = AgentStore()
        let agent = Agent(id: UUID(), name: "Probe", role: "Probe", personality: "Plain.", look: .init(hue: 0.5, accessory: "none"), connectors: [], attachment: target, createdAt: Date())
        store.save(agent)
        let worker = AgentWorker(store: store, autostart: false)
        let started = Date()
        guard let tool = worker.sweepTools(agent, attachment: target, folder: AgentFolder(agent, in: store), offLimits: false).first else { print("no sweep tool"); return }
        let output = await tool.run(args)
        print(String(format: "RESULT ok=%@ wall=%.1f", String(output.ok), Date().timeIntervalSince(started)))
        print(output.text)
        withExtendedLifetime(worker) {}
    }

    private static func probeAgent(_ target: Attachment, in store: AgentStore) -> Agent {
        let name = ProcessInfo.processInfo.environment["BEAN_PROBE_AGENT"] ?? "Probe"
        var agent = store.agents.first { $0.name == name } ?? Agent(id: UUID(), name: name, role: "Works in the window it is attached to, as asked.", personality: "Plain.", look: .init(hue: 0.5, accessory: "none"), connectors: [], attachment: target, createdAt: Date())
        agent.attachment = target
        store.save(agent)
        return agent
    }

    private static func create(_ sentence: String) async {
        let store = AgentStore()
        Agents.adoptBean(in: store)
        let worker = AgentWorker(store: store, autostart: false)
        Tools.shared.add(Connectors())
        guard let created = try? await AgentMaker().write(sentence, avoiding: [], reality: await AgentWorker.reality(in: store)) else { print("SUMMARY could not create"); return }
        try? AgentMaker.save(created, in: store)
        await worker.connectSource(created.agent, created.source)
        while worker.isBusy(created.agent.id) { try? await Task.sleep(for: .milliseconds(200)) }
        let agent = store.agents.first { $0.id == created.agent.id } ?? created.agent
        let folder = AgentFolder(agent, in: store)
        print("SOURCE \(created.source.kind.rawValue) \(created.source.service) window=\(created.source.window) on=\(agent.attachment?.windowTitle ?? "nothing")")
        print("CARD \(folder.job?.source ?? "no source")")
        for need in folder.needs { print("asked \(need.kind.rawValue) \(need.question.prefix(220))") }
        for entry in folder.journal where entry.kind != .said { print("journal \(entry.kind.rawValue) \(entry.did.prefix(240))") }
        withExtendedLifetime(worker) {}
    }

    private static func wake(_ target: Attachment, _ mission: String) async {
        let store = AgentStore()
        Agents.adoptBean(in: store)
        let agent = probeAgent(target, in: store)
        let folder = AgentFolder(agent, in: store)
        folder.save(AgentMission(mission: mission))
        let worker = AgentWorker(store: store, autostart: false)
        for changed in [false, true] {
            let outcome = await worker.run(agent, trigger: changed ? "Your window changed" : "A routine check", changed: changed)
            print("RUN changed=\(changed) help=\(outcome.decided?.help.description ?? "none") calls=\(outcome.calls) summary=\(outcome.summary?.prefix(160) ?? "none")")
        }
        print("REPORTS \(folder.journal.filter { $0.kind == .replied }.map { String($0.did.prefix(200)) })")
        withExtendedLifetime(worker) {}
    }

    private static func chat(_ target: Attachment, _ text: String) async {
        let store = AgentStore()
        let environment = ProcessInfo.processInfo.environment
        Agents.adoptBean(in: store)
        var agent = environment["BEAN_PROBE_AGENT"] == "Bean" ? store.agents.first(where: \.isBean)! : probeAgent(target, in: store)
        if environment["BEAN_PROBE_NO_WINDOW"] != nil, !agent.isBean {
            agent.attachment = nil
            store.save(agent)
        }
        let folder = AgentFolder(agent, in: store)
        if !agent.isBean { folder.save(AgentMission(mission: agent.role)) }
        let worker = AgentWorker(store: store, autostart: false)
        worker.send(agent.id, text)
        while worker.replying.contains(agent.id) { try? await Task.sleep(for: .milliseconds(200)) }
        print("SUMMARY \(folder.journal.last { $0.kind == .replied }?.did ?? "no reply")")
        for other in store.agents {
            let its = AgentFolder(other, in: store)
            for entry in its.journal where entry.kind != .replied && entry.kind != .said { print("journal \(other.name) \(entry.kind.rawValue) \(entry.did.prefix(110))") }
            for need in its.needs { print("asked \(other.name) \(need.kind.rawValue) \(need.question.prefix(160))") }
        }
        withExtendedLifetime(worker) {}
    }

    private static func agent(_ target: Attachment, _ goal: String) async {
        let store = AgentStore()
        let agent = probeAgent(target, in: store)
        let folder = AgentFolder(agent, in: store)
        folder.save(AgentMission(mission: agent.role))
        let worker = AgentWorker(store: store, autostart: false)
        let started = Date()
        let summary = await worker.runHandedOff(agent, task: goal)
        let entries = folder.journal.filter { $0.kind == .action || $0.kind == .failed || $0.kind == .refused }
        print(String(format: "RESULT seconds=%.1f actions=%d failed=%d", Date().timeIntervalSince(started), entries.filter { $0.kind == .action }.count, entries.filter { $0.kind != .action }.count))
        for entry in entries { print("journal \(entry.kind.rawValue) \(entry.did) | \((entry.result ?? "").prefix(90).replacingOccurrences(of: "\n", with: " "))") }
        for need in folder.needs { print("asked \(need.kind.rawValue) \(need.question.prefix(200)) options \(need.options ?? [])") }
        print("SUMMARY \(summary)")
        withExtendedLifetime(worker) {}
    }
}
