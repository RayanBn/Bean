import ApplicationServices
import Foundation

enum AppTabs {
    private static let chromium: Set<String> = ["company.thebrowser.Browser", "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac"]
    private static let safari = "com.apple.Safari"
    static let page = 4000

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
        let open = WindowChannels.open().filter { $0.bundleId == attachment.bundleId }.compactMap(\.title)
        if ProcessInfo.processInfo.environment["BEAN_WINDOW_FILTER"]?.isEmpty == false { return open }
        let known = SpaceWindows.known(of: attachment.pid).values.compactMap { Accessibility.attribute(kAXTitleAttribute, of: $0) as? String }
        return Array(Set(open + known.filter { !$0.isEmpty })).sorted()
    }

    static func list(_ attachment: Attachment) async -> String {
        let place = "\(attachment.appName) \(attachment.bundleId)"
        var lines = windowTitles(of: attachment).map { OffLimits.match("\(place) \($0)") == nil ? "Window: \($0)" : "Window: off limits" }
        if isBrowser(attachment.bundleId) {
            let tabs = await AppActions.runScript(listScript(app: attachment.appName, bundleId: attachment.bundleId), timeout: 30)
            guard tabs.ok else { return (lines + ["Tabs cannot be listed: \(tabs.text)"]).joined(separator: "\n") }
            lines += tabs.text.split(separator: "\n").map { line in
                let text = String(line)
                return OffLimits.match(text) == nil ? "Tab \(text.prefix(220))" : "Tab \(text.prefix(while: { $0 != " " })) | off limits"
            }
        }
        return lines.isEmpty ? "No window of this app can be seen." : lines.joined(separator: "\n")
    }

    // Tab numbers follow the order of the windows, which the person can change. So what comes back says which tab it is.
    static func read(_ attachment: Attachment, window: Int, tab: Int, from: Int = 0) async -> AppActions.Outcome {
        let identity = await AppActions.runScript(identityScript(app: attachment.appName, bundleId: attachment.bundleId, window: window, tab: tab))
        guard identity.ok else { return identity }
        if OffLimits.match(identity.text) != nil { return AppActions.Outcome(text: "This tab is off limits.", ok: false) }
        // A tab the browser put to sleep never answers, and only showing it would wake it.
        let read = await AppActions.runScript(readScript(app: attachment.appName, bundleId: attachment.bundleId, window: window, tab: tab), timeout: 6)
        let stillOnly = "The tab's title and address still come from app_windows."
        guard read.ok else {
            let why = read.text.hasPrefix("The app did not answer") ? "the browser has probably put it to sleep, and waking it would change what the person sees." : read.text
            return AppActions.Outcome(text: "\(identity.text)\nThis tab's text cannot be read now: \(why) \(stillOnly)", ok: false)
        }
        let words = OffLimits.redact(read.text).text
        let blank = words.trimmingCharacters(in: .whitespacesAndNewlines)
        if blank.isEmpty || blank == "missing value" { return AppActions.Outcome(text: "\(identity.text)\nThis tab gave no text: it may be asleep or not loaded. \(stillOnly)", ok: false) }
        let shown = words.dropFirst(max(from, 0)).prefix(page)
        let more = words.count > max(from, 0) + page ? "\n(The page goes on: read again with from \(max(from, 0) + page).)" : ""
        return AppActions.Outcome(text: "\(identity.text)\n\(shown)\(more)", ok: true)
    }
}
