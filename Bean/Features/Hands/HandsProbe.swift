import AppKit

enum HandsProbe {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
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
        let before = (NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "", NSEvent.mouseLocation)
        let report = await hands.run(goal: goal)
        print("background front_same=\(before.0 == NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") mouse_same=\(before.1 == NSEvent.mouseLocation)")
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

    private static func agent(_ target: Attachment, _ goal: String) async {
        let store = AgentStore()
        let agent = Agent(id: UUID(), name: "Probe", role: "Works in the window it is attached to, as asked.", personality: "Plain.", look: .init(hue: 0.5, accessory: "none"), connectors: [], attachment: target, createdAt: Date())
        store.save(agent)
        let folder = AgentFolder(agent, in: store)
        folder.save(AgentMission(mission: agent.role))
        let worker = AgentWorker(store: store, autostart: false)
        let started = Date()
        let summary = await worker.runHandedOff(agent, task: goal)
        let entries = folder.journal.filter { $0.kind == .action || $0.kind == .failed || $0.kind == .refused }
        print(String(format: "RESULT seconds=%.1f actions=%d failed=%d", Date().timeIntervalSince(started), entries.filter { $0.kind == .action }.count, entries.filter { $0.kind != .action }.count))
        for entry in entries { print("journal \(entry.kind.rawValue) \(entry.did)") }
        print("SUMMARY \(summary)")
        withExtendedLifetime(worker) {}
    }
}
