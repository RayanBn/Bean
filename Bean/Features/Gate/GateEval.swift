import Foundation

enum GateEval {
    struct Case: Decodable {
        let expected: Bool
        let note: String
        let trigger: Trigger
    }

    static func run(cases url: URL, gate: Gate) async -> Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            print("cannot read \(url.path)")
            return false
        }
        let cases = text.split(separator: "\n").compactMap { try? decoder.decode(Case.self, from: Data($0.utf8)) }
        var results: [(expected: Bool, decision: GateDecision)] = []
        for item in cases {
            let decision = await gate.decide(item.trigger)
            results.append((item.expected, decision))
            let mark = decision.stepIn == item.expected ? "ok  " : "MISS"
            print("\(mark) expected=\(item.expected ? "yes" : "no ") score=\(decision.score.map { String(format: "%.3f", $0) } ?? "nil  ") \(decision.latencyMs)ms  \(item.note)\(decision.failure.map { "  FAILURE: \($0)" } ?? "")")
        }
        let right = results.filter { $0.decision.stepIn == $0.expected }.count
        let latencies = results.map(\.decision.latencyMs).sorted()
        print("\(right)/\(results.count) right at threshold \(gate.threshold), median \(latencies[latencies.count / 2])ms, max \(latencies.last ?? 0)ms")
        let sweep = stride(from: 0.05, through: 0.95, by: 0.05).map { t in
            (t, results.filter { (($0.decision.score ?? 0) >= t) == $0.expected }.count)
        }
        let best = sweep.max { $0.1 < $1.1 }!
        print("best threshold \(String(format: "%.2f", best.0)): \(best.1)/\(results.count)")
        return right == results.count
    }
}
