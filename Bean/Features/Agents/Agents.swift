import AppKit
import Combine
import SwiftUI

@MainActor
final class Agents: ObservableObject {
    @Published private(set) var selected: UUID? = Agent.beanID
    @Published private(set) var creating = false
    @Published private(set) var creationError: String?
    @Published private(set) var settingsTab = SettingsTab.general
    @Published private(set) var settingsOpen = false
    private var windowsTimer: Timer?
    @Published private var openWindows: [OpenWindow] = []
    private var leftFullScreen: NSObjectProtocol?
    private var escape: Any?
    private var resigned: NSObjectProtocol?
    private var summaries: [UUID: AwaySummary] = [:]
    private var summariesAt = Date.distantPast
    private var readyAt = Date.distantPast
    private var needsKey = false
    private var accessibilityMissing = false
    private var missions: [UUID: AgentMission] = [:]
    private var resignedAt = Date.distantPast
    var onSendHome: ((UUID) -> Void)?
    var onBeginDrag: ((UUID) -> Void)?
    var onEndDrag: (() -> Void)?
    private var awayEnded = Date()
    private var awaySince = BeanDefaults.shared.object(forKey: "agentsLastSeen") as? Date ?? Calendar.current.startOfDay(for: Date())
    let store: AgentStore
    let worker: AgentWorker
    let catalogue: ConnectorCatalogue
    private var hearing: AnyObject?
    private let notch: NotchController
    private let reader: WindowReader
    private let window: NSWindow
    private var previous: NSRunningApplication?
    private var closing: NSObjectProtocol?
    private var shortcut: Any?
    var onAddKey: (() -> Void)?

    private let connectors: Connectors

