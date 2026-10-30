import AppKit
import Combine
import SwiftUI
import UserNotifications

final class NeedsYouNotifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((UUID) -> Void)?
    var onDenied: ((Bool) -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func update(_ agents: [Agent], needs: [UUID: [AgentNeed]], pageIsKey: Bool) {
        let open = Set(needs.values.joined().map(\.id.uuidString))
        var notified = Set(UserDefaults.standard.stringArray(forKey: "agentsNotifiedNeeds") ?? []).intersection(open)
        defer { UserDefaults.standard.set(Array(notified), forKey: "agentsNotifiedNeeds") }
        guard !pageIsKey else { return notified.formUnion(open) }
        for agent in agents {
            for need in needs[agent.id] ?? [] where notified.insert(need.id.uuidString).inserted {
                let content = UNMutableNotificationContent()
                content.title = "\(agent.name) needs you"
                content.body = need.question
                content.userInfo = ["agent": agent.id.uuidString]
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] granted, error in
                    if let error { print("notification refused: \(error.localizedDescription)") }
                    DispatchQueue.main.async { self?.onDenied?(!granted) }
                    guard granted else {
                        DispatchQueue.main.async { Self.forget(need.id) }
                        return
                    }
                    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: need.id.uuidString, content: content, trigger: nil)) { error in
                        if let error { print("notification failed: \(error.localizedDescription)") }
                    }
                }
            }
        }
    }

    private static func forget(_ id: UUID) {
        let kept = (UserDefaults.standard.stringArray(forKey: "agentsNotifiedNeeds") ?? []).filter { $0 != id.uuidString }
        UserDefaults.standard.set(kept, forKey: "agentsNotifiedNeeds")
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let text = response.notification.request.content.userInfo["agent"] as? String, let id = UUID(uuidString: text) else { return }
        await MainActor.run { onOpen?(id) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner] }
}

final class Agents: ObservableObject {
    @Published private(set) var selected: UUID? = Agent.beanID
    @Published private(set) var creating = false
    @Published private(set) var creationError: String?
    @Published private var notificationsOff = false
    var onSendHome: ((UUID) -> Void)?
    var onBeginDrag: ((UUID) -> Void)?
    var onEndDrag: (() -> Void)?
    private var awaySince = UserDefaults.standard.object(forKey: "agentsLastSeen") as? Date ?? Calendar.current.startOfDay(for: Date())
    let store: AgentStore
    let worker: AgentWorker
    private let notch: NotchController
    private let reader: WindowReader
    private let window: NSWindow
    private var previous: NSRunningApplication?
    private var closing: NSObjectProtocol?
    private var shortcut: Any?
    private let notifier = NeedsYouNotifier()
    private var watching: AnyCancellable?
    private static let welcomed = JSONLog.directory.appendingPathComponent("welcomed")
    var onAddKey: (() -> Void)?

