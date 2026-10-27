import AppKit
import Carbon.HIToolbox

struct StepOutcome: Codable {
    let intent: String
    let ok: Bool
    let channel: String?
    let effect: AXDiff?
    let learnedPost: Check?
    let note: String
    let milliseconds: Int
}

final class Channels {
    enum Mode: String, Codable { case background, takeover }

    static let shared = Channels()
    static let settle: TimeInterval = 0.6
    static let userMovedWithin: TimeInterval = 0.5
    static let postProbe: TimeInterval = 1.5

    var locate: ((Step, Data) async -> CGPoint?)?
    private var depth = 0
    var isActing: Bool { depth > 0 }
    static let maxEach = 20
    private var injectedAt = Date.distantPast
    private let log = JSONLog(name: "channels")

    @MainActor
    func perform(_ step: Step, mode: Mode) async -> StepOutcome {
        let started = Date()
        depth += 1
        let outcome = await attempt(step, mode: mode)
        depth -= 1
        let result = StepOutcome(intent: step.intent, ok: outcome.ok, channel: outcome.channel, effect: outcome.effect, learnedPost: step.post == nil && outcome.ok ? outcome.effect?.learnedCheck : nil,
                                 note: outcome.note, milliseconds: Int(Date().timeIntervalSince(started) * 1000))
        log.append(result)
        return result
    }

    private struct Attempt {
        var ok: Bool
        var channel: String?
        var effect: AXDiff?
        var note: String
    }

    @MainActor
    private func attempt(_ step: Step, mode: Mode) async -> Attempt {
        for _ in 0..<10 where userIsActing() != nil { try? await Task.sleep(nanoseconds: 500_000_000) }
        if let problem = userIsActing() { return Attempt(ok: false, note: problem) }
        switch step.kind {
        case .shell:
            if Plan(steps: [PlanStep(title: "", command: step.text ?? "")], appBundleId: "shell").blockedCommand != nil {
                return Attempt(ok: false, channel: "shell", note: "blocked: \(step.text ?? "")")
            }
            let result = await Task.detached { HiddenShell.run(step.text ?? "", in: step.cwd, timeout: step.timeout) }.value
            return await verified(step, Attempt(ok: result.exit == 0 && !result.timedOut, channel: "shell", note: "exit \(result.exit): \(result.output.suffix(300))"))
        case .terminal:
            let output = VisibleTerminal.start(step.text ?? "", in: step.cwd)
            return Attempt(ok: output.ok, channel: "terminal", note: output.text)
        case .open:
            return await observed(step) { self.open(step) }
        case .script:
            guard let bundleId = step.bundleId else { return Attempt(ok: false, note: "a script step needs the bundleId of the app it tells") }
            if step.runsCode, HiddenShell.requiresConsent(step.text ?? "") {
                return Attempt(ok: false, channel: "script", note: "refused: this script runs code that deletes data or reaches outside the Mac")
            }
            return await observed(step) { Scripting.run(step.text ?? "", tellingApp: bundleId) }
        case .wait:
            guard let check = step.check else { return Attempt(ok: false, note: "a wait step needs a check") }
            let ok = await poll(check, seconds: step.seconds ?? 8)
            return Attempt(ok: ok, channel: "wait", note: ok ? "check passed" : "check still failing after \(step.seconds ?? 8) s")
        case .menu:
            return await observed(step) { self.menu(step) }
        case .window:
            return await observed(step) { await self.window(step) }
        case .keys:
            guard mode == .takeover else { return Attempt(ok: false, note: "keys need takeover mode") }
            return await observed(step) { await self.keys(step) }
        case .press, .setValue, .typeText:
            return await interact(step, mode: mode)
        case .each:
            return await each(step, mode: mode)
        }
    }

    @MainActor
    private func each(_ step: Step, mode: Mode) async -> Attempt {
        guard var target = step.target, let steps = step.steps, !steps.isEmpty else { return Attempt(ok: false, note: "each needs a target and steps") }
        if target.bundleId == nil { target.bundleId = step.bundleId }
        var done = Set(step.excluding ?? [])
        var labels: [String] = []
        for _ in 0..<Self.maxEach {
            if mode == .takeover, let app = AXTree.app(target.bundleId) { _ = await bringToFront(app) }
            guard let node = AXTree.all(target).first(where: { !done.contains($0.text ?? "") }), let label = node.text else { break }
            done.insert(label)
            for inner in steps {
                let outcome = await perform(inner.filled(["item": label]), mode: mode)
                if !outcome.ok {
                    return Attempt(ok: false, channel: "each", note: "stopped at \"\(label)\", step \"\(inner.intent)\": \(outcome.note); done before: \(labels.joined(separator: ", "))")
                }
            }
            labels.append(label)
        }
        return Attempt(ok: true, channel: "each", note: labels.isEmpty ? "no matching element left" : "done for \(labels.count): \(labels.joined(separator: ", "))")
    }

