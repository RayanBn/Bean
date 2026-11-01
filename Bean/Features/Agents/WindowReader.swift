import AppKit
import ApplicationServices
import Combine

struct WindowSnapshot: Equatable {
    let title: String?
    let text: String

    static func read(_ attachment: Attachment, limit: Int = 6000) -> WindowSnapshot? {
        if Skills.forApp(attachment.bundleId)?.sealed == true { return WindowSnapshot(title: attachment.windowTitle, text: "") }
        let app = AXUIElementCreateApplication(attachment.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var found = window(of: app, for: attachment)
        for _ in 0..<2 where found == nil && stillOpen(attachment) {
            usleep(300_000)
            found = window(of: app, for: attachment)
        }
        guard let window = found else {
            var windows: CFTypeRef?
            let code = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
            WindowReader.log.append(WindowReader.Entry(agent: attachment.appName, event: "unreachable", title: attachment.windowTitle, error: "windows \(code.rawValue), \((windows as? [AXUIElement])?.count ?? -1) listed, open \(stillOpen(attachment)), running \(NSRunningApplication(processIdentifier: attachment.pid) != nil)"))
            return nil
        }
        let title = Accessibility.attribute(kAXTitleAttribute, of: window) as? String
        var lines = text(of: window, limit: limit).components(separatedBy: "\n")
        if lines.count > 1, let last = lines.last, last == title || last == attachment.windowTitle { lines.removeLast() }
        return WindowSnapshot(title: title?.isEmpty == false ? title : attachment.windowTitle, text: lines.joined(separator: "\n"))
    }

    static func element(for attachment: Attachment) -> AXUIElement? {
        let app = AXUIElementCreateApplication(attachment.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        return window(of: app, for: attachment)
    }

    // Only this exact window. A closed one matches nothing, so nothing reads or writes the app's next document in its place.
    private static func window(of app: AXUIElement, for attachment: Attachment) -> AXUIElement? {
        let windows = (Accessibility.attribute(kAXWindowsAttribute, of: app) as? [AXUIElement]) ?? []
        if attachment.windowNumber == 0 { return windows.first { (Accessibility.attribute(kAXTitleAttribute, of: $0) as? String) == attachment.windowTitle } }
        guard let bounds = bounds(of: attachment.windowNumber) else { return nil }
        if let match = windows.first(where: { SpaceWindows.number(of: $0) == attachment.windowNumber }) { return match }
        if let match = windows.first(where: { SpaceWindows.number(of: $0) == nil && frame(of: $0).map { abs($0.minX - bounds.minX) + abs($0.minY - bounds.minY) + abs($0.width - bounds.width) < 4 } ?? false }) { return match }
        return SpaceWindows.windows(of: attachment.pid)[attachment.windowNumber]
    }

    static func stillOpen(_ attachment: Attachment) -> Bool { bounds(of: attachment.windowNumber) != nil }

    // Without a yes for the app, a script reaches only the agent's own window: by its title, or as the front window when it names none.
    static func scriptRefusal(_ script: String, for attachment: Attachment) -> String? {
        guard !ReadingYes.covers(attachment.bundleId) else { return nil }
        let live = element(for: attachment).flatMap { Accessibility.attribute(kAXTitleAttribute, of: $0) as? String }
        let title = live ?? attachment.windowTitle ?? "your window"
        let why = "Without the user's yes for this app you work only in your own window, \"\(title)\". Nothing ran."
        switch AppGuard.target(of: script, ownTitles: [live, attachment.windowTitle].compactMap { $0 }) {
        case .own: return nil
        case let .other(name): return "\"\(name)\" is not your window. \(why) If the work needs it, say so when you finish."
        case .unclear: return "this script does not name its document by the exact title, so Bean cannot tell whose it is. \(why) Name your window's document in quotes."
        case .noDocument: return isFront(attachment) ? nil : "this script names no document, so it would reach the app's front window, and that is not yours. \(why) Name your window's document in quotes."
        }
    }

    private static func isFront(_ attachment: Attachment) -> Bool {
        let app = AXUIElementCreateApplication(attachment.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let main = Accessibility.attribute(kAXMainWindowAttribute, of: app).map { $0 as! AXUIElement }
        let front = main ?? (Accessibility.attribute(kAXWindowsAttribute, of: app) as? [AXUIElement])?.first
        return front.flatMap { SpaceWindows.number(of: $0) } == attachment.windowNumber
    }

    enum Presence { case open, notShowing, closed }

    // macOS drops a minimized window and a background tab from the plain lookup, exactly like a closed one.
    static func presence(_ attachment: Attachment) -> Presence {
        if stillOpen(attachment) { return .open }
        let all = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        guard let info = all.first(where: { $0[kCGWindowNumber as String] as? Int == attachment.windowNumber }),
              let own = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) else { return .closed }
        if NSRunningApplication(processIdentifier: attachment.pid)?.isHidden == true { return .notShowing }
        let app = AXUIElementCreateApplication(attachment.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let windows = (Accessibility.attribute(kAXWindowsAttribute, of: app) as? [AXUIElement]) ?? []
        if let window = windows.first(where: { SpaceWindows.number(of: $0) == attachment.windowNumber }), Accessibility.attribute(kAXMinimizedAttribute, of: window) as? Bool == true { return .notShowing }
        let tabShowing = windows.contains { window in
            guard let shown = frame(of: window), abs(shown.minX - own.minX) + abs(shown.minY - own.minY) + abs(shown.width - own.width) < 4 else { return false }
            let parts = (Accessibility.attribute(kAXChildrenAttribute, of: window) as? [AXUIElement]) ?? []
            return parts.contains { Accessibility.attribute(kAXRoleAttribute, of: $0) as? String == kAXTabGroupRole }
        }
        return tabShowing ? .notShowing : .closed
    }

    private static func bounds(of windowNumber: Int) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowNumber)) as? [[String: Any]])?.first,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = Accessibility.attribute(kAXPositionAttribute, of: element),
              let size = Accessibility.attribute(kAXSizeAttribute, of: element) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    private static let valueRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXCell"]
    private static let labelRoles: Set<String> = ["AXLink", "AXTab", "AXRadioButton", "AXMenuButton", "AXImage", "AXGroup"]

