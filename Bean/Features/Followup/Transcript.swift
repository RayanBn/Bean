import Foundation

struct Utterance: Codable {
    let channel: Channel
    var speaker: String?
    let start: Double
    let text: String
}

struct Transcript: Codable {
    let app: String
    let startedAt: Date
    let endedAt: Date
    let utterances: [Utterance]

    static let echoWindow: Double = 4
    static let echoSimilarity = 0.6

    init(app: String, startedAt: Date, endedAt: Date, utterances: [Utterance]) {
        self.app = app
        self.startedAt = startedAt
        self.endedAt = endedAt
        let theirs = utterances.filter { $0.channel == .them }
        self.utterances = utterances
            .filter { line in
                line.channel == .them || !theirs.contains { abs($0.start - line.start) < Self.echoWindow && Self.similarity($0.text, line.text) >= Self.echoSimilarity }
            }
            .sorted { $0.start < $1.start }
    }

    var isEmpty: Bool { utterances.allSatisfy { $0.text.trimmingCharacters(in: .whitespaces).isEmpty } }

    var text: String {
        utterances.map { line in
            let time = String(format: "%02d:%02d", Int(line.start) / 60, Int(line.start) % 60)
            let who = line.channel == .me ? "me" : "them" + (line.speaker.map { " \($0)" } ?? "")
            return "[\(time) \(who)] \(line.text.trimmingCharacters(in: .whitespaces))"
        }.joined(separator: "\n")
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let words = { (s: String) in Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)) }
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }
}
