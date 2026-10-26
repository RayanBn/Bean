import AppKit
import ApplicationServices

final class SignalCollector {
    static let pollInterval: TimeInterval = 2
    static let idleThreshold: TimeInterval = 60
    static let focusedTextLimit = 8000

    var onSnapshot: ((Snapshot) -> Void)?

    private let log: JSONLog
    private var timer: Timer?
    private var lastWindowTitle: String?
    private var isIdle = false

    init(log: JSONLog) {
        self.log = log
    }

    func start() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.appActivated(app)
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        if let app = NSWorkspace.shared.frontmostApplication { appActivated(app) }
    }

    private func appActivated(_ app: NSRunningApplication) {
        lastWindowTitle = Accessibility.focusedWindowTitle(of: app.processIdentifier)
        record(.appActivated, app: app)
        publish(app: app, idle: Self.idleSeconds())
    }

    private func poll() {
        let idle = Self.idleSeconds()
        if idle >= Self.idleThreshold, !isIdle {
            isIdle = true
            record(.idleStarted, app: NSWorkspace.shared.frontmostApplication, idle: idle)
        } else if idle < Self.idleThreshold, isIdle {
            isIdle = false
            record(.idleEnded, app: NSWorkspace.shared.frontmostApplication, idle: idle)
        }

        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let title = Accessibility.focusedWindowTitle(of: app.processIdentifier)
        if title != lastWindowTitle {
            lastWindowTitle = title
            record(.windowChanged, app: app, idle: idle)
        }
        publish(app: app, idle: idle)
    }

    private func publish(app: NSRunningApplication, idle: Double) {
        var snapshot = Snapshot(at: Date(), app: app.localizedName, bundleId: app.bundleIdentifier, windowTitle: lastWindowTitle, idleSeconds: idle, focusedText: Accessibility.focusedText(of: app.processIdentifier, limit: Self.focusedTextLimit))
        if BeanSettings.shared.readBrowser, let bundleId = app.bundleIdentifier {
            snapshot.browser = BrowserReader.current(bundleId: bundleId, pid: app.processIdentifier)
        }
        snapshot.presence = Presence.current()
        onSnapshot?(snapshot)
    }

    private func record(_ kind: Signal.Kind, app: NSRunningApplication?, idle: Double = SignalCollector.idleSeconds()) {
        log.append(Signal(at: Date(), kind: kind, app: app?.localizedName, bundleId: app?.bundleIdentifier, windowTitle: lastWindowTitle, idleSeconds: idle.rounded()))
    }

    static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}