    @MainActor
    private func observed(_ step: Step, _ act: () async -> (ok: Bool, channel: String, note: String)) async -> Attempt {
        let before = AXSnapshot.capture(step.app)
        let result = await act()
        guard result.ok else { return Attempt(ok: false, channel: result.channel, note: result.note) }
        try? await Task.sleep(nanoseconds: UInt64(Self.settle * 1e9))
        let effect = before.flatMap { before in AXSnapshot.capture(step.app).map(before.diff) }
        return await verified(step, Attempt(ok: true, channel: result.channel, effect: effect, note: result.note))
    }

    @MainActor
    private func verified(_ step: Step, _ attempt: Attempt) async -> Attempt {
        guard attempt.ok, let post = step.post else { return attempt }
        var result = attempt
        result.ok = await poll(post, seconds: step.seconds ?? 8)
        if !result.ok { result.note += "; postcondition failed: \(post.kind.rawValue) \(post.value ?? post.target?.summary ?? "")" }
        return result
    }

    @MainActor
    private func interact(_ step: Step, mode: Mode) async -> Attempt {
        if step.target == nil, step.kind == .typeText { return await typeIntoFocus(step, mode: mode) }
        var target = step.target ?? Locator()
        if target.bundleId == nil { target.bundleId = step.bundleId }
        if mode == .takeover, let app = AXTree.app(target.bundleId) { _ = await bringToFront(app) }
        let node: AXNode, app: NSRunningApplication
        switch AXTree.resolve(target) {
        case let .missing(why):
            return mode == .takeover && !step.isIrreversible ? await byVision(step, why: why) : Attempt(ok: false, note: why)
        case let .found(found, owner):
            node = found
            app = owner
        }
        let before = AXSnapshot.capture(app.bundleIdentifier)
        var tried: [String] = []
        for channel in channels(for: step, node: node, mode: mode) {
            tried.append(channel)
            guard await act(channel, step, node, app) else { continue }
            try? await Task.sleep(nanoseconds: UInt64(Self.settle * 1e9))
            let effect = before.flatMap { before in AXSnapshot.capture(app.bundleIdentifier).map(before.diff) }
            let changed = !(effect?.isEmpty ?? true)
            if let post = step.post {
                if await poll(post, seconds: Self.postProbe) {
                    return Attempt(ok: true, channel: channel, effect: effect, note: "tried \(tried.joined(separator: ", "))")
                }
                if changed || step.isIrreversible {
                    return await verified(step, Attempt(ok: true, channel: channel, effect: effect, note: "tried \(tried.joined(separator: ", "))"))
                }
                continue
            }
            if changed {
                return Attempt(ok: true, channel: channel, effect: effect, note: "tried \(tried.joined(separator: ", "))")
            }
            if step.isIrreversible { return Attempt(ok: false, channel: channel, effect: effect, note: "no visible effect; irreversible step, not retried") }
        }
        return Attempt(ok: false, note: step.post == nil ? "no channel changed anything (tried \(tried.joined(separator: ", ")))" : "postcondition never met (tried \(tried.joined(separator: ", ")))")
    }

    private func channels(for step: Step, node: AXNode, mode: Mode) -> [String] {
        switch step.kind {
        case .press:
            var list: [String] = []
            if node.actions.contains(kAXPressAction) { list.append("axAction") }
            if mode == .takeover { list += ["focusKey", "click"] }
            return list
        case .setValue:
            return ["axValue"] + (mode == .takeover ? ["focusType"] : [])
        default:
            return mode == .takeover ? ["focusType"] : []
        }
    }

