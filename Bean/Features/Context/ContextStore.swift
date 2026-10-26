import AppKit

final class ContextStore {
    static let recentWindow: TimeInterval = 1800
    private static let home = NSHomeDirectory()
    private static let ignoredPaths = ["/.git/", "/node_modules/", "/DerivedData/", "/build/", "/artifacts/", "/.build/", "/Pods/", "/.next/", "/dist/"]
    private static let excludedRoots = ["Library", ".Trash", ".cache", ".npm", ".claude", ".cursor", ".vscode", ".local"].map { home + "/" + $0 }
    private static let devServers = ["node", "python", "Python", "ruby", "java", "deno", "bun", "postgres", "redis", "mysqld", "com.docke", "llama", "ollama", "php", "uvicorn", "gunicorn", "puma", "beam", "dotnet", "vite", "next", "go", "cargo", "swift"]

    var onAgents: (([AgentSession]) -> Void)?
    var onChange: (() -> Void)?

    private let log: JSONLog
    private let shellLog: URL
    private var sessions: [String: AgentSession] = [:]
    private var commands: [ShellCommand] = []
    private var recentFiles: [String: Date] = [:]
    private var agentEvents: FileEvents?
    private var homeEvents: FileEvents?

    init(log: JSONLog, shellLog: URL) {
        self.log = log
        self.shellLog = shellLog
    }

    var agents: [AgentSession] { sessions.values.sorted { $0.lastActivity > $1.lastActivity } }
    var commandList: [ShellCommand] { commands }
    var recentFileList: [String] {
        let cutoff = Date().addingTimeInterval(-Self.recentWindow)
        return recentFiles.filter { $0.value > cutoff }.sorted { $0.value > $1.value }.prefix(25).map { $0.key.replacingOccurrences(of: Self.home, with: "~") }
    }

    func start() {
        for agent in AgentSessions.all() { sessions[agent.id] = agent }
        commands = ShellWatcher.lastCommands(in: shellLog, count: 20)
        onAgents?(agents)
        agentEvents = FileEvents(paths: [AgentSessions.desktopSessions.path, AgentSessions.transcripts.path], latency: 2) { [weak self] paths in self?.agentFilesChanged(paths) }
        homeEvents = FileEvents(paths: [Self.home], latency: 2, exclude: Self.excludedRoots) { [weak self] paths in self?.homeFilesChanged(paths) }
    }

    func observe(_ command: ShellCommand) {
        commands = Array((commands + [command]).suffix(20))
        onChange?()
    }

    @MainActor
    func picture() async -> MacContext {
        let agents = agents, commands = commands
        let files = recentFileList
        let presence = Presence.current()
        let readsTabs = BeanSettings.shared.readBrowser
        return await Task.detached(priority: .userInitiated) {
            MacContext(
                at: Date(), idleSeconds: IdleClock.seconds().rounded(), apps: WindowReader.apps(), tabs: readsTabs ? TabReader.all() : [],
                agents: agents, commands: commands, recentFiles: files, ports: Self.listeningPorts(), presence: presence
            )
        }.value
    }

    private func agentFilesChanged(_ paths: [String]) {
        var changed = Set<String>()
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if path.hasPrefix(AgentSessions.desktopSessions.path), url.lastPathComponent.hasPrefix("local_"), url.pathExtension == "json" {
                changed.insert(path)
            } else if url.pathExtension == "jsonl" {
                let transcriptId = url.deletingPathExtension().lastPathComponent
                if let id = sessions.values.first(where: { $0.transcriptId == transcriptId })?.id, let file = sessionFile(id) { changed.insert(file.path) }
            }
        }
        guard !changed.isEmpty else { return }
        for path in changed {
            let id = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let before = sessions[id]
            sessions[id] = AgentSessions.session(URL(fileURLWithPath: path))
            if let after = sessions[id], before?.state != after.state || before?.unseen != after.unseen {
                log.append(after)
            }
        }
        onAgents?(agents)
        onChange?()
    }

    private func sessionFile(_ id: String) -> URL? {
        FileManager.default.enumerator(at: AgentSessions.desktopSessions, includingPropertiesForKeys: nil)?
            .lazy.compactMap { $0 as? URL }.first { $0.lastPathComponent == id + ".json" }
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
