import AppKit

struct RestoreOutcome: Codable {
    enum Result: String, Codable { case alreadyOpen, reopened, appOnly, failed }
    let app: String
    let title: String
    let result: Result
    let placed: Bool
    let fullScreen: Bool
    let seconds: Double
    var note: String?
}

/// Puts a project's windows back: reopens what is missing through the learned recipes, then places each window where it was.
final class Resumer {
    static let newWindowWait: TimeInterval = 12
    static let windowBudget: Duration = .seconds(300)

    /// Panels and popups can carry the same title as the content (a quick-look browser window, for one); only a standard window counts as restored.
    static func isStandard(_ window: CGWindowID, pid: pid_t) -> Bool {
        guard let element = WindowPlacer.element(for: window, pid: pid) else { return true }
        return Accessibility.attribute(kAXSubroleAttribute, of: element) as? String == kAXStandardWindowSubrole
    }

    /// A model call or a step that never answers must not hold the other windows back. A task group would wait for the cancelled child, so this races two loose tasks.
    static func within<T>(_ budget: Duration, _ work: @escaping () async -> T) async -> T? {
        let settled = NSLock()
        var done = false
        func claim() -> Bool { settled.withLock { defer { done = true }; return !done } }
        return await withCheckedContinuation { continuation in
            let task = Task { let value = await work(); if claim() { continuation.resume(returning: value) } }
            Task {
                try? await Task.sleep(for: budget)
                if claim() {
                    task.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
    }


    private let build: () async -> Inventory
    private let client: ModelClient
    private let log = JSONLog(name: "resume")

    init(build: @escaping () async -> Inventory, client: ModelClient) {
        self.build = build
        self.client = client
    }

    /// A title that changes with the content proves the content is back; a title that is just the app's name says nothing, so Bean looks.
    static func titleSaysContent(_ saved: SavedWindow) -> Bool {
        !saved.facts.title.isEmpty && saved.facts.title != saved.facts.appName
    }

    static let commandKey = "running_command"

    /// A window that ran a command comes back without it, so its title differs: a new window of the app is enough, and the command follows.
    private func verify(_ saved: SavedWindow, excluding: Set<CGWindowID>, before: Set<CGWindowID>) async -> Bool {
        let ranCommand = Self.runnable(saved) != nil
        guard ranCommand || Self.titleSaysContent(saved) else {
            try? await Task.sleep(for: .seconds(3))
            return await screenShows(saved.content?.description ?? saved.facts.title)
        }
        let deadline = Date().addingTimeInterval(Self.newWindowWait)
        repeat {
            let live = await build()
            if ranCommand {
                if windows(of: saved.facts.bundleId, in: live).contains(where: { !before.contains($0.window.id) }) { return true }
            } else if let (window, app) = match(saved, in: live, excluding: excluding), Self.isStandard(window.id, pid: app.pid) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(400))
        } while Date() < deadline
        return false
    }

    func screenShows(_ description: String) async -> Bool {
        guard let jpeg = try? await ScreenCapture.mainDisplayJPEG() else { return false }
        let answer: [String: Any] = ["type": "function", "function": ["name": "answer", "description": "Say whether the screen shows it.",
                                                                       "parameters": ["type": "object", "properties": ["shown": ["type": "boolean"]], "required": ["shown"]]]]
        let messages: [[String: Any]] = [["role": "user", "content": [["type": "text", "text": "Is the main content of the frontmost window on this screen this: \(description)? A long title may be cut short on screen, and side panels may be open; judge what the main area shows. Call answer."], ModelClient.image(jpeg)]]]
        let reply = try? await client.chat(messages, tools: [answer])
        guard let call = reply?.toolCalls.first, let args = try? JSONSerialization.jsonObject(with: call.arguments) as? [String: Any] else {
            log.append(["vision": description, "answer": "no tool call: \(reply?.text ?? "request failed")"])
            return false
        }
        log.append(["vision": description, "answer": "\(args["shown"] ?? "?")"])
        return args["shown"] as? Bool ?? false
    }

    func restore(_ project: ProjectState, progress: @escaping (Int, Int, String) -> Void = { _, _, _ in }, done: @escaping (Int, Bool) -> Void = { _, _ in }) async -> [RestoreOutcome] {
        let wanted = project.toRestore().sorted { ($0.fullScreen ? 1 : 0, $0.lastFocused ?? .distantPast) < ($1.fullScreen ? 1 : 0, $1.lastFocused ?? .distantPast) }
        var outcomes: [RestoreOutcome] = []
        var claimed: Set<CGWindowID> = []
        for (index, saved) in wanted.enumerated() {
            let started = Date()
            progress(index, wanted.count, saved.facts.appName)
            var result = RestoreOutcome.Result.failed
            var live = await build()
            var before = Set(windows(of: saved.facts.bundleId, in: live).map(\.window.id))
            var target = Self.titleSaysContent(saved) ? match(saved, in: live, excluding: claimed).flatMap { Self.isStandard($0.0.id, pid: $0.1.pid) ? $0 : nil } : nil
            if target != nil {
                result = .alreadyOpen
            } else {
                before = Set(windows(of: saved.facts.bundleId, in: live).map(\.window.id))
                let taken = claimed
                let checkBefore = before
                let reopened = await Self.within(Self.windowBudget) { [self] in
                    await WindowRecipes.reopen(saved) { await self.verify(saved, excluding: taken, before: checkBefore) }
                } ?? false
                let deadline = Date().addingTimeInterval(Self.newWindowWait)
                repeat {
                    try? await Task.sleep(for: .milliseconds(300))
                    live = await build()
                    target = match(saved, in: live, excluding: claimed) ?? windows(of: saved.facts.bundleId, in: live).first { !before.contains($0.window.id) && !claimed.contains($0.window.id) }
                } while target == nil && Date() < deadline
                if target == nil, reopened { target = windows(of: saved.facts.bundleId, in: live).first { !claimed.contains($0.window.id) } }
                result = target == nil ? .failed : (reopened ? .reopened : .appOnly)
            }
            var placed = false, full = false
            var note: String?
            if let (window, app) = target {
                claimed.insert(window.id)
                if result == .reopened { await closeLeftovers(of: saved.facts.bundleId, keeping: window.id, existing: before) }
                (placed, full) = await place(window, pid: app.pid, like: saved)
                if result == .reopened, let command = Self.runnable(saved) { note = await relaunch(command, in: window.id, of: app) }
            }
            outcomes.append(RestoreOutcome(app: saved.facts.appName, title: saved.facts.title, result: result, placed: placed, fullScreen: full,
                                           seconds: (Date().timeIntervalSince(started) * 10).rounded() / 10, note: note))
            done(index, result != .failed)
        }
        return outcomes
    }

    /// Learning tries really act, so a failed try can leave its own window behind.
    private func closeLeftovers(of bundleId: String, keeping kept: CGWindowID, existing: Set<CGWindowID>) async {
        for (window, app) in windows(of: bundleId, in: await build()) where window.id != kept && !existing.contains(window.id) {
            guard let element = WindowPlacer.element(for: window.id, pid: app.pid),
                  let button = Accessibility.attribute(kAXCloseButtonAttribute, of: element) else { continue }
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
    }

    /// Only a process that really ran on the window's own terminal is relaunched, with its real program and arguments: a command named in a handle
    /// but not running on a terminal (an app that merely shows one) is never typed anywhere.
    static func runnable(_ saved: SavedWindow) -> String? {
        guard saved.content?.handle[commandKey] != nil, let tty = saved.content?.handle["tty"].map({ ($0 as NSString).lastPathComponent }) else { return nil }
        let shells: Set<String> = ["login", "zsh", "bash", "sh", "fish"]
        let ran = saved.facts.processes.last { $0.tty == tty && !shells.contains(($0.executable as NSString?)?.lastPathComponent ?? "") }
        return ran?.commandLine
    }


    /// The user's click on the resume card is the confirmation; a command the denylist flags is typed but never sent.
    private func relaunch(_ command: String, in window: CGWindowID, of app: InventoryApp) async -> String {
        guard let bundleId = app.bundleId, let element = WindowPlacer.element(for: window, pid: app.pid) else { return "could not reach the window to relaunch `\(command)`" }
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: app.pid)?.activate()
        try? await Task.sleep(for: .milliseconds(400))
        guard Accessibility.focusedWindow(of: app.pid).flatMap(WindowServer.windowId(of:)) == window else { return "the window did not take focus: `\(command)` not typed" }
        let dangerous = HiddenShell.requiresConsent(command)
        let typed = await Channels.shared.perform(Step(intent: "Type the command that ran here", kind: .typeText, text: command, bundleId: bundleId), mode: .takeover)
        guard typed.ok, !dangerous else { return dangerous ? "typed `\(command)` without running it: it needs the user's own go" : "could not type `\(command)`: \(typed.note)" }
        let before = Set(ProcessTable().descendants(of: app.pid).map(\.pid))
        let sent = await Channels.shared.perform(Step(intent: "Run it", kind: .keys, text: "return", bundleId: bundleId), mode: .takeover)
        try? await Task.sleep(for: .seconds(1.5))
        let started = ProcessTable().descendants(of: app.pid).contains { !before.contains($0.pid) }
        return sent.ok && started ? "relaunched `\(command)`" : "typed `\(command)`, but no process started"
    }


    private func windows(of bundleId: String, in inventory: Inventory) -> [(window: InventoryWindow, app: InventoryApp)] {
        inventory.apps.filter { $0.bundleId == bundleId }.flatMap { app in app.windows.map { ($0, app) } }
    }

    private func match(_ saved: SavedWindow, in inventory: Inventory, excluding: Set<CGWindowID>) -> (InventoryWindow, InventoryApp)? {
        let candidates = windows(of: saved.facts.bundleId, in: inventory).filter { !excluding.contains($0.window.id) }
        if let same = candidates.first(where: { $0.window.title == saved.facts.title && !saved.facts.title.isEmpty }) { return same }
        let words = Set(saved.facts.title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { $0.lowercased() }.filter { $0.count >= 3 })
        return candidates.first { candidate in
            let other = Set(candidate.window.title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { $0.lowercased() })
            return !words.isEmpty && words.isSubset(of: other)
        }
    }

    private func place(_ window: InventoryWindow, pid: pid_t, like saved: SavedWindow) async -> (placed: Bool, fullScreen: Bool) {
        var found = WindowPlacer.element(for: window.id, pid: pid)
        for _ in 0 ..< 4 where found == nil {
            try? await Task.sleep(for: .seconds(1))
            found = WindowPlacer.element(for: window.id, pid: pid)
        }
        guard let element = found else { return (false, false) }
        if saved.fullScreen {
            if WindowPlacer.isFullScreen(element) { return (true, true) }
            let entered = await WindowPlacer.enterFullScreen(element, window: window.id)
            return (entered, entered)
        }
        if WindowPlacer.isFullScreen(element) {
            WindowPlacer.exitFullScreen(element)
            try? await Task.sleep(for: .seconds(1.5))
        }
        if let space = saved.space, space != window.space, WindowPlacer.spaces().contains(where: { $0.id == space && !$0.fullScreen }) {
            _ = await WindowPlacer.move(window.id, toSpace: space)
        }
        WindowPlacer.setFrame(element, pid: pid, to: saved.frame)
        let landed = WindowPlacer.frame(of: element) ?? .zero
        let close = abs(landed.minX - saved.frame.minX) <= saved.frame.width * 0.03 && abs(landed.minY - saved.frame.minY) <= saved.frame.height * 0.03
            && abs(landed.width - saved.frame.width) <= saved.frame.width * 0.05 && abs(landed.height - saved.frame.height) <= saved.frame.height * 0.05
        return (close, false)
    }
}
