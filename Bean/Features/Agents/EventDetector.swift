import AppKit
import CoreAudio
import CoreMediaIO

struct MacEvent {
    enum Kind: String { case appOpened, appClosed, appSwitched, windowOpened, windowClosed, titleChanged, tabChanged, contentChanged, callStarted, callEnded }
    var at = Date()
    let kind: Kind
    var app: String?
    var bundleId: String?
    var window: Int?
    var title: String?
    var detail: String?

    var key: String { "\(kind.rawValue)|\(window.map(String.init) ?? app ?? "")" }

    var summary: String {
        let place = [app, title].compactMap { $0 }.joined(separator: ", ")
        let number = window.map { " (window \($0))" } ?? ""
        switch kind {
        case .appOpened: return "\(place) was opened"
        case .appClosed: return "\(place) was closed"
        case .appSwitched: return "The user switched to \(place)"
        case .windowOpened: return "A window opened: \(place)\(number)"
        case .windowClosed: return "A window closed: \(place)"
        case .titleChanged: return "The window title changed: \(place)\(number)"
        case .tabChanged: return "The tab changed: \(place)\(number)"
        case .contentChanged: return "Content changed in \(place)\(number)"
        case .callStarted: return "A call started\(place.isEmpty ? "" : " in \(place)")\(number)"
        case .callEnded: return "A call ended\(place.isEmpty ? "" : " in \(place)")"
        }
    }
}

final class EventDetector {
    private static let browsers: Set<String> = ["company.thebrowser.Browser", "com.apple.Safari", "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac"]
    private static let userIdleForContent: TimeInterval = 10
    private let queue = DispatchQueue(label: "dev.rayanbn.Bean.events", qos: .utility)
    private let emit: (MacEvent) -> Void
    private let attached: () -> Set<Int>
    private var timer: DispatchSourceTimer?
    private var known: [Int: OpenWindow]?
    private var seenText: [Int: String] = [:]
    private var inCall = false
    private var ticks = 0
    private var observers: [NSObjectProtocol] = []
    private let filtered = ProcessInfo.processInfo.environment["BEAN_WINDOW_FILTER"] != nil

    init(attached: @escaping () -> Set<Int>, emit: @escaping (MacEvent) -> Void) {
        self.attached = attached
        self.emit = emit
    }

    func start() {
        if !filtered, ProcessInfo.processInfo.environment["BEAN_DATA_DIR"] == nil { observeApps() }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
    }

