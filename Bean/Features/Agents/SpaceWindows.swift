import AppKit
import ApplicationServices
import Vision

// Reaches one exact window of an app, on any Space. AppKit gives a window its Accessibility id only when it first hands that window out, and it hands out only the current Space's windows and the main one. So a window never seen here has no id to find until something makes it main.
enum SpaceWindows {
    private typealias CreateFromToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private typealias WindowNumber = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias Connection = @convention(c) () -> Int32
    private typealias ActiveSpace = @convention(c) (Int32) -> UInt64
    private typealias SpacesOfWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private typealias Capture = @convention(c) (Int32, UnsafeMutablePointer<UInt32>, UInt32, UInt32) -> Unmanaged<CFArray>?

    private static let accessibility = UnsafeMutableRawPointer(bitPattern: -2)
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let create = dlsym(accessibility, "_AXUIElementCreateWithRemoteToken").map { unsafeBitCast($0, to: CreateFromToken.self) }
    private static let windowNumber = dlsym(accessibility, "_AXUIElementGetWindow").map { unsafeBitCast($0, to: WindowNumber.self) }
    private static let connection = dlsym(skyLight, "SLSMainConnectionID").map { unsafeBitCast($0, to: Connection.self)() }
    private static let activeSpace = dlsym(skyLight, "SLSGetActiveSpace").map { unsafeBitCast($0, to: ActiveSpace.self) }
    private static let spacesOfWindows = dlsym(skyLight, "SLSCopySpacesForWindows").map { unsafeBitCast($0, to: SpacesOfWindows.self) }
    private static let setWindowLocation = dlsym(accessibility, "CGEventSetWindowLocation").map { unsafeBitCast($0, to: SetWindowLocation.self) }
    private static let capture = dlsym(skyLight, "SLSHWCaptureWindowList").map { unsafeBitCast($0, to: Capture.self) }

    private struct App {
        var elements: [Int: AXUIElement] = [:]
        var nextId: UInt64 = 0
        var ceiling = sweepStart
        var sweptAll: Date?
        var nudged: [Int: Date] = [:]
        var activatesOnNudge = false
    }

    private static let lock = NSLock()
    private static let nudging = NSLock()
    private static let keeping = DispatchQueue(label: "dev.rayanbn.Bean.spaces.keep", qos: .utility)
    private static var apps: [Int32: App] = [:]
    private static var woken = Set<Int32>()
    private static let sweepBudget: TimeInterval = 0.25
    private static let sweepStart: UInt64 = 1 << 14
    private static let sweepCeiling: UInt64 = 1 << 20
    private static let sweepRest: TimeInterval = 30
    private static let nudgeRest: TimeInterval = 30
    // With no location inside the window set on the event, AppKit puts it in the title bar, and clicks close together there zoom the window. This is outside any window and any display.
    private static let nowhere = CGPoint(x: -20000, y: -20000)

    static func number(of element: AXUIElement) -> Int? {
        var window: CGWindowID = 0
        guard let windowNumber, windowNumber(element, &window) == .success, window != 0 else { return nil }
        return Int(window)
    }

    // A window ordered out, minimized or in a background tab is in no Space.
    static func spaces(of window: Int) -> [UInt64] {
        guard let connection, let spacesOfWindows else { return [] }
        return (spacesOfWindows(connection, 7, [window] as CFArray)?.takeRetainedValue() as? [UInt64]) ?? []
    }

    static func isOnAnotherSpace(_ window: Int) -> Bool {
        guard let connection, let activeSpace else { return false }
        let spaces = spaces(of: window)
        return !spaces.isEmpty && !spaces.contains(activeSpace(connection))
    }

    // Every window of the app known by now, with no search: what it lists, plus what was reached before.
    static func known(of pid: Int32) -> [Int: AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let listed = (Accessibility.attribute(kAXWindowsAttribute, of: app) as? [AXUIElement]) ?? []
        let single = [kAXMainWindowAttribute, kAXFocusedWindowAttribute].compactMap { Accessibility.attribute($0, of: app).map { $0 as! AXUIElement } }
        for element in listed + single { adopt(element, pid: pid) }
        let held = lock.withLock { apps[pid]?.elements ?? [:] }
        let alive = held.filter { number(of: $0.value) == $0.key }
        if alive.count != held.count { lock.withLock { apps[pid]?.elements = alive } }
        return alive
    }

