import Foundation

struct GateDecision: Codable {
    let at: Date
    let trigger: Trigger.Kind
    let app: String?
    let errorLine: String?
    let score: Double?
    let stepIn: Bool
    let threshold: Double
    let latencyMs: Int
    let model: String
    let failure: String?
}

final class Gate {
    static let system = """
    You are the gate of Bean, a discreet assistant that lives in the Mac notch. You get one event about what the user is doing. Decide whether Bean should interrupt the user right now to help.
    Say yes only when the user is likely stuck and Bean can clearly help: the same error has stayed on screen for minutes, tests keep failing for minutes, or the user is searching the web for an error message.
    Say no for normal work: switching apps, reading, browsing, writing code, chatting, a meeting, time away from the Mac, an error that just appeared (give the user time to read it), and output that mentions errors without anything failing.
    An unneeded interruption is worse than a missed one. Answer with one word: yes or no.
    """

    var onDecision: ((GateDecision, Trigger) -> Void)?

    let threshold: Double
    private let server: GateServer
    private let log: JSONLog

    init(server: GateServer, log: JSONLog, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.server = server
        self.log = log
        threshold = environment["BEAN_GATE_THRESHOLD"].flatMap(Double.init) ?? 0.65
    }

    func judge(_ trigger: Trigger) {
        Task {
            let decision = await decide(trigger)
            await MainActor.run { self.onDecision?(decision, trigger) }
        }
    }

    func decide(_ trigger: Trigger) async -> GateDecision {
        let started = Date()
        var score: Double?
        var failure: String?
        do {
            score = try await Self.score(from: requestCompletion(for: trigger))
            if score == nil { failure = "no yes/no token in the top logprobs" }
        } catch {
            failure = error.localizedDescription
        }
        let decision = GateDecision(
            at: started, trigger: trigger.kind, app: trigger.app, errorLine: trigger.errorLine,
            score: score.map { ($0 * 1000).rounded() / 1000 }, stepIn: (score ?? 0) >= threshold, threshold: threshold,
            latencyMs: Int(Date().timeIntervalSince(started) * 1000), model: server.modelName, failure: failure
        )
        log.append(decision)
        return decision
    }

    private func requestCompletion(for trigger: Trigger) async throws -> Data {
        let body: [String: Any] = [
            "messages": [["role": "system", "content": Self.system], ["role": "user", "content": Self.describe(trigger)]],
            "max_tokens": 1, "temperature": 0, "logprobs": true, "top_logprobs": 10,
        ]
        var request = URLRequest(url: server.endpoint.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20
        return try await URLSession.shared.data(for: request).0
    }

    static func describe(_ trigger: Trigger) -> String {
        var lines: [String] = []
        switch trigger.kind {
        case .appChanged: lines.append("Event: the user switched to another app.")
        case .terminalError: lines.append("Event: an error just appeared in the terminal.")
        case .stuckOnError: lines.append("Event: the same error has stayed in the terminal for \(minutes(trigger.errorSeconds ?? 0)).")
        case .idle: lines.append("Event: the user has not touched the Mac for \(minutes(trigger.idleSeconds)).")
        }
        if let app = trigger.app { lines.append("App: \(app)") }
        if let title = trigger.windowTitle { lines.append("Window: \(title)") }
        if let error = trigger.errorLine { lines.append("Error line: \(error)") }
        if let tail = trigger.terminalTail { lines.append("Last terminal lines:\n\(tail)") }
        if trigger.kind != .idle { lines.append("Seconds since the last keyboard or mouse input: \(Int(trigger.idleSeconds))") }
        lines.append("Should Bean step in now?")
        return lines.joined(separator: "\n")
    }

    static func score(from data: Data) throws -> Double? {
        struct Response: Decodable {
            struct Choice: Decodable { let logprobs: Logprobs? }
            struct Logprobs: Decodable { let content: [Token] }
            struct Token: Decodable { let top_logprobs: [Candidate] }
            struct Candidate: Decodable { let token: String; let logprob: Double }
            let choices: [Choice]
        }
        let candidates = try JSONDecoder().decode(Response.self, from: data).choices.first?.logprobs?.content.first?.top_logprobs ?? []
        func probability(of word: String) -> Double {
            candidates.filter { $0.token.trimmingCharacters(in: .whitespaces).lowercased() == word }.reduce(0) { $0 + exp($1.logprob) }
        }
        let yes = probability(of: "yes"), no = probability(of: "no")
        return yes + no > 0 ? yes / (yes + no) : nil
    }

    private static func minutes(_ seconds: Double) -> String {
        seconds < 90 ? "\(Int(seconds)) seconds" : "\(Int((seconds / 60).rounded())) minutes"
    }
}
