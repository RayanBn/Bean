import Foundation

enum OffLimits {
    static var terms: [String] { BeanSettings.shared.effectiveOffLimits.map { $0.lowercased() } }

    static func match(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let terms = terms
        guard !terms.isEmpty else { return nil }
        let lower = text.lowercased(), compact = compacted(lower)
        return terms.first { lower.contains($0) || compact.contains(compacted($0)) }
    }

    static func redact(_ text: String) -> (text: String, hidden: Int) {
        guard !terms.isEmpty else { return (text, 0) }
        var hidden = 0
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            guard match(String(line)) != nil else { return true }
            hidden += 1
            return false
        }
        return (kept.joined(separator: "\n"), hidden)
    }

    static func redactWords(_ text: String) -> (text: String, hidden: Int) {
        guard !terms.isEmpty else { return (text, 0) }
        var hidden = 0
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
                guard match(String(word)) != nil else { return String(word) }
                hidden += 1
                return "[off limits]"
            }.joined(separator: " ")
        }
        return (lines.joined(separator: "\n"), hidden)
    }

    private static func compacted(_ text: String) -> String {
        text.filter { $0.isLetter || $0.isNumber || $0 == "/" }
    }
}
