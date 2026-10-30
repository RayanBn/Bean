import AppKit
import ApplicationServices
import Combine

struct WindowSnapshot: Equatable {
    let title: String?
    let text: String

    static func read(_ attachment: Attachment, limit: Int = 6000) -> WindowSnapshot? {
        let app = AXUIElementCreateApplication(attachment.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window = window(of: app, for: attachment) else { return nil }
        let title = Accessibility.attribute(kAXTitleAttribute, of: window) as? String
        return WindowSnapshot(title: title?.isEmpty == false ? title : attachment.windowTitle, text: text(of: window, limit: limit))
    }

    static func element(for attachment: Attachment) -> AXUIElement? {
        let app = AXUIElementCreateApplication(attachment.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        return window(of: app, for: attachment)
    }

    private static func window(of app: AXUIElement, for attachment: Attachment) -> AXUIElement? {
        let windows = (Accessibility.attribute(kAXWindowsAttribute, of: app) as? [AXUIElement]) ?? []
        if let bounds = bounds(of: attachment.windowNumber),
           let match = windows.first(where: { frame(of: $0).map { abs($0.minX - bounds.minX) + abs($0.minY - bounds.minY) + abs($0.width - bounds.width) < 4 } ?? false }) {
            return match
        }
        if let title = attachment.windowTitle, let match = windows.first(where: { (Accessibility.attribute(kAXTitleAttribute, of: $0) as? String) == title }) {
            return match
        }
        return windows.count == 1 ? windows[0] : nil
    }

    static func stillOpen(_ attachment: Attachment) -> Bool { bounds(of: attachment.windowNumber) != nil }

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
    private var lastSeen: WindowSnapshot?
    private var lastUnderstood: WindowSnapshot?
    private var lastCall = Date.distantPast
    private var thinking = false
    private var blocked = false
    private var stopped = false
    private var firstRead = true
    private var wasUnreadable = false

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
        let attachment = attachment
        if BeanSettings.shared.effectivePaused {
            if firstRead {
                firstRead = false
                worker.dropped(agent, app: attachment.appName, title: attachment.windowTitle, text: nil)
            }
            return
        }
        if !AXIsProcessTrusted(), firstRead {
            firstRead = false
            return worker.cannotRead(agent, AgentStrings.local("Bean needs the Accessibility permission to read this window. Turn it on in System Settings, then drop me again."))
        }
        if OffLimits.match([attachment.appName, attachment.bundleId, attachment.windowTitle ?? ""].joined(separator: " ")) != nil { return refuse() }
        Self.queue.async { [weak self] in
            let snapshot = WindowSnapshot.read(attachment)
            DispatchQueue.main.async { self?.seen(snapshot) }
        }
    }

    private func refuse() {
        guard !blocked else { return }
        blocked = true
        folder.clearUnderstanding()
        let line = folder.lines?.offLimits ?? "This window is off limits, so I'm not looking."
        store?.activity[agent.id] = AgentActivity(mood: .idle, bubble: line)
        WindowReader.log.append(WindowReader.Entry(agent: agent.name, event: "offLimits", app: attachment.appName, bubble: line))
    }

    private func seen(_ snapshot: WindowSnapshot?) {
        guard !stopped else { return }
        guard let snapshot else {
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
        if CostLedger.spentToday(agent: agent.id.uuidString) >= folder.mission?.dailyBudgetUSD ?? 1 {
            if firstRead {
                firstRead = false
                worker.cannotRead(agent, AgentStrings.local("My budget for today is spent."))
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
        - bubble: one plain line, at most 70 characters, telling the user what you see. Name the concrete thing (the file, the person, the topic). Never say you are fixing, sending or doing anything: you only read here. \(AgentWriting.rule) \(AgentContext.user())
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
