import Foundation

struct AgentMission: Equatable {
    struct Check: Codable, Equatable {
        var command: String?
        var tool: String?
        var arguments: String?
    }

    var mission: String
    var targets: [AgentTarget]
    var explicitlyAllowed: [String] = []
    var every: TimeInterval = 300
    var check: Check?

    init(mission: String, targets: [AgentTarget] = [], explicitlyAllowed: [String] = []) {
        self.mission = mission
        self.targets = targets
        self.explicitlyAllowed = explicitlyAllowed
    }

    var scope: [String] {
        get { targets.filter { $0.kind == .repo || $0.kind == .project }.map(\.name) }
        set {
            let others = targets.filter { $0.kind != .repo && $0.kind != .project }
            let kept = targets.filter { newValue.contains($0.name) && ($0.kind == .repo || $0.kind == .project) }
            let added = newValue.filter { name in !kept.contains { $0.name == name } }.map(AgentTarget.named)
            targets = kept + added + others
        }
    }

    var isActive: Bool { !mission.isEmpty && !scope.isEmpty }
    var named: String { scope.joined(separator: ", ") }
}

struct JournalEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case action, refused, failed, stuck, undo, session, said, replied, handoff, notice }
    var id = UUID()
    var at = Date()
    var kind: Kind
    var did: String
    var why: String
    var result: String?
    var script: String?
    var link: String?
    var undo: String?
    var undoCommand: String?
    var undoText: String?
    var undoField: Int?
    var undoApp: String?
    var undoes: UUID?
    var to: UUID?
    // The person's own words, as against a click on a card.
    var typed: Bool?

    // What a script received and ran is for the logs and the model. The person reads did and why.
    var forPerson: String? { script == nil ? result : nil }
}

extension AgentFolder {
    var journalFile: URL { url.appendingPathComponent("journal.jsonl") }

    var journal: [JournalEntry] { JournalReads.entries(of: journalFile) }

    func append(_ entry: JournalEntry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let line = try? encoder.encode(entry) else { return }
        JSONLines.append(line, to: journalFile)
    }
}

// A journal only grows, and it is read again and again on the main thread, so only what was added since the last read is decoded.
private enum JournalReads {
    private static let lock = NSLock()
    private static var known: [URL: (size: UInt64, entries: [JournalEntry])] = [:]

    static func entries(of file: URL) -> [JournalEntry] {
        guard let handle = try? FileHandle(forReadingFrom: file), let size = try? handle.seekToEnd() else {
            lock.withLock { known[file] = nil }
            return []
        }
        defer { try? handle.close() }
        let before = lock.withLock { known[file] }.flatMap { $0.size <= size ? $0 : nil }
        let start = before?.size ?? 0
        guard start < size else { return before?.entries ?? [] }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let end = data.lastIndex(of: 0x0A) else { return before?.entries ?? [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let added = data[..<end].split(separator: 0x0A).compactMap { try? decoder.decode(JournalEntry.self, from: Data($0)) }
        let entries = (before?.entries ?? []) + added
        lock.withLock { known[file] = (start + UInt64(end - data.startIndex + 1), entries) }
        return entries
    }
}

// O_APPEND, because several tasks and sessions write one file at the same time, and none may overwrite another.
enum JSONLines {
    static func append(_ line: Data, to file: URL) {
        let descriptor = open(file.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        (line + [0x0A]).withUnsafeBytes { _ = write(descriptor, $0.baseAddress, $0.count) }
    }
}
