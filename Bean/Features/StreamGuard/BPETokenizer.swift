import Foundation

struct BPETokenizer {
    struct Token {
        let id: Int64
        let range: NSRange
    }

    private let vocab: [String: Int64]
    private let ranks: [String: Int]
    private let splitter: NSRegularExpression
    private static let byteChars: [Character] = {
        let visible = Set(Array(33...126) + Array(161...172) + Array(174...255))
        var chars = [Character](repeating: " ", count: 256)
        var extra = 0
        for byte in 0..<256 {
            if visible.contains(byte) {
                chars[byte] = Character(UnicodeScalar(UInt8(byte)))
            } else {
                chars[byte] = Character(UnicodeScalar(256 + extra)!)
                extra += 1
            }
        }
        return chars
    }()

    init(url: URL) throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        guard let model = json?["model"] as? [String: Any],
              let vocab = model["vocab"] as? [String: NSNumber],
              let merges = model["merges"] as? [[String]],
              let pre = json?["pre_tokenizer"] as? [String: Any],
              let steps = pre["pretokenizers"] as? [[String: Any]],
              let pattern = steps.compactMap({ ($0["pattern"] as? [String: String])?["Regex"] }).first
        else { throw CocoaError(.fileReadCorruptFile) }
        self.vocab = vocab.mapValues { $0.int64Value }
        var ranks: [String: Int] = [:]
        ranks.reserveCapacity(merges.count)
        for (rank, pair) in merges.enumerated() where pair.count == 2 { ranks[pair[0] + " " + pair[1]] = rank }
        self.ranks = ranks
        splitter = try NSRegularExpression(pattern: pattern)
    }

    func encode(_ text: String) -> [Token] {
        let ns = text as NSString
        var pieces: [NSRange] = []
        var cursor = 0
        for match in splitter.matches(in: text, range: NSRange(location: 0, length: ns.length)) where match.range.length > 0 {
            if match.range.location > cursor { pieces.append(NSRange(location: cursor, length: match.range.location - cursor)) }
            pieces.append(match.range)
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length { pieces.append(NSRange(location: cursor, length: ns.length - cursor)) }
        return pieces.flatMap { encode(piece: ns.substring(with: $0), at: $0.location) }
    }

    private func encode(piece: String, at start: Int) -> [Token] {
        var bytes: [UInt8] = []
        var utf16At: [Int] = []
        var offset = start
        for scalar in piece.unicodeScalars {
            let encoded = Array(String(scalar).utf8)
            bytes += encoded
            utf16At += Array(repeating: offset, count: encoded.count)
            offset += scalar.utf16.count
        }
        utf16At.append(offset)
        let word = String(bytes.map { Self.byteChars[Int($0)] })
        let parts = vocab[word] != nil ? [word] : merge(word.unicodeScalars.map { String($0) })
        var tokens: [Token] = []
        var byte = 0
        for part in parts {
            let length = part.unicodeScalars.count
            let from = utf16At[byte], to = utf16At[byte + length]
            if let id = vocab[part] { tokens.append(Token(id: id, range: NSRange(location: from, length: to - from))) }
            byte += length
        }
        return tokens
    }

    private func merge(_ start: [String]) -> [String] {
        var symbols = start
        while symbols.count > 1 {
            var best: (rank: Int, index: Int)?
            for i in 0..<(symbols.count - 1) {
                if let rank = ranks[symbols[i] + " " + symbols[i + 1]], rank < (best?.rank ?? .max) { best = (rank, i) }
            }
            guard let best else { break }
            let left = symbols[best.index], right = symbols[best.index + 1]
            var merged: [String] = []
            var i = 0
            while i < symbols.count {
                if i < symbols.count - 1, symbols[i] == left, symbols[i + 1] == right {
                    merged.append(left + right)
                    i += 2
                } else {
                    merged.append(symbols[i])
                    i += 1
                }
            }
            symbols = merged
        }
        return symbols
    }
}
