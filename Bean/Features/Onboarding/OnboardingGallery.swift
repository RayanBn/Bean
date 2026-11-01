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
        AgentFolder(agent, in: store).create(agent: agent, job: AgentJob(goal: "Keep a list", output: "", done: "", quiet: ""))
        store.save(agent)
        NSApp.windows.forEach { $0.orderOut(nil) }

        let screens: [(name: String, step: Onboarding.Step, sentence: String?, setup: (Onboarding) -> Void)] = [
            ("1-ask", .ask, nil, { _ in }),
            ("1-ask-typed", .ask, nil, { $0.draft = "Write down what's decided in my meetings and send me a recap" }),
            ("2-model", .model, "Keep a list", { _ in }),
            ("3-sees", .sees, "Keep a list", { _ in }),
            ("4-access", .access, "Keep a list", { _ in }),
            ("4-access-asked", .access, "Keep a list", { $0.accessAsked = true }),
            ("5-making", .making, "Keep a list", { _ in }),
            ("6-job", .job, "Write down what's decided in my meetings and send me a recap", { $0.jobDraft = "Write down what's decided in my meetings and send me a recap" }),
            ("7-drag", .drag, "Keep a list", { _ in }),
            ("7-drag-missed", .drag, "Keep a list", {
                $0.returned = true
                $0.missed = 2
            }),
            ("7-drag-no-app", .drag, "Keep a list", { $0.openWindows = false }),
            ("8-closing", .closing, "Keep a list", { $0.accessOn = true }),
            ("8-closing-switch-off", .closing, "Keep a list", { _ in }),
            ("8-closing-setup-running", .closing, "Keep a list", {
                $0.accessOn = true
                StrandsInstaller.shared.stage = .running(0.4)
            }),
            ("8-closing-setup-failed", .closing, "Keep a list", {
                $0.accessOn = true
                StrandsInstaller.shared.stage = .failed("The download stopped. Check the network.")
            }),
        ]
        var left = screens

        func next() {
            guard !left.isEmpty else { exit(0) }
            let item = left.removeFirst()
            StrandsInstaller.shared.stage = .idle
            let file = JSONLog.directory.appendingPathComponent("onboarding.json")
            try? JSONEncoder().encode(Onboarding.Saved(step: item.step, sentence: item.sentence, agent: agent.id)).write(to: file, options: .atomic)
            let current = Onboarding(store: store, worker: agents.worker, agents: agents, notch: notch, desk: desk, creatures: creatures)
            let attached = item.step == .closing ? Attachment(bundleId: "com.example.app", appName: "Arc", pid: 0, windowNumber: 0, windowTitle: nil) : nil
            store.attach(agent.id, to: attached)
            item.setup(current)
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
