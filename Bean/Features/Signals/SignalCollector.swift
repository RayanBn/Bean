import AppKit
import ApplicationServices

final class SignalCollector {
    static let pollInterval: TimeInterval = 2
    static let idleThreshold: TimeInterval = 60

    private let log: SignalLog
    private var timer: Timer?
    private var lastWindowTitle: String?
    private var isIdle = false

    init(log: SignalLog) {
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
        lastWindowTitle = focusedWindowTitle(of: app)
        record(.appActivated, app: app)
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
        let title = focusedWindowTitle(of: app)
        if title != lastWindowTitle {
            lastWindowTitle = title
            record(.windowChanged, app: app, idle: idle)
        }
    }

    private func record(_ kind: Signal.Kind, app: NSRunningApplication?, idle: Double = SignalCollector.idleSeconds()) {
        log.append(Signal(at: Date(), kind: kind, app: app?.localizedName, bundleId: app?.bundleIdentifier, windowTitle: lastWindowTitle, idleSeconds: idle.rounded()))
    }

    private func focusedWindowTitle(of app: NSRunningApplication) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success, let window else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }

    static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}
