import SwiftUI

@main
struct BeanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {}
                CommandGroup(replacing: .newItem) {
                    Button("New Agent") { appDelegate.agents?.startNew() }.keyboardShortcut("n")
                }
                CommandGroup(after: .sidebar) {
                    Button("Bean") { appDelegate.agents?.showBean() }.keyboardShortcut("0")
                    Button("Previous Agent") { appDelegate.agents?.selectNeighbour(-1) }.keyboardShortcut("[")
                    Button("Next Agent") { appDelegate.agents?.selectNeighbour(1) }.keyboardShortcut("]")
                }
                SidebarCommands()
                InspectorCommands()
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notch: NotchController?
    private var menuBar: MenuBarController?
    private(set) var agents: Agents?
    private var creatures: CreatureController?
    private var terminationSource: DispatchSourceSignal?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        agents?.open()
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
        if ConnectorsProbe.runIfRequested() || AgentsProbe.runIfRequested() || ActionsProbe.runIfRequested() { return }
        if CreatureGallery.runIfRequested() { return }

        let client = ModelClient()
        let notch = NotchController()
        Tools.shared.add(Connectors())
        self.notch = notch
        let menuBar = MenuBarController(notch: notch.model)
        notch.onSecondaryClick = { [weak menuBar] view, rect in menuBar?.open(relativeTo: rect, of: view) }
        self.menuBar = menuBar
        let agents = Agents(store: AgentStore(), notch: notch)
        self.agents = agents
        let creatures = CreatureController(store: agents.store, notch: notch)
        creatures.onAgentClick = { [weak agents] id in agents?.open(id) }
        agents.onSendHome = { [weak creatures] id in creatures?.sendHome(id) }
        agents.onAddKey = { [weak menuBar] in menuBar?.open() }
        menuBar.openAgents = { [weak agents] in agents?.open() }
        agents.onBeginDrag = { [weak creatures] id in creatures?.liftFromPage(id) }
        agents.onEndDrag = { [weak creatures] in creatures?.endPageDrag() }
        creatures.pageWasFront = { [weak agents] in agents?.wasFront ?? false }
        creatures.pageComeBack = { [weak agents] in agents?.comeBack() }
        creatures.dragBlocked = { [weak agents] point in agents?.coversDrag(at: point) ?? false }
        self.creatures = creatures
        agents.worker.onAttach = { [weak creatures] id, number in creatures?.attachFromBean(id, windowNumber: number) }
        if !client.isReady { agents.open() }
    }
}
