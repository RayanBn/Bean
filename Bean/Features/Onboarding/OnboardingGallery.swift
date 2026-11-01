import AppKit
import SwiftUI

// Renders every step off screen, with no input and no model.
enum OnboardingGallery {
    private static var flow: Onboarding?

    @MainActor
    static func runIfRequested() -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-onboarding"), CommandLine.arguments.indices.contains(index + 1),
              ProcessInfo.processInfo.environment["BEAN_DATA_DIR"] != nil else { return false }
        let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Onboarding.holding = true
        let store = AgentStore()
        let notch = NotchController()
        let agents = Agents(store: store, notch: notch, connectors: Connectors())
        let creatures = CreatureController(store: store, notch: notch)
        let desk = NotchDesk(store: store, worker: agents.worker, notch: notch, agents: agents) { _ in }
        let agent = Agent(id: UUID(), name: "Rosa", role: "Keeps the list", look: .init(hue: 0.6, accessory: "none"), attachment: nil, createdAt: Date())
        AgentFolder(agent, in: store).create(agent: agent, job: AgentJob(goal: "Keep a list of what you promised customers.", output: "", done: "", first: "", quiet: ""))
        store.save(agent)
        NSApp.windows.forEach { $0.orderOut(nil) }

        let steps: [(name: String, step: Onboarding.Step, on: Bool)] = [
            ("1-ask", .ask, false), ("2-brain", .brain, false), ("3-sees", .sees, false), ("4-switch-off", .access, false), ("4-switch-on", .access, true),
            ("5-making", .making, false), ("5-drag", .drag, false), ("6-result", .result, false), ("7-closing", .closing, false),
        ]
        var left = steps

        func next() {
            guard !left.isEmpty else { exit(0) }
            let item = left.removeFirst()
            let file = JSONLog.directory.appendingPathComponent("onboarding.json")
            try? JSONEncoder().encode(Onboarding.Saved(step: item.step, sentence: "Keep a list", agent: agent.id)).write(to: file, options: .atomic)
            let current = Onboarding(store: store, worker: agents.worker, agents: agents, notch: notch, desk: desk, creatures: creatures)
            if item.on { current.told() }
            if item.step == .ask { current.draft = "Keep track of what I promised" }
            flow = current
            let host = NSHostingView(rootView: OnboardingView(flow: current))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -9000, y: 0))
            window.orderBack(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let name = "\(item.name).png"
                    try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name))
                    print("\(name) \(Int(view.bounds.width))x\(Int(view.bounds.height))")
                }
                window.orderOut(nil)
                next()
            }
        }
        next()
        return true
    }
}
