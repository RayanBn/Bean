import AppKit
import Combine
import SwiftUI

@MainActor
final class Onboarding: ObservableObject {
    enum Step: String, Codable { case ask, brain, sees, access, making, drag, result, closing, done }

    struct Saved: Codable {
        var step = Step.ask
        var sentence: String?
        var agent: UUID?
        var strands: Bool?
    }

    nonisolated(unsafe) static var holding = false
    private static let file = JSONLog.directory.appendingPathComponent("onboarding.json")

    private static var loaded: Saved? { (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } }

    // A test data folder stays out of it unless the run asks, and someone who already uses Bean never sees it.
    static func isDue(in store: AgentStore) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["BEAN_DATA_DIR"] != nil, environment["BEAN_ONBOARDING"] == nil { return false }
        if let saved = loaded { return saved.step != .done }
        let welcomed = FileManager.default.fileExists(atPath: JSONLog.directory.appendingPathComponent("welcomed").path)
        guard welcomed || Goals.text != nil || store.agents.contains(where: { !$0.isBean && !$0.name.isEmpty }) else { return true }
        write(Saved(step: .done))
        return false
    }

    private static func write(_ saved: Saved) {
        try? FileManager.default.createDirectory(at: JSONLog.directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: file, options: .atomic)
    }

    @Published private(set) var saved: Saved {
        didSet { Self.write(saved) }
    }
    @Published var draft = ""
    @Published var key = ""
    @Published var correction = ""
    @Published var reply = ""
    @Published private(set) var checking = false
    @Published private(set) var keyPassed = false
    @Published private(set) var keyFound = false
    @Published private(set) var keyProblem: String?
    @Published private(set) var accessOn = false
    @Published private(set) var accessAsked = false
    @Published private(set) var accessProof: String?
    @Published private(set) var makeProblem: String?
    @Published private(set) var missed = 0
    @Published private(set) var returned = false
    @Published private(set) var holding = false
    @Published private(set) var openWindows = true
    @Published private(set) var found: String?
    @Published private(set) var problem: String?
    @Published private(set) var askedInNotch = false
    @Published private(set) var working = false

    var step: Step { saved.step }
    var unreadable: Bool { found == AgentWorker.unreadable }
    var agent: Agent? { saved.agent.flatMap { id in store.agents.first { $0.id == id } } }
    var job: String? { agent.flatMap { AgentFolder($0, in: store).card?.job.goal } }

    private let store: AgentStore
    private let worker: AgentWorker
    private let agents: Agents
    private let notch: NotchController
    private let desk: NotchDesk
    private let creatures: CreatureController
    private var window: NSWindow?
    private var previous: NSRunningApplication?
    private var closing: NSObjectProtocol?
    private var subscriptions: Set<AnyCancellable> = []
    private var timer: Timer?
    private var contentSize = CGSize(width: OnboardingView.width, height: 400)

    init(store: AgentStore, worker: AgentWorker, agents: Agents, notch: NotchController, desk: NotchDesk, creatures: CreatureController) {
        self.store = store
        self.worker = worker
        self.agents = agents
        self.notch = notch
        self.desk = desk
        self.creatures = creatures
        saved = Self.loaded ?? Saved()
    }

    func start() {
        if saved.strands == true { startInstall() }
        guard Self.holding else { return }
        desk.opensFromRest = { [weak self] in self?.reopen() ?? false }
        creatures.onMissedDrop = { [weak self] id in self?.missedDrop(id) }
        store.$agents.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.agentsChanged() }.store(in: &subscriptions)
        notch.model.$lifted.receive(on: DispatchQueue.main).sink { [weak self] lifted in self?.holding = lifted != nil && lifted == self?.saved.agent }.store(in: &subscriptions)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat() }
        }
        resume()
        show()
        notch.call(.white)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.notch.call(nil) }
    }

    private func go(_ step: Step) {
        saved.step = step
        place()
    }

    private func resume() {
        switch saved.step {
        case .making: make()
        case .drag:
            guard let agent else { return go(.making) }
            worker.firstLookAgent = agent.id
            desk.showReady(agent)
        case .result:
            guard let agent, agent.attachment != nil else { return go(saved.agent == nil ? .making : .drag) }
            readResult()
            if found == nil { lookAgain() }
        default: break
        }
    }

    // MARK: The window

    func reopen() -> Bool {
        guard saved.step != .done else { return false }
        show()
        return true
    }

    func covers(_ point: NSPoint) -> Bool { window?.isVisible == true && window?.frame.contains(point) == true }

    private func show() {
        let window = window ?? makeWindow()
        self.window = window
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous = front }
        place()
        window.orderFrontRegardless()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Changing the activation policy can drop a window ordered just before it.
        for delay in [0, 0.3, 1] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
                guard let self, let window, self.saved.step != .done else { return }
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: OnboardingView.width, height: 400), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.isMovableByWindowBackground = true
        window.title = "Bean"
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        let host = NSHostingController(rootView: OnboardingView(flow: self))
        host.sizingOptions = []
        window.contentViewController = host
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                NSApp.setActivationPolicy(.accessory)
                self?.previous?.activate()
                self?.previous = nil
            }
        }
        return window
    }

    // The windows a drag needs stay in sight, and System Settings has room next to this one.
    private func place() {
        guard let window, let area = (Screens.containing(NSEvent.mouseLocation) ?? NSScreen.main)?.visibleFrame else { return }
        let aside = [.access, .making, .drag, .result].contains(saved.step)
        window.level = aside ? .floating : .normal
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        let margin: CGFloat = 20
        let origin = aside ? NSPoint(x: area.maxX - frame.width - margin, y: area.minY + margin) : NSPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2)
        window.setFrame(NSRect(origin: origin, size: frame.size), display: true, animate: window.isVisible)
    }

    func fit(_ size: CGSize) {
        guard size != contentSize, size.height > 0 else { return }
        contentSize = size
        place()
    }

    // MARK: Steps

    func answer() {
        let words = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        Goals.add(words)
        saved.sentence = words
        go(.brain)
    }

    func notSure() {
        go(.brain)
    }

    func lookForKey() {
        guard !keyPassed, APIKeyStore.current().key != nil else { return }
        keyFound = true
        check()
    }

    func check() {
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        keyProblem = nil
        checking = true
        Task { @MainActor in
            if !typed.isEmpty { try? APIKeyStore.save(typed, for: .meta) }
            let problem = await ModelClient().checkKey()
            checking = false
            if let problem {
                if !typed.isEmpty {
                    APIKeyStore.delete(for: .meta)
                    key = ""
                }
                keyProblem = problem
                return
            }
            key = ""
            keyPassed = true
            saved.strands = true
            startInstall()
            try? await Task.sleep(for: .seconds(0.9))
            go(.sees)
        }
    }

    private func startInstall() {
        StrandsInstaller.shared.onReady = {
            guard !Onboarding.holding else { return }
            NotchInbox.shared.report(NotchReport(line: "The private check is on."))
        }
        StrandsInstaller.shared.onFailed = {
            guard !Onboarding.holding else { return }
            NotchInbox.shared.report(NotchReport(line: "The private check did not install. Window names stay on this Mac. Try again in Settings."))
        }
        StrandsInstaller.shared.start()
    }

    var offLimits: Binding<[String]> {
        Binding(get: { BeanSettings.shared.offLimits }, set: { [weak self] in
            BeanSettings.shared.offLimits = $0
            self?.objectWillChange.send()
        })
    }

    func told() {
        go(.access)
        accessOn = WindowAccess.isOn
        if accessOn { proveAccess() }
    }

    func askAccess() {
        accessAsked = true
        WindowAccess.ask()
    }

    func openPane() { NSWorkspace.shared.open(WindowAccess.settingsURL) }

    private func proveAccess() {
        accessProof = WindowChannels.open().first { $0.title != nil && OffLimits.match("\($0.app) \($0.bundleId) \($0.title ?? "")") == nil }?.title
    }

    func leaveAccess() { make() }

    func make() {
        for agent in store.agents where !agent.isBean && agent.name.isEmpty {
            store.remove(agent.id)
        }
        makeProblem = nil
        go(.making)
        let request = saved.sentence ?? "Stay on the window you are given, and give one small useful result from what it shows."
        agents.hatchFirst(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let agent):
                self.saved.agent = agent.id
                self.worker.firstLookAgent = agent.id
                self.missed = 0
                self.go(.drag)
                self.desk.showReady(agent)
            case .failure(let error):
                self.makeProblem = ModelClient.plain(error)
            }
        }
    }

    func correct() {
        let words = correction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, let agent else { return }
        correction = ""
        worker.firstLookAgent = nil
        worker.forget(agent)
        if let old = saved.sentence { Goals.replace(old, with: words) } else { Goals.add(words) }
        saved.sentence = words
        saved.agent = nil
        make()
    }

    private func missedDrop(_ id: UUID) {
        guard id == saved.agent, saved.step == .drag else { return }
        missed += 1
        returned = true
    }

    func placeForMe() {
        guard let agent, let target = WindowChannels.open().first else { return }
        creatures.attachFromBean(agent.id, windowNumber: target.number)
    }

    private func agentsChanged() {
        if saved.step == .drag, agent?.attachment != nil {
            notch.closeReady()
            found = nil
            go(.result)
        }
    }

    func lookAgain() {
        guard let agent, let attachment = agent.attachment else { return }
        problem = nil
        Task { @MainActor in
            await worker.firstLook(agent, place: [attachment.appName, attachment.windowTitle].compactMap { $0 }.joined(separator: ": "), text: "")
        }
    }

    func tell() {
        let words = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, let agent else { return }
        reply = ""
        worker.send(agent.id, words)
    }

    private func readResult() {
        guard let id = saved.agent else { return }
        found = worker.journal[id]?.last { $0.kind == .replied }?.did
        askedInNotch = worker.needs[id]?.isEmpty == false
        working = worker.isBusy(id) || worker.replying.contains(id)
        if found == nil, !working { problem = ModelClient.problem }
    }

    func finishResult() { go(.closing) }

    func finish() {
        saved.step = .done
        Self.holding = false
        worker.setupEnded()
        timer?.invalidate()
        timer = nil
        desk.opensFromRest = nil
        window?.close()
    }

    private func beat() {
        switch saved.step {
        case .access:
            let on = WindowAccess.isOn
            if on, !accessOn {
                proveAccess()
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
            }
            if on, accessProof == nil { proveAccess() }
            accessOn = on
        case .drag:
            openWindows = !WindowChannels.open().isEmpty
        case .result:
            accessOn = WindowAccess.isOn
            readResult()
        default: break
        }
    }
}
