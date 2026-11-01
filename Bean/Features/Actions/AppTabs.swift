import AppKit
import ApplicationServices

enum AppTabs {
    static let page = 4000

    // Read from what the app's scripting says about itself, so no browser is named: a browser is what holds tabs with a URL.
    struct Shape {
        let title: String
        let hasText: Bool
        let runsJavaScript: Bool
    }

    private static let lock = NSLock()
    private static var shapes: [String: Shape?] = [:]

    static func shape(of bundleId: String) -> Shape? {
        if let known = lock.withLock({ shapes[bundleId] }) { return known }
        let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId).flatMap { ScriptDictionary.load(appAt: $0.path) }.flatMap { dictionary -> Shape? in
            guard let tab = dictionary.kinds.first(where: { $0.name.lowercased() == "tab" }) else { return nil }
            let properties = tab.properties.map { $0.replacingOccurrences(of: " (read only)", with: "").lowercased() }
            guard properties.contains("url") else { return nil }
            return Shape(title: properties.contains("title") ? "title" : "name", hasText: properties.contains("text"),
                         runsJavaScript: dictionary.commands.contains { $0.name == "execute" && $0.parameters.contains("javascript") })
        }
        lock.withLock { shapes[bundleId] = .some(found) }
        return found
    }

    static func isBrowser(_ bundleId: String) -> Bool { shape(of: bundleId) != nil }

    static func listScript(app: String, bundleId: String) -> String {
        """
        tell application "\(app)"
        set out to ""
        set w to 0
        repeat with aWindow in windows
        set w to w + 1
        set t to 0
        repeat with aTab in tabs of aWindow
        set t to t + 1
        set out to out & w & "." & t & " | " & (\(shape(of: bundleId)?.title ?? "name") of aTab) & " | " & (URL of aTab) & linefeed
        end repeat
        end repeat
        return out
        end tell
        """
    }

    static func identityScript(app: String, bundleId: String, window: Int, tab: Int) -> String {
        "tell application \"\(app)\" to get (\(shape(of: bundleId)?.title ?? "name") of tab \(tab) of window \(window)) & \" \" & (URL of tab \(tab) of window \(window))"
    }

    static func readScript(app: String, bundleId: String, window: Int, tab: Int) -> String? {
        guard let shape = shape(of: bundleId) else { return nil }
        if shape.hasText { return "tell application \"\(app)\" to get text of tab \(tab) of window \(window)" }
        return shape.runsJavaScript ? "tell application \"\(app)\" to tell tab \(tab) of window \(window) to execute javascript \"document.body.innerText\"" : nil
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
        let stillOnly = "The tab's title and address still come from app_windows."
        guard let script = readScript(app: attachment.appName, bundleId: attachment.bundleId, window: window, tab: tab) else {
            return AppActions.Outcome(text: "\(identity.text)\n\(attachment.appName) gives no way to read a tab's text in the background. \(stillOnly)", ok: false)
        }
        let read = await AppActions.runScript(script, timeout: 6)
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
