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
        notch.onRestClick = { [weak agents] in agents?.create() }
        self.agents = agents
        let creatures = CreatureController(store: agents.store, notch: notch)
        creatures.onAgentClick = { [weak agents] id in agents?.onAgentClick(id) }
        self.creatures = creatures
        if !client.isReady {
            notch.show(NotchMessage(text: "I need an AI key to think. Add yours from the Bean icon in the menu bar.", choices: [
                NotchChoice(label: "Later", isPrimary: false) { [weak notch] in notch?.rest() },
                NotchChoice(label: "Add key", isPrimary: true) { [weak notch] in
                    notch?.rest()
                    menuBar.open()
                },
            ]))
        }
    }
}
