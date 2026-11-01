import AppKit
import CryptoKit

struct SenseRun {
    let params: [String: String]
    let lastSeen: String?
    let remember: (String) -> Void
    let emit: (SenseSignal) -> Void
}

protocol SenseDriver: AnyObject {
    func start(_ run: SenseRun) -> () -> Void
}

enum SenseDrivers {
    static func make(_ name: String, attached: @escaping () -> Set<Int>, readsText: @escaping (String) -> Bool) -> SenseDriver? {
        switch name {
        case "audioActivity": return AudioActivityDriver()
        case "windowActivity": return WindowActivityDriver(attached: attached, readsText: readsText)
        case "connector": return ConnectorDriver()
        default: return nil
        }
    }
}

final class AudioActivityDriver: SenseDriver {
    func start(_ run: SenseRun) -> () -> Void {
        let environment = ProcessInfo.processInfo.environment
        if let file = environment["BEAN_FAKE_CALL_FILE"] { return fake(file, run) }
        guard #available(macOS 14.2, *), environment["BEAN_DATA_DIR"] == nil || environment["BEAN_WATCH_CALLS"] != nil else { return {} }
        let watcher = CallWatcher()
        var window: OpenWindow?
        watcher.onStart = { call in
            let chain = Set(CallWatcher.parents(of: call.pid)), bundle = call.bundleId?.lowercased()
            window = WindowChannels.open().first { chain.contains($0.pid) || bundle?.hasPrefix($0.bundleId.lowercased() + ".") == true }
            run.emit(SenseSignal(type: "call.started", at: call.startedAt, app: call.app, bundleId: call.bundleId, pid: call.pid, window: window?.number, title: window?.title))
        }
        watcher.onEnd = { call in
            run.emit(SenseSignal(type: "call.ended", app: call.app, bundleId: call.bundleId, pid: call.pid, window: window?.number, title: window?.title))
        }
        watcher.start()
        return { watcher.stop() }
    }

    private func fake(_ file: String, _ run: SenseRun) -> () -> Void {
        var inCall = false
        var place: OpenWindow?
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            let now = FileManager.default.fileExists(atPath: file)
            guard now != inCall else { return }
            inCall = now
            let wanted = (try? String(contentsOfFile: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if now { place = WindowChannels.open().first { wanted.isEmpty || $0.title == wanted } }
            let window = place
            run.emit(SenseSignal(type: now ? "call.started" : "call.ended", app: window?.app, bundleId: window?.bundleId, pid: window?.pid, window: window?.number, title: window?.title))
        }
        return { timer.invalidate() }
    }
}

final class WindowActivityDriver: SenseDriver {
    private static let userIdleForContent: TimeInterval = 10
    private let queue = DispatchQueue(label: "dev.rayanbn.Bean.events", qos: .utility)
    private let attached: () -> Set<Int>
    private let readsText: (String) -> Bool
    private let filtered = ProcessInfo.processInfo.environment["BEAN_WINDOW_FILTER"] != nil
    private var emit: (SenseSignal) -> Void = { _ in }
    private var timer: DispatchSourceTimer?
    private var known: [Int: OpenWindow]?
    private var seenText: [Int: String] = [:]
    private var ticks = 0
    private var focused: OpenWindow?
    private var observers: [NSObjectProtocol] = []

    init(attached: @escaping () -> Set<Int>, readsText: @escaping (String) -> Bool) {
        self.attached = attached
        self.readsText = readsText
    }

    func start(_ run: SenseRun) -> () -> Void {
        emit = run.emit
        let environment = ProcessInfo.processInfo.environment
        if (!filtered && environment["BEAN_DATA_DIR"] == nil) || environment["BEAN_WATCH_APPS"] != nil { observeApps() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        return { [weak self] in
            timer.cancel()
            self?.observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
            self?.observers = []
        }
    }

    private func observeApps() {
        let center = NSWorkspace.shared.notificationCenter
        let add: (NSNotification.Name, String) -> Void = { [weak self] name, type in
            guard let self else { return }
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.activationPolicy == .regular,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
                self?.emit(SenseSignal(type: type, app: app.localizedName, bundleId: app.bundleIdentifier, pid: app.processIdentifier))
            })
        }
        add(NSWorkspace.didActivateApplicationNotification, "app.switched")
        add(NSWorkspace.didLaunchApplicationNotification, "app.opened")
        add(NSWorkspace.didTerminateApplicationNotification, "app.closed")
    }

