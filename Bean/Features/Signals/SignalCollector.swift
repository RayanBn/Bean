import AppKit
import ApplicationServices

final class SignalCollector {
    static let idleThreshold: TimeInterval = 60
    static let focusedTextLimit = 8000
    static let valueDebounce: TimeInterval = 0.3

    var onSnapshot: ((Snapshot) -> Void)?

    private let log: JSONLog
    private let idle: IdleClock
    private let observer = AppObserver()
    private var lastWindowTitle: String?
    private var isIdle = false
    private var pendingValue: DispatchWorkItem?

    init(log: JSONLog, idle: IdleClock) {
        self.log = log
        self.idle = idle
    }

    func start() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.appActivated(app)
        }
        observer.onEvent = { [weak self] event in self?.frontmostChanged(event) }
        idle.every(idleFor: { Self.idleThreshold }) { [weak self] seconds in
            guard let self, !isIdle else { return }
            isIdle = true
            record(.idleStarted, app: NSWorkspace.shared.frontmostApplication, idle: seconds)
        }
        idle.onReturn { [weak self] _ in
            guard let self, isIdle else { return }
            isIdle = false
            record(.idleEnded, app: NSWorkspace.shared.frontmostApplication, idle: IdleClock.seconds())
            if let app = NSWorkspace.shared.frontmostApplication { publish(app: app) }
        }

        var launched = Signal(at: Date(), kind: .launched, app: nil, bundleId: nil, windowTitle: nil, idleSeconds: IdleClock.seconds().rounded())
        launched.accessibility = AXIsProcessTrusted()
        launched.screenRecording = CGPreflightScreenCaptureAccess()
        log.append(launched)
        if let app = NSWorkspace.shared.frontmostApplication { appActivated(app) }
    }

    private func appActivated(_ app: NSRunningApplication) {
        observer.watch(pid: app.processIdentifier, values: TerminalText.terminals.contains(app.bundleIdentifier ?? ""))
        lastWindowTitle = Accessibility.focusedWindowTitle(of: app.processIdentifier)
        record(.appActivated, app: app)
        publish(app: app)
    }

    private func frontmostChanged(_ event: AppObserver.Event) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        if event == .valueChanged {
            pendingValue?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.publish(app: app) }
            pendingValue = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.valueDebounce, execute: work)
            return
        }
        let title = Accessibility.focusedWindowTitle(of: app.processIdentifier)
        guard title != lastWindowTitle || event == .focusChanged else { return }
        if title != lastWindowTitle {
            lastWindowTitle = title
            record(.windowChanged, app: app)
        }
        publish(app: app)
    }

    private func publish(app: NSRunningApplication) {
        var snapshot = Snapshot(at: Date(), app: app.localizedName, bundleId: app.bundleIdentifier, windowTitle: lastWindowTitle, idleSeconds: IdleClock.seconds(), focusedText: Accessibility.focusedText(of: app.processIdentifier, limit: Self.focusedTextLimit))
        if BeanSettings.shared.readBrowser, let bundleId = app.bundleIdentifier {
            snapshot.browser = BrowserReader.current(bundleId: bundleId, pid: app.processIdentifier)
        }
        snapshot.presence = Presence.current()
        onSnapshot?(snapshot)
    }

    private func record(_ kind: Signal.Kind, app: NSRunningApplication?, idle: Double = IdleClock.seconds()) {
        log.append(Signal(at: Date(), kind: kind, app: app?.localizedName, bundleId: app?.bundleIdentifier, windowTitle: lastWindowTitle, idleSeconds: idle.rounded()))
    }
}
