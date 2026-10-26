import AppKit

final class ContextWatcher {
    static let interval: TimeInterval = 20
    static let slowInterval: TimeInterval = 60

    var onContext: ((MacContext) -> Void)?
    private(set) var current: MacContext?

    private let log: JSONLog
    private let shellLog: URL
    private let queue = DispatchQueue(label: "bean.context", qos: .utility)
    private var timer: Timer?
    private var slowAt = Date.distantPast
    private var tabs: [BrowserTab] = []
    private var recentFiles: [String] = []
    private var ports: [ListeningPort] = []
    private var lastLogged: String?
    private var building = false

    init(log: JSONLog, shellLog: URL) {
        self.log = log
        self.shellLog = shellLog
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in self?.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        guard !building else { return }
        building = true
        let presence = Presence.current()
        queue.async { [self] in
            let context = build(presence: presence)
            DispatchQueue.main.async {
                self.building = false
                self.current = context
                self.record(context)
                self.onContext?(context)
            }
        }
    }

    func build(presence: PresenceState?) -> MacContext {
        if Date().timeIntervalSince(slowAt) >= Self.slowInterval {
            slowAt = Date()
            tabs = BeanSettings.shared.readBrowser ? TabReader.all() : []
            recentFiles = Self.recentFiles()
            ports = Self.listeningPorts()
        }
        return MacContext(
            at: Date(), idleSeconds: SignalCollector.idleSeconds().rounded(), apps: WindowReader.apps(), tabs: tabs,
            agents: AgentSessions.all(), commands: recentCommands(), recentFiles: recentFiles, ports: ports, presence: presence
        )
    }

    private func record(_ context: MacContext) {
        struct Entry: Encodable {
            let at: Date
            let frontmost: String?
            let window: String?
            let apps: Int
            let windows: Int
            let tabs: Int
            let agents: [String]
            let summaryChars: Int
        }
        let agents = context.agents.prefix(8).map { "\($0.title): \($0.state.rawValue)\($0.needsUser && $0.unseen ? " (unseen)" : "")" }
        let key = [context.frontmost?.name ?? "", context.focusedWindow?.title ?? "", "\(context.tabs.count)"].joined(separator: "|") + agents.joined()
        guard key != lastLogged else { return }
        lastLogged = key
        log.append(Entry(
            at: context.at, frontmost: context.frontmost?.name, window: context.focusedWindow?.title, apps: context.apps.count,
            windows: context.apps.reduce(0) { $0 + $1.windows.count }, tabs: context.tabs.count, agents: agents, summaryChars: context.summary().count
        ))
    }

    private func recentCommands() -> [ShellCommand] {
        guard let handle = try? FileHandle(forReadingFrom: shellLog) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 20000 ? size - 20000 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return data.split(separator: 0x0A).suffix(20).compactMap { try? JSONDecoder().decode(ShellCommand.self, from: $0) }
    }

    private static let ignoredPaths = ["/Library/", "/.git/", "/node_modules/", "/DerivedData/", "/build/", "/artifacts/", "/.Trash/", "/.cache/", "/.claude/", "/.npm/", "/Caches/", "/.cursor/", "/.vscode/"]

    static func recentFiles() -> [String] {
        let home = NSHomeDirectory()
        let found = HiddenShell.capture("/usr/bin/mdfind", ["-onlyin", home, "kMDItemFSContentChangeDate >= $time.now(-1800) && kMDItemContentTypeTree != public.folder"], timeout: 5) ?? ""
        return found.split(separator: "\n").map(String.init)
            .filter { path in !ignoredPaths.contains { path.contains($0) } && !URL(fileURLWithPath: path).lastPathComponent.hasPrefix(".") }
            .prefix(25)
            .map { $0.replacingOccurrences(of: home, with: "~") }
    }

    private static let devServers = ["node", "python", "Python", "ruby", "java", "deno", "bun", "postgres", "redis", "mysqld", "com.docke", "llama", "ollama", "php", "uvicorn", "gunicorn", "puma", "beam", "dotnet", "vite", "next", "go", "cargo", "swift"]

    static func listeningPorts() -> [ListeningPort] {
        let output = HiddenShell.capture("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-u", NSUserName()], timeout: 4) ?? ""
        var seen = Set<Int>()
        return output.split(separator: "\n").dropFirst().compactMap { line in
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 9, devServers.contains(where: { columns[0].hasPrefix($0) }), let port = columns[8].split(separator: ":").last.flatMap({ Int($0) }), seen.insert(port).inserted else { return nil }
            return ListeningPort(process: String(columns[0]), port: port)
        }
    }
}
