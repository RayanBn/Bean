import SwiftUI

@main
struct BeanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let greeted = JSONLog.directory.appendingPathComponent("greeted")
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
        creatures.onAgentClick = { [weak agents] id, anchor in agents?.onAgentClick(id, from: anchor) }
        agents.onUnplug = { [weak creatures] id in creatures?.sendHome(id) }
        self.creatures = creatures
        if agents.store.agents.isEmpty, client.isReady, !FileManager.default.fileExists(atPath: Self.greeted.path) {
            FileManager.default.createFile(atPath: Self.greeted.path, contents: nil)
            notch.say("Hi! Tap + to make your first agent.", for: 8)
        }
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