    init(store: AgentStore, notch: NotchController) {
        self.store = store
        self.notch = notch
        reader = WindowReader(store: store)
        worker = reader.worker
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.title = "Bean"
        window.minSize = NSSize(width: 900, height: 520)
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        let host = NSHostingController(rootView: AgentsPageRoot(agents: self, store: store, worker: worker))
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1080, height: 680))
        if !window.setFrameUsingName("BeanAgentsWindow") { window.center() }
        window.setFrameAutosaveName("BeanAgentsWindow")
        shortcut = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" else { return event }
            self.window.close()
            return nil
        }
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            NSApp.setActivationPolicy(.accessory)
            self?.awaySince = Date()
            UserDefaults.standard.set(Date(), forKey: "agentsLastSeen")
            self?.previous?.activate()
            self?.previous = nil
        }
        notifier.onOpen = { [weak self] id in self?.open(id) }
        notifier.onDenied = { [weak self] denied in self?.notificationsOff = denied }
        watching = worker.$needs.combineLatest(store.$agents).receive(on: DispatchQueue.main).sink { [weak self] needs, agents in
            guard let self else { return }
            self.notifier.update(agents, needs: needs, pageIsKey: self.window.isKeyWindow)
        }
        notch.onRoster = { [weak self] id in self?.open(id) }
        notch.rosterProvider = { [weak self] in self?.roster ?? [] }
        notch.onNew = { [weak self] in self?.startNew() }
        notch.onOpen = { [weak self] in self?.showBean() }
        adoptBean()
        if !FileManager.default.fileExists(atPath: Self.welcomed.path) {
            FileManager.default.createFile(atPath: Self.welcomed.path, contents: nil)
            DispatchQueue.main.async { [weak self] in self?.open() }
        }
    }

    func open(_ id: UUID? = nil) {
        if let id, store.agents.contains(where: { $0.id == id }) {
            selected = id
            creating = false
        } else if !window.isVisible {
            selected = Agent.beanID
            creating = false
        }
        show()
    }

    func selectNeighbour(_ step: Int) {
        guard window.isKeyWindow, let index = store.agents.firstIndex(where: { $0.id == selected }) else { return }
        selected = store.agents[(index + step + store.agents.count) % store.agents.count].id
        creating = false
    }

    func showBean() {
        selected = Agent.beanID
        creating = false
        show()
    }

    func coversDrag(at point: NSPoint) -> Bool {
        guard window.isVisible, window.frame.contains(point) else { return false }
        let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], CGWindowID(window.windowNumber)) as? [[String: Any]] ?? []
        let cg = Screens.toCG(point)
        return !above.filter { $0[kCGWindowLayer as String] as? Int == 0 }.compactMap(ForeignWindow.init)
            .contains { $0.frame.contains(cg) && $0.pid != ProcessInfo.processInfo.processIdentifier }
    }

    func startNew() {
        creating = true
        creationError = nil
        show()
    }

    private func show() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous = front }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible, let screen = Screens.containing(NSEvent.mouseLocation), window.screen != screen {
            let area = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2))
        }
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in self?.window.makeKeyAndOrderFront(nil) }
    }

    private var roster: [RosterItem] {
        let current = feed
        return store.agents
            .sorted { ($0.isBean ? -1 : Self.rank(store.activity[$0.id]?.mood)) < ($1.isBean ? -1 : Self.rank(store.activity[$1.id]?.mood)) }
            .map { RosterItem(id: $0.id, name: $0.name, look: $0.look, mood: store.activity[$0.id]?.mood ?? .idle,
                              line: AgentsPage.line(of: $0, activity: store.activity[$0.id], feed: current)) }
    }

    private static func rank(_ mood: AgentActivity.Mood?) -> Int {
        switch PageStatus(mood ?? .idle) {
        case .needsYou: 0
        case .working: 1
        case .idle: 2
        }
    }

    var actions: PageActions {
        PageActions(
            select: { [weak self] id in
                self?.selected = id
                self?.creating = false
            },
            pauseAll: { BeanSettings.shared.paused = true },
            setCredits: { [weak self] left in
                CostLedger.setBase(left: left)
                self?.worker.refresh()
            },
            requestAccessibility: { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) },
            openNotificationSettings: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
            },
            retry: { [weak self] in
                Task { @MainActor in
                    _ = await ModelClient().checkKey()
                    self?.objectWillChange.send()
                }
            },
            resume: { BeanSettings.shared.paused = false },
            setBudget: { [weak self] id, value in self?.worker.setBudget(id, usd: value) },
            answer: { [weak self] id, need, text in self?.worker.answer(id, need: need, text) },
            correct: { [weak self] id, decision, text in self?.worker.correct(id, decision: decision, text) },
            beginDrag: { [weak self] id in self?.onBeginDrag?(id) },
            endDrag: { [weak self] in self?.onEndDrag?() },
            newAgent: { [weak self] in self?.startNew() },
            addKey: { [weak self] in self?.onAddKey?() },
            cancelNew: { [weak self] in self?.creating = false },
            create: { [weak self] mission in self?.hatch(mission) },
            send: { [weak self] id, text in self?.worker.send(id, text) },
            saveMission: { [weak self] id, text in self?.saveMission(text, for: id) },
            rename: { [weak self] id, name in self?.rename(id, to: name) },
            undo: { [weak self] id, entry in self?.worker.undo(id, entry: entry) },
            setAbility: { [weak self] id, ability, on in self?.worker.setAbility(id, ability: ability, allowed: on) },
            connect: { [weak self] id, connector in self?.worker.connect(id, connector: connector) },
            removeTarget: { [weak self] id, target in self?.worker.removeTarget(id, target: target) },
            sendHome: { [weak self] id in self?.onSendHome?(id) },
            delete: { [weak self] id in self?.delete(id) },
            reveal: { [weak self] id in
                guard let self, let agent = self.store.agents.first(where: { $0.id == id }) else { return }
                NSWorkspace.shared.activateFileViewerSelecting([AgentFolder(agent, in: self.store).url])
            })
    }

    var feed: PageFeed {
        var missions: [UUID: AgentMission] = [:]
        for agent in store.agents { missions[agent.id] = AgentFolder(agent, in: store).mission }
        var summaries: [UUID: AwaySummary] = [:]
        for agent in store.agents { summaries[agent.id] = worker.away(agent.id, since: awaySince) }
        return PageFeed(journal: worker.journal, doing: worker.doing, sessions: worker.sessions, credits: worker.credits, missions: missions,
                        needsKey: !ModelClient().isReady, needsAccessibility: !AXIsProcessTrusted(), notificationsOff: notificationsOff, problem: ModelClient.problem, allPaused: BeanSettings.shared.effectivePaused,
                        spend: worker.spend, spentToday: worker.spentToday, needs: worker.needs, decisions: worker.decisions, summaries: summaries, awaySince: awaySince, targets: worker.targets, connectors: worker.connectors, abilities: worker.abilities, replying: worker.replying)
    }

    private func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var agent = store.agents.first(where: { $0.id == id }), !agent.isBean, agent.name != name else { return }
        let folder = AgentFolder(agent, in: store)
        let persona = folder.personaText.replacingOccurrences(of: agent.name, with: name)
        try? persona.write(to: folder.persona, atomically: true, encoding: .utf8)
        agent.name = name
        store.save(agent)
    }

    private func saveMission(_ text: String, for id: UUID) {
        guard let agent = store.agents.first(where: { $0.id == id }) else { return }
        let folder = AgentFolder(agent, in: store)
        guard var mission = folder.mission else { return }
        mission.mission = text
        folder.save(mission)
        objectWillChange.send()
    }

    private func delete(_ id: UUID) {
        guard id != Agent.beanID else { return }
        if selected == id { selected = Agent.beanID }
        store.remove(id)
        store.activity[id] = nil
    }

    private func hatch(_ request: String) {
        let id = UUID()
        let hue = Self.hue(for: request)
        store.activity[id] = AgentActivity(mood: .forming(Date()))
        store.save(Agent(id: id, name: "", role: "", personality: "", look: .init(hue: hue, accessory: "none"),
                         connectors: [], attachment: nil, createdAt: Date()))
        selected = id
        creating = false
        creationError = nil
        notch.hatch(id, hue: hue)
        Task { @MainActor in
            do {
                let created = try await AgentMaker().write(request)
                guard let current = store.agents.first(where: { $0.id == id }) else { return }
                let agent = Agent(id: id, name: created.agent.name, role: created.agent.role, personality: created.agent.personality,
                                  look: .init(hue: hue, accessory: created.agent.look.accessory), connectors: [],
                                  attachment: current.attachment, createdAt: current.createdAt)
                let folder = AgentFolder(agent, in: store)
                try folder.create(agent: agent, voice: created.voice, lines: created.lines)
                folder.save(created.mission)
                store.activity[id] = AgentActivity()
                store.save(agent)
                notch.settle(id)
            } catch {
                store.remove(id)
                store.activity[id] = nil
                notch.settle(id)
                if selected == id { selected = Agent.beanID }
                creationError = "The agent could not be created: \(ModelClient.plain(error))"
                creating = true
            }
        }
    }

    private static func hue(for text: String) -> Double {
        let sum = text.lowercased().unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }
        return Double(sum % 1000) / 1000
    }

    private func adoptBean() {
        let existing = store.agents.first(where: \.isBean)
        var bean = Agent(id: Agent.beanID, name: "Bean", role: "The brain. Knows your goals, decides what each agent does and when, passes work between them, and answers for you when you are away.",
                         personality: "A chief of staff who knows your work and your priorities. Direct, precise and calm. Decides what you would decide and records why.",
                         look: .pearl, connectors: existing?.connectors ?? [], attachment: nil, createdAt: .distantPast)
        bean.attachment = existing?.attachment
        let lines = AgentLines(greeting: "Ready.", offLimits: "This window is off limits, so it was not read.")
        try? AgentFolder(bean, in: store).create(agent: bean, voice: "Short, factual sentences. States what was done and what is next. No filler.", lines: lines)
        if existing != bean { store.save(bean) }
    }
}