    @MainActor
    private func act(_ channel: String, _ step: Step, _ node: AXNode, _ app: NSRunningApplication) async -> Bool {
        switch channel {
        case "axAction":
            return AXUIElementPerformAction(node.element, kAXPressAction as CFString) == .success
        case "axValue":
            var settable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(node.element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue else { return false }
            return AXUIElementSetAttributeValue(node.element, kAXValueAttribute as CFString, (step.text ?? "") as CFString) == .success
        case "focusKey":
            guard await bringToFront(app) else { return false }
            AXUIElementSetAttributeValue(node.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            try? await Task.sleep(nanoseconds: 100_000_000)
            post(key: CGKeyCode(kVK_Space), flags: [], to: app.processIdentifier)
            return true
        case "focusType":
            guard await bringToFront(app), !IsSecureEventInputEnabled() else { return false }
            AXUIElementSetAttributeValue(node.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            try? await Task.sleep(nanoseconds: 100_000_000)
            if step.kind == .setValue { post(key: CGKeyCode(kVK_ANSI_A), flags: .maskCommand, to: app.processIdentifier) }
            await type(step.text ?? "", to: app.processIdentifier)
            return true
        case "click":
            guard let frame = node.frame, await bringToFront(app) else { return false }
            click(at: CGPoint(x: frame.midX, y: frame.midY))
            return true
        default:
            return false
        }
    }

    @MainActor
    private func typeIntoFocus(_ step: Step, mode: Mode) async -> Attempt {
        guard mode == .takeover else { return Attempt(ok: false, note: "typing needs takeover mode") }
        guard let app = AXTree.app(step.bundleId), await bringToFront(app) else { return Attempt(ok: false, note: "the app did not come to the front") }
        guard !IsSecureEventInputEnabled() else { return Attempt(ok: false, note: "secure input is on: Bean does not type into password fields") }
        return await observed(step) {
            await self.type(step.text ?? "", to: app.processIdentifier)
            return (true, "type", "typed \(step.text?.count ?? 0) characters")
        }
    }

    @MainActor
    private func byVision(_ step: Step, why: String) async -> Attempt {
        guard let locate, let app = AXTree.app(step.app), await bringToFront(app),
              let jpeg = try? await ScreenCapture.mainDisplayJPEG(), let point = await locate(step, jpeg) else {
            return Attempt(ok: false, note: "\(why); vision found nothing")
        }
        return await observed(step) {
            self.click(at: point)
            if step.kind != .press, let text = step.text { await self.type(text, to: app.processIdentifier) }
            return (true, "vision", "\(why); clicked \(Int(point.x)),\(Int(point.y)) from the screenshot")
        }
    }

    private func open(_ step: Step) -> (ok: Bool, channel: String, note: String) {
        var arguments: [String] = []
        if let bundleId = step.bundleId { arguments += ["-b", bundleId] }
        if let url = step.url { arguments.append(url) } else if let path = step.path { arguments.append((path as NSString).expandingTildeInPath) }
        guard !arguments.isEmpty else { return (false, "open", "nothing to open") }
        let output = HiddenShell.capture("/usr/bin/open", arguments, timeout: 10)
        return (output != nil, "open", output == nil ? "open failed: \(arguments.joined(separator: " "))" : "opened \(arguments.last ?? "")")
    }

    private func menu(_ step: Step) -> (ok: Bool, channel: String, note: String) {
        guard let app = AXTree.app(step.bundleId), let path = step.menu, !path.isEmpty,
              var element = Accessibility.attribute(kAXMenuBarAttribute, of: AXUIElementCreateApplication(app.processIdentifier)).map({ $0 as! AXUIElement }) else {
            return (false, "menu", "no menu bar")
        }
        for (depth, title) in path.enumerated() {
            let children = (Accessibility.attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? [])
                .flatMap { child -> [AXUIElement] in
                    (Accessibility.attribute(kAXRoleAttribute, of: child) as? String) == kAXMenuRole ? (Accessibility.attribute(kAXChildrenAttribute, of: child) as? [AXUIElement] ?? []) : [child]
                }
            guard let next = children.first(where: { (Accessibility.attribute(kAXTitleAttribute, of: $0) as? String)?.caseInsensitiveCompare(title) == .orderedSame }) else {
                return (false, "menu", "no menu item \"\(title)\"")
            }
            if depth == path.count - 1 { return (AXUIElementPerformAction(next, kAXPressAction as CFString) == .success, "menu", "pressed \(path.joined(separator: " › "))") }
            AXUIElementPerformAction(next, kAXPressAction as CFString)
            element = next
        }
        return (false, "menu", "empty menu path")
    }

    private func window(_ step: Step) async -> (ok: Bool, channel: String, note: String) {
        guard let app = AXTree.app(step.app), let id = WindowPlacer.find(pid: app.processIdentifier, title: step.target?.window),
              let element = WindowPlacer.element(for: id, pid: app.processIdentifier) else {
            return (false, "window", "no such window for \(step.app ?? "the frontmost app")")
        }
        var done: [String] = [], failed: [String] = []
        if let space = step.space { await WindowPlacer.move(id, toSpace: space) ? done.append("moved to Space \(space)") : failed.append("move to Space \(space)") }
        if let frame = step.frame?.rect { WindowPlacer.setFrame(element, pid: app.processIdentifier, to: frame) ? done.append("framed") : failed.append("frame") }
        if let fullScreen = step.fullScreen, fullScreen != WindowPlacer.isFullScreen(element) {
            if fullScreen {
                await WindowPlacer.enterFullScreen(element, window: id) ? done.append("full screen") : failed.append("full screen")
            } else {
                WindowPlacer.exitFullScreen(element)
                done.append("left full screen")
            }
        }
        return (failed.isEmpty, "window", failed.isEmpty ? done.joined(separator: ", ") : "failed: \(failed.joined(separator: ", "))")
    }

    @MainActor
    private func keys(_ step: Step) async -> (ok: Bool, channel: String, note: String) {
        guard let app = AXTree.app(step.bundleId), await bringToFront(app), let combo = step.text, let (key, flags) = Self.parse(combo) else {
            return (false, "keys", "could not send \(step.text ?? "")")
        }
        post(key: key, flags: flags, to: app.processIdentifier)
        return (true, "keys", "sent \(combo)")
    }

    @MainActor
    func poll(_ check: Check, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if await Checks.passes(check) { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        } while Date() < deadline
        return false
    }

    private func userIsActing() -> String? {
        let since = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
        let ours = Date().timeIntervalSince(injectedAt)
        return since < Self.userMovedWithin && ours > 1 ? "the user kept using the Mac for 5 s: Bean stopped" : nil
    }

    @MainActor
    private func bringToFront(_ app: NSRunningApplication) async -> Bool {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return true }
        app.activate()
        for _ in 0..<30 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    private func post(key: CGKeyCode, flags: CGEventFlags, to pid: pid_t) {
        injectedAt = Date()
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.postToPid(pid)
        }
    }

    @MainActor
    private func type(_ text: String, to pid: pid_t) async {
        injectedAt = Date()
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        for start in stride(from: 0, to: units.count, by: 16) {
            let chunk = Array(units[start..<min(start + 16, units.count)])
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event?.postToPid(pid)
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    private func click(at point: CGPoint) {
        injectedAt = Date()
        let back = CGEvent(source: nil)?.location ?? point
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        CGWarpMouseCursorPosition(back)
    }

    static func parse(_ combo: String) -> (CGKeyCode, CGEventFlags)? {
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for part in combo.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: key = keyCodes[part]
            }
        }
        return key.map { ($0, flags) }
    }

    private static let keyCodes: [String: CGKeyCode] = {
        var map: [String: CGKeyCode] = [
            "return": CGKeyCode(kVK_Return), "enter": CGKeyCode(kVK_Return), "tab": CGKeyCode(kVK_Tab), "space": CGKeyCode(kVK_Space),
            "escape": CGKeyCode(kVK_Escape), "esc": CGKeyCode(kVK_Escape), "delete": CGKeyCode(kVK_Delete), "backspace": CGKeyCode(kVK_Delete),
            "left": CGKeyCode(kVK_LeftArrow), "right": CGKeyCode(kVK_RightArrow), "up": CGKeyCode(kVK_UpArrow), "down": CGKeyCode(kVK_DownArrow),
            "home": CGKeyCode(kVK_Home), "end": CGKeyCode(kVK_End), "pageup": CGKeyCode(kVK_PageUp), "pagedown": CGKeyCode(kVK_PageDown),
            ",": CGKeyCode(kVK_ANSI_Comma), ".": CGKeyCode(kVK_ANSI_Period), "/": CGKeyCode(kVK_ANSI_Slash), "[": CGKeyCode(kVK_ANSI_LeftBracket), "]": CGKeyCode(kVK_ANSI_RightBracket),
        ]
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E), ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H),
            ("i", kVK_ANSI_I), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P),
            ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T), ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X),
            ("y", kVK_ANSI_Y), ("z", kVK_ANSI_Z), ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3), ("4", kVK_ANSI_4), ("5", kVK_ANSI_5),
            ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
        ]
        for (name, code) in letters { map[name] = CGKeyCode(code) }
        return map
    }()
}

extension Step {
    var timeout: Double { seconds ?? 15 }
}