    private func tick() {
        ticks += 1
        let windows = WindowChannels.open()
        diff(windows)
        focus(windows)
        if ticks % 5 == 0 { checkContent(windows) }
    }

    private func signal(_ type: String, _ window: OpenWindow, detail: String? = nil) -> SenseSignal {
        SenseSignal(type: type, app: window.app, bundleId: window.bundleId, pid: window.pid, window: window.number, title: window.title, detail: detail)
    }

    private func diff(_ windows: [OpenWindow]) {
        let now = Dictionary(windows.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        defer { known = now }
        guard let known else { return }
        for (number, window) in now {
            guard let before = known[number] else {
                emit(signal("window.opened", window))
                continue
            }
            guard before.title != window.title else { continue }
            seenText[number] = nil
            emit(signal("window.changed", window))
        }
        for (number, window) in known where now[number] == nil {
            seenText[number] = nil
            emit(signal("window.closed", window))
        }
    }

    private func focus(_ windows: [OpenWindow]) {
        let me = ProcessInfo.processInfo.processIdentifier
        let frontApp = NSWorkspace.shared.frontmostApplication
        guard filtered || frontApp?.processIdentifier != me else { return }
        let front = filtered ? windows.first : frontApp.flatMap { app in windows.first { $0.pid == app.processIdentifier } }
        guard front?.number != focused?.number || front?.title != focused?.title else { return }
        focused = front
        emit(front.map { signal("window.focused", $0) } ?? SenseSignal(type: "window.unfocused"))
    }

    private func checkContent(_ windows: [OpenWindow]) {
        let taken = attached()
        let candidates: [OpenWindow]
        if filtered {
            candidates = windows
        } else {
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            guard idle >= Self.userIdleForContent, let front = NSWorkspace.shared.frontmostApplication,
                  let window = windows.first(where: { $0.pid == front.processIdentifier }) else { return }
            candidates = [window]
        }
        for window in candidates where !taken.contains(window.number) && readsText(window.bundleId) {
            guard OffLimits.match("\(window.app) \(window.bundleId) \(window.title ?? "")") == nil,
                  let text = WindowSnapshot.read(WindowChannels.attachment(for: window))?.text else { continue }
            defer { seenText[window.number] = text }
            guard let before = seenText[window.number], before != text else { continue }
            let old = Set(before.split(separator: "\n"))
            let added = text.split(separator: "\n").filter { !old.contains($0) }.joined(separator: "\n")
            guard !added.isEmpty else { continue }
            let detail = OffLimits.redact(added).text
            Task { [weak self] in
                guard await !PrivateCheck.suspects(added) else { return }
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.emit(self.signal("window.content", window, detail: detail))
                }
            }
        }
    }
}

final class ConnectorDriver: SenseDriver {
    static func every(_ params: [String: String]) -> TimeInterval {
        ProcessInfo.processInfo.environment["BEAN_SENSE_EVERY"].flatMap(Double.init) ?? max(60, params["every"].flatMap(Double.init) ?? 300)
    }

    static func readTool(_ name: String) async -> BrainTool? {
        guard let tool = await Tools.shared.tool(named: name), tool.effect == .read else { return nil }
        return tool
    }

    static func arguments(_ params: [String: String]) -> JSONArgs? {
        guard let text = params["args"], !text.isEmpty else { return [:] }
        return text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? JSONArgs }
    }

    func start(_ run: SenseRun) -> () -> Void {
        guard let name = run.params["tool"], let args = Self.arguments(run.params) else { return {} }
        let every = Self.every(run.params)
        let task = Task {
            var hash = run.lastSeen, text: String?
            while !Task.isCancelled {
                if let output = await Self.readTool(name)?.run(args), output.ok {
                    let digest = SHA256.hash(data: Data(output.text.utf8)).map { String(format: "%02x", $0) }.joined()
                    if digest != hash {
                        if hash != nil {
                            let old = Set((text ?? "").split(separator: "\n"))
                            let added = output.text.split(separator: "\n").filter { !old.contains($0) }.joined(separator: "\n")
                            run.emit(SenseSignal(type: "service.changed", app: name.components(separatedBy: "__").first, title: name, detail: OffLimits.redact(String(added.prefix(2000))).text))
                        }
                        hash = digest
                        run.remember(digest)
                    }
                    text = output.text
                }
                try? await Task.sleep(for: .seconds(every))
            }
        }
        return { task.cancel() }
    }
}