    private static func text(of root: AXUIElement, limit: Int) -> String {
        var lines: [String] = [], total = 0, visited = 0
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while let (element, depth) = stack.popLast(), visited < 4000, total < limit {
            visited += 1
            let role = Accessibility.attribute(kAXRoleAttribute, of: element) as? String ?? ""
            var line: String?
            if valueRoles.contains(role) {
                line = (Accessibility.attribute(kAXValueAttribute, of: element) as? String).map { String($0.prefix(2500)) }
            } else if labelRoles.contains(role) {
                line = (Accessibility.attribute(kAXTitleAttribute, of: element) as? String) ?? (Accessibility.attribute(kAXDescriptionAttribute, of: element) as? String)
            }
            if let text = line?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text != lines.last {
                lines.append(text)
                total += text.count + 1
            }
            if role == "AXTextArea" || role == "AXTextField" || depth > 60 { continue }
            let children = (Accessibility.attribute(kAXChildrenAttribute, of: element) as? [AXUIElement]) ?? []
            stack += children.reversed().map { ($0, depth + 1) }
        }
        return String(lines.joined(separator: "\n").prefix(limit))
    }
}

@MainActor
final class WindowReader {
    static let log = JSONLog(name: "agents")

    struct Entry: Encodable {
        var at = Date()
        let agent: String
        var event: String
        var app: String?
        var title: String?
        var chars: Int?
        var bubble: String?
        var understanding: String?
        var seconds: Double?
        var error: String?
    }

    private let store: AgentStore
    let worker: AgentWorker
    private var watches: [UUID: Watch] = [:]
    private var subscription: AnyCancellable?

    init(store: AgentStore) {
        self.store = store
        worker = AgentWorker(store: store)
        subscription = store.$agents.receive(on: DispatchQueue.main).sink { [weak self] agents in self?.sync(agents) }
    }

    private func sync(_ agents: [Agent]) {
        let attached = Dictionary(uniqueKeysWithValues: agents.filter { !$0.name.isEmpty }.compactMap { agent in agent.attachment.map { (agent.id, (agent, $0)) } })
        for (id, watch) in watches where attached[id]?.1 != watch.attachment {
            watch.stop()
            watches[id] = nil
            if attached[id] == nil, let agent = agents.first(where: { $0.id == id }) {
                store.activity[id] = AgentActivity()
                Self.log.append(Entry(agent: agent.name, event: "unplugged"))
            }
        }
        for (id, (agent, attachment)) in attached where watches[id] == nil {
            let watch = Watch(agent: agent, attachment: attachment, store: store, worker: worker)
            watches[id] = watch
            watch.start()
        }
    }
}

