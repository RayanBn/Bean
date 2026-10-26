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
    private var shell: ShellWatcher?
    private var settingsWindow: SettingsWindow?
    private var gateServer: GateServer?
    private var terminationSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if BrowserProbe.runIfRequested() || PresenceProbe.runIfRequested() { exit(0) }
        signal(SIGTERM, SIG_IGN)
        terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSource?.setEventHandler { NSApp.terminate(nil) }
        terminationSource?.resume()

        let gateLog = JSONLog(name: "gate")
        let gateServer = GateServer(logTo: gateLog.url.deletingLastPathComponent().appendingPathComponent("gate-server.log"))
        let spark = MuseSpark()
        let gate = Gate(cloud: CloudGate(spark: spark), local: LocalGate(server: gateServer), log: gateLog)
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
        let brain = Brain(spark: spark, notch: notch, actions: ActionRunner(log: JSONLog(name: "actions")), log: JSONLog(name: "brain"))
        gate.onDecision = brain.consider
        self.notch = notch
        self.brain = brain
        let triggers = TriggerDetector(log: JSONLog(name: "triggers"))
        let signals = SignalCollector(log: JSONLog(name: "signals"))
        signals.onSnapshot = triggers.observe
        triggers.onTrigger = gate.judge
        signals.start()
        let shell = ShellWatcher(log: JSONLog(name: "shell").url)
        shell.onCommand = triggers.observe
        self.shell = shell
        shell.start()
        self.triggers = triggers
        self.signals = signals

        let settingsWindow = SettingsWindow {
            SettingsView(settings: .shared, localGateAvailable: gateServer.isAvailable, shellLog: shell.log)
        }
        self.settingsWindow = settingsWindow
        notch.restMessage = NotchMessage(text: "Bean is here. I'll speak up only when I can help.", choices: [
            NotchChoice(label: "Settings", isPrimary: false) { [weak notch] in
                notch?.rest()
                settingsWindow.show()
            },
        ])
        if spark.hasKey {
            ShellConsent.askIfNeeded(notch: notch, logTo: shell.log) {}
        } else {
            notch.show(NotchMessage(text: "I need a Meta API key to think. Paste yours in Settings: it stays in your Keychain.", choices: [
                NotchChoice(label: "Later", isPrimary: false) { [weak notch] in notch?.rest() },
                NotchChoice(label: "Open Settings", isPrimary: true) { [weak notch] in
                    notch?.rest()
                    settingsWindow.show()
                },
            ]))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        gateServer?.stop()
    }
}
