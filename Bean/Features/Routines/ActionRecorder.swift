import AppKit
import ApplicationServices

final class ActionRecorder {
    var onAction: ((RecordedAction) -> Void)?
    var isPaused: () -> Bool = { false }

    private let queue = DispatchQueue(label: "bean.routines.ax", qos: .utility)
    private let systemWide = AXUIElementCreateSystemWide()
    private var monitors: [Any] = []
    private var pending: RecordedAction?
    private var pendingGeneration = 0
    private var state: (app: String, snapshot: AXSnapshot)?
    private var map: ClickMap?
    private let mapLock = NSLock()
    private var field: (element: AXUIElement, locator: ElementLocator, value: String, window: String?, url: String?)?

    static let actionable: Set<String> = ["AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTab", "AXRow", "AXCell", "AXTextField", "AXTextArea", "AXComboBox", "AXDisclosureTriangle", "AXSegment"]
    private static let editable: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    private static let recordedKeys: Set<UInt16> = [36, 76, 53]

    func start() {
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier != getpid() else { return }
            self.queue.async { _ = self.observe(app) }
        }
        if let mouse = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            guard let self, !self.isPaused(), let point = event.cgEvent?.location else { return }
            self.mouseDown(at: point)
        }) { monitors.append(mouse) }
        if let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, !self.isPaused() else { return }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard flags.contains(.command) || flags.contains(.control) || Self.recordedKeys.contains(event.keyCode) else { return }
            let app = NSWorkspace.shared.frontmostApplication
            let combo = Self.combo(key: event.keyCode, flags: flags, characters: event.charactersIgnoringModifiers)
            self.queue.async { self.pressed(combo: combo, front: app) }
        }) { monitors.append(keys) }
    }

    private var activation: NSObjectProtocol?

    private var refreshGeneration = 0

    func windowChanged(pid: pid_t?) {
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid(), pid == nil || pid == front.processIdentifier else { return }
        queue.async {
            self.refreshGeneration += 1
            let generation = self.refreshGeneration
            self.queue.asyncAfter(deadline: .now() + 0.3) {
                guard generation == self.refreshGeneration, self.pending == nil else { return }
                let fresh = ClickMap.build(front)
                self.mapLock.withLock { self.map = fresh }
            }
        }
    }

    private func mouseDown(at point: CGPoint) {
        guard let action = clicked(at: point, front: NSWorkspace.shared.frontmostApplication) else { return }
        queue.async { self.settle(next: action) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    func observe(_ command: ShellCommand) {
        guard !isPaused() else { return }
        let action = RecordedAction(at: Date(timeIntervalSince1970: command.start), kind: .shell, app: command.bundleId ?? command.term ?? "shell", appName: command.appName, window: command.cwd, url: nil, value: command.cmd)
        queue.async { self.settle(next: action) }
    }

    private func clicked(at point: CGPoint, front: NSRunningApplication?) -> RecordedAction? {
        let mapped = mapLock.withLock { map }.flatMap { map in map.pid == front?.processIdentifier ? map.locator(at: point) : nil }
        let seen = hitTest(at: point, front: front)
        guard let app = front ?? seen?.app, let locator = mapped ?? seen?.locator else { return nil }
        var action = RecordedAction(at: Date(), kind: .press, app: locator.bundleId, appName: app.localizedName, window: Accessibility.focusedWindowTitle(of: app.processIdentifier), url: locator.url, element: locator)
        let sameRole = mapLock.withLock { map }?.items.filter { $0.locator.role == locator.role }
            .sorted { hypot($0.frame.midX - point.x, $0.frame.midY - point.y) < hypot($1.frame.midX - point.x, $1.frame.midY - point.y) }
            .map(\.locator) ?? []
        action.alternatives = ([seen?.locator].compactMap { $0 } + sameRole).filter { $0.label != locator.label }
        return action
    }

    private func hitTest(at point: CGPoint, front: NSRunningApplication?) -> (locator: ElementLocator, app: NSRunningApplication)? {
        var hit: AXUIElement?
        var result = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit)
        if result != .success || hit.map({ AX.pid(of: $0) == getpid() }) ?? true, let front, front.processIdentifier != getpid() {
            let app = AXUIElementCreateApplication(front.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.25)
            result = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit)
        }
        guard result == .success, let hit else { return Self.skip("no element at \(point): \(result.rawValue)") }
        let pid = AX.pid(of: hit)
        guard pid != getpid(), let app = NSRunningApplication(processIdentifier: pid) else { return Self.skip("click on Bean") }
        let element = Self.actionableDescendant(of: hit, at: point) ?? Self.actionableAncestor(of: hit)
        guard let role = AX.string(kAXRoleAttribute, of: element), Self.actionable.contains(role) else { return Self.skip("not a control: \(AX.string(kAXRoleAttribute, of: element) ?? "?")") }
        guard let locator = Self.locator(of: element, app: app) else { return Self.skip("no locator") }
        return (locator, app)
    }

    private static func skip<T>(_ reason: String) -> T? {
        print("routines: hit test missed, \(reason)")
        return nil
    }

    private func pressed(combo: String?, front: NSRunningApplication?) {
        guard let combo, let front, front.processIdentifier != getpid(), let bundle = front.bundleIdentifier else { return }
        let window = Accessibility.focusedWindowTitle(of: front.processIdentifier)
        let action = RecordedAction(at: Date(), kind: .key, app: bundle, appName: front.localizedName, window: window, url: nil, value: combo)
        settle(next: action)
    }

    private func settle(next action: RecordedAction) {
        commitField()
        if pending != nil { finishPending() }
        pending = action
        pendingGeneration += 1
        let generation = pendingGeneration
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.pendingGeneration == generation, self.pending != nil else { return }
            self.finishPending()
            self.watchField()
        }
    }

    private func finishPending() {
        guard var action = pending else { return }
        pending = nil
        action.effect = observe(NSWorkspace.shared.frontmostApplication)
        if let alternatives = action.alternatives, let element = action.element, let effect = action.effect,
           let title = effect.titleAfter, title != effect.titleBefore {
            action.element = ([element] + alternatives).first { candidate in candidate.label.map { !$0.isEmpty && title.contains($0) } ?? false } ?? element
        }
        action.alternatives = nil
        let done = action
        DispatchQueue.main.async { self.onAction?(done) }
    }

    private func observe(_ app: NSRunningApplication?) -> AXDiff? {
        guard let app, app.processIdentifier != getpid(), let bundle = app.bundleIdentifier, let after = Self.pageSnapshot(app) ?? AXSnapshot.capture(bundle) else { return nil }
        let fresh = ClickMap.build(app)
        mapLock.withLock { map = fresh }
        defer { state = (bundle, after) }
        guard let state, state.app == bundle else { return nil }
        return state.snapshot.diff(to: after)
    }

    private static func pageSnapshot(_ app: NSRunningApplication) -> AXSnapshot? {
        guard let window = Accessibility.focusedWindow(of: app.processIdentifier) else { return nil }
        var queue = [window], seen = 0
        while !queue.isEmpty, seen < 3000 {
            let element = queue.removeFirst()
            seen += 1
            if AX.string(kAXRoleAttribute, of: element) == "AXWebArea" {
                let lines = AXTree.nodes(in: element).compactMap { node in node.text.map { "\(node.role) \($0.prefix(120))" } ?? node.url.map { "\(node.role) <\($0)>" } }
                return AXSnapshot(lines: lines, title: AX.string(kAXTitleAttribute, of: window))
            }
            queue += AX.children(of: element)
        }
        return nil
    }

    private func watchField() {
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid(),
              let focused = AX.element(kAXFocusedUIElementAttribute, of: AXUIElementCreateApplication(front.processIdentifier)),
              let role = AX.string(kAXRoleAttribute, of: focused), Self.editable.contains(role),
              let locator = Self.locator(of: focused, app: front) else { field = nil; return }
        field = (focused, locator, AX.string(kAXValueAttribute, of: focused) ?? "", Self.windowTitle(of: focused), locator.url)
    }

    private func commitField() {
        guard let field else { return }
        self.field = nil
        guard let value = AX.string(kAXValueAttribute, of: field.element), value != field.value, !value.isEmpty, !Self.looksSecret(value) else { return }
        var action = RecordedAction(at: Date(), kind: .commit, app: field.locator.bundleId, appName: nil, window: field.window, url: field.url, element: field.locator, value: String(value.prefix(300)))
        action.effect = observe(NSRunningApplication(processIdentifier: AX.pid(of: field.element)))
        let done = action
        DispatchQueue.main.async { self.onAction?(done) }
    }

    private static func actionableDescendant(of element: AXUIElement, at point: CGPoint, depth: Int = 4) -> AXUIElement? {
        guard depth > 0 else { return nil }
        for child in AX.children(of: element).prefix(40) where frame(of: child)?.contains(point) ?? false {
            if let role = AX.string(kAXRoleAttribute, of: child), actionable.contains(role) { return child }
            if let found = actionableDescendant(of: child, at: point, depth: depth - 1) { return found }
        }
        return nil
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = AX.value(kAXPositionAttribute, of: element), let size = AX.value(kAXSizeAttribute, of: element) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    private static func actionableAncestor(of element: AXUIElement) -> AXUIElement {
        var current: AXUIElement? = element
        for _ in 0..<5 {
            guard let candidate = current else { break }
            if let role = AX.string(kAXRoleAttribute, of: candidate), actionable.contains(role) { return candidate }
            current = AX.element(kAXParentAttribute, of: candidate)
        }
        return element
    }

    static func locator(of element: AXUIElement, app: NSRunningApplication) -> ElementLocator? {
        guard let bundle = app.bundleIdentifier, let role = AX.string(kAXRoleAttribute, of: element), role != "AXSecureTextField" else { return nil }
        var path: [String] = [], url: String?, current = AX.element(kAXParentAttribute, of: element)
        while let ancestor = current, path.count < 12 {
            let ancestorRole = AX.string(kAXRoleAttribute, of: ancestor) ?? "?"
            if ancestorRole == "AXWebArea" { url = AX.string("AXURL", of: ancestor); break }
            if ancestorRole == "AXWindow" { break }
            path.append(ancestorRole)
            current = AX.element(kAXParentAttribute, of: ancestor)
        }
        return ElementLocator(bundleId: bundle, role: role, identifier: nonEmpty(AX.string(kAXIdentifierAttribute, of: element)), domId: nonEmpty(AX.string("AXDOMIdentifier", of: element)), label: label(of: element), path: Array(path.prefix(4)), url: url, href: nonEmpty(AX.string(kAXURLAttribute, of: element)))
    }

    static func nonEmpty(_ text: String?) -> String? { text.flatMap { $0.isEmpty ? nil : $0 } }

    static func label(of element: AXUIElement) -> String? {
        for name in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let text = AX.string(name, of: element)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return String(text.prefix(80)) }
        }
        for child in AX.children(of: element).prefix(4) where AX.string(kAXRoleAttribute, of: child) == "AXStaticText" {
            if let text = AX.string(kAXValueAttribute, of: child)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return String(text.prefix(80)) }
        }
        return nil
    }

    private static func windowTitle(of element: AXUIElement) -> String? {
        AX.element(kAXWindowAttribute, of: element).flatMap { AX.string(kAXTitleAttribute, of: $0) }
    }

    private static func looksSecret(_ value: String) -> Bool {
        value.range(of: #"(?i)passw|token|secret|api[_-]?key|\b[A-Za-z0-9_\-]{32,}\b"#, options: .regularExpression) != nil
    }

    private static func combo(key: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> String? {
        let names: [UInt16: String] = [36: "return", 76: "enter", 53: "escape", 48: "tab", 51: "delete", 123: "left", 124: "right", 125: "down", 126: "up"]
        guard let name = names[key] ?? characters?.lowercased().first.map(String.init), !name.isEmpty else { return nil }
        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("alt") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }
        return (parts + [name]).joined(separator: "+")
    }
}
