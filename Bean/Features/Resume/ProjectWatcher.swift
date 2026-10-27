import AppKit

extension Trigger.Kind {
    static let projectLeft: Self = "projectLeft"
    static let projectBack: Self = "projectBack"
}

/// Keeps the last known state of each project the user works on, and tells the brain when the user leaves one and comes back to it.
final class ProjectWatcher {
    static let awayMinutes = ProcessInfo.processInfo.environment["BEAN_RESUME_AWAY_MINUTES"].flatMap(Double.init) ?? 15
    static let refreshDelay: TimeInterval = 1.5
    static let settleSeconds: TimeInterval = 10
    private static let refreshing: Set<String> = ["appActivated", "windowFocused", "windowOpened", "windowClosed", "titleChanged", "tabChanged", "spaceChanged", "appQuit"]
    private static let leaving: Set<String> = ["screenLocked", "macSleeping", "sessionInactive", "screensSlept"]
    private static let returning: Set<String> = ["screenUnlocked", "macWoke", "sessionActive", "screensWoke"]

    let store: ResumeStore
    var describe: ((WindowFacts) async -> WindowContent?)?

    private let log = JSONLog(name: "resume")
    private let build: (@escaping (Inventory) -> Void) -> Void
    private let knownPaths: () -> [String]
    private var contents: [CGWindowID: (title: String, content: WindowContent?)] = [:]
    private var describing: Set<CGWindowID> = []
    private var queue: [WindowFacts] = []
    private var active: String?
    private var pending: DispatchWorkItem?
    private var announced: [String: Date] = [:]
    private var switching: (to: String?, since: Date)?

    init(store: ResumeStore, build: @escaping (@escaping (Inventory) -> Void) -> Void, knownPaths: @escaping () -> [String]) {
        self.store = store
        self.build = build
        self.knownPaths = knownPaths
    }

    func observe(_ event: InventoryEvent) {
        if Self.leaving.contains(event.event), let active {
            leave(active)
            self.active = nil
        } else if Self.returning.contains(event.event) {
            if let last = store.projects.values.filter({ $0.leftAt != nil }).max(by: { $0.lastActive < $1.lastActive }) { offerBack(last.root, because: "the user is back at the Mac") }
        } else if Self.refreshing.contains(event.event) {
            scheduleRefresh()
        }
    }

    func observe(_ command: ShellCommand) {
        guard let root = ProjectGraph.root(of: command.cwd), store.projects[root] != nil, root != active else { return }
        offerBack(root, because: "the user ran `\(command.cmd)` in \(command.cwd)")
    }

    func remember(_ content: WindowContent?, for window: CGWindowID, title: String) {
        contents[window] = (title, content)
    }

