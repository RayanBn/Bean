import AppKit

struct WhatBeanSees {
    struct App: Identifiable { let pid: Int32; let name: String; let bundleId: String; let isActive: Bool; let windows: Int; var id: Int32 { pid } }
    struct Window: Identifiable { let number: Int; let app: String; let bundleId: String; let title: String?; let agent: UUID?; var id: Int { number } }
    struct Tab: Identifiable { let app: String; let window: Int; let tab: Int; let title: String; let url: String; var id: String { "\(app) \(window).\(tab)" } }
    struct Focused { let app: String; let window: String?; let text: String; var behindBean = false }
    struct Command: Identifiable { let at: Date; let command: String; let exit: Int; let directory: String; var id: String { "\(at.timeIntervalSince1970) \(command)" } }

    var at = Date()
    var apps: [App] = []
    var windows: [Window] = []
    var tabs: [Tab] = []
    var focused: Focused?
    var commands: [Command] = []
    var hidden = 0
}

final class WhatBeanSeesReader {
    private static let queue = DispatchQueue(label: "dev.rayanbn.Bean.sees", qos: .utility)
    private static let shellLog = JSONLog.directory.appendingPathComponent("shell.jsonl")
    private var timer: DispatchSourceTimer?

    func start(agents: @escaping () -> [Agent], publish: @escaping (WhatBeanSees) -> Void) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: Self.queue)
        timer.schedule(deadline: .now(), repeating: 3)
        timer.setEventHandler { publish(Self.read(agents())) }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    static func read(_ agents: [Agent]) -> WhatBeanSees {
        var sees = WhatBeanSees()
        let open = WindowChannels.open()
        let allowed = open.filter { OffLimits.match("\($0.app) \($0.bundleId) \($0.title ?? "")") == nil }
        sees.hidden = open.count - allowed.count
        let filtered = ProcessInfo.processInfo.environment["BEAN_WINDOW_FILTER"] != nil
        let frontmost = NSWorkspace.shared.frontmostApplication
        let behindBean = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        let front = filtered || behindBean ? allowed.first : frontmost.flatMap { app in allowed.first { $0.pid == app.processIdentifier } }
        let running = filtered ? allowed.compactMap { NSRunningApplication(processIdentifier: $0.pid) } : NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var seenPids = Set<Int32>()
        sees.apps = running.compactMap { app in
            guard seenPids.insert(app.processIdentifier).inserted, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  OffLimits.match("\(app.localizedName ?? "") \(app.bundleIdentifier ?? "")") == nil else { return nil }
            return WhatBeanSees.App(pid: app.processIdentifier, name: app.localizedName ?? "", bundleId: app.bundleIdentifier ?? "", isActive: app.processIdentifier == front?.pid, windows: allowed.filter { $0.pid == app.processIdentifier }.count)
        }
        sees.windows = allowed.map { window in
            WhatBeanSees.Window(number: window.number, app: window.app, bundleId: window.bundleId, title: window.title, agent: agents.first { $0.attachment?.windowNumber == window.number }?.id)
        }
        if let front {
            let text = WindowSnapshot.read(WindowChannels.attachment(for: front))?.text ?? ""
            sees.focused = WhatBeanSees.Focused(app: front.app, window: front.title, text: OffLimits.redact(text).text, behindBean: behindBean)
            sees.tabs = tabs(of: front)
        }
        sees.commands = commands()
        return sees
    }

    private static func tabs(of window: OpenWindow) -> [WhatBeanSees.Tab] {
        guard AppTabs.isBrowser(window.bundleId), AppAutomation.state(of: window.bundleId, ask: false) == .allowed else { return [] }
        let done = DispatchSemaphore(value: 0)
        var text = ""
        Task {
            let outcome = await AppActions.runScript(AppTabs.listScript(app: window.app, bundleId: window.bundleId), timeout: 2)
            if outcome.ok { text = outcome.text }
            done.signal()
        }
        done.wait()
        return text.split(separator: "\n").compactMap { line in
            guard OffLimits.match(String(line)) == nil else { return nil }
            let parts = line.components(separatedBy: " | ")
            let place = parts.first?.split(separator: ".").compactMap { Int($0) } ?? []
            guard parts.count >= 3, place.count == 2 else { return nil }
            return WhatBeanSees.Tab(app: window.app, window: place[0], tab: place[1], title: parts[1], url: parts[2])
        }
    }

    private static func commands() -> [WhatBeanSees.Command] {
        struct Line: Decodable { let cmd: String; let exit: Int; let cwd: String; let end: Double }
        guard let handle = try? FileHandle(forReadingFrom: shellLog) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 20000 ? size - 20000 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return data.split(separator: 0x0A).suffix(40).compactMap { raw in
            guard OffLimits.match(String(decoding: raw, as: UTF8.self)) == nil, let line = try? JSONDecoder().decode(Line.self, from: raw) else { return nil }
            return WhatBeanSees.Command(at: Date(timeIntervalSince1970: line.end), command: OffLimits.redact(line.cmd).text, exit: line.exit, directory: line.cwd)
        }.suffix(20)
    }
}
