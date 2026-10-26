import AppKit

enum TabReader {
    private static let browsers: [(bundleId: String, name: String, script: String)] = [
        ("company.thebrowser.Browser", "Arc", chromium("Arc")),
        ("com.google.Chrome", "Chrome", chromium("Google Chrome")),
        ("com.brave.Browser", "Brave", chromium("Brave Browser")),
        ("com.apple.Safari", "Safari", """
        set sep to character id 9
        set out to ""
        tell application "Safari"
            repeat with w in windows
                set activeName to ""
                try
                    set activeName to name of current tab of w
                end try
                repeat with t in tabs of w
                    set out to out & (name of t = activeName) & sep & name of t & sep & URL of t & linefeed
                end repeat
            end repeat
        end tell
        return out
        """),
    ]
    private static let privateHosts = ["mail.google.com", "outlook.live.com", "outlook.office.com", "mail.proton.me", "mail.yahoo.com", "fastmail.com", "icloud.com", "accounts.google.com"]

    static func all() -> [BrowserTab] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return browsers.filter { running.contains($0.bundleId) }.flatMap { browser in
            (HiddenShell.capture("/usr/bin/osascript", ["-e", browser.script], timeout: 6) ?? "")
                .split(separator: "\n")
                .compactMap { line -> BrowserTab? in
                    let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                    guard parts.count == 3, let host = URL(string: parts[2])?.host?.lowercased(),
                          !privateHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
                    return BrowserTab(browser: browser.name, title: parts[1], url: parts[2], isActive: parts[0] == "true")
                }
        }
    }

    private static func chromium(_ app: String) -> String {
        """
        set sep to character id 9
        set out to ""
        tell application "\(app)"
            repeat with w in windows
                set activeURL to ""
                try
                    set activeURL to URL of active tab of w
                end try
                repeat with t in tabs of w
                    set u to URL of t
                    set out to out & (u = activeURL) & sep & title of t & sep & u & linefeed
                end repeat
            end repeat
        end tell
        return out
        """
    }
}
