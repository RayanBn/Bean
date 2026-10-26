import Darwin
import Foundation

struct TrackedProcess: Codable, Equatable {
    let pid: pid_t
    let parent: pid_t
    let name: String
    let path: String
    let arguments: String
    let startedAt: Date
}

final class ProcessTracker {
    static let scanInterval: TimeInterval = 3
    private static let ignoredPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/", "/Applications/Xcode.app/"]
    private static let ignoredNames: Set<String> = ["ps", "lsof", "osascript", "login", "mdworker_shared", "zsh", "bash", "sh", "git", "sleep", "cat", "grep", "sample", "top", "perl", "sysctl", "head", "tail", "jq", "sed", "awk"]

    var onEvent: ((InventoryEvent) -> Void)?
    private(set) var processes: [pid_t: TrackedProcess] = [:]

    private let queue = DispatchQueue(label: "bean.processes", qos: .utility)
    private var known = Set<pid_t>()
    private var timer: DispatchSourceTimer?
    private var exits: [pid_t: DispatchSourceProcess] = [:]
    private let uid = getuid()

    func start() {
        queue.async { [self] in
            known = Set(Self.allPids())
            for pid in known { if let process = describe(pid) { watch(process) } }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.scanInterval, repeating: Self.scanInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.scan() }
        timer.resume()
        self.timer = timer
    }

    func current(_ reply: @escaping ([TrackedProcess]) -> Void) {
        queue.async { [self] in reply(Array(processes.values)) }
    }

    private func scan() {
        let now = Set(Self.allPids())
        for pid in now.subtracting(known) {
            guard let process = describe(pid) else { continue }
            watch(process)
            onEvent?(InventoryEvent(at: Date(), event: "processStarted", app: process.name, detail: process.path, pid: pid))
        }
        known = now
    }

    private func watch(_ process: TrackedProcess) {
        processes[process.pid] = process
        let source = DispatchSource.makeProcessSource(identifier: process.pid, eventMask: [.exit, .exec], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if source.data.contains(.exit) {
                source.cancel()
                exits[process.pid] = nil
                processes[process.pid] = nil
                onEvent?(InventoryEvent(at: Date(), event: "processExited", app: process.name, detail: process.path, pid: process.pid))
            } else if let updated = describe(process.pid) {
                processes[process.pid] = updated
                onEvent?(InventoryEvent(at: Date(), event: "processExec", app: updated.name, detail: updated.path, pid: process.pid))
            }
        }
        source.resume()
        exits[process.pid] = source
    }

    private func describe(_ pid: pid_t) -> TrackedProcess? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0, info.pbi_uid == uid, info.pbi_ppid != getpid() else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard !path.contains(".app/"), !path.contains("CoreSimulator"), !Self.ignoredPrefixes.contains(where: path.hasPrefix), !Self.ignoredNames.contains(name) else { return nil }
        return TrackedProcess(pid: pid, parent: pid_t(info.pbi_ppid), name: name, path: path, arguments: Self.arguments(of: pid), startedAt: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)))
    }

    static func arguments(of pid: pid_t) -> String {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return "" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return "" }
        let count = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var parts: [String] = [], index = 4
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        while parts.count < count, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            parts.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return String(parts.dropFirst().joined(separator: " ").prefix(300))
    }

    static func allPids() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(filled, 0))))
    }
}
