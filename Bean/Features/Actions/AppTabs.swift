import AppKit
import ApplicationServices

enum AppTabs {
    static let page = 4000

    // Read from what the app's scripting says about itself, so no browser is named: a browser is what holds tabs with a URL.
    struct Shape {
        let title: String
        let hasText: Bool
        let runsJavaScript: Bool
        let selectsTabs: Bool
    }

    private static let lock = NSLock()
    private static var shapes: [String: Shape?] = [:]

    static func shape(of bundleId: String) -> Shape? {
        if let known = lock.withLock({ shapes[bundleId] }) { return known }
        let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId).flatMap { ScriptDictionary.load(appAt: $0.path) }.flatMap { dictionary -> Shape? in
            guard let tab = dictionary.kinds.first(where: { $0.name.lowercased() == "tab" }) else { return nil }
            let properties = tab.properties.map { $0.replacingOccurrences(of: " (read only)", with: "").lowercased() }
            guard properties.contains("url") else { return nil }
            let window = dictionary.kinds.first { $0.name.lowercased() == "window" }?.properties.map { $0.replacingOccurrences(of: " (read only)", with: "").lowercased() } ?? []
            return Shape(title: properties.contains("title") ? "title" : "name", hasText: properties.contains("text"),
                         runsJavaScript: dictionary.commands.contains { $0.name == "execute" && $0.parameters.contains("javascript") },
                         selectsTabs: dictionary.commands.contains { $0.name == "select" } && window.contains("active tab") && properties.contains("id"))
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

    // A tab the browser put to sleep answers no script, and only selecting it wakes it: reload and setting its URL do nothing, measured on a real browser.
    // The script goes back in the same breath. With no window on screen nothing shows, and the front app, active tab and active space end as they were.
    // With a window on screen it shows for about 50 ms, measured, so it waits until the person has left.
    static func wakeScript(app: String, window: Int, tab: Int) -> String {
        """
        tell application "\(app)"
        set prior to id of active tab of window \(window) as text
        tell tab \(tab) of window \(window) to select
        tell (first tab of window \(window) whose id is prior) to select
        end tell
        """
    }

    static func hasWindowOnScreen(pid: pid_t) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { window in
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid, window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return (bounds["Height"] ?? 0) > 100
        }
    }

    // Numbers follow the order of the windows, which changes when the person moves, so a tab is found again by what it is.
    static func locate(_ identity: String, in attachment: Attachment) async -> (window: Int, tab: Int)? {
        let tabs = await AppActions.runScript(listScript(app: attachment.appName, bundleId: attachment.bundleId), timeout: 30)
        guard tabs.ok else { return nil }
        for line in tabs.text.split(separator: "\n") {
            let parts = line.components(separatedBy: " | ")
            let numbers = parts[0].split(separator: ".").compactMap { Int($0) }
            if numbers.count == 2, parts.dropFirst().joined(separator: " | ").replacingOccurrences(of: " | ", with: " ") == identity { return (numbers[0], numbers[1]) }
        }
        return nil
    }

    static func wake(_ attachment: Attachment, window: Int, tab: Int) async -> Bool {
        await AppActions.runScript(wakeScript(app: attachment.appName, window: window, tab: tab)).ok
    }

    private static func isAsleep(_ outcome: AppActions.Outcome) -> Bool {
        if !outcome.ok { return outcome.text.hasPrefix("The app did not answer") }
        let blank = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return blank.isEmpty || blank == "missing value"
    }

    // Tab numbers follow the order of the windows, which the person can change. So what comes back says which tab it is.
    static let wokeWords = "This tab was asleep, and was woken to read it."
    static let readDescription = "Read the text of a tab of your app in the background, by its numbers from app_windows: tab 2.3 is window 2, tab 3. The person's view does not change. A tab the browser put to sleep is not read until you pass wake true, and waking it runs its page as if it were opened."
    static let wakeDescription = "Wake this tab if it is asleep, which runs its page. Weigh its title and address first."
    static let asleepWords = "This tab is asleep, and nothing has been woken. Reading it first wakes it, and that runs its page as if it were opened: a call or a room can join, media can play. Weigh its title and address. If it may be a live call, a room or playing media, leave it asleep unless the person asked for this very tab, because joining reaches other people. Otherwise call tab_read again with wake true."

    static func read(_ attachment: Attachment, window: Int, tab: Int, from: Int = 0, mayWake: Bool = false) async -> AppActions.Outcome {
        let identity = await AppActions.runScript(identityScript(app: attachment.appName, bundleId: attachment.bundleId, window: window, tab: tab))
        guard identity.ok else { return identity }
        if OffLimits.match(identity.text) != nil { return AppActions.Outcome(text: "This tab is off limits.", ok: false) }
        let stillOnly = "The tab's title and address still come from app_windows."
        guard let script = readScript(app: attachment.appName, bundleId: attachment.bundleId, window: window, tab: tab) else {
            return AppActions.Outcome(text: "\(identity.text)\n\(attachment.appName) gives no way to read a tab's text in the background. \(stillOnly)", ok: false)
        }
        var read = await AppActions.runScript(script, timeout: 6)
        var woke = false
        if isAsleep(read) {
            guard shape(of: attachment.bundleId)?.selectsTabs == true else {
                return AppActions.Outcome(text: "\(identity.text)\nThis tab is asleep, and \(attachment.appName) gives no way to wake it in the background. \(stillOnly)", ok: false)
            }
            guard mayWake else { return AppActions.Outcome(text: "\(identity.text)\n\(asleepWords) \(stillOnly)", ok: false) }
            if hasWindowOnScreen(pid: attachment.pid) {
                var waits = AppActions.Outcome(text: "\(identity.text)\nThis tab is asleep, so what it holds is unknown. Waking it would show on the person's screen, so it is woken when they leave \(attachment.appName), and you get a new run then. \(stillOnly)", ok: false)
                waits.waitsForTheView = true
                return waits
            }
            guard await wake(attachment, window: window, tab: tab) else {
                return AppActions.Outcome(text: "\(identity.text)\nThis tab is asleep and could not be woken. \(stillOnly)", ok: false)
            }
            woke = true
            for _ in 0..<5 where isAsleep(read) {
                try? await Task.sleep(for: .seconds(1))
                read = await AppActions.runScript(script, timeout: 4)
            }
        }
        guard read.ok, !isAsleep(read) else {
            let why = isAsleep(read) ? "it did not wake up in time, so read it again in a moment." : read.text
            return AppActions.Outcome(text: "\(identity.text)\nThis tab's text cannot be read now: \(why) \(stillOnly)", ok: false)
        }
        let words = OffLimits.redact(read.text).text
        let shown = words.dropFirst(max(from, 0)).prefix(page)
        let more = words.count > max(from, 0) + page ? "\n(The page goes on: read again with from \(max(from, 0) + page).)" : ""
        return AppActions.Outcome(text: "\(identity.text)\n\(woke ? wokeWords + "\n" : "")\(shown)\(more)", ok: true)
    }
}