    private func observeApps() {
        let center = NSWorkspace.shared.notificationCenter
        let add: (NSNotification.Name, MacEvent.Kind) -> Void = { [weak self] name, kind in
            guard let self else { return }
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.activationPolicy == .regular,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
                self?.emit(MacEvent(kind: kind, app: app.localizedName, bundleId: app.bundleIdentifier))
            })
        }
        add(NSWorkspace.didActivateApplicationNotification, .appSwitched)
        add(NSWorkspace.didLaunchApplicationNotification, .appOpened)
        add(NSWorkspace.didTerminateApplicationNotification, .appClosed)
    }

    private func tick() {
        ticks += 1
        let windows = WindowChannels.open()
        diff(windows)
        if ticks % 2 == 0 { checkCall(windows) }
        if ticks % 5 == 0 { checkContent(windows) }
    }

    private func diff(_ windows: [OpenWindow]) {
        let now = Dictionary(windows.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        defer { known = now }
        guard let known else { return }
        for (number, window) in now {
            guard let before = known[number] else {
                emit(MacEvent(kind: .windowOpened, app: window.app, bundleId: window.bundleId, window: number, title: window.title))
                continue
            }
            guard before.title != window.title else { continue }
            seenText[number] = nil
            emit(MacEvent(kind: Self.browsers.contains(window.bundleId) ? .tabChanged : .titleChanged, app: window.app, bundleId: window.bundleId, window: number, title: window.title))
        }
        for (number, window) in known where now[number] == nil {
            seenText[number] = nil
            emit(MacEvent(kind: .windowClosed, app: window.app, bundleId: window.bundleId, window: number, title: window.title))
        }
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
        for window in candidates where !taken.contains(window.number) {
            guard OffLimits.match("\(window.app) \(window.bundleId) \(window.title ?? "")") == nil,
                  let text = WindowSnapshot.read(WindowChannels.attachment(for: window))?.text else { continue }
            defer { seenText[window.number] = text }
            guard let before = seenText[window.number], before != text else { continue }
            let old = Set(before.split(separator: "\n"))
            let added = text.split(separator: "\n").filter { !old.contains($0) }.joined(separator: "\n")
            guard !added.isEmpty else { continue }
            emit(MacEvent(kind: .contentChanged, app: window.app, bundleId: window.bundleId, window: window.number, title: window.title, detail: OffLimits.redact(added).text))
        }
    }

    private func checkCall(_ windows: [OpenWindow]) {
        let environment = ProcessInfo.processInfo.environment
        let now: Bool
        if let file = environment["BEAN_FAKE_CALL_FILE"] {
            now = FileManager.default.fileExists(atPath: file)
        } else if environment["BEAN_DATA_DIR"] != nil {
            return
        } else {
            now = Self.micInUse() || Self.cameraInUse()
        }
        guard now != inCall else { return }
        inCall = now
        let front = NSWorkspace.shared.frontmostApplication
        let window = windows.first { $0.pid == front?.processIdentifier } ?? (environment["BEAN_FAKE_CALL_FILE"] == nil ? nil : windows.first)
        emit(MacEvent(kind: now ? .callStarted : .callEnded, app: window?.app ?? front?.localizedName, bundleId: window?.bundleId ?? front?.bundleIdentifier, window: window?.number, title: window?.title))
    }

    private static func micInUse() -> Bool {
        let own = getpid()
        return audioObjects(kAudioHardwarePropertyProcessObjectList).contains { process in
            audioValue(kAudioProcessPropertyPID, of: process, as: pid_t.self) != own && audioValue(kAudioProcessPropertyIsRunningInput, of: process, as: UInt32.self) == 1
        }
    }

    private static func audioObjects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private static func audioValue<T>(_ selector: AudioObjectPropertySelector, of object: AudioObjectID, as _: T.Type) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr ? value.pointee : nil
    }

    private static func cameraInUse() -> Bool {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == 0, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices) == 0 else { return false }
        return devices.contains { device in
            var running = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            var value: UInt32 = 0, read: UInt32 = 0
            return CMIOObjectGetPropertyData(device, &running, 0, nil, UInt32(MemoryLayout<UInt32>.size), &read, &value) == 0 && value == 1
        }
    }
}

struct GateEntry: Encodable, Identifiable {
    let id = UUID()
    var at = Date()
    let event: String
    let app: String?
    let title: String?
    let decision: String
    let by: String
    var score: Double?
    var ms: Int?
    var detail: String?
    enum CodingKeys: String, CodingKey { case at, event, app, title, decision, by, score, ms, detail }
}

