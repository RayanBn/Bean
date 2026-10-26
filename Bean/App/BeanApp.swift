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

    func applicationDidFinishLaunching(_ notification: Notification) {
        notch = NotchController()
        signals = SignalCollector(log: SignalLog())
        signals?.start()
    }
}
