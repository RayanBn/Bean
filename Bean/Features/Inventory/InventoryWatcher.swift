import AppKit
import IOKit.ps
import Network

final class InventoryWatcher {
    static let newAppDelay: TimeInterval = 0.25
    static let typingPause: TimeInterval = 1.5
    static let tabsDelay: TimeInterval = 2
    private static let workspaceEvents: [(Notification.Name, String)] = [
        (NSWorkspace.didActivateApplicationNotification, "appActivated"),
        (NSWorkspace.didHideApplicationNotification, "appHidden"),
        (NSWorkspace.didUnhideApplicationNotification, "appShown"),
        (NSWorkspace.activeSpaceDidChangeNotification, "spaceChanged"),
        (NSWorkspace.willSleepNotification, "macSleeping"),
        (NSWorkspace.didWakeNotification, "macWoke"),
        (NSWorkspace.screensDidSleepNotification, "screensSlept"),
        (NSWorkspace.screensDidWakeNotification, "screensWoke"),
        (NSWorkspace.sessionDidResignActiveNotification, "sessionInactive"),
        (NSWorkspace.sessionDidBecomeActiveNotification, "sessionActive"),
        (NSWorkspace.didMountNotification, "volumeMounted"),
        (NSWorkspace.didUnmountNotification, "volumeUnmounted"),
    ]

    private(set) var focusedText: WindowText?
    private var subscribers: [(InventoryEvent) -> Void] = []

    func subscribe(_ handler: @escaping (InventoryEvent) -> Void) {
        subscribers.append(handler)
    }

    private let log: JSONLog
    private let file: URL
    private let context: ContextStore
    private let windows = WindowTracker()
    private let processes = ProcessTracker()
    private var appsObservation: NSKeyValueObservation?
    private var tokens: [NSObjectProtocol] = []
    private var monitors: [Any] = []
    private var locked = false
    private var asleep = false
    private var spaceChanges = 0
    private var network: String?
    private let pathMonitor = NWPathMonitor()
    private var powerSource: CFRunLoopSource?
    private var tabs: [BrowserTab] = []
    private let signalSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    private var pendingText: DispatchWorkItem?
    private var pendingTabs: DispatchWorkItem?
    private var readingTabs = false
    private var appNames: [pid_t: (name: String?, bundleId: String?)] = [:]

    init(log: JSONLog, context: ContextStore) {
        self.log = log
        self.context = context
        file = log.url.deletingLastPathComponent().appendingPathComponent("inventory.json")
    }

