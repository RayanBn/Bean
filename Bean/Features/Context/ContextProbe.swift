import Foundation

enum ContextProbe {
    static func runIfRequested(shellLog: URL) -> Bool {
        guard CommandLine.arguments.contains("--probe-context") else { return false }
        let started = Date()
        let context = ContextWatcher(log: JSONLog(name: "context"), shellLog: shellLog).build(presence: Presence.current())
        print(context.summary())
        print(String(format: "\n--- built in %.1f s: %d apps, %d windows, %d tabs, %d agent sessions, %d commands, %d files, %d ports",
                     Date().timeIntervalSince(started), context.apps.count, context.apps.reduce(0) { $0 + $1.windows.count },
                     context.tabs.count, context.agents.count, context.commands.count, context.recentFiles.count, context.ports.count))
        return true
    }
}
