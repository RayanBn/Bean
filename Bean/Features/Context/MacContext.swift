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

struct AgentSession: Codable, Equatable {
    enum State: String, Codable { case working, asking, finished, idle }

    let id: String
    let transcriptId: String?
    var transcript: String? = nil
    let title: String
    let cwd: String
    let state: State
    let lastActivity: Date
    let lastFocused: Date?
    let question: String?
    let lastWords: String?

    var unseen: Bool { lastFocused.map { $0 < lastActivity } ?? true }
    var needsUser: Bool { state == .asking || state == .finished }
    var folder: String { URL(fileURLWithPath: cwd).lastPathComponent }

    var line: String {
        var line = "\"\(title)\" (\(folder)): \(state.rawValue), last activity \(Self.ago(lastActivity))"
        if needsUser { line += unseen ? ", not seen by the user yet" : ", seen" }
        if let question { line += "\n    Question for the user: \(question)" }
        if let lastWords { line += "\n    Last words: \(lastWords)" }
        if let transcript { line += "\n    Transcript: \(transcript)" }
        return line
    }

    static func ago(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        switch seconds {
        case ..<90: return "\(Int(seconds)) s ago"
        case ..<5400: return "\(Int(seconds / 60)) min ago"
        case ..<172_800: return "\(Int(seconds / 3600)) h ago"
        default: return "\(Int(seconds / 86400)) days ago"
        }
    }
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
    let agents: [AgentSession]
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

        let liveAgents = agents.filter { Date().timeIntervalSince($0.lastActivity) < 86400 }
        if !liveAgents.isEmpty {
            lines.append("\nAI coding agent sessions (Claude Code), most recent first:")
            lines += liveAgents.prefix(12).map { "- " + $0.line }
        }

        if !commands.isEmpty {
            lines.append("\nRecent terminal commands:")
            lines += commands.suffix(12).map { "- [\($0.exit == 0 ? "ok" : "exit \($0.exit)")] \($0.cmd)  (in \($0.cwd), \(AgentSession.ago(Date(timeIntervalSince1970: $0.end))))" }
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
