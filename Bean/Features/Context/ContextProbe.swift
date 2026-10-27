import Foundation

enum ContextProbe {
    static func runIfRequested(shellLog: URL) -> Bool {
        guard CommandLine.arguments.contains("--probe-context") else { return false }
        Task {
            let started = Date()
            let store = ContextStore(log: JSONLog(name: "context"), shellLog: shellLog)
            store.start()
            let context = await store.picture()
            print(context.summary())
            print(String(format: "\n--- built in %.1f s: %d apps, %d windows, %d tabs, %d activities, %d commands, %d ports",
                         Date().timeIntervalSince(started), context.apps.count, context.apps.reduce(0) { $0 + $1.windows.count },
                         context.tabs.count, context.activities.count, context.commands.count, context.ports.count))
            exit(0)
        }
        return true
    }
}
