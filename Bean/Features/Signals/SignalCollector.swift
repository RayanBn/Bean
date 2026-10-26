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
        lastWindowTitle = focusedWindowTitle(of: app)
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
        let title = focusedWindowTitle(of: app)
        if title != lastWindowTitle {
            lastWindowTitle = title
            record(.windowChanged, app: app, idle: idle)
        }
        publish(app: app, idle: idle)
    }

    private func publish(app: NSRunningApplication, idle: Double) {
        onSnapshot?(Snapshot(at: Date(), app: app.localizedName, bundleId: app.bundleIdentifier, windowTitle: lastWindowTitle, idleSeconds: idle, focusedText: focusedText(of: app)))
    }

    private func record(_ kind: Signal.Kind, app: NSRunningApplication?, idle: Double = SignalCollector.idleSeconds()) {
        log.append(Signal(at: Date(), kind: kind, app: app?.localizedName, bundleId: app?.bundleIdentifier, windowTitle: lastWindowTitle, idleSeconds: idle.rounded()))
    }

    private func focusedWindowTitle(of app: NSRunningApplication) -> String? {
        guard let window = attribute(kAXFocusedWindowAttribute, of: AXUIElementCreateApplication(app.processIdentifier)) else { return nil }
        return attribute(kAXTitleAttribute, of: window as! AXUIElement) as? String
    }

    private func focusedText(of app: NSRunningApplication) -> String? {
        guard let element = attribute(kAXFocusedUIElementAttribute, of: AXUIElementCreateApplication(app.processIdentifier)),
              let text = attribute(kAXValueAttribute, of: element as! AXUIElement) as? String else { return nil }
        return String(text.suffix(Self.focusedTextLimit))
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        guard AXIsProcessTrusted() else { return nil }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}
