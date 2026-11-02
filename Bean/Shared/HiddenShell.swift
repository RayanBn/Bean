import Foundation

struct ShellResult: Codable {
    let command: String
    let exit: Int32
    let output: String
    let timedOut: Bool
    let seconds: Double
    var reason: String? = nil
}

enum HiddenShell {
    static let outputLimit = 6000
    private static let running = NSLock()
    private static var processes: Set<Process> = []

    static func terminateAll() {
        running.lock()
        let all = processes
        running.unlock()
        for process in all where process.isRunning { kill(-process.processIdentifier, SIGTERM); process.terminate() }
    }

    static func run(_ command: String, in directory: String? = nil, timeout: TimeInterval = 15) -> ShellResult {
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: directory.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? NSHomeDirectory())
        var environment = ProcessInfo.processInfo.environment
        environment["BEAN_HIDDEN_SHELL"] = "1"
        environment["GIT_PAGER"] = "cat"
        environment["PAGER"] = "cat"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else {
            return ShellResult(command: command, exit: -1, output: "could not start zsh", timedOut: false, seconds: 0)
        }
        running.lock()
        processes.insert(process)
        running.unlock()
        defer {
            running.lock()
            processes.remove(process)
            running.unlock()
        }
        var timedOut = false
        let killer = DispatchWorkItem { if process.isRunning { timedOut = true; process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        var output = String(decoding: data, as: UTF8.self)
        if output.count > outputLimit { output = String(output.prefix(outputLimit / 2)) + "\n…\n" + String(output.suffix(outputLimit / 2)) }
        return ShellResult(command: command, exit: process.terminationStatus, output: output, timedOut: timedOut, seconds: (Date().timeIntervalSince(started) * 10).rounded() / 10)
    }

    static func capture(_ executable: String, _ arguments: [String], timeout: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