    // An element taken while its window is on the current Space stays good on any other, with nothing posted to the app. So Bean takes them each time the person moves.
    static func keepUp() {
        let center = NSWorkspace.shared.notificationCenter
        let take = { keeping.async { for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && !app.isHidden { _ = known(of: app.processIdentifier) } } }
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: nil) { _ in take() }
        }
        take()
    }

    static func element(of window: Int, pid: Int32, mayNudge: Bool) -> AXUIElement? {
        if let found = known(of: pid)[window] { return found }
        if let found = sweep(for: window, pid: pid) { return found }
        return mayNudge ? nudge(window, pid: pid) : nil
    }

    private static func adopt(_ element: AXUIElement, pid: Int32) {
        guard let window = number(of: element) else { return }
        AXUIElementSetMessagingTimeout(element, 0.5)
        lock.withLock { apps[pid, default: App()].elements[window] = element }
    }

    // Ids grow without a ceiling, so time is the bound and each search goes on from where the last one stopped. A new window takes the next low id, so a pass comes back to the start and then reaches further.
    private static func sweep(for window: Int, pid: Int32) -> AXUIElement? {
        guard let create, let token = CFDataCreateMutable(nil, 20), let bytes = CFDataGetMutableBytePtr(token) else { return nil }
        let state = lock.withLock { apps[pid] }
        if let rested = state?.sweptAll, Date().timeIntervalSince(rested) < sweepRest { return nil }
        CFDataSetLength(token, 20)
        memset(bytes, 0, 20)
        withUnsafeBytes(of: pid) { memcpy(bytes, $0.baseAddress, 4) }
        withUnsafeBytes(of: Int32(0x636f636f)) { memcpy(bytes + 8, $0.baseAddress, 4) }
        var id = state?.nextId ?? 0
        let ceiling = state?.ceiling ?? sweepStart
        var found: AXUIElement?
        let deadline = Date().addingTimeInterval(sweepBudget)
        while found == nil, id < ceiling, id & 63 != 0 || Date() < deadline {
            withUnsafeBytes(of: id) { memcpy(bytes + 12, $0.baseAddress, 8) }
            id += 1
            guard let element = create(token)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(element, 0.05)
            guard let seen = number(of: element), Accessibility.attribute(kAXRoleAttribute, of: element) as? String == kAXWindowRole else { continue }
            adopt(element, pid: pid)
            if seen == window { found = element }
        }
        lock.withLock {
            apps[pid, default: App()].nextId = id < ceiling ? id : 0
            guard id >= ceiling else { return }
            apps[pid, default: App()].ceiling = min(ceiling * 4, sweepCeiling)
            if ceiling == sweepCeiling { apps[pid, default: App()].sweptAll = Date() }
        }
        return found
    }

    // Reaching a window must never bring its app to the front. These are the apps measured to take the posted mouse-down with no activation, at 1 kHz, while typing went on elsewhere. An app not measured gets no event: its window comes from the other routes, or says it cannot be reached. Add one only after the same measure.
    private static let takesItQuietly: Set<String> = [
        "com.apple.TextEdit", "com.apple.Terminal", "com.apple.Safari", "com.apple.calculator", "com.apple.Preview", "com.apple.Dictionary", "com.apple.Chess",
        "com.apple.ActivityMonitor", "com.apple.ScriptEditor2", "com.apple.systempreferences", "com.apple.iWork.Numbers", "com.apple.iWork.Pages", "com.apple.iWork.Keynote",
        "com.apple.freeform", "com.apple.finder", "com.apple.Notes", "com.apple.reminders", "com.apple.iCal", "com.apple.Maps",
        "com.microsoft.VSCode", "company.thebrowser.Browser", "com.hnc.Discord", "com.automattic.beeper.desktop", "com.openai.codex", "dev.warp.Warp-Stable", "ai.elementlabs.lmstudio", "com.google.antigravity",
    ]

    // A mouse-down posted to the app itself and addressed to the window, at a point outside it and off every display, so it lands on nothing. AppKit makes that window main and answers for it. The app stays in the background, the Space does not change, and the mouse does not move. The window that was main gets the same, so the person comes back to the app as they left it.
    private static func nudge(_ window: Int, pid: Int32) -> AXUIElement? {
        guard setWindowLocation != nil, let running = NSRunningApplication(processIdentifier: pid), running.bundleIdentifier.map(takesItQuietly.contains) == true, !running.isActive, !running.isHidden, isOnAnotherSpace(window) else { return nil }
        // Never in the person's way: a held button means they are dragging or clicking now.
        guard NSEvent.pressedMouseButtons == 0 else { return nil }
        nudging.lock()
        defer { nudging.unlock() }
        let state = lock.withLock { apps[pid] }
        if state?.activatesOnNudge == true { return nil }
        if let last = state?.nudged[window], Date().timeIntervalSince(last) < nudgeRest { return nil }
        let front = NSWorkspace.shared.frontmostApplication
        lock.withLock { apps[pid, default: App()].nudged[window] = Date() }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let before = Accessibility.attribute(kAXMainWindowAttribute, of: app).flatMap { number(of: $0 as! AXUIElement) }
        guard post(to: window, pid: pid) else { return nil }
        var found: AXUIElement?
        for _ in 0..<8 where found == nil {
            found = [kAXMainWindowAttribute, kAXFocusedWindowAttribute].lazy.compactMap { Accessibility.attribute($0, of: app).map { $0 as! AXUIElement } }.first { number(of: $0) == window }
            if found == nil { usleep(40_000) }
        }
        if let found { adopt(found, pid: pid) }
        if let before, before != window, !running.isActive, NSEvent.pressedMouseButtons == 0 { _ = post(to: before, pid: pid) }
        // Only a net, for an app that changed since it was measured: it never gets another event.
        if running.isActive, front?.processIdentifier != pid {
            lock.withLock { apps[pid, default: App()].activatesOnNudge = true }
            front?.activate()
        }
        return found
    }

    private static func post(to window: Int, pid: Int32) -> Bool {
        let source = CGEventSource(stateID: .privateState)
        for kind in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: source, mouseType: kind, mouseCursorPosition: nowhere, mouseButton: .left) else { return false }
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            setWindowLocation?(event, nowhere)
            // AppKit takes the window from this field, which has no public name.
            event.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(window))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window))
            event.postToPid(pid)
            usleep(20_000)
        }
        return true
    }

    // Chromium apps build no tree for a window nobody can see until asked, and then take seconds. Only they accept this attribute, and each needs the wait once.
    static func wake(_ window: AXUIElement, pid: Int32) {
        let accepted = AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
        guard accepted, let number = number(of: window), isOnAnotherSpace(number) else { return }
        let first = lock.withLock { woken.insert(pid).inserted }
        guard first else { return }
        for _ in 0..<8 where treeSize(of: window) < 30 { usleep(700_000) }
    }

    private static func treeSize(of window: AXUIElement) -> Int {
        var stack = [window], seen = 0
        while let element = stack.popLast(), seen < 30 {
            seen += 1
            stack += (Accessibility.attribute(kAXChildrenAttribute, of: element) as? [AXUIElement]) ?? []
        }
        return seen
    }

    // The window's picture, for what cannot answer through Accessibility. It needs Screen Recording, which Bean never asks for here.
    static var picturesWork: Bool { CGPreflightScreenCaptureAccess() && ProcessInfo.processInfo.environment["BEAN_NO_PICTURES"] == nil }

    static func pictureText(of window: Int) -> String? {
        guard picturesWork, let connection, let capture else { return nil }
        var number = UInt32(window)
        guard let image = (capture(connection, &number, 1, 1 << 11 | 1 << 9)?.takeRetainedValue() as? [CGImage])?.first else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
