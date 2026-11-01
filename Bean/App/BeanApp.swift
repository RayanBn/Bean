import SwiftUI

@main
struct BeanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { appDelegate.openSettings() }.keyboardShortcut(",")
                }
                CommandGroup(replacing: .newItem) {
                    Button("New Agent") { appDelegate.agents?.startNew() }.keyboardShortcut("n")
                }
                CommandGroup(after: .sidebar) {
                    Button("Bean") { appDelegate.agents?.showBean() }.keyboardShortcut("0")
                    Button("What Bean Sees") { appDelegate.agents?.showSettings(.sees) }.keyboardShortcut("i")
                    Button("Previous Agent") { appDelegate.agents?.selectNeighbour(-1) }.keyboardShortcut("[")
                    Button("Next Agent") { appDelegate.agents?.selectNeighbour(1) }.keyboardShortcut("]")
                    Button("Toggle Full Screen") { appDelegate.agents?.toggleFullScreen() }.keyboardShortcut("f", modifiers: [.command, .control])
                }
                SidebarCommands()
                InspectorCommands()
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notch: NotchController?
    private var menuBar: MenuBarController?
    private(set) var agents: Agents?
    private var creatures: CreatureController?
    private var desk: NotchDesk?
    private var onboarding: Onboarding?
    private var terminationSource: DispatchSourceSignal?

    func openSettings() {
        agents?.showSettings(.general)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if onboarding?.reopen() != true { agents?.open() }
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
        terminationSource?.setEventHandler {
            HiddenShell.terminateAll()
            DispatchQueue.main.async { NSApp.terminate(nil) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { _exit(0) }
        }
        terminationSource?.resume()
        if ConnectorsProbe.runIfRequested() || AgentsProbe.runIfRequested() || ActionsProbe.runIfRequested() || HandsProbe.runIfRequested() { return }
        if StepsProbe.runIfRequested() { exit(0) }
        if CreatureGallery.runIfRequested() { return }

        let notch = NotchController()
        let connectors = Connectors()
        Tools.shared.add(connectors)
        self.notch = notch
        let menuBar = MenuBarController(notch: notch.model)
        notch.onSecondaryClick = { [weak menuBar] view, rect in menuBar?.open(relativeTo: rect, of: view) }
        self.menuBar = menuBar
        let store = AgentStore()
        Onboarding.holding = Onboarding.isDue(in: store)
        let agents = Agents(store: store, notch: notch, connectors: connectors)
        self.agents = agents
        let creatures = CreatureController(store: agents.store, notch: notch)
        creatures.onAgentClick = { [weak agents, weak notch] id in
            guard let notch else { return }
            if notch.model.surface == .list { agents?.open(id) } else { notch.showList() }
        }
        agents.onSendHome = { [weak creatures] id in creatures?.sendHome(id) }
        agents.onAddKey = { [weak agents] in agents?.showSettings(.ai) }
        menuBar.openAgents = { [weak agents] in agents?.open() }
        menuBar.openSettings = { [weak agents] in agents?.showSettings(.general) }
        agents.onBeginDrag = { [weak creatures] id in creatures?.liftFromPage(id) }
        agents.onEndDrag = { [weak creatures] in creatures?.endPageDrag() }
        creatures.pageWasFront = { [weak agents] in agents?.wasFront ?? false }
        creatures.pageComeBack = { [weak agents] in agents?.comeBack() }
        creatures.dragBlocked = { [weak self, weak agents] point in agents?.coversDrag(at: point) == true || self?.onboarding?.covers(point) == true }
        self.creatures = creatures
        desk = NotchDesk(store: agents.store, worker: agents.worker, notch: notch, agents: agents) { [weak agents] id in
            agents?.catalogue.connect(id)
        }
        agents.worker.onAttach = { [weak creatures] id, number in creatures?.attachFromBean(id, windowNumber: number) }
        creatures.onAppQuit = { [weak worker = agents.worker, weak store = agents.store] id, attachment in
            guard let agent = store?.agents.first(where: { $0.id == id }) else { return }
            worker?.windowClosed(agent, attachment: attachment)
        }
        let onboarding = Onboarding(store: agents.store, worker: agents.worker, agents: agents, notch: notch, desk: desk!, creatures: creatures)
        self.onboarding = onboarding
        onboarding.start()
    }
}
