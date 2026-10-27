import AppKit

enum InventoryProbe {
    static func runIfRequested(shellLog: URL) -> Bool {
        if let index = CommandLine.arguments.firstIndex(of: "--probe-text"), index + 1 < CommandLine.arguments.count {
            let bundleId = CommandLine.arguments[index + 1]
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
                print("not running: \(bundleId)")
                exit(1)
            }
            let text = FocusedText.read(app)
            print(text.map { "\($0.app ?? "?") — \($0.window ?? "") · \($0.text.count) chars, \($0.nodes) nodes, \($0.milliseconds) ms\n\(String($0.text.prefix(1500)))" } ?? "no text")
            FocusedText.resetManualAccessibility()
            exit(0)
        }
        guard CommandLine.arguments.contains("--probe-inventory") else { return false }
        let started = Date()
        let store = ContextStore(log: JSONLog(name: "context"), shellLog: shellLog)
        store.start()
        let watcher = InventoryWatcher(log: JSONLog(name: "inventory"), context: store)
        watcher.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + (ProcessInfo.processInfo.environment["BEAN_PROBE_SECONDS"].flatMap(Double.init) ?? 4)) {
            watcher.write { inventory in
                print(text(inventory))
                print(String(format: "--- built in %.1f s", Date().timeIntervalSince(started)))
                watcher.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
            }
        }
        withExtendedLifetime(watcher) {}
        objc_setAssociatedObject(NSApp as Any, "inventoryProbe", watcher, .OBJC_ASSOCIATION_RETAIN)
        return true
    }

    static func text(_ inventory: Inventory) -> String {
        let system = inventory.system
        var lines = [
            "SYSTEM  \(system.host) · \(system.user) · \(system.os) · up \(system.uptimeHours) h · \(system.darkMode ? "dark" : "light") mode",
            "        battery \(system.battery ?? "?") · network \(system.network ?? "?") · audio \(system.audioOutput ?? "?") \(system.volume.map { "\($0) %" } ?? "")",
            "        mic \(system.micInUse ? "on" : "off") · camera \(system.cameraInUse ? "on" : "off") · idle \(Int(system.idleSeconds)) s · locked \(system.locked) · volumes \(system.mountedVolumes.joined(separator: ", "))",
            "        active Space \(system.activeSpace) · displays " + system.displays.map { "\($0.name) \($0.width)×\($0.height)\($0.isMain ? " (main)" : "")" }.joined(separator: ", "),
        ]
        for kind in [InventoryApp.Kind.dock, .menuBar, .background] {
            let apps = inventory.apps.filter { $0.kind == kind }
            lines.append("\nAPPS \(kind.rawValue) (\(apps.count))")
            for app in apps {
                lines.append("  \(app.isActive ? "▶" : " ") \(app.name)\(app.isHidden ? " (hidden)" : "") · pid \(app.pid) · \(app.windows.count) windows")
                for window in app.windows {
                    lines.append("      \(window.isFocused ? "*" : "-") \"\(window.title)\" \(window.width)×\(window.height) · Space \(window.space.map(String.init) ?? "?")\(window.onScreen ? "" : " · not on screen")\(window.isMinimized ? " · minimized" : "")\(window.seenByAccessibility ? "" : " · no AX")")
                }
            }
        }
        lines.append("  + \(inventory.backgroundApps) Apple background services")
        lines.append("\nPROCESSES (\(inventory.processes.reduce(0) { $0 + $1.count }) outside apps, by memory)")
        lines += inventory.processes.prefix(25).map { "  \($0.name) ×\($0.count) · \($0.memoryMB) MB · \($0.cpu) % CPU" }
        lines.append("\nNON-APP PROCESSES TRACKED (\(inventory.trackedProcesses.count))")
        lines += inventory.trackedProcesses.prefix(40).map { "  \($0.name) · pid \($0.pid) · \($0.arguments.isEmpty ? $0.path : $0.arguments)" }
        if let text = inventory.focusedText {
            lines.append("\nFOCUSED WINDOW TEXT: \(text.app ?? "?") — \(text.window ?? "") · \(text.text.count) chars, \(text.nodes) nodes, \(text.milliseconds) ms")
            lines.append("  " + String(text.text.prefix(600)).replacingOccurrences(of: "\n", with: " ⏎ "))
        }
        lines.append("\nTABS (\(inventory.tabs.count))")
        lines += inventory.tabs.map { "  \($0.isActive ? "▶" : "-") [\($0.browser)] \($0.title)" }
        lines.append("\nACTIVITIES (\(inventory.activities.count))")
        lines += inventory.activities.map { "  - \($0.app): \($0.title) · \($0.state)\($0.unseen ? " · unseen" : "")" }
        lines.append("\nPORTS " + inventory.ports.map { "\($0.process):\($0.port)" }.joined(separator: ", "))
        lines.append("RECENT FILES (\(inventory.recentFiles.count)) · COMMANDS (\(inventory.commands.count))")
        return lines.joined(separator: "\n")
    }
}