    init(store: AgentStore, notch: NotchController, connectors: Connectors) {
        defer {
            // For a test run on the shared screen, which has no menu to reach the page from.
            if ProcessInfo.processInfo.environment["BEAN_OPEN_PAGE"] == "1" { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.show() } }
        }
        self.connectors = connectors
        self.store = store
        self.notch = notch
        reader = WindowReader(store: store)
        worker = reader.worker
        let worker = worker
        if #available(macOS 14.2, *) {
            hearing = CallListening(store: store, worker: worker)
        }
        catalogue = MainActor.assumeIsolated {
            let catalogue = ConnectorCatalogue(connectors: connectors, store: store)
            catalogue.onConnected = { [weak worker] entry in worker?.connected(entry) }
            return catalogue
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 880),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.title = "Bean"
        window.minSize = NSSize(width: 900, height: 520)
        window.isRestorable = false
        window.collectionBehavior = Self.floating
        let host = NSHostingController(rootView: AgentsPageRoot(agents: self, store: store, worker: worker, catalogue: catalogue))
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1440, height: 880))
        if ProcessInfo.processInfo.environment["BEAN_DATA_DIR"] == nil {
            if !window.setFrameUsingName("BeanAgentsWindow") { window.center() }
            window.setFrameAutosaveName("BeanAgentsWindow")
        } else {
            window.center()
        }
        leftFullScreen = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            self?.window.collectionBehavior = Self.floating
        }
        escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, event.window === self.window, self.window.childWindows?.isEmpty != false, !self.creating, (self.window.firstResponder as? NSTextView)?.string.isEmpty != false else { return event }
            if self.settingsOpen {
                self.settingsOpen = false
            } else {
                self.leave()
            }
            return nil
        }
        shortcut = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" else { return event }
            self.leave()
            return nil
        }
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            NSApp.setActivationPolicy(.accessory)
            self?.worker.watchWhatBeanSees(false)
            self?.awaySince = Date()
            BeanDefaults.shared.set(Date(), forKey: "agentsLastSeen")
            self?.previous?.activate()
            self?.previous = nil
        }
        resigned = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.resignedAt = Date()
        }
        Self.adoptBean(in: store)
        recolorOnce()
        refreshWindows()
        windowsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.window.isVisible else { return }
            self.refreshWindows()
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

    var wasFront: Bool { window.isVisible && (NSApp.isActive || Date().timeIntervalSince(resignedAt) < 1) }

    // A click on a non-activating notch panel hands focus to the previous app, sometimes after a delay.
    func comeBack() {
        for delay in [0, 0.7] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !NSApp.isActive else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.window.makeKeyAndOrderFront(nil)
            }
        }
    }

    // The page floats over whatever Space is active. It takes a Space of its own only when asked to.
    private static let floating: NSWindow.CollectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

    func toggleFullScreen() {
        if !window.styleMask.contains(.fullScreen) { window.collectionBehavior = [.fullScreenPrimary] }
        window.toggleFullScreen(nil)
    }

    private func leave() {
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        } else {
            window.close()
        }
    }

    func showSettings(_ tab: SettingsTab) {
        settingsTab = tab
        settingsOpen = true
        creating = false
        show()
        if tab == .sees { worker.watchWhatBeanSees(true) }
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

    func shows(_ id: UUID) -> Bool { window.isVisible && window.isKeyWindow && selected == id }

    private func show() {
        if !window.isVisible { awayEnded = Date() }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previous = front }
        if !window.isVisible, let screen = Screens.containing(NSEvent.mouseLocation), window.screen != screen {
            let area = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2))
        }
        window.orderFrontRegardless()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in self?.window.makeKeyAndOrderFront(nil) }
    }

    var roster: [RosterItem] {
        let current = feed
        return store.agents
            .filter { !$0.isBean || $0.attachment != nil || store.activity[$0.id].map { $0.mood != .idle } == true }
            .sorted { Self.rank(store.activity[$0.id]?.mood) < Self.rank(store.activity[$1.id]?.mood) }
            .map { agent in
                let attachment = agent.attachment
                let line = AgentsPage.line(of: agent, activity: store.activity[agent.id], feed: current)
                let plain = line == attachment?.appName
                return RosterItem(id: agent.id, name: agent.name, look: agent.look, mood: store.activity[agent.id]?.mood ?? .idle,
                                  line: plain ? AgentsPage.recent(of: agent, feed: current) ?? "Watching this app" : line,
                                  place: attachment?.appName, app: attachment?.pid, isLive: current.live[agent.id] != nil)
            }
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
                self?.settingsOpen = false
            },
            openSettings: { [weak self] in self?.showSettings(self?.settingsTab ?? .general) },
            closeSettings: { [weak self] in
                self?.settingsOpen = false
                self?.worker.watchWhatBeanSees(false)
            },
            pauseAll: { BeanSettings.shared.paused = true },
            setLook: { [weak self] id, look in self?.setLook(id, look) },
            setSettingsTab: { [weak self] tab in self?.settingsTab = tab },
            watchSees: { [weak self] on in self?.worker.watchWhatBeanSees(on) },
            putAgent: { [weak self] window in self?.putAgent(on: window) },
            putOnApp: { [weak self] id, window in
                guard let self, let agent = self.store.agents.first(where: { $0.id == id }) else { return }
                self.worker.put(agent, on: window)
            },
            agentFolder: { [weak self] id in
                guard let self, let agent = self.store.agents.first(where: { $0.id == id }) else { return nil }
                return self.store.folder(for: agent)
            },
            connectService: { [weak self] id in Task { @MainActor in self?.catalogue.connect(id) } },
            disconnectService: { [weak self] id in Task { @MainActor in self?.catalogue.disconnect(id) } },
            refreshConnectors: { [weak self] in await self?.catalogue.refresh() },
            searchConnectors: { [weak self] query in await self?.catalogue.search(query) ?? [] },
            addConnector: { [weak self] url in try await self?.catalogue.addCustom(url: url) },
            requestAccessibility: { WindowAccess.ask() },
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
            answer: { [weak self] id, need, text in self?.worker.answer(id, need: need, text) },
            correct: { [weak self] id, decision, text in self?.worker.correct(id, decision: decision, text) },
            beginDrag: { [weak self] id in self?.onBeginDrag?(id) },
            endDrag: { [weak self] in self?.onEndDrag?() },
            newAgent: { [weak self] in
                self?.settingsOpen = false
                self?.startNew()
            },
            addKey: { [weak self] in self?.onAddKey?() },
            cancelNew: { [weak self] in self?.creating = false },
            create: { [weak self] mission in self?.hatch(mission) },
            send: { [weak self] id, text in self?.worker.send(id, text) },
            saveMission: { [weak self] id, text in self?.saveMission(text, for: id) },
            rename: { [weak self] id, name in self?.rename(id, to: name) },
            undo: { [weak self] id, entry in self?.worker.undo(id, entry: entry) },
            setAbility: { [weak self] id, ability, on in self?.worker.setAbility(id, ability: ability, allowed: on) },
            senses: { [weak self] id in
                guard let self, let agent = self.store.agents.first(where: { $0.id == id }) else { return [] }
                return self.worker.senseRows(agent)
            },
            setSense: { [weak self] id, sense, on in
                guard let self, let agent = self.store.agents.first(where: { $0.id == id }) else { return }
                self.worker.setSense(agent, id: sense, on: on)
            },
            connect: { [weak self] id, connector in self?.worker.connect(id, connector: connector) },
            removeTarget: { [weak self] id, target in self?.worker.removeTarget(id, target: target) },
            sendHome: { [weak self] id in self?.onSendHome?(id) },
            delete: { [weak self] id in self?.delete(id) },
            reveal: { [weak self] id in
                guard let self, let agent = self.store.agents.first(where: { $0.id == id }) else { return }
                NSWorkspace.shared.activateFileViewerSelecting([AgentFolder(agent, in: self.store).url])
            },
            refreshWork: { [weak self] in self?.worker.refresh() },
            stopSession: { [weak self] agent, session in MainActor.assumeIsolated { self?.worker.stopSession(agent, session: session) } },
            stopWork: { [weak self] agent in MainActor.assumeIsolated { self?.worker.stopWork(agent) } },
            resumeWork: { [weak self] agent in MainActor.assumeIsolated { self?.worker.resumeWork(agent) } },
            openSessionInTerminal: { [weak self] agent, session in MainActor.assumeIsolated { self?.worker.openInTerminal(agent, session: session) } },
            sendToSession: { [weak self] agent, session, text in MainActor.assumeIsolated { self?.worker.sendToSession(agent, session: session, text: text) } },
            takeOver: { [weak self] agent, session in await self?.worker.takeOver(agent, session: session) },
            endTakeOver: { [weak self] agent, session in MainActor.assumeIsolated { self?.worker.endTakeOver(agent, session: session) } },
            sessionChanges: { [weak self] agent, session in await self?.worker.sessionChanges(agent, session: session) },
            connectedServices: { [connectors = self.connectors] in Array(await connectors.state().live).sorted() },
            connectorReads: { [connectors = self.connectors] server in await connectors.exposure(server: server).filter { $0.kind == .read }.map(\.tool).sorted() },
            readConnector: { [connectors = self.connectors] server, tool, arguments in await connectors.read(server: server, tool: tool, arguments: arguments) })
    }

    var feed: PageFeed {
        if Date().timeIntervalSince(readyAt) > 3 {
            needsKey = !ModelClient().isReady
            accessibilityMissing = !WindowAccess.isOn
            missions = Dictionary(uniqueKeysWithValues: store.agents.compactMap { agent in AgentFolder(agent, in: store).mission.map { (agent.id, $0) } })
            readyAt = Date()
        }
        if Date().timeIntervalSince(summariesAt) > 3 {
            summaries = Dictionary(uniqueKeysWithValues: store.agents.compactMap { agent in worker.away(agent.id, since: awaySince, until: awayEnded).map { (agent.id, $0) } })
            summariesAt = Date()
        }
        return PageFeed(journal: worker.journal, steps: worker.steps, live: worker.liveSteps, doing: worker.doing, sessions: worker.sessions, missions: missions,
                        needsKey: needsKey, needsAccessibility: accessibilityMissing, notificationsOff: false, problem: ModelClient.problem, allPaused: BeanSettings.shared.effectivePaused,
                        needs: worker.needs, decisions: worker.decisions, summaries: summaries, catalogue: MainActor.assumeIsolated { catalogue.entries }, openWindows: openWindows, listening: worker.listening, gate: worker.gateDecisions, sees: worker.sees, thoughts: worker.thoughts, awaySince: awaySince, awayEnded: awayEnded, targets: worker.targets, connectors: worker.connectors, abilities: worker.abilities, replying: worker.replying, doingSince: worker.doingSince, stopped: worker.stoppedAgents, notDone: worker.notDone, endedWork: worker.endedWork, windowText: worker.windowText, sessionEvents: worker.sessionEvents, plan: worker.plan)
    }

    private func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var agent = store.agents.first(where: { $0.id == id }), !agent.isBean, agent.name != name else { return }
        agent.name = name
        store.save(agent)
    }

    private func saveMission(_ text: String, for id: UUID) {
        readyAt = .distantPast
        guard let agent = store.agents.first(where: { $0.id == id }) else { return }
        let folder = AgentFolder(agent, in: store)
        guard var mission = folder.mission else { return }
        var updated = agent
        if agent.role == mission.mission { updated.role = text }
        mission.mission = text
        folder.save(mission)
        store.save(updated)
        objectWillChange.send()
    }

    private func delete(_ id: UUID) {
        guard id != Agent.beanID else { return }
        if selected == id { selected = Agent.beanID }
        guard let agent = store.agents.first(where: { $0.id == id }) else { return }
        worker.forget(agent)
    }

    func hatchFromNotch(_ request: String, done: @escaping (Result<Agent, Error>) -> Void) {
        hatch(request, done: done)
    }

    // The first agent reads nothing to be born: the person's sentence is all it gets, and the drag says where it works.
    func hatchFirst(_ request: String, done: @escaping (Result<Agent, Error>) -> Void) {
        hatch(request, first: true, done: done)
    }

    private func hatch(_ request: String, first: Bool = false, done: ((Result<Agent, Error>) -> Void)? = nil) {
        let id = UUID()
        let hue = Agent.Look.nextHue(taken: store.agents.filter { !$0.isBean }.map(\.look.hue))
        store.activity[id] = AgentActivity(mood: .forming(Date()))
        store.save(Agent(id: id, name: "", role: "", look: .init(hue: hue, accessory: "none"), attachment: nil, createdAt: Date()))
        if done == nil {
            selected = id
            creating = false
        }
        creationError = nil
        notch.hatch(id, hue: hue)
        Task { @MainActor in
            do {
                let created = try await AgentMaker().write(request, avoiding: self.store.agents.map(\.name), reality: first ? nil : await AgentWorker.reality(in: self.store))
                guard let current = store.agents.first(where: { $0.id == id }) else { return }
                var card = created.card
                card.id = id
                card.created = current.createdAt
                card.look = .init(hue: hue, accessory: card.look.accessory)
                let folder = AgentFolder(url: store.folder(for: current))
                folder.write(card)
                let agent = card.agent(attachment: current.attachment)
                store.activity[id] = AgentActivity()
                store.save(agent)
                notch.settle(id)
                done?(.success(agent))
                if !first { await worker.connectSource(agent, created.source, request: request) }
            } catch {
                store.remove(id)
                store.activity[id] = nil
                notch.settle(id)
                if selected == id { selected = Agent.beanID }
                if let done { return done(.failure(error)) }
                creationError = "The agent could not be created: \(ModelClient.plain(error))"
                creating = true
            }
        }
    }

    private func recolorOnce() {
        guard !BeanDefaults.shared.bool(forKey: "agentsRecolored") else { return }
        BeanDefaults.shared.set(true, forKey: "agentsRecolored")
        let agents = store.agents.filter { !$0.isBean && !$0.name.isEmpty }
        var taken = agents.filter { $0.look.chosen == true }.map(\.look.hue)
        for var agent in agents.filter({ $0.look.chosen != true }).sorted(by: { $0.createdAt < $1.createdAt }) {
            agent.look.hue = Agent.Look.nextHue(taken: taken)
            taken.append(agent.look.hue)
            store.save(agent)
        }
    }

    private func setLook(_ id: UUID, _ look: Agent.Look) {
        guard var agent = store.agents.first(where: { $0.id == id }), !agent.isBean else { return }
        agent.look = look
        agent.look.chosen = true
        store.save(agent)
    }

    private func putAgent(on window: OpenWindow) {
        guard BeanSettings.shared.effectivePaused else {
            worker.send(Agent.beanID, "Put an agent on this window: \(window.app), \(window.title ?? "no title").")
            return
        }
        worker.momentLine = MomentLine(text: "All agents are paused. Resume from Bean's page, then put one on.", undoAgent: nil)
    }

    private func refreshWindows() {
        Task.detached { [weak self] in
            let testing = ProcessInfo.processInfo.environment["BEAN_WINDOW_FILTER"] != nil
            let own = Bundle.main.bundleIdentifier
            let open = WindowChannels.open().filter { window in
                OffLimits.match(window.title ?? window.app) == nil && OffLimits.match(window.app) == nil
                    && (testing || (!window.bundleId.isEmpty && window.bundleId != own))
            }
            await MainActor.run { self?.openWindows = open }
        }
    }

    static func adoptBean(in store: AgentStore) {
        let existing = store.agents.first(where: \.isBean)
        let bean = Agent(id: Agent.beanID, name: "Bean", role: "The chief. Knows your goals, decides what each agent does and when, passes work between them, and answers for you when you are away.",
                         look: .pearl, attachment: existing?.attachment, createdAt: .distantPast)
        let folder = AgentFolder(bean, in: store)
        let job = AgentJob(goal: "Run the user's agents toward their goals: put agents on the right apps, decide what each does and when, pass work between them, answer for the user while they are away, and give one report. Tasks come from the user's goals, connected trackers and plan files.", output: "", done: "", quiet: "")
        if var card = folder.card {
            card.job = job
            if card != folder.card { folder.write(card) }
        } else {
            folder.create(agent: bean, job: job)
            folder.updateState { $0.every = 600 }
        }
        if existing != bean { store.save(bean) }
    }
}
