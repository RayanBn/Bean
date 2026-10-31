import Combine
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notch: NotchController?
    private var menuBar: MenuBarController?
    private(set) var agents: Agents?
    private var creatures: CreatureController?
    private var needsWatch: AnyCancellable?
    private var terminationSource: DispatchSourceSignal?

    func openSettings() {
        agents?.showSettings(.ai)
    }

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
        if ConnectorsProbe.runIfRequested() || AgentsProbe.runIfRequested() || ActionsProbe.runIfRequested() || HandsProbe.runIfRequested() { return }
        if CreatureGallery.runIfRequested() { return }

        let client = ModelClient()
        let notch = NotchController()
        let connectors = Connectors()
        Tools.shared.add(connectors)
        self.notch = notch
        let menuBar = MenuBarController(notch: notch.model)
        notch.onSecondaryClick = { [weak menuBar] view, rect in menuBar?.open(relativeTo: rect, of: view) }
        self.menuBar = menuBar
        let agents = Agents(store: AgentStore(), notch: notch, connectors: connectors)
        self.agents = agents
        let creatures = CreatureController(store: agents.store, notch: notch)
        creatures.onAgentClick = { [weak agents] id in agents?.open(id) }
        agents.onSendHome = { [weak creatures] id in creatures?.sendHome(id) }
        agents.onAddKey = { [weak agents] in agents?.showSettings(.ai) }
        menuBar.openAgents = { [weak agents] in agents?.open() }
        menuBar.openSettings = { [weak agents] in agents?.showSettings(.ai) }
        agents.onBeginDrag = { [weak creatures] id in creatures?.liftFromPage(id) }
        agents.onEndDrag = { [weak creatures] in creatures?.endPageDrag() }
        creatures.pageWasFront = { [weak agents] in agents?.wasFront ?? false }
        creatures.pageShows = { [weak agents] id in agents?.shows(id) ?? false }
        creatures.pageComeBack = { [weak agents] in agents?.comeBack() }
        creatures.dragBlocked = { [weak agents] point in agents?.coversDrag(at: point) ?? false }
        self.creatures = creatures
        creatures.onAnswer = { [weak agents] id, need, text in agents?.worker.answer(id, need: need, text) }
        needsWatch = agents.worker.$needs.receive(on: DispatchQueue.main).sink { [weak creatures] in creatures?.setNeeds($0) }
        agents.worker.onAttach = { [weak creatures] id, number in creatures?.attachFromBean(id, windowNumber: number) }
        if !client.isReady { agents.open() }
    }
}