    func scheduleRefresh() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.build { self?.refresh($0) } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.refreshDelay, execute: work)
    }

    func group(_ inventory: Inventory) -> (live: [String: [SavedWindow]], focused: String?) {
        let spaces = Dictionary(uniqueKeysWithValues: WindowPlacer.spaces().map { ($0.id, $0) })
        var known = Array(store.projects.values)
        let table = ProcessTable()
        let processes = Dictionary(uniqueKeysWithValues: inventory.apps.map { ($0.pid, table.descendants(of: $0.pid)) })
        let processCwds = processes.values.flatMap { $0.compactMap(\.cwd) }
        for path in knownPaths() + processCwds {
            if let root = ProjectGraph.root(of: path), !known.contains(where: { $0.root == root }) {
                known.append(ProjectState(root: root, name: URL(fileURLWithPath: root).lastPathComponent, windows: [], lastActive: .distantPast))
            }
        }
        var live: [String: [SavedWindow]] = [:]
        var focusedRoot: String?
        let frontmost = inventory.apps.first(where: \.isActive)
        let lookedAt = frontmost.flatMap { Accessibility.focusedWindow(of: $0.pid) }.flatMap(WindowServer.windowId(of:))
        for app in inventory.apps where app.kind == .dock && app.bundleId != Bundle.main.bundleIdentifier {
            for window in app.windows where !window.title.isEmpty || app.windows.count == 1 {
                guard var saved = savedWindow(window, app: app, spaces: spaces, processes: processes[app.pid] ?? []) else { continue }
                let root = ProjectGraph.project(of: saved, windowsOfApp: app.windows.count, known: known)
                let looking = app.pid == frontmost?.pid && window.id == lookedAt
                if contents[window.id]?.title != window.title, looking || (root != nil && root == active) {
                    contents[window.id] = (window.title, nil)
                    learn(saved.facts)
                }
                guard let root else { continue }
                if looking { saved.lastFocused = Date() }
                live[root, default: []].append(saved)
                if looking { focusedRoot = root }
            }
        }
        return (live, focusedRoot)
    }

    private func refresh(_ inventory: Inventory) {
        let (live, focusedRoot) = group(inventory)
        log.append(["at": ISO8601DateFormatter().string(from: Date()), "focused": focusedRoot ?? "-", "active": active ?? "-", "switching": switching.map { "\($0.to ?? "-") since \($0.since)" } ?? "-",
                    "projects": live.map { "\(URL(fileURLWithPath: $0.key).lastPathComponent): \($0.value.count)" }.joined(separator: ", ")])
        if let active, live[active]?.isEmpty ?? true {
            leave(active)
            self.active = nil
            switching = nil
        }
        if focusedRoot == nil || focusedRoot == active {
            switching = nil
        } else if active == nil {
            active = focusedRoot
            if let focusedRoot { offerBack(focusedRoot, because: "the user opened a window of this project") }
        } else if let since = switching?.since, switching?.to == focusedRoot, Date().timeIntervalSince(since) >= Self.settleSeconds {
            switching = nil
            if let active { leave(active, at: since) }
            if let focusedRoot { offerBack(focusedRoot, because: "the user opened a window of this project") }
            active = focusedRoot
        } else {
            if switching?.to != focusedRoot { switching = (focusedRoot, Date()) }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleSeconds + 0.5) { [weak self] in self?.scheduleRefresh() }
        }
        guard let active else { return }
        store.update(active) { project in
            let now = Date()
            let current = live[active] ?? []
            var merged = project.windows.map { saved -> SavedWindow in
                var saved = saved
                if !current.contains(where: { $0.facts.windowId == saved.facts.windowId }), saved.closedAt == nil { saved.closedAt = now }
                return saved
            }
            for window in current {
                var window = window
                if let index = merged.firstIndex(where: { $0.facts.windowId == window.facts.windowId || $0.key == window.key }) {
                    window.content = window.content ?? merged[index].content
                    window.lastFocused = window.lastFocused ?? merged[index].lastFocused
                    merged[index] = window
                } else {
                    merged.append(window)
                }
            }
            project.windows = merged
            project.lastActive = now
            project.leftAt = nil
        }
    }

    private func savedWindow(_ window: InventoryWindow, app: InventoryApp, spaces: [Int: SpaceInfo], processes: [ProcessFact]) -> SavedWindow? {
        guard var facts = WindowFacts.read(window: window, app: app, element: nil, table: ProcessTable.none) else { return nil }
        facts.processes = processes
        let fullScreen = window.space.flatMap { spaces[$0] }?.fullScreen ?? false
        return SavedWindow(facts: facts, content: contents[window.id]?.content, frame: CGRect(x: window.x, y: window.y, width: window.width, height: window.height),
                           space: window.space, fullScreen: fullScreen, minimized: window.isMinimized, lastFocused: nil)
    }

    private func learn(_ facts: WindowFacts) {
        guard describe != nil, !describing.contains(facts.windowId), !queue.contains(where: { $0.windowId == facts.windowId }) else { return }
        queue.append(facts)
        guard queue.count == 1 else { return }
        Task { @MainActor in await drain() }
    }

    @MainActor
    private func drain() async {
        while let next = queue.first, let describe {
            describing.insert(next.windowId)
            var facts = next
            facts.recentFiles = WindowFacts.recentlyWritten(by: facts.appName, bundleId: facts.bundleId)
            let content = await describe(facts)
            describing.remove(facts.windowId)
            queue.removeFirst()
            if contents[facts.windowId]?.title == facts.title { contents[facts.windowId] = (facts.title, content) }
            for project in store.projects.values where project.windows.contains(where: { $0.facts.windowId == facts.windowId && $0.facts.title == facts.title }) {
                store.update(project.root) { project in
                    for index in project.windows.indices where project.windows[index].facts.windowId == facts.windowId { project.windows[index].content = content }
                }
            }
            scheduleRefresh()
        }
    }

    private func leave(_ root: String, at date: Date = Date()) {
        store.update(root) { $0.leftAt = date }
        Events.post(trigger(.projectLeft, root, details: "The user left the project \(store.projects[root]?.name ?? root).", gate: .never))
    }

    private func offerBack(_ root: String, because reason: String) {
        guard let project = store.projects[root], let left = project.leftAt, Date().timeIntervalSince(left) >= Self.awayMinutes * 60,
              announced[root].map({ $0 < left }) ?? true else { return }
        build { [weak self] inventory in
            guard let self else { return }
            let open = Set(inventory.apps.flatMap { app in app.windows.map { "\(app.bundleId ?? "")|\($0.title)" } })
            let saved = project.toRestore()
            let missing = saved.filter { !open.contains("\($0.facts.bundleId)|\($0.facts.title)") }
            guard !missing.isEmpty else { return }
            announced[root] = Date()
            let minutes = Int(Date().timeIntervalSince(left) / 60)
            var lines = ["The user is coming back to the project \(project.name) (\(root)), left \(minutes) min ago (\(reason)).", "Its windows when the user left:"]
            for window in saved {
                let state = missing.contains(window) ? "missing now" : "still open"
                lines.append("- \(window.facts.appName) \"\(window.facts.title)\"\(window.fullScreen ? " (full screen)" : "") — \(state)\(window.content.map { ": \($0.description)" } ?? "")")
            }
            Events.post(trigger(.projectBack, root, details: lines.joined(separator: "\n"), gate: .always, notice: "Welcome back"))
        }
    }

    private func trigger(_ kind: Trigger.Kind, _ root: String, details: String, gate: Trigger.GatePolicy, notice: String? = nil) -> Trigger {
        Trigger(at: Date(), kind: kind, app: nil, bundleId: nil, windowTitle: nil, idleSeconds: IdleClock.seconds(), errorLine: nil, errorSeconds: nil,
                terminalTail: nil, cwd: root, details: details, notice: notice, gate: gate, source: "Resume")
    }
}
