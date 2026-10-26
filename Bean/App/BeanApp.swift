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

    func applicationDidFinishLaunching(_ notification: Notification) {
        notch = NotchController()
        let triggers = TriggerDetector(log: JSONLog(name: "triggers"))
        let signals = SignalCollector(log: JSONLog(name: "signals"))
        signals.onSnapshot = triggers.observe
        signals.start()
        self.triggers = triggers
        self.signals = signals
    }
}
