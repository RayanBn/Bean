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

    private let build: () async -> Inventory
    private let opener: ContentOpener
    private let client: ModelClient

    init(build: @escaping () async -> Inventory, opener: ContentOpener, client: ModelClient) {
        self.build = build
        self.opener = opener
        self.client = client
    }

    /// A title that changes with the content proves the content is back; a title that is just the app's name says nothing, so Bean looks.
    static func titleSaysContent(_ saved: SavedWindow) -> Bool {
        !saved.facts.title.isEmpty && saved.facts.title != saved.facts.appName
    }

    static let commandKey = "running_command"

    /// A window that ran a command comes back without it, so its title differs: a new window of the app is enough, and the command follows.
    private func verify(_ saved: SavedWindow, excluding: Set<CGWindowID>, before: Set<CGWindowID>) async -> Bool {
        let live = await build()
        if saved.content?.handle[Self.commandKey] != nil {
            return windows(of: saved.facts.bundleId, in: live).contains { !before.contains($0.window.id) }
        }
        if Self.titleSaysContent(saved) { return match(saved, in: live, excluding: excluding) != nil }
        return await screenShows(saved.content?.description ?? saved.facts.title)
    }

    func screenShows(_ description: String) async -> Bool {
        guard let jpeg = try? await ScreenCapture.mainDisplayJPEG() else { return false }
        let answer: [String: Any] = ["type": "function", "function": ["name": "answer", "description": "Say whether the screen shows it.",
                                                                       "parameters": ["type": "object", "properties": ["shown": ["type": "boolean"]], "required": ["shown"]]]]
        let messages: [[String: Any]] = [["role": "user", "content": [["type": "text", "text": "Does the frontmost window on this screen show exactly this: \(description)? Call answer."], ModelClient.image(jpeg)]]]
        guard let call = try? await client.chat(messages, tools: [answer]).toolCalls.first,
              let args = try? JSONSerialization.jsonObject(with: call.arguments) as? [String: Any] else { return false }
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
            var target = Self.titleSaysContent(saved) ? match(saved, in: live, excluding: claimed) : nil
            if target != nil {
                result = .alreadyOpen
            } else {
                let before = Set(windows(of: saved.facts.bundleId, in: live).map(\.window.id))
                let taken = claimed
                let reopened = await opener.reopen(saved) { [self] in await verify(saved, excluding: taken, before: before) }
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
                (placed, full) = await place(window, pid: app.pid, like: saved)
                if result == .reopened, let command = saved.content?.handle[Self.commandKey] { note = await relaunch(command, in: saved.facts.bundleId) }
            }
            outcomes.append(RestoreOutcome(app: saved.facts.appName, title: saved.facts.title, result: result, placed: placed, fullScreen: full,
                                           seconds: (Date().timeIntervalSince(started) * 10).rounded() / 10, note: note))
            done(index, result != .failed)
        }
        return outcomes
    }

    /// The user's click on the resume card is the confirmation; a command the denylist flags is typed but never sent.
    private func relaunch(_ command: String, in bundleId: String) async -> String {
        let dangerous = HiddenShell.requiresConsent(command)
        let typed = await Channels.shared.perform(Step(intent: "Type the command that ran here", kind: .typeText, text: command, bundleId: bundleId), mode: .takeover)
        guard typed.ok, !dangerous else { return dangerous ? "typed `\(command)` without running it: it needs the user's own go" : "could not type `\(command)`: \(typed.note)" }
        let sent = await Channels.shared.perform(Step(intent: "Run it", kind: .keys, text: "return", bundleId: bundleId), mode: .takeover)
        return sent.ok ? "relaunched `\(command)`" : "typed `\(command)`, Return failed: \(sent.note)"
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
        guard let element = WindowPlacer.element(for: window.id, pid: pid) else { return (false, false) }
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
