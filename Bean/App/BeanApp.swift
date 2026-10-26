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
    private let gateServer = GateServer()
    private var terminationSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSource?.setEventHandler { NSApp.terminate(nil) }
        terminationSource?.resume()

        let gateLog = JSONLog(name: "gate")
        gateServer.start(logTo: gateLog.url.deletingLastPathComponent().appendingPathComponent("gate-server.log"))
        let gate = Gate(server: gateServer, log: gateLog)
        self.gate = gate

        if let index = CommandLine.arguments.firstIndex(of: "--gate-eval"), index + 1 < CommandLine.arguments.count {
            let cases = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task {
                let ready = await gateServer.waitUntilReady()
                let passed = ready ? await GateEval.run(cases: cases, gate: gate) : false
                if !ready { print("gate server not ready") }
                gateServer.stop()
                exit(passed ? 0 : 1)
            }
            return
        }

        let notch = NotchController()
        let brain = Brain(spark: MuseSpark(), notch: notch, actions: ActionRunner(log: JSONLog(name: "actions")), log: JSONLog(name: "brain"))
        gate.onDecision = brain.consider
        self.notch = notch
        self.brain = brain
        let triggers = TriggerDetector(log: JSONLog(name: "triggers"))
        let signals = SignalCollector(log: JSONLog(name: "signals"))
        signals.onSnapshot = triggers.observe
        triggers.onTrigger = gate.judge
        signals.start()
        self.triggers = triggers
        self.signals = signals
    }

    func applicationWillTerminate(_ notification: Notification) {
        gateServer.stop()
    }
}
