import Foundation

struct AgentNeed: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case stuck, decision, problem, budget, setup }
    var id = UUID()
    var at = Date()
    var kind: Kind
    var question: String
    var options: [String] = []
    var consequences: [String: String]?
    var settingsPane: String?
    var recommended: String?
    var session: String?
    var decision: UUID?
    var permission: String?
    var task: String?
    var connector: String?
    var ability: String?
    var consent: String?
    var detail: String?
    var senseParams: [String: String]?
    var senseWhy: String?
    var sourceWindow: Int?
    var firstMove: Bool?

    var blocksRuns: Bool { kind != .decision }

    func repeats(_ other: AgentNeed) -> Bool {
        Self.similar(question, other.question)
    }

    static func similar(_ one: String, _ other: String) -> Bool {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count > 3 })
        }
        let mine = words(one), theirs = words(other)
        guard !mine.isEmpty, !theirs.isEmpty else { return one == other }
        return Double(mine.intersection(theirs).count) / Double(min(mine.count, theirs.count)) >= 0.6
    }
}

struct AgentDecision: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case permission, judgment }
    enum State: String, Codable { case decided, escalated, answered, corrected }
    var id = UUID()
    var at = Date()
    var kind: Kind
    var session: String?
    var repo: String?
    var question: String
    var answer: String
    var why: String
    var confidence: Double
    var state: State = .decided
    var correction: String?
}

struct AwaySummary: Equatable {
    let since: Date
    let decided: [AgentDecision]
    let permissionsAnswered: Int
    let waiting: [AgentNeed]
    let done: [JournalEntry]
}

extension AgentFolder {
    private var needsFile: URL { url.appendingPathComponent("needs.json") }
    private var decisionsFile: URL { memory.appendingPathComponent("decisions.jsonl") }

    private static let coder: (JSONEncoder, JSONDecoder) = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }()

    var needs: [AgentNeed] {
        (try? Data(contentsOf: needsFile)).flatMap { try? Self.coder.1.decode([AgentNeed].self, from: $0) } ?? []
    }

    func save(_ needs: [AgentNeed]) {
        try? Self.coder.0.encode(needs).write(to: needsFile, options: .atomic)
    }

    var decisions: [AgentDecision] {
        let text = (try? String(contentsOf: decisionsFile, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? Self.coder.1.decode(AgentDecision.self, from: Data($0.utf8)) }
    }

    func append(_ decision: AgentDecision) {
        guard let line = try? Self.coder.0.encode(decision) else { return }
        try? FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        JSONLines.append(line, to: decisionsFile)
    }

    func save(_ decisions: [AgentDecision]) {
        try? FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        let lines = decisions.compactMap { (try? Self.coder.0.encode($0)).map { String(decoding: $0, as: UTF8.self) } }
        try? (lines.joined(separator: "\n") + "\n").write(to: decisionsFile, atomically: true, encoding: .utf8)
    }

    var corrections: String? { (try? String(contentsOf: correctionsFile.url, encoding: .utf8)).flatMap { $0.isEmpty ? nil : String($0.suffix(correctionsFile.limit)) } }

    func addCorrection(_ line: String) {
        correctionsFile.append(line)
    }
}
