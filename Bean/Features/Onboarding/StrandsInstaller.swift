import AppKit
import CryptoKit

// Strands reads window titles on this Mac before any reach the cloud. Every step can run again: a quit picks up where it stopped, and the weights only count once complete.
@MainActor
final class StrandsInstaller: ObservableObject {
    enum Stage: Equatable {
        case idle
        case running(Double)
        case ready
        case failed(String)
        case unsupported
    }

    static let shared = StrandsInstaller()
    private nonisolated static let uvVersion = "0.12.8"
    private nonisolated static let uvHash = "8ce083658dbff20143607ca7af8e0c1d64b6fd7bf03a5cdcb62bf3d47d991b5f"
    private nonisolated static let repositories = ["Qwen/Qwen3.5-2B-Base", StrandsServer.checkpoint]
    private nonisolated static let fullSize = 5.7e9
    private nonisolated static let needsFree = 7_000_000_000

    @Published private(set) var stage = Stage.idle
    var onReady: (() -> Void)?
    var onFailed: (() -> Void)?
    private var didNotStart = false
    private var current: Process?
    private var work: Task<Void, Never>?
    private var progress: Timer?

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.current?.terminate() }
        }
    }

    var isWanted: Bool { BeanSettings.shared.effectiveDecidesOnThisMac }

    func start() {
        guard isWanted, work == nil else { return }
        if StrandsServer.isAvailable, !didNotStart {
            stage = .ready
            return
        }
        #if !arch(arm64)
        stage = .unsupported
        return
        #else
        stage = .running(0)
        progress = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task.detached {
                let done = Self.done
                await MainActor.run {
                    if case .running = self?.stage { self?.stage = .running(done) }
                }
            }
        }
        work = Task { @MainActor [weak self] in await self?.install() }
        #endif
    }

    private func install() async {
        defer {
            progress?.invalidate()
            progress = nil
            work = nil
        }
        do {
            try FileManager.default.createDirectory(atPath: StrandsServer.home, withIntermediateDirectories: true)
            if !StrandsServer.isAvailable {
                try checkDisk()
                try await installUV()
                try await installPython()
                try await installWeights()
            }
            didNotStart = await StrandsDecider.score(state: "ready") == nil
            guard !didNotStart else { throw Failure.plain("The check did not start.") }
            stage = .ready
            onReady?()
        } catch Failure.plain(let line) {
            fail(line)
        } catch {
            fail("The download stopped. Check the network.")
        }
    }

    private func fail(_ line: String) {
        stage = .failed(line)
        onFailed?()
    }

    private enum Failure: Error { case plain(String) }

    private func checkDisk() throws {
        let values = try URL(fileURLWithPath: StrandsServer.home).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let free = values.volumeAvailableCapacityForImportantUsage ?? 0
        if free + Int64(Self.sizeOnDisk) < Self.needsFree { throw Failure.plain("It needs 7 GB free on this Mac.") }
    }

    private nonisolated static var uv: String { StrandsServer.home + "/tools/uv" }

    private func installUV() async throws {
        guard !FileManager.default.isExecutableFile(atPath: Self.uv) else { return }
        guard let url = URL(string: "https://github.com/astral-sh/uv/releases/download/\(Self.uvVersion)/uv-aarch64-apple-darwin.tar.gz") else { return }
        let (file, _) = try await URLSession.shared.download(from: url)
        let hash = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        guard hash == Self.uvHash else { throw Failure.plain("The download did not match what Bean expected.") }
        let tools = StrandsServer.home + "/tools"
        try FileManager.default.createDirectory(atPath: tools, withIntermediateDirectories: true)
        try await run("/usr/bin/tar", ["-xzf", file.path, "--strip-components", "1", "-C", tools])
    }

    private func installPython() async throws {
        let venv = StrandsServer.home + "/venv"
        if !FileManager.default.isExecutableFile(atPath: venv + "/bin/python") {
            try await run(Self.uv, ["venv", "--python", "3.12", "--python-preference", "only-managed", venv])
        }
        guard !FileManager.default.fileExists(atPath: venv + "/bin/strands-decider"), let lock = Bundle.main.path(forResource: "strands-lock", ofType: "txt") else { return }
        try await run(Self.uv, ["pip", "install", "--python", venv + "/bin/python", "--requirements", lock])
        try? FileManager.default.removeItem(atPath: StrandsServer.home + "/uv-cache")
    }

    private func installWeights() async throws {
        let partial = StrandsServer.home + "/hf-partial"
        for repository in Self.repositories {
            try await run(StrandsServer.home + "/venv/bin/python", [StrandsServer.home + "/venv/bin/hf", "download", repository], hfHome: partial)
        }
        let final = StrandsServer.home + "/hf"
        try? FileManager.default.removeItem(atPath: final)
        try FileManager.default.moveItem(atPath: partial, toPath: final)
    }

    private func run(_ tool: String, _ arguments: [String], hfHome: String? = nil) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.qualityOfService = .utility
        var environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "UV_PYTHON_INSTALL_DIR": StrandsServer.home + "/python", "UV_CACHE_DIR": StrandsServer.home + "/uv-cache", "HF_HUB_DISABLE_TELEMETRY": "1"]
        if let hfHome { environment["HF_HOME"] = hfHome }
        process.environment = environment
        let log = JSONLog.directory.appendingPathComponent("strands-install.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: log)
        handle.seekToEndOfFile()
        process.standardOutput = handle
        process.standardError = handle
        current = process
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        current = nil
        try? handle.close()
        guard status == 0 else { throw Failure.plain("The download stopped. Check the network.") }
    }

    private nonisolated static var sizeOnDisk: Double {
        guard let files = FileManager.default.enumerator(at: URL(fileURLWithPath: StrandsServer.home), includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total = 0
        for case let file as URL in files { total += (try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0 }
        return Double(total)
    }

    private nonisolated static var done: Double { min(0.99, sizeOnDisk / fullSize) }
}
