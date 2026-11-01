import AppKit
import ApplicationServices
import Combine

struct WindowSnapshot: Equatable {
    let title: String?
    let text: String
    // Why this read may not hold all the window does. What it leaves out is unknown, never absent.
    var partial: String? = nil

    // What goes to the model: cut to its limit, and saying so.
    func shown(limit: Int) -> String {
        let words = OffLimits.redact(text).text
        let notice = partialNotice ?? (words.count > limit ? WindowSnapshot(title: nil, text: "", partial: "it stopped at its size limit").partialNotice : nil)
        return "Title: \(title ?? "untitled")\n\(words.prefix(limit))\(notice.map { "\n\n\($0)" } ?? "")"
    }

    // A title can change after the agent was placed, so this looks at it now.
    static func offLimitsNow(_ attachment: Attachment) -> Bool {
        let title = shownTitle(of: attachment.windowNumber) ?? element(for: attachment).flatMap { Accessibility.attribute(kAXTitleAttribute, of: $0) as? String }
        return title.map { OffLimits.match("\(attachment.appName) \(attachment.bundleId) \($0)") != nil } ?? false
    }

    private static func shownTitle(of windowNumber: Int) -> String? {
        ((CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowNumber)) as? [[String: Any]])?.first?[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    var partialNotice: String? {
        partial.map { "This is only part of the window: \($0). Something not shown here may still be there, so never say it is not there from this read. Read the rest another way: tab_read for a page in a browser, app_script for a document, which needs no permission when it only reads. Otherwise say what you could not read." }
    }

    static func read(_ attachment: Attachment, limit: Int = 6000) -> WindowSnapshot? {
        if Skills.forApp(attachment.bundleId)?.sealed == true { return WindowSnapshot(title: attachment.windowTitle, text: "") }
        func allowed(_ title: String?) -> Bool { OffLimits.match("\(attachment.appName) \(attachment.bundleId) \(title ?? "")") == nil }
        guard allowed(shownTitle(of: attachment.windowNumber)) else { return nil }
        let app = AXUIElementCreateApplication(attachment.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var found = window(of: app, for: attachment)
        for _ in 0..<2 where found == nil && stillOpen(attachment) {
            usleep(300_000)
            found = window(of: app, for: attachment)
        }
        guard let window = found else {
            var windows: CFTypeRef?
            let code = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
            WindowReader.log.append(WindowReader.Entry(agent: attachment.appName, event: "unreachable", title: attachment.windowTitle, error: "windows \(code.rawValue), \((windows as? [AXUIElement])?.count ?? -1) listed, open \(stillOpen(attachment)), running \(NSRunningApplication(processIdentifier: attachment.pid) != nil)"))
            // With no title to check, a picture's own first words stand in for it.
            guard let seen = SpaceWindows.pictureText(of: attachment.windowNumber), allowed(shownTitle(of: attachment.windowNumber) ?? String(seen.prefix(200))) else { return nil }
            return WindowSnapshot(title: attachment.windowTitle, text: String(seen.prefix(limit)), partial: fromPicture)
        }
        SpaceWindows.wake(window, pid: attachment.pid)
        let title = Accessibility.attribute(kAXTitleAttribute, of: window) as? String
        guard allowed(title) else { return nil }
        let read = text(of: window, limit: limit)
        var lines = read.text.components(separatedBy: "\n")
        let away = SpaceWindows.isOnAnotherSpace(attachment.windowNumber)
        var partial = !read.sawContent ? "it shows the app's buttons and labels, not what the document holds" : read.cut ? "it stopped at its size limit" : away ? "the window is on another Space, where an app can hide part of it" : nil
        // What has no tree even when asked can still show its picture.
        if lines == [""], away, let seen = SpaceWindows.pictureText(of: attachment.windowNumber), title != nil || allowed(String(seen.prefix(200))) {
            lines = [String(seen.prefix(limit))]
            partial = fromPicture
        }
        if lines.count > 1, let last = lines.last, last == title || last == attachment.windowTitle { lines.removeLast() }
        return WindowSnapshot(title: title?.isEmpty == false ? title : attachment.windowTitle, text: lines.joined(separator: "\n"), partial: partial)
    }

    static func element(for attachment: Attachment) -> AXUIElement? {
        let app = AXUIElementCreateApplication(attachment.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        return window(of: app, for: attachment)
    }

    // Only this exact window. A closed one matches nothing, so nothing reads or writes the app's next document in its place.
    private static func window(of app: AXUIElement, for attachment: Attachment) -> AXUIElement? {
        if attachment.windowNumber == 0 { return SpaceWindows.known(of: attachment.pid).values.first { (Accessibility.attribute(kAXTitleAttribute, of: $0) as? String) == attachment.windowTitle } }
        guard let bounds = bounds(of: attachment.windowNumber) else {
            // The plain lookup also drops a closed window an app keeps in memory, so only a hidden or minimized one counts here.
            let held = SpaceWindows.known(of: attachment.pid)[attachment.windowNumber]
            return held.flatMap { NSRunningApplication(processIdentifier: attachment.pid)?.isHidden == true || Accessibility.attribute(kAXMinimizedAttribute, of: $0) as? Bool == true ? $0 : nil }
        }
        // Some apps' windows do not say their number, so only their place tells them apart, and only among what the app lists.
        let listed = (Accessibility.attribute(kAXWindowsAttribute, of: app) as? [AXUIElement]) ?? []
        if let match = listed.first(where: { SpaceWindows.number(of: $0) == nil && frame(of: $0).map { abs($0.minX - bounds.minX) + abs($0.minY - bounds.minY) + abs($0.width - bounds.width) < 4 } ?? false }) { return match }
        let sealed = Skills.forApp(attachment.bundleId)?.sealed == true || OffLimits.match("\(attachment.appName) \(attachment.bundleId) \(attachment.windowTitle ?? "")") != nil
        return SpaceWindows.element(of: attachment.windowNumber, pid: attachment.pid, mayNudge: !sealed)
    }

    static func stillOpen(_ attachment: Attachment) -> Bool { stillOpen(attachment.windowNumber) }

    // What the app's other windows show, through what is already at hand: watching never wakes or nudges a window.
    static func others(of attachment: Attachment, limit: Int = 1500) -> [(number: Int, title: String?, text: String)] {
        WindowChannels.open().filter { $0.bundleId == attachment.bundleId && $0.number != attachment.windowNumber && OffLimits.match("\($0.app) \($0.bundleId) \($0.title ?? "")") == nil }.compactMap { window in
            SpaceWindows.element(of: window.number, pid: window.pid, mayNudge: false).map { (window.number, window.title, OffLimits.redact(text(of: $0, limit: limit).text).text) }
        }
    }

    // This plain lookup holds a window on another Space or behind a full-screen app, and drops a closed, minimized or background-tab one.
    static func stillOpen(_ windowNumber: Int) -> Bool { bounds(of: windowNumber) != nil }

    private static func isOnScreen(_ windowNumber: Int) -> Bool {
        (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowNumber)) as? [[String: Any]])?.first?[kCGWindowIsOnscreen as String] as? Bool == true
    }

    enum Presence { case open, notShowing, closed }

    // macOS drops a hidden or minimized window and a background tab from the plain lookup, exactly like a closed one.
    static func presence(_ attachment: Attachment) -> Presence {
        // A window on another Space, or behind a full-screen app, is not closed. What cannot be reached now comes back when the person does.
        if stillOpen(attachment) { return isOnScreen(attachment.windowNumber) || element(for: attachment) != nil || SpaceWindows.picturesWork ? .open : .notShowing }
        let all = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        guard let info = all.first(where: { $0[kCGWindowNumber as String] as? Int == attachment.windowNumber }),
              let own = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) else { return .closed }
        if element(for: attachment) != nil { return .open }
        if NSRunningApplication(processIdentifier: attachment.pid)?.isHidden == true { return .notShowing }
        let app = AXUIElementCreateApplication(attachment.pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let windows = (Accessibility.attribute(kAXWindowsAttribute, of: app) as? [AXUIElement]) ?? []
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

    private static let fromPicture = "it comes from a picture of the window, so it holds only what shows there"
    // Where a document's own words live. A canvas app such as Numbers exposes none of these: only its toolbar reads.
    private static let contentRoles: Set<String> = ["AXTextArea", "AXWebArea", "AXTable", "AXOutline", "AXList", "AXBrowser"]

    private static func text(of root: AXUIElement, limit: Int) -> (text: String, sawContent: Bool, cut: Bool) {
        var lines: [String] = [], total = 0, visited = 0, sawContent = false, valueCut = false
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while let (element, depth) = stack.popLast(), visited < 4000, total < limit {
            visited += 1
            let role = Accessibility.attribute(kAXRoleAttribute, of: element) as? String ?? ""
            if contentRoles.contains(role) { sawContent = true }
            var line: String?
            if valueRoles.contains(role) {
                let value = Accessibility.attribute(kAXValueAttribute, of: element) as? String
                if (value?.count ?? 0) > 2500 { valueCut = true }
                line = value.map { String($0.prefix(2500)) }
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
        return (String(lines.joined(separator: "\n").prefix(limit)), sawContent, valueCut || total >= limit || !stack.isEmpty)
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
        var bubble: String?
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
        // The app is the work. Another window of it only moves where the agent sits.
        for (id, watch) in watches {
            if let moved = attached[id]?.1, moved.windowNumber != watch.attachment.windowNumber || moved.windowTitle != watch.attachment.windowTitle { watch.follow(moved) }
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
    static let othersEvery: TimeInterval = 20

    let agent: Agent
    private(set) var attachment: Attachment
    private weak var store: AgentStore?
    private let worker: AgentWorker
    private let folder: AgentFolder
    private var observer: AXObserver?
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var checking = false
    private var lastSeen: WindowSnapshot?
    private var othersSeen: [Int: String] = [:]
    private var othersRead = Date.distantPast
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

    func follow(_ moved: Attachment) {
        attachment = moved
        lastSeen = nil
        othersSeen = [:]
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
                worker.dropped(agent, app: attachment.appName, title: attachment.windowTitle)
            }
            return
        }
        if firstRead, !WindowAccess.isOn {
            if !saidSwitch {
                saidSwitch = true
                worker.cannotRead(agent, String(format: AgentStrings.needsSwitch, WindowAccess.paneName))
            }
            return
        }
        if OffLimits.match([attachment.appName, attachment.bundleId, attachment.windowTitle ?? ""].joined(separator: " ")) != nil { return refuse() }
        Self.queue.async { [weak self] in
            let snapshot = WindowSnapshot.read(attachment)
            DispatchQueue.main.async { self?.seen(snapshot) }
        }
        guard !firstRead, Date().timeIntervalSince(othersRead) >= Self.othersEvery else { return }
        othersRead = Date()
        Self.queue.async { [weak self] in
            let others = WindowSnapshot.others(of: attachment)
            DispatchQueue.main.async { self?.checkedOthers(others) }
        }
    }

    private func checkedOthers(_ others: [(number: Int, title: String?, text: String)]) {
        guard !stopped else { return }
        for window in others {
            defer { othersSeen[window.number] = window.text }
            guard let before = othersSeen[window.number], before != window.text else { continue }
            let old = Set(before.split(separator: "\n"))
            let added = window.text.split(separator: "\n").filter { !old.contains($0) }.joined(separator: "\n")
            guard !added.isEmpty else { continue }
            let (agent, worker) = (agent, worker)
            Task { @MainActor in
                guard await !PrivateCheck.suspects(added) else { return }
                worker.windowChanged(agent, title: window.title, window: window.number, newText: added)
            }
        }
    }

    // One look can catch a window between two states, so a second look five seconds later decides.
    private func windowIsGone() -> Bool {
        guard !WindowSnapshot.stillOpen(attachment), WindowSnapshot.presence(attachment) == .closed else {
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

    // Landing makes no model call and shows no bubble. The agent reads for itself in the run that follows.
    private func seen(_ snapshot: WindowSnapshot?) {
        guard !stopped else { return }
        guard let snapshot else {
            guard WindowSnapshot.stillOpen(attachment) else { return }
            if !wasUnreadable {
                wasUnreadable = true
                WindowReader.log.append(WindowReader.Entry(agent: agent.name, event: "unreadable", app: attachment.appName, title: attachment.windowTitle))
            }
            land(title: attachment.windowTitle)
            return
        }
        if firstRead || wasUnreadable { worker.canRead(agent) }
        wasUnreadable = false
        if OffLimits.match(snapshot.title) != nil { return refuse() }
        blocked = false
        if snapshot != lastSeen {
            if !firstRead, let lastSeen {
                let before = Set(lastSeen.text.split(separator: "\n"))
                let added = snapshot.text.split(separator: "\n").filter { !before.contains($0) }.joined(separator: "\n")
                let (agent, worker, number) = (agent, worker, attachment.windowNumber)
                Task { @MainActor in
                    guard await !PrivateCheck.suspects(added) else { return }
                    worker.windowChanged(agent, title: snapshot.title, window: number, newText: OffLimits.redact(added).text)
                }
            }
            folder.saveUnderstanding(String(OffLimits.redact(snapshot.text).text.prefix(1500)), app: attachment.appName, title: snapshot.title)
            lastSeen = snapshot
        }
        land(title: snapshot.title)
    }

    private func land(title: String?) {
        guard firstRead else { return }
        firstRead = false
        WindowReader.log.append(WindowReader.Entry(agent: agent.name, event: "landed", app: attachment.appName, title: title))
        worker.dropped(agent, app: attachment.appName, title: title)
    }
}