@MainActor
private final class Watch {
    static let queue = DispatchQueue(label: "dev.rayanbn.Bean.agents.read", qos: .utility)
    static let poll: TimeInterval = 5
    static let settle: TimeInterval = 1.2
    static let spacing: TimeInterval = 600

    let agent: Agent
    let attachment: Attachment
    private weak var store: AgentStore?
    private let worker: AgentWorker
    private let folder: AgentFolder
    private var observer: AXObserver?
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var checking = false
    private var lastSeen: WindowSnapshot?
    private var lastUnderstood: WindowSnapshot?
    private var lastCall = Date.distantPast
    private var thinking = false
    private var blocked = false
    private var stopped = false
    private var firstRead = true
    private var saidSwitch = false
    private var wasUnreadable = false
    private var goneOnce = false

    init(agent: Agent, attachment: Attachment, store: AgentStore, worker: AgentWorker) {
        self.agent = agent
        self.attachment = attachment
        self.store = store
        self.worker = worker
        folder = AgentFolder(agent, in: store)
    }

    func start() {
        WindowReader.log.append(WindowReader.Entry(agent: agent.name, event: "plugged", app: attachment.appName, title: attachment.windowTitle))
        observe()
        timer = Timer.scheduledTimer(withTimeInterval: Self.poll, repeats: true) { [weak self] _ in self?.read() }
        read()
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        pending?.cancel()
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
    }

    func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.read() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    private func observe() {
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<Watch>.fromOpaque(refcon).takeUnretainedValue().changed()
        }
        guard AXObserverCreate(attachment.pid, callback, &created) == .success, let created else { return }
        let app = AXUIElementCreateApplication(attachment.pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXTitleChangedNotification, kAXValueChangedNotification, kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification, kAXSelectedTextChangedNotification] {
            AXObserverAddNotification(created, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }

    private func read() {
        guard !stopped else { return }
        if windowIsGone() {
            worker.windowClosed(agent, attachment: attachment)
            return
        }
        let attachment = attachment
        if BeanSettings.shared.effectivePaused {
            if firstRead {
                firstRead = false
                worker.dropped(agent, app: attachment.appName, title: attachment.windowTitle, text: nil)
            }
            return
        }
        if firstRead, !WindowAccess.isOn {
            if !saidSwitch {
                saidSwitch = true
                worker.cannotRead(agent, String(format: AgentStrings.local(AgentStrings.needsSwitch), WindowAccess.paneName))
            }
            return
        }
        if OffLimits.match([attachment.appName, attachment.bundleId, attachment.windowTitle ?? ""].joined(separator: " ")) != nil { return refuse() }
        Self.queue.async { [weak self] in
            let snapshot = WindowSnapshot.read(attachment)
            DispatchQueue.main.async { self?.checked(snapshot) }
        }
    }

    // One look can catch a window between two states, so a second look five seconds later decides.
    private func windowIsGone() -> Bool {
        guard WindowSnapshot.presence(attachment) == .closed else {
            goneOnce = false
            return false
        }
        defer { goneOnce = true }
        return goneOnce
    }

    private func refuse() {
        guard !blocked else { return }
        blocked = true
        folder.clearUnderstanding()
        let line = "This window is off limits, so I'm not looking."
        store?.activity[agent.id] = AgentActivity(mood: .idle, bubble: line)
        WindowReader.log.append(WindowReader.Entry(agent: agent.name, event: "offLimits", app: attachment.appName, bubble: line))
    }

    private func checked(_ snapshot: WindowSnapshot?) {
        guard let snapshot, snapshot != lastSeen else { return seen(snapshot) }
        guard !checking, !MainActor.assumeIsolated({ PrivateCheck.isHeld(snapshot.text, attachment) }) else { return }
        checking = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let held = await self.worker.holdsBack(snapshot.text, attachment: self.attachment, agent: self.agent)
            self.checking = false
            if !held { self.seen(snapshot) }
        }
    }