final class EventGate {
    static let log = JSONLog(name: "gate")
    private static let settle: TimeInterval = 2
    private static let repeatWindow: TimeInterval = 60
    private static let noise = try! NSRegularExpression(pattern: #"^\s*(loading|saving|saved|all changes saved|typing|.* is typing|.* is online|\d{1,2}:\d{2}( ?[ap]m)?|\d+ ?%|downloading.*|now playing.*|thanks!?|merci.*|ok)\W*$"#, options: .caseInsensitive)

    private weak var worker: AgentWorker?
    private var detector: EventDetector?
    private var pending: [String: (event: MacEvent, work: DispatchWorkItem)] = [:]
    private var waiting: [MacEvent] = []
    private var scoring = false
    private var lastSeen: [String: (text: String, at: Date)] = [:]

    init(worker: AgentWorker) {
        self.worker = worker
    }

    func start() {
        let attached = OSAllocatedUnfairLockBox(Set<Int>())
        let detector = EventDetector(attached: { attached.value }) { [weak self] event in
            DispatchQueue.main.async { self?.consider(event) }
        }
        self.detector = detector
        worker?.onAttachedWindows = { attached.value = $0 }
        worker?.publishAttachedWindows()
        detector.start()
    }

    func consider(_ event: MacEvent) {
        let place = "\(event.app ?? "") \(event.bundleId ?? "") \(event.title ?? "")"
        if OffLimits.match(place) != nil {
            return record(GateEntry(event: event.kind.rawValue, app: nil, title: nil, decision: "offLimits", by: "code"))
        }
        pending[event.key]?.work.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settled(event) }
        pending[event.key] = (event, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    private func settled(_ event: MacEvent) {
        pending[event.key] = nil
        let text = "\(event.title ?? "")|\(event.detail ?? "")"
        if let last = lastSeen[event.key], last.text == text, Date().timeIntervalSince(last.at) < Self.repeatWindow {
            return record(entry(event, "repeat", by: "debounce"))
        }
        lastSeen[event.key] = (text, Date())
        if worker?.isOwnChange(window: event.window) == true { return record(entry(event, "ownChange", by: "code")) }
        waiting.append(event)
        if waiting.count > 30 { waiting.removeFirst(waiting.count - 30) }
        scoreNext()
    }

    private func scoreNext() {
        guard !scoring, !waiting.isEmpty else { return }
        scoring = true
        let event = waiting.removeFirst()
        Task { @MainActor in
            await judge(event)
            scoring = false
            scoreNext()
        }
    }

    private func entry(_ event: MacEvent, _ decision: String, by: String, score: Double? = nil, ms: Int? = nil, detail: String? = nil) -> GateEntry {
        GateEntry(at: Date(), event: event.kind.rawValue, app: event.app, title: event.title, decision: decision, by: by, score: score, ms: ms, detail: detail)
    }

    private func judge(_ event: MacEvent) async {
        guard let worker else { return }
        if BeanSettings.shared.effectivePaused { return record(entry(event, "paused", by: "code")) }
        let context = worker.gateContext(window: event.window)
        let started = Date()
        let judged = await Self.score(event, context: context)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let yes = judged.score > judged.quietAtOrBelow
        record(entry(event, yes ? "yes" : "quiet", by: judged.by, score: judged.score, ms: ms))
        guard yes else { return }
        let words = context.hasAgent && event.detail != nil ? "\(event.summary). New text: \(event.detail!.prefix(500))" : event.summary
        worker.wake(words)
    }

    private struct Judged { let score: Double; let quietAtOrBelow: Double; let by: String }

    private static func score(_ event: MacEvent, context: AgentWorker.GateContext) async -> Judged {
        let state = StrandsDecider.state(mission: context.mission, goals: context.goals, trigger: event.summary, seen: event.detail ?? "Nothing more.", journal: context.journal)
        if BeanSettings.shared.effectiveDecidesOnThisMac, StrandsServer.isAvailable, let score = await StrandsDecider.score(state: state) {
            return Judged(score: score, quietAtOrBelow: StrandsDecider.quietAtOrBelow, by: "Strands")
        }
        if let key = APIKeyStore.named("TYPESAFE_API_KEY") {
            let sent = context.hasAgent ? state : StrandsDecider.state(mission: context.mission, goals: context.goals, trigger: event.summary, seen: "Not shared.", journal: context.journal)
            if let score = await JEVDecider.score(state: sent, key: key) { return Judged(score: score, quietAtOrBelow: JEVDecider.no, by: "JEV") }
        }
        return Judged(score: filter(event, context: context), quietAtOrBelow: 0.5, by: "filter")
    }

    static func filter(_ event: MacEvent, context: AgentWorker.GateContext) -> Double {
        if event.kind == .callStarted { return 1 }
        if event.kind == .appSwitched || event.kind == .appOpened || event.kind == .appClosed || event.kind == .callEnded { return 0 }
        let text = [event.title, event.detail].compactMap { $0 }.joined(separator: "\n")
        let changed = event.detail ?? event.title ?? ""
        if noise.firstMatch(in: changed, range: NSRange(changed.startIndex..., in: changed)) != nil { return 0.1 }
        if context.hasAgent, event.kind == .contentChanged || event.kind == .windowClosed { return 0.8 }
        func words(_ value: String) -> Set<String> { Set(value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 3 }) }
        return words(text).isDisjoint(with: words(context.goals ?? "")) ? 0.2 : 0.9
    }

    func record(_ entry: GateEntry) {
        Self.log.append(entry)
        worker?.noteGate(entry)
    }
}

private final class OSAllocatedUnfairLockBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
