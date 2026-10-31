import AppKit
import os

@MainActor
final class StrandsServer {
    static let shared = StrandsServer()
    private nonisolated static let environment = ProcessInfo.processInfo.environment
    private nonisolated static let home = environment["BEAN_STRANDS_HOME"] ?? NSString(string: "~/Models/strands-decider").expandingTildeInPath
    private nonisolated static let checkpoint = "StrandsAgents/strands-decider-2B-qwen3.5-v1-2610"
    private nonisolated static var python: String { home + "/venv/bin/python" }
    private nonisolated static var command: String { home + "/venv/bin/strands-decider" }
    private nonisolated static var weights: String { home + "/hf/hub/models--StrandsAgents--strands-decider-2B-qwen3.5-v1-2610" }
    private static let idleLimit = environment["BEAN_STRANDS_IDLE"].flatMap(TimeInterval.init) ?? 300
    private static let startLimit: TimeInterval = 45

    nonisolated static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: python) && FileManager.default.fileExists(atPath: command) && FileManager.default.fileExists(atPath: weights)
    }

    private let port = Int.random(in: 49152...65000)
    private var endpoint: URL { URL(string: "http://127.0.0.1:\(port)")! }
    private var process: Process?
    private var lifeline: Pipe?
    private var idleStop: DispatchWorkItem?

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func ready() async -> URL? {
        guard Self.isAvailable else { return nil }
        keepAlive()
        if process?.isRunning == true, await healthy() { return endpoint }
        if process?.isRunning != true { start() }
        let deadline = Date().addingTimeInterval(Self.startLimit)
        while Date() < deadline, process?.isRunning == true {
            if await healthy() { return endpoint }
            try? await Task.sleep(for: .milliseconds(300))
        }
        stop()
        return nil
    }

    private func healthy() async -> Bool {
        var request = URLRequest(url: endpoint.appendingPathComponent("health"))
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func start() {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The shell outlives Bean only until its stdin closes, so even a crash of Bean stops the server.
        process.arguments = ["-c", "\"$1\" \"$2\" serve \"$3\" --device mlx --host 127.0.0.1 --port \"$4\" & server=$!; trap 'kill $server' TERM; read _; kill $server",
                             "strands", Self.python, Self.command, Self.checkpoint, String(port)]
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
            "HF_HOME": Self.home + "/hf",
            "HF_HUB_OFFLINE": "1",
        ]
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        self.process = process
        lifeline = pipe
    }

    private func keepAlive() {
        idleStop?.cancel()
        let stop = DispatchWorkItem { [weak self] in self?.stop() }
        idleStop = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleLimit, execute: stop)
    }

    func stop() {
        idleStop?.cancel()
        idleStop = nil
        try? lifeline?.fileHandleForWriting.close()
        lifeline = nil
        process?.terminate()
        process = nil
    }
}

struct StrandsDecider: HelpDecider {
    static let quietAtOrBelow = 0.47
    private static let question = "Does something new here need work toward the mission now, that has not already been done?"
    private static let counter = OSAllocatedUnfairLock(initialState: (quiet: 0, passed: 0))
    let fallback: HelpDecider

    func decide(_ situation: HelpSituation) async throws -> HelpDecision {
        let started = Date()
        guard let score = await Self.score(situation) else { return try await fallback.decide(situation) }
        let quiet = score <= Self.quietAtOrBelow
        let count = Self.counter.withLock { (value: inout (quiet: Int, passed: Int)) -> (quiet: Int, passed: Int) in
            if quiet { value.quiet += 1 } else { value.passed += 1 }
            return value
        }
        AgentWorker.log.append(AgentWorker.Entry(agent: situation.agent.name, event: quiet ? "strandsQuiet" : "strandsPassed",
                                                 detail: String(format: "%.3f in %d ms, since launch %d quiet, %d passed on to Muse Spark", score, Int(Date().timeIntervalSince(started) * 1000), count.quiet, count.passed)))
        if quiet { return HelpDecision(help: false, what: "Nothing there needs action now.") }
        return try await fallback.decide(situation)
    }

    static func state(mission: String, goals: String?, trigger: String, seen: String, journal: [String]) -> String {
        let done = journal.isEmpty ? "empty" : String(journal.joined(separator: "\n").suffix(600))
        return "Mission: \(mission)\(goals.map { "\nGoals: \($0.prefix(500))" } ?? "")\nWhat happened: \(trigger.prefix(1000))\nWhat is there now:\n\(seen.prefix(2500))\nJournal: \(done)"
    }

    static func score(_ situation: HelpSituation) async -> Double? {
        await score(state: state(mission: situation.mission.mission, goals: situation.goals, trigger: situation.trigger, seen: situation.observation, journal: situation.journal))
    }

    static func score(state: String) async -> Double? {
        guard let endpoint = await StrandsServer.shared.ready() else { return nil }
        let body: [String: Any] = ["state": state, "questions": ["act": ["type": "noul", "instructions": question]]]
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/systemone"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let answers = json["answers"] as? [String: Any], let act = answers["act"] as? [String: Any] else { return nil }
        return act["noul"] as? Double
    }
}
