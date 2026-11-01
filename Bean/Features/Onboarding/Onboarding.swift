import AppKit
import Combine
import SwiftUI

@MainActor
final class Onboarding: ObservableObject {
    enum Step: String, Codable { case ask, model, sees, access, making, job, drag, closing, done }

    struct Saved: Codable {
        var step = Step.ask
        var draft: String?
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
    var draft: String {
        get { saved.draft ?? "" }
        set { saved.draft = newValue }
    }
    @Published var key = ""
    @Published var jobDraft = ""
    @Published private(set) var checking = false
    @Published private(set) var keyPassed = false
    @Published private(set) var keyFound = false
    @Published private(set) var keyProblem: String?
    @Published var accessOn = false
    @Published var accessAsked = false
    @Published private(set) var makeProblem: String?
    @Published private(set) var rewriting = false
    @Published var missed = 0
    @Published var returned = false
    @Published var openWindows = true

    var step: Step { saved.step }
    var agent: Agent? { saved.agent.flatMap { id in store.agents.first { $0.id == id } } }

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
        notch.model.$lifted.receive(on: DispatchQueue.main).sink { [weak self] lifted in self?.getOutOfTheWay(lifted != nil && lifted == self?.saved.agent) }.store(in: &subscriptions)
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
        accessOn = WindowAccess.isOn
        switch saved.step {
        case .making: make()
        case .job:
            guard let agent else { return go(.making) }
            jobDraft = saved.sentence ?? AgentFolder(agent, in: store).card?.job.goal ?? ""
        case .drag:
            guard let agent else { return go(.making) }
            if agent.attachment != nil { return go(.closing) }
            desk.showReady(agent)
        default: break
        }
    }

    // MARK: The window

    func reopen() -> Bool {
        guard saved.step != .done else { return false }
        if saved.step == .drag, let agent, window?.isVisible == true {
            desk.showReady(agent)
        } else {
            show()
        }
        return true
    }

    // While the agent is held the window is gone, so a drop can land on whatever was behind it.
    func covers(_ point: NSPoint) -> Bool { !away && window?.isVisible == true && window?.frame.contains(point) == true }

    private var away = false
    private var shownAt = Date.distantPast

    private func getOutOfTheWay(_ holding: Bool) {
        guard holding != away, let window else { return }
        away = holding
        window.ignoresMouseEvents = holding
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            window.animator().alphaValue = holding ? 0 : 1
        }
    }

    private func show() {
        let window = window ?? makeWindow()
        self.window = window
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous = front }
        place()
        shownAt = Date()
        window.orderFrontRegardless()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Changing the activation policy can drop a window ordered just before it, or leave it on another Space.
        for delay in [0, 0.3, 1] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
                guard let self, let window, self.saved.step != .done else { return }
                NSApp.activate(ignoringOtherApps: true)
                window.orderFrontRegardless()
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

    private func place() {
        guard let window, let area = (Screens.containing(NSEvent.mouseLocation) ?? NSScreen.main)?.visibleFrame else { return }
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        let origin = NSPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2)
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
        go(.model)
    }

    func notSure() {
        go(.model)
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
            accessOn = WindowAccess.isOn
            go(.sees)
        }
    }

    private func startInstall() {
        StrandsInstaller.shared.onReady = {
            guard !Onboarding.holding else { return }
            NotchInbox.shared.report(NotchReport(line: "Bean has finished setting up."))
        }
        StrandsInstaller.shared.onFailed = {
            guard !Onboarding.holding else { return }
            NotchInbox.shared.report(NotchReport(line: "Setup did not finish. Bean makes no offers yet."))
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
        WindowAccess.isOn ? make() : go(.access)
    }

    func askAccess() {
        accessAsked = true
        WindowAccess.ask()
    }

    func openPane() { NSWorkspace.shared.open(WindowAccess.settingsURL) }

    func make() {
        for agent in store.agents where !agent.isBean && agent.name.isEmpty {
            store.remove(agent.id)
        }
        makeProblem = nil
        go(.making)
        let request = saved.sentence ?? Goals.text ?? "Work in the app you are put on, and do what is useful there."
        agents.hatchFirst(request) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let agent):
                self.saved.agent = agent.id
                if let words = self.saved.sentence { AgentFolder(agent, in: self.store).updateCard { $0.job.goal = words } }
                self.jobDraft = self.saved.sentence ?? AgentFolder(agent, in: self.store).card?.job.goal ?? ""
                self.go(.job)
            case .failure(let error):
                self.makeProblem = ModelClient.plain(error)
            }
        }
    }

    // The job stays in the person's words. A change rewrites the rest of the card from them, on the same agent.
    func confirmJob() {
        let words = jobDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, let agent, !rewriting else { return }
        let folder = AgentFolder(agent, in: store)
        guard words != folder.card?.job.goal else { return toDrag(agent) }
        makeProblem = nil
        rewriting = true
        Task { @MainActor in
            defer { rewriting = false }
            do {
                let created = try await AgentMaker().write(words, avoiding: store.agents.map(\.name))
                folder.updateCard {
                    $0.role = created.card.role
                    $0.job = created.card.job
                    $0.job.goal = words
                    $0.bornFrom = .person(words)
                }
                var updated = agent
                updated.role = created.card.role
                store.save(updated)
                if let old = saved.sentence { Goals.replace(old, with: words) } else { Goals.add(words) }
                saved.sentence = words
                toDrag(updated)
            } catch {
                makeProblem = ModelClient.plain(error)
            }
        }
    }

    private func toDrag(_ agent: Agent) {
        missed = 0
        returned = false
        go(.drag)
        desk.showReady(agent)
    }

    private func missedDrop(_ id: UUID) {
        guard id == saved.agent, saved.step == .drag else { return }
        missed += 1
        returned = true
    }

    func placeForMe() {
        guard let agent, let target = WindowChannels.open().first(where: { OffLimits.match("\($0.app) \($0.bundleId) \($0.title ?? "")") == nil && !SealedApps.contains(bundleId: $0.bundleId, app: $0.app) }) else { return }
        creatures.attachFromBean(agent.id, windowNumber: target.number)
    }

    private func agentsChanged() {
        guard saved.step == .drag, agent?.attachment != nil else { return }
        notch.closeReady()
        accessOn = WindowAccess.isOn
        go(.closing)
        show()
    }

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
        if let window, window.isVisible, !window.isOnActiveSpace, Date().timeIntervalSince(shownAt) < 10 { window.orderFrontRegardless() }
        switch saved.step {
        case .access:
            guard WindowAccess.isOn else { return }
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            make()
        case .closing:
            accessOn = WindowAccess.isOn
        case .drag:
            openWindows = !WindowChannels.open().isEmpty
        default: break
        }
    }
}
