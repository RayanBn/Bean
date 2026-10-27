import Foundation

struct WindowInfo: Codable, Equatable {
    let title: String
    let document: String?
    let isFocused: Bool
    let isMinimized: Bool
    let text: String?
}

struct AppInfo: Codable, Equatable {
    let name: String
    let bundleId: String?
    let isFrontmost: Bool
    let isHidden: Bool
    let windows: [WindowInfo]
}

struct BrowserTab: Codable, Equatable {
    let browser: String
    let title: String
    let url: String
    let isActive: Bool
}

struct ListeningPort: Codable, Equatable {
    let process: String
    let port: Int
}

struct MacContext: Codable {
    let at: Date
    let idleSeconds: Double
    let apps: [AppInfo]
    let tabs: [BrowserTab]
    let activities: [Activity]
    let commands: [ShellCommand]
    let recentFiles: [String]
    let ports: [ListeningPort]
    let presence: PresenceState?

    var frontmost: AppInfo? { apps.first(where: \.isFrontmost) }
    var focusedWindow: WindowInfo? { frontmost?.windows.first(where: \.isFocused) ?? frontmost?.windows.first }

    func summary(textBudget: Int = 9000) -> String {
        var lines: [String] = []
        var budget = textBudget
        func text(_ value: String?, limit: Int) -> String? {
            guard let value, !value.isEmpty, budget > 0 else { return nil }
            let cut = String(value.prefix(min(limit, budget)))
            budget -= cut.count
            return cut
        }

        if let app = frontmost {
            lines.append("Frontmost: \(app.name)" + (focusedWindow.map { " — \"\($0.title)\"" } ?? ""))
        }
        lines.append("Seconds since the last keyboard or mouse input: \(Int(idleSeconds))")
        if presence?.inMeeting == true { lines.append("The user is in a call (microphone or camera in use).") }

        let ordered = apps.sorted { $0.isFrontmost && !$1.isFrontmost }
        lines.append("\nOpen apps and windows:")
        for app in ordered {
            lines.append("- \(app.name)\(app.isHidden ? " (hidden)" : "")")
            for window in app.windows.prefix(8) {
                var line = "    • \"\(window.title)\""
                if let document = window.document { line += " [\(document)]" }
                if window.isMinimized { line += " (minimized)" }
                lines.append(line)
                if let excerpt = text(window.text, limit: app.isFrontmost && window.isFocused ? 4000 : 400) {
                    lines.append("      text: \(excerpt.replacingOccurrences(of: "\n", with: " ⏎ "))")
                }
            }
        }

        if !tabs.isEmpty {
            lines.append("\nBrowser tabs (\(tabs.count)):")
            for tab in tabs.prefix(60) {
                lines.append("- \(tab.isActive ? "[active] " : "")\(tab.title) — \(tab.url)")
            }
        }

        if !activities.isEmpty {
            lines.append("\nWhat the user's apps are working on (read by recipes Bean learned), most recent first:")
            lines += activities.prefix(15).map { "- " + $0.line }
        }

        if !commands.isEmpty {
            lines.append("\nRecent terminal commands:")
            lines += commands.suffix(12).map { "- [\($0.exit == 0 ? "ok" : "exit \($0.exit)")] \($0.cmd)  (in \($0.cwd), \(Activity.ago(Date(timeIntervalSince1970: $0.end))))" }
        }
        if !recentFiles.isEmpty {
            lines.append("\nFiles changed in the last 30 minutes:")
            lines += recentFiles.prefix(20).map { "- \($0)" }
        }
        if !ports.isEmpty {
            lines.append("\nLocal servers listening: " + ports.map { "\($0.process):\($0.port)" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}
