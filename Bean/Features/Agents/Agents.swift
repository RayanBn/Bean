import AppKit
import Combine
import SwiftUI
import UserNotifications

final class NeedsYouNotifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((UUID) -> Void)?
    var onDenied: ((Bool) -> Void)?
    var onFallback: ((Agent) -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func update(_ agents: [Agent], needs: [UUID: [AgentNeed]], pageIsKey: Bool) {
        let open = Set(needs.values.joined().map(\.id.uuidString))
        var notified = Set(BeanDefaults.shared.stringArray(forKey: "agentsNotifiedNeeds") ?? []).intersection(open)
        defer { BeanDefaults.shared.set(Array(notified), forKey: "agentsNotifiedNeeds") }
        guard !pageIsKey else { return }
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
                        Self.scriptNotification(title: content.title, body: need.question)
                        DispatchQueue.main.async { self?.onFallback?(agent) }
                        return
                    }
                    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: need.id.uuidString, content: content, trigger: nil)) { error in
                        if let error { print("notification failed: \(error.localizedDescription)") }
                    }
                }
            }
        }
    }

    private static func scriptNotification(title: String, body: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "on run argv", "-e", "display notification (item 2 of argv) with title (item 1 of argv)", "-e", "end run", "--", title, String(body.prefix(200))]
        do { try process.run() } catch { print("notification fallback failed: \(error.localizedDescription)") }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let text = response.notification.request.content.userInfo["agent"] as? String, let id = UUID(uuidString: text) else { return }
        await MainActor.run { onOpen?(id) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner] }
}

final class Agents: ObservableObject {
    @Published private(set) var selected: UUID? = AgentsPage.wallID
    @Published private(set) var creating = false
    @Published private(set) var creationError: String?
    @Published private var notificationsOff = false
    private var leftPage: NSObjectProtocol?
    @Published private(set) var settingsTab = SettingsTab.ai
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
    private let notifier = NeedsYouNotifier()
    private var watching: AnyCancellable?
    private static let welcomed = JSONLog.directory.appendingPathComponent("welcomed")
    var onAddKey: (() -> Void)?

    private let connectors: Connectors

