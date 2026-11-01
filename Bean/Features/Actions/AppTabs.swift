import ApplicationServices
import Foundation

enum AppTabs {
    private static let chromium: Set<String> = ["company.thebrowser.Browser", "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac"]
    private static let safari = "com.apple.Safari"

    static func isBrowser(_ bundleId: String) -> Bool { chromium.contains(bundleId) || bundleId == safari }

    static func listScript(app: String, bundleId: String) -> String {
        let title = bundleId == safari ? "name" : "title"
        return """
        tell application "\(app)"
        set out to ""
        set w to 0
        repeat with aWindow in windows
        set w to w + 1
        set t to 0
        repeat with aTab in tabs of aWindow
        set t to t + 1
        set out to out & w & "." & t & " | " & (\(title) of aTab) & " | " & (URL of aTab) & linefeed
        end repeat
        end repeat
        return out
        end tell
        """
    }

    static func identityScript(app: String, bundleId: String, window: Int, tab: Int) -> String {
        "tell application \"\(app)\" to get (\(bundleId == safari ? "name" : "title") of tab \(tab) of window \(window)) & \" \" & (URL of tab \(tab) of window \(window))"
    }

    static func readScript(app: String, bundleId: String, window: Int, tab: Int) -> String {
        bundleId == safari
            ? "tell application \"\(app)\" to get text of tab \(tab) of window \(window)"
            : "tell application \"\(app)\" to tell tab \(tab) of window \(window) to execute javascript \"document.body.innerText\""
    }

    static func windowTitles(of attachment: Attachment) -> [String] {
        return SpaceWindows.known(of: attachment.pid).values.compactMap { Accessibility.attribute(kAXTitleAttribute, of: $0) as? String }
    }

    static func list(_ attachment: Attachment) async -> String {
        let place = "\(attachment.appName) \(attachment.bundleId)"
        var lines = windowTitles(of: attachment).map { OffLimits.match("\(place) \($0)") == nil ? "Window: \($0)" : "Window: off limits" }
        if isBrowser(attachment.bundleId) {
            let tabs = await AppActions.runScript(listScript(app: attachment.appName, bundleId: attachment.bundleId))
            guard tabs.ok else { return (lines + ["Tabs cannot be listed: \(tabs.text)"]).joined(separator: "\n") }
            lines += tabs.text.split(separator: "\n").map { line in
                let text = String(line)
                return OffLimits.match(text) == nil ? "Tab \(text)" : "Tab \(text.prefix(while: { $0 != " " })) | off limits"
            }
        }
        return lines.isEmpty ? "No window of this app can be seen." : lines.joined(separator: "\n")
    }

    static func read(_ attachment: Attachment, window: Int, tab: Int) async -> AppActions.Outcome {
        let identity = await AppActions.runScript(identityScript(app: attachment.appName, bundleId: attachment.bundleId, window: window, tab: tab))
        guard identity.ok else { return identity }
        if OffLimits.match(identity.text) != nil { return AppActions.Outcome(text: "This tab is off limits.", ok: false) }
        let page = await AppActions.runScript(readScript(app: attachment.appName, bundleId: attachment.bundleId, window: window, tab: tab))
        return AppActions.Outcome(text: page.ok ? String(OffLimits.redact(page.text).text.prefix(4000)) : page.text, ok: page.ok)
    }
}
