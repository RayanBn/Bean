import SwiftUI

@main
struct BeanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notch: NotchController?
    private var menuBar: MenuBarController?
    private var agents: Agents?
    private var creatures: CreatureController?
    private var terminationSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
        terminationSource?.setEventHandler {
            HiddenShell.terminateAll()
            DispatchQueue.main.async { NSApp.terminate(nil) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { _exit(0) }
        }
        terminationSource?.resume()
        if ConnectorsProbe.runIfRequested() || AgentsProbe.runIfRequested() { return }
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
        self.creatures = creatures
        if !client.isReady {
            notch.show(NotchMessage(text: "Bean needs an API key to run agents.", choices: [
                NotchChoice(label: "Not Now", isPrimary: false) { [weak notch] in notch?.rest() },
                NotchChoice(label: "Add key", isPrimary: true) { [weak notch] in
                    notch?.rest()
                    menuBar.open()
                },
            ]))
        }
    }
}