    init(store: AgentStore, notch: NotchController, connectors: Connectors) {
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
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
        window.setContentSize(NSSize(width: 1080, height: 680))
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
            guard let self, event.window === self.window, event.keyCode == 53, !self.creating, (self.window.firstResponder as? NSTextView)?.string.isEmpty != false else { return event }
            self.leave()
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
        notifier.onOpen = { [weak self] id in self?.open(id) }
        notifier.onDenied = { [weak self] denied in self?.notificationsOff = denied }
        notifier.onFallback = { agent in print("alerted about \(agent.name) with a script notification") }
        watching = worker.$needs.combineLatest(store.$agents).receive(on: DispatchQueue.main).sink { [weak self] needs, agents in
            guard let self else { return }
            self.notifier.update(agents, needs: needs, pageIsKey: self.window.isKeyWindow)
        }
        leftPage = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.notifier.update(self.store.agents, needs: self.worker.needs, pageIsKey: false)
        }
        notch.onRoster = { [weak self] id in self?.open(id) }
        notch.rosterProvider = { [weak self] in self?.roster ?? [] }
        notch.hasAgents = { [weak self] in (self?.store.agents.count ?? 0) > 1 }
        notch.onNew = { [weak self] in self?.startNew() }
        notch.onOpen = { [weak self] in self?.showBean() }
        Self.adoptBean(in: store)
        recolorOnce()
        refreshWindows()
        windowsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.window.isVisible else { return }
            self.refreshWindows()
        }
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
            selected = AgentsPage.wallID
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
        selected = AgentsPage.settingsID
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
            setLook: { [weak self] id, look in self?.setLook(id, look) },
            setSettingsTab: { [weak self] tab in self?.settingsTab = tab },
            watchSees: { [weak self] on in self?.worker.watchWhatBeanSees(on) },
            putAgent: { [weak self] window in self?.putAgent(on: window) },
            connectService: { [weak self] id in Task { @MainActor in self?.catalogue.connect(id) } },
            disconnectService: { [weak self] id in Task { @MainActor in self?.catalogue.disconnect(id) } },
            refreshConnectors: { [weak self] in await self?.catalogue.refresh() },
            searchConnectors: { [weak self] query in await self?.catalogue.search(query) ?? [] },
            addConnector: { [weak self] url in try await self?.catalogue.addCustom(url: url) },
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
            accessibilityMissing = !AXIsProcessTrusted()
            missions = Dictionary(uniqueKeysWithValues: store.agents.compactMap { agent in AgentFolder(agent, in: store).mission.map { (agent.id, $0) } })
            readyAt = Date()
        }
        if Date().timeIntervalSince(summariesAt) > 3 {
            summaries = Dictionary(uniqueKeysWithValues: store.agents.compactMap { agent in worker.away(agent.id, since: awaySince).map { (agent.id, $0) } })
            summariesAt = Date()
        }
        return PageFeed(journal: worker.journal, doing: worker.doing, sessions: worker.sessions, credits: worker.credits, missions: missions,
                        needsKey: needsKey, needsAccessibility: accessibilityMissing, notificationsOff: notificationsOff, problem: ModelClient.problem, allPaused: BeanSettings.shared.effectivePaused,
                        spend: worker.spend, spentToday: worker.spentToday, needs: worker.needs, decisions: worker.decisions, summaries: summaries, catalogue: MainActor.assumeIsolated { catalogue.entries }, openWindows: openWindows, listening: worker.listening, gate: worker.gateDecisions, sees: worker.sees, thoughts: worker.thoughts, awaySince: awaySince, targets: worker.targets, connectors: worker.connectors, abilities: worker.abilities, replying: worker.replying, doingSince: worker.doingSince, endedWork: worker.endedWork, windowText: worker.windowText, sessionEvents: worker.sessionEvents, planSteps: worker.planSteps)
    }

    private func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var agent = store.agents.first(where: { $0.id == id }), !agent.isBean, agent.name != name else { return }
        let folder = AgentFolder(agent, in: store)
        let persona = ((try? String(contentsOf: folder.persona, encoding: .utf8)) ?? "").replacingOccurrences(of: agent.name, with: name)
        try? persona.write(to: folder.persona, atomically: true, encoding: .utf8)
        agent.name = name
        store.save(agent)
    }

    private func saveMission(_ text: String, for id: UUID) {
        readyAt = .distantPast
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
        let hue = Agent.Look.nextHue(taken: store.agents.filter { !$0.isBean }.map(\.look.hue))
        store.activity[id] = AgentActivity(mood: .forming(Date()))
        store.save(Agent(id: id, name: "", role: "", personality: "", look: .init(hue: hue, accessory: "none"),
                         connectors: [], attachment: nil, createdAt: Date()))
        selected = id
        creating = false
        creationError = nil
        notch.hatch(id, hue: hue)
        Task { @MainActor in
            do {
                let created = try await AgentMaker().write(request, avoiding: self.store.agents.map(\.name))
                guard let current = store.agents.first(where: { $0.id == id }) else { return }
                let agent = Agent(id: id, name: created.agent.name, role: created.agent.role, personality: created.agent.personality,
                                  look: .init(hue: hue, accessory: created.agent.look.accessory), connectors: [],
                                  attachment: current.attachment, createdAt: current.createdAt)
                let folder = AgentFolder(agent, in: store)
                try folder.create(agent: agent, voice: created.voice, lines: created.lines, job: created.job)
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
        let agents = store.agents.filter { !$0.isBean && !$0.name.isEmpty }
        worker.place(agents.first { $0.attachment == nil } ?? localAgent(for: window, among: agents), on: window)
    }

    private func localAgent(for window: OpenWindow, among agents: [Agent]) -> Agent {
        var name = "\(window.app) Agent"
        var number = 2
        while agents.contains(where: { $0.name == name }) {
            name = "\(window.app) Agent \(number)"
            number += 1
        }
        let agent = Agent(id: UUID(), name: name, role: "Works on the \(window.app) window.", personality: "Careful and brief.",
                          look: .init(hue: Agent.Look.nextHue(taken: agents.map(\.look.hue)), accessory: "none"), connectors: [], attachment: nil, createdAt: Date())
        let folder = AgentFolder(agent, in: store)
        try? folder.create(agent: agent, voice: "Short, factual sentences.", lines: AgentLines(greeting: "Ready.", offLimits: "This window is off limits, so it was not read."))
        folder.save(AgentMission(mission: agent.role))
        store.save(agent)
        return agent
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
        var bean = Agent(id: Agent.beanID, name: "Bean", role: "The brain. Knows your goals, decides what each agent does and when, passes work between them, and answers for you when you are away.",
                         personality: "A chief of staff who knows your work and your priorities. Direct, precise and calm. Decides what you would decide and records why.",
                         look: .pearl, connectors: existing?.connectors ?? [], attachment: nil, createdAt: .distantPast)
        bean.attachment = existing?.attachment
        let lines = AgentLines(greeting: "Ready.", offLimits: "This window is off limits, so it was not read.")
        try? AgentFolder(bean, in: store).create(agent: bean, voice: "Short, factual sentences. States what was done and what is next. No filler.", lines: lines)
        if existing != bean { store.save(bean) }
    }
}
