import AppKit

struct ProcessTable {
    private var parents: [pid_t: pid_t] = [:]
    private var terminals: [pid_t: UInt32] = [:]
    private var cache: [pid_t: [ProcessFact]] = [:]

    static let none = ProcessTable(empty: true)

    init(empty: Bool = false) {
        guard !empty else { return }
        for pid in ProcessTracker.allPids() {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { continue }
            parents[pid] = pid_t(info.pbi_ppid)
            terminals[pid] = info.e_tdev
        }
    }

    func descendants(of root: pid_t) -> [ProcessFact] {
        var found: [pid_t] = [], frontier: Set<pid_t> = [root]
        while !frontier.isEmpty {
            let next = Set(parents.filter { frontier.contains($0.value) }.keys)
            found += next.sorted()
            frontier = next
        }
        return found.compactMap { pid -> ProcessFact? in
            let args = ProcessTracker.arguments(of: pid)
            guard !args.isEmpty, !WindowFacts.helperMarkers.contains(where: args.contains) else { return nil }
            let device = terminals[pid] ?? UInt32(bitPattern: -1)
            var tty: String?
            if device != UInt32(bitPattern: -1), device != 0, let name = devname(dev_t(bitPattern: device), S_IFCHR) as UnsafeMutablePointer<CChar>? {
                tty = String(cString: name)
            }
            return ProcessFact(pid: pid, tty: tty, cwd: WindowFacts.cwd(of: pid), args: String(args.prefix(240)))
        }
    }
}

struct ProcessFact: Codable, Equatable {
    let pid: pid_t
    let tty: String?
    let cwd: String?
    let args: String
}

/// What Bean can read about any window without knowing its app. The recipe learner turns it into what the window shows.
struct WindowFacts: Codable, Equatable {
    let bundleId: String
    let appPath: String
    let appName: String
    let pid: pid_t
    let windowId: CGWindowID
    let title: String
    let document: String?
    var processes: [ProcessFact]
    var recentFiles: [String]

    static let helperMarkers = ["Helper", "crashpad", "--type="]
    static let recentMinutes = 20
    static let recentLimit = 25

    static func read(window: InventoryWindow, app: InventoryApp, element: AXUIElement?, table: ProcessTable = ProcessTable()) -> WindowFacts? {
        guard let bundleId = app.bundleId, let path = app.path else { return nil }
        let element = element ?? (Accessibility.attribute(kAXWindowsAttribute, of: AXUIElementCreateApplication(app.pid)) as? [AXUIElement])?
            .first { WindowServer.windowId(of: $0) == window.id }
        let document = element.flatMap { Accessibility.attribute(kAXDocumentAttribute, of: $0) as? String }
            .flatMap { URL(string: $0)?.path ?? $0 }
        return WindowFacts(
            bundleId: bundleId, appPath: path, appName: app.name, pid: app.pid, windowId: window.id, title: window.title,
            document: document, processes: table.descendants(of: app.pid), recentFiles: []
        )
    }

    static func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return path.isEmpty ? nil : path
    }

    /// Files an app wrote lately often say what it shows (ids, paths, focus times). Matched by app name, since the writer is unknown without Endpoint Security.
    static func recentlyWritten(by appName: String, bundleId: String) -> [String] {
        let key = appName.lowercased().split(separator: " ").first.map(String.init) ?? appName.lowercased()
        let home = NSHomeDirectory()
        let roots = ["\(home)/Library/Application Support", "\(home)/Library/Containers/\(bundleId)", "\(home)/.\(key)", "\(home)/.config/\(key)"]
            .filter { FileManager.default.fileExists(atPath: $0) }
        guard !roots.isEmpty else { return [] }
        let quoted = roots.map { "'\($0)'" }.joined(separator: " ")
        let command = "find \(quoted) -maxdepth 7 -type f -mmin -\(recentMinutes) -not -path '*Cache*' -not -path '*/leveldb/*' -not -path '*IndexedDB*' -not -name '*.log' -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | grep -i -- '\(key)' | head -\(recentLimit)"
        return HiddenShell.run(command, timeout: 4).output.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") }
    }
}
