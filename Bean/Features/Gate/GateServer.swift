import Foundation

final class GateServer {
    let endpoint: URL
    let modelName: String
    private let binary: String
    private let model: String
    private let port: Int
    private let log: URL
    private let lock = NSLock()
    private var process: Process?

    init(logTo log: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.log = log
        binary = environment["BEAN_LLAMA_SERVER"] ?? "/opt/homebrew/bin/llama-server"
        model = environment["BEAN_GATE_MODEL"] ?? NSString(string: "~/Models/llama32/Llama-3.2-3B-Instruct-Q4_K_M.gguf").expandingTildeInPath
        port = environment["BEAN_GATE_PORT"].flatMap(Int.init) ?? 8089
        endpoint = URL(string: "http://127.0.0.1:\(port)")!
        modelName = URL(fileURLWithPath: model).deletingPathExtension().lastPathComponent
    }

    var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: binary) && FileManager.default.fileExists(atPath: model)
    }

    func startIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard process?.isRunning != true, isAvailable else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-m", model, "-ngl", "99", "--jinja", "-c", "4096", "--host", "127.0.0.1", "--port", String(port)]
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        do {
            try process.run()
            self.process = process
        } catch {
            FileHandle.standardError.write(Data("gate server failed to start: \(error)\n".utf8))
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        process?.terminate()
        process = nil
    }

    func waitUntilReady(timeout: TimeInterval = 60) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let (_, response) = try? await URLSession.shared.data(from: endpoint.appendingPathComponent("health")),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }
}
