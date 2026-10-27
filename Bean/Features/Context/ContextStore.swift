import AppKit

final class ContextStore {
    static let recentWindow: TimeInterval = 1800
    private static let home = NSHomeDirectory()
    private static let ignoredPaths = ["/.git/", "/node_modules/", "/DerivedData/", "/build/", "/artifacts/", "/.build/", "/Pods/", "/.next/", "/dist/"]
    private static var excludedRoots: [String] {
        let dotFolders = ((try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []).filter { $0.hasPrefix(".") }
        return (["Library"] + dotFolders).map { home + "/" + $0 }
    }
    private static let devServers = ["node", "python", "Python", "ruby", "java", "deno", "bun", "postgres", "redis", "mysqld", "com.docke", "llama", "ollama", "php", "uvicorn", "gunicorn", "puma", "beam", "dotnet", "vite", "next", "go", "cargo", "swift"]

    var onChange: (() -> Void)?

    private let log: JSONLog
    private let shellLog: URL
    private let watches = Watches(log: JSONLog(name: "activities"))
    private var commands: [ShellCommand] = []
    private var recentFiles: [String: Date] = [:]
    private var homeEvents: FileEvents?

    init(log: JSONLog, shellLog: URL) {
        self.log = log
        self.shellLog = shellLog
    }

    var activities: [Activity] { watches.all }
    var onActivities: (([Activity]) -> Void)? {
        get { watches.onChange }
        set { watches.onChange = newValue }
    }
    var commandList: [ShellCommand] { commands }
    var recentFileList: [String] {
        let cutoff = Date().addingTimeInterval(-Self.recentWindow)
        return recentFiles.filter { $0.value > cutoff }.sorted { $0.value > $1.value }.prefix(25).map { $0.key.replacingOccurrences(of: Self.home, with: "~") }
    }

    func start() {
        commands = ShellWatcher.lastCommands(in: shellLog, count: 20)
        watches.start()
        homeEvents = FileEvents(paths: [Self.home], latency: 2, exclude: Self.excludedRoots) { [weak self] paths in self?.homeFilesChanged(paths) }
    }

    func observe(_ command: ShellCommand) {
        commands = Array((commands + [command]).suffix(20))
        onChange?()
    }

    @MainActor
    func picture() async -> MacContext {
        let activities = activities, commands = commands
        let files = recentFileList
        let presence = Presence.current()
        let readsTabs = BeanSettings.shared.readBrowser
        return await Task.detached(priority: .userInitiated) {
            MacContext(
                at: Date(), idleSeconds: IdleClock.seconds().rounded(), apps: WindowReader.apps(), tabs: readsTabs ? TabReader.all() : [],
                activities: activities, commands: commands, recentFiles: files, ports: Self.listeningPorts(), presence: presence
            )
        }.value
    }

    private func homeFilesChanged(_ paths: [String]) {
        let now = Date()
        for path in paths where !Self.ignoredPaths.contains(where: path.contains) && !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
            recentFiles[path] = now
        }
        let cutoff = now.addingTimeInterval(-Self.recentWindow)
        recentFiles = recentFiles.filter { $0.value > cutoff }
        onChange?()
    }

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