    func start() {
        windows.onEvent = { [weak self] event in DispatchQueue.main.async { self?.windowEvent(event) } }
        windows.onFocus = { [weak self] pid in DispatchQueue.main.async { self?.focusMoved(pid) } }
        processes.onEvent = { [weak self] event in DispatchQueue.main.async { self?.record(event) } }
        processes.start()

        appsObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new]) { [weak self] _, change in
            DispatchQueue.main.async { self?.appsChanged(added: change.newValue ?? [], removed: change.oldValue ?? []) }
        }
        for app in NSWorkspace.shared.runningApplications {
            appNames[app.processIdentifier] = (app.localizedName, app.bundleIdentifier)
            windows.track(app)
        }

        let workspace = NSWorkspace.shared.notificationCenter
        for (name, event) in Self.workspaceEvents {
            tokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in self?.workspace(event, note) })
        }
        let distributed = DistributedNotificationCenter.default()
        for (name, event) in [("com.apple.screenIsLocked", "screenLocked"), ("com.apple.screenIsUnlocked", "screenUnlocked"), ("AppleInterfaceThemeChangedNotification", "themeChanged")] {
            tokens.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if event == "screenLocked" { locked = true }
                if event == "screenUnlocked" { locked = false }
                record(InventoryEvent(at: Date(), event: event))
            })
        }
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.record(InventoryEvent(at: Date(), event: "displaysChanged", detail: NSScreen.screens.map(\.localizedName).joined(separator: ", ")))
        })
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let summary = path.status != .satisfied ? "offline" : ([NWInterface.InterfaceType.wifi, .wiredEthernet, .cellular].first { path.usesInterfaceType($0) }.map { "online (\($0))" } ?? "online")
            DispatchQueue.main.async {
                guard let self, summary != self.network else { return }
                self.network = summary
                self.record(InventoryEvent(at: Date(), event: "networkChanged", detail: summary))
            }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        if let power = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<InventoryWatcher>.fromOpaque(context).takeUnretainedValue().record(InventoryEvent(at: Date(), event: "powerChanged", detail: SystemReader.battery()))
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), power, .defaultMode)
            powerSource = power
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseUp], handler: { [weak self] _ in self?.userActed() }) {
            monitors.append(monitor)
        }
        if let front = NSWorkspace.shared.frontmostApplication { focusMoved(front.processIdentifier) }
        refreshTabs()
        signalSource.setEventHandler { [weak self] in self?.write() }
        signal(SIGUSR1, SIG_IGN)
        signalSource.resume()
    }

    func stop() {
        windows.thread.async { FocusedText.resetManualAccessibility() }
    }

    private func appsChanged(added: [NSRunningApplication], removed: [NSRunningApplication]) {
        for app in removed {
            windows.untrack(app.processIdentifier)
            guard let known = appNames.removeValue(forKey: app.processIdentifier) else { continue }
            record(InventoryEvent(at: Date(), event: "appQuit", app: known.name, bundleId: known.bundleId, pid: app.processIdentifier))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.newAppDelay) { [weak self] in
            for app in added where !app.isTerminated && !Self.isOwnChild(app.processIdentifier) && !(app.bundleURL?.path.contains(".xpc") ?? false) {
                self?.appNames[app.processIdentifier] = (app.localizedName, app.bundleIdentifier)
                self?.windows.track(app)
                self?.record(InventoryEvent(at: Date(), event: "appLaunched", app: app.localizedName, bundleId: app.bundleIdentifier, detail: app.bundleURL?.path, pid: app.processIdentifier))
            }
        }
    }

    private static func isOwnChild(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 && pid_t(info.pbi_ppid) == getpid()
    }

    private func workspace(_ event: String, _ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        switch event {
        case "appActivated": if let app { focusMoved(app.processIdentifier) }
        case "spaceChanged": spaceChanges += 1
        case "macSleeping", "screensSlept": asleep = true
        case "macWoke", "screensWoke": asleep = false
        default: break
        }
        let volume = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
        record(InventoryEvent(at: Date(), event: event, app: app?.localizedName, bundleId: app?.bundleIdentifier, detail: volume, pid: app?.processIdentifier))
    }

    private func windowEvent(_ event: InventoryEvent) {
        record(event)
        if let bundleId = event.bundleId, TabReader.bundleIds.contains(bundleId), ["titleChanged", "tabChanged", "windowOpened", "windowClosed"].contains(event.event) {
            refreshTabs()
        }
    }

    private func userActed() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        readText(of: front.processIdentifier, after: Self.typingPause)
    }

    private func focusMoved(_ pid: pid_t) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
        readText(of: pid, after: 0.3)
    }

    private func readText(of pid: pid_t, after delay: TimeInterval) {
        pendingText?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let app = NSRunningApplication(processIdentifier: pid), !WindowReader.privateApps.contains(app.bundleIdentifier ?? "") else { return }
            windows.thread.async {
                let text = FocusedText.read(app)
                DispatchQueue.main.async { self.textRead(text) }
            }
        }
        pendingText = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func textRead(_ text: WindowText?) {
        guard let text, text.text != focusedText?.text || text.pid != focusedText?.pid else { return }
        focusedText = text
        record(InventoryEvent(at: text.at, event: "textChanged", app: text.app, detail: "\(text.window ?? "") · \(text.text.count) chars, \(text.nodes) nodes, \(text.milliseconds) ms", pid: text.pid))
    }

    private func refreshTabs() {
        guard BeanSettings.shared.readBrowser, pendingTabs == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pendingTabs = nil
            guard !readingTabs else { return refreshTabs() }
            readingTabs = true
            DispatchQueue.global(qos: .utility).async {
                let read = TabReader.all()
                DispatchQueue.main.async {
                    self.readingTabs = false
                    guard read.map(\.url) != self.tabs.map(\.url) || read.map(\.isActive) != self.tabs.map(\.isActive) else { return }
                    self.tabs = read
                    self.record(InventoryEvent(at: Date(), event: "tabsChanged", detail: "\(read.count) tabs, active: \(read.filter(\.isActive).map(\.title).joined(separator: " | "))"))
                }
            }
        }
        pendingTabs = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tabsDelay, execute: work)
    }

    private func record(_ event: InventoryEvent) {
        log.append(event)
        subscribers.forEach { $0(event) }
    }

    func write(_ done: @escaping (Inventory) -> Void = { _ in }) {
        build { [weak self] inventory in
            guard let self else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try? encoder.encode(inventory).write(to: file, options: .atomic)
            done(inventory)
        }
    }

    func build(_ reply: @escaping (Inventory) -> Void) {
        let state = (locked: locked, asleep: asleep, spaces: spaceChanges, network: network)
        let tabs = tabs, text = focusedText
        let agents = context.agents, files = context.recentFileList, commands = context.commandList
        windows.snapshot { tracked, focused in
            self.processes.current { processes in
                DispatchQueue.global(qos: .utility).async {
                    let (apps, background) = SystemReader.apps(tracked: tracked, focused: focused)
                    let presence = Presence.current()
                    let audio = SystemReader.audioOutput()
                    let system = InventorySystem(
                        host: Host.current().localizedName ?? "", user: NSUserName(), os: ProcessInfo.processInfo.operatingSystemVersionString,
                        uptimeHours: (ProcessInfo.processInfo.systemUptime / 360).rounded() / 10, darkMode: false, locked: state.locked, asleep: state.asleep,
                        idleSeconds: IdleClock.seconds().rounded(), battery: SystemReader.battery(), network: state.network, audioOutput: audio.name, volume: audio.volume,
                        micInUse: presence.micInUse, cameraInUse: presence.cameraInUse, displays: [], mountedVolumes: SystemReader.mountedVolumes(),
                        spaceChanges: state.spaces, activeSpace: WindowServer.activeSpace
                    )
                    var inventory = Inventory(
                        at: Date(), system: system, apps: apps, backgroundApps: background, processes: SystemReader.processes(),
                        trackedProcesses: processes.sorted { $0.startedAt > $1.startedAt }, focusedText: text, tabs: tabs,
                        agents: agents, recentFiles: files, ports: ContextStore.listeningPorts(), commands: commands
                    )
                    DispatchQueue.main.async {
                        inventory.system.darkMode = SystemReader.darkMode
                        inventory.system.displays = SystemReader.displays()
                        reply(inventory)
                    }
                }
            }
        }
    }
}
