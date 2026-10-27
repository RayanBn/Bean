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
    private var signals: SignalCollector?
    private var triggers: TriggerDetector?
    private var gate: Gate?
    private var brain: Brain?
    private var context: ContextStore?
    private var idle: IdleClock?
    private var inventory: InventoryWatcher?
    private var shell: ShellWatcher?
    private var menuBar: MenuBarController?
    private var inspector: InspectorWindow?
    private var gateServer: GateServer?
    private var terminationSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if BrowserProbe.runIfRequested() || PresenceProbe.runIfRequested() { exit(0) }
        if StepsProbe.runIfRequested() { return }
        if ContextProbe.runIfRequested(shellLog: JSONLog(name: "shell").url) || InventoryProbe.runIfRequested(shellLog: JSONLog(name: "shell").url) { return }
        signal(SIGTERM, SIG_IGN)
        terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSource?.setEventHandler { NSApp.terminate(nil) }
        terminationSource?.resume()

        let gateLog = JSONLog(name: "gate")
        let gateServer = GateServer(logTo: gateLog.url.deletingLastPathComponent().appendingPathComponent("gate-server.log"))
        let client = ModelClient()
        let gate = Gate(cloud: CloudGate(client: client), local: LocalGate(server: gateServer), log: gateLog)
        self.gateServer = gateServer
        self.gate = gate

        if let index = CommandLine.arguments.firstIndex(of: "--gate-eval"), index + 1 < CommandLine.arguments.count {
            let cases = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task {
                let passed = await GateEval.run(cases: cases, gate: gate)
                gateServer.stop()
                exit(passed ? 0 : 1)
            }
            return
        }

        let notch = NotchController()
        Tools.shared.add(CoreTools())
        Tools.shared.add(ActionTools())
        Channels.shared.locate = Vision(client: client).locate
        let shellLog = JSONLog(name: "shell").url
        let context = ContextStore(log: JSONLog(name: "context"), shellLog: shellLog)
        self.context = context
        let brain = Brain(client: client, notch: notch, actions: ActionRunner(log: JSONLog(name: "actions")), log: JSONLog(name: "brain")) { [weak context] in await context?.picture() }
        gate.onDecision = brain.consider
        self.notch = notch
        self.brain = brain
        let idle = IdleClock()
        self.idle = idle
        let triggers = TriggerDetector(idle: idle)
        let triggerLog = JSONLog(name: "triggers")
        Events.connect { trigger in
            var trigger = trigger
            if trigger.inMeeting == nil { trigger.inMeeting = Presence.current().inMeeting }
            triggerLog.append(trigger)
            gate.judge(trigger)
        }
        let signals = SignalCollector(log: JSONLog(name: "signals"), idle: idle)
        signals.onSnapshot = triggers.observe
        signals.start()
        context.onAgents = triggers.observe
        triggers.start()
        context.start()
        let inventory = InventoryWatcher(log: JSONLog(name: "inventory"), context: context)
        self.inventory = inventory
        inventory.start()
        let shell = ShellWatcher(log: shellLog)
        shell.onCommand = { command in
            triggers.observe(command)
            context.observe(command)
        }
        self.shell = shell
        shell.start()
        self.triggers = triggers
        self.signals = signals

        let inspector = InspectorWindow(model: InspectorModel(dataDir: shell.log.deletingLastPathComponent()) { inventory.build($0) })
        self.inspector = inspector
        let menuBar = MenuBarController(notch: notch.model, localGateAvailable: gateServer.isAvailable, shellLog: shell.log) { inspector.show() }
        self.menuBar = menuBar
        if client.isReady {
            ShellConsent.askIfNeeded(notch: notch, logTo: shell.log) {}
        } else {
            notch.show(NotchMessage(text: "I need an AI key to think. Add yours from the Bean icon in the menu bar.", choices: [
                NotchChoice(label: "Later", isPrimary: false) { [weak notch] in notch?.rest() },
                NotchChoice(label: "Add key", isPrimary: true) { [weak notch] in
                    notch?.rest()
                    menuBar.open()
                },
            ]))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        inventory?.stop()
        gateServer?.stop()
    }
}
