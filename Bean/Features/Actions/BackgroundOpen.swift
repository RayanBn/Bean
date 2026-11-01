import AppKit

// Asking for the background is only a request: an app can still activate itself as it starts, and that moves the person to its Space.
// So the app starts hidden, and for its first seconds the front and the Space go back to whoever had them, and only then is it hidden again.
// In that order: hiding the front app first lets macOS pick the next app, which can be the Finder on another Space.
struct BackgroundOpen {
    let app: NSRunningApplication
    private let watch: Watch

    @MainActor var sentBack: Int { watch.sentBack }

    private static let guarded: Duration = .seconds(15)

    @MainActor
    private final class Watch {
        var sentBack = 0
    }

    @MainActor
    static func start(_ url: URL, bundleId: String, document: URL?) async throws -> BackgroundOpen {
        let previous = NSWorkspace.shared.frontmostApplication
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        // With no document to open, a document app can greet with an Open panel. Only Cocoa reads this, and another app could take it for a file to open.
        if document == nil, isCocoaDocumentApp(url) { configuration.arguments = ["-NSShowAppCentricOpenPanelInsteadOfUntitledFile", "NO"] }
        let watch = Watch()
        let center = NSWorkspace.shared.notificationCenter
        func sendBack() {
            watch.sentBack += 1
            if previous?.isTerminated == false { previous?.activate() }
        }
        let activated = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, running.bundleIdentifier == bundleId else { return }
            MainActor.assumeIsolated { sendBack() }
        }
        let opened: NSRunningApplication
        do {
            if let document {
                opened = try await NSWorkspace.shared.open([document], withApplicationAt: url, configuration: configuration)
            } else {
                opened = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            }
        } catch {
            center.removeObserver(activated)
            throw error
        }
        Task { @MainActor in
            let clock = ContinuousClock(), end = clock.now + guarded
            while clock.now < end, !opened.isTerminated {
                if NSWorkspace.shared.frontmostApplication == opened { sendBack() } else if !opened.isHidden { opened.hide() }
                try? await Task.sleep(for: .milliseconds(50))
            }
            center.removeObserver(activated)
        }
        return BackgroundOpen(app: opened, watch: watch)
    }

    private static func isCocoaDocumentApp(_ url: URL) -> Bool {
        (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])?.contains { $0["NSDocumentClass"] != nil } == true
    }
}