    private func seen(_ snapshot: WindowSnapshot?) {
        guard !stopped else { return }
        guard let snapshot else {
            guard WindowSnapshot.stillOpen(attachment) else { return }
            if !wasUnreadable {
                wasUnreadable = true
                WindowReader.log.append(WindowReader.Entry(agent: agent.name, event: "unreadable", app: attachment.appName, title: attachment.windowTitle))
            }
            if firstRead, !(worker.placedWithoutTheUser(agent.id) && WindowSnapshot.stillOpen(attachment)) {
                firstRead = false
                worker.cannotRead(agent, AgentStrings.local(AgentWorker.unreadable))
            }
            return
        }
        if firstRead || wasUnreadable { worker.canRead(agent) }
        wasUnreadable = false
        if OffLimits.match(snapshot.title) != nil { return refuse() }
        blocked = false
        if !firstRead, let lastSeen, snapshot != lastSeen {
            let before = Set(lastSeen.text.split(separator: "\n"))
            let added = snapshot.text.split(separator: "\n").filter { !before.contains($0) }.joined(separator: "\n")
            worker.windowChanged(agent, title: snapshot.title, newText: OffLimits.redact(added).text)
        }
        lastSeen = snapshot
        guard snapshot != lastUnderstood, !thinking else { return }
        let wait = lastCall.addingTimeInterval(Self.spacing).timeIntervalSinceNow
        if wait > 0 {
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.understand() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
            return
        }
        understand()
    }

    private func understand() {
        guard !stopped, !thinking, let snapshot = lastSeen, snapshot != lastUnderstood else { return }
        if worker.isOverBudget(agent) {
            if firstRead {
                firstRead = false
                worker.cannotRead(agent, AgentStrings.local(AgentStrings.stoppedToday))
            }
            return
        }
        thinking = true
        lastCall = Date()
        let previous = store?.activity[agent.id]?.bubble
        if !worker.isBusy(agent.id) { store?.activity[agent.id] = AgentActivity(mood: .reading, bubble: previous) }
        let started = Date()
        let persona = folder.personaText
        let before = folder.understanding
        let app = attachment.appName
        Task { @MainActor [weak self] in
            let result = await CostLedger.$agent.withValue(self?.agent.id.uuidString) { await Self.understand(snapshot: snapshot, app: app, persona: persona, before: before) }
            guard let self, !self.stopped else { return }
            self.thinking = false
            var entry = WindowReader.Entry(agent: self.agent.name, event: "understood", app: app, title: snapshot.title, chars: snapshot.text.count,
                                           seconds: (Date().timeIntervalSince(started) * 10).rounded() / 10)
            switch result {
            case let .success(output):
                self.lastUnderstood = snapshot
                self.folder.saveUnderstanding(output.understanding, app: app, title: snapshot.title)
                entry.bubble = output.bubble
                entry.understanding = output.understanding
                let first = self.firstRead
                self.firstRead = false
                if !self.worker.isBusy(self.agent.id) {
                    self.store?.activity[self.agent.id] = AgentActivity(mood: .idle, bubble: output.bubble)
                    if first { self.worker.dropped(self.agent, app: app, title: snapshot.title, text: output.understanding) }
                }
            case let .failure(error):
                if !self.worker.isBusy(self.agent.id) { self.store?.activity[self.agent.id] = AgentActivity(mood: .idle, bubble: previous) }
                entry.event = "failed"
                entry.error = ModelClient.plain(error)
            }
            WindowReader.log.append(entry)
            if self.lastSeen != self.lastUnderstood { self.seen(self.lastSeen) }
        }
    }

    struct Understanding: Decodable {
        let understanding: String
        let bubble: String
    }

    static func understand(snapshot: WindowSnapshot, app: String, persona: String, before: String?) async -> Result<Understanding, Error> {
        let system = """
        \(persona)

        You are plugged into one window of \(app) on your user's Mac. You only read it: you never act in the app. \
        Below is what the window shows right now, read through Accessibility. Write:
        - understanding: two to four plain sentences on what is happening in this window now (the file, conversation, page or task, and what stands out). Facts from the text only.
        - bubble: one plain line, at most 70 characters, telling the user what you see. Name the concrete thing (the file, the person, the topic). Never say you are fixing, sending or doing anything: you only read here. \(Prompts.writing) \(AgentContext.user())
        """
        let redacted = String(OffLimits.redact(snapshot.text).text.prefix(3000))
        var text = "Window title: \(snapshot.title ?? "untitled")\n\nWindow text:\n\(redacted.isEmpty ? "(no readable text)" : redacted)"
        if let before, !before.isEmpty { text += "\n\nWhat you understood a moment ago:\n\(before)" }
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["understanding", "bubble"],
            "properties": ["understanding": ["type": "string"], "bubble": ["type": "string"]],
        ]
        do {
            let reply = try await ModelClient().json(system: system, text: text, schema: schema, effort: "low")
            guard let body = reply.text, let output = try? JSONDecoder().decode(Understanding.self, from: Data(body.utf8)) else {
                return .failure(AgentMaker.MakerError.unreadable(reply.text ?? ""))
            }
            return .success(output)
        } catch {
            return .failure(error)
        }
    }
}
