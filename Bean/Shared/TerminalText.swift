import Foundation

struct TerminalText {
    static let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty"]
    static let errorPattern = try! NSRegularExpression(pattern: #"\w*(Error|Exception)\b|(?i:\b(error|traceback|fatal|panic|failed)\b)"#)
    static let promptPattern = try! NSRegularExpression(pattern: #"^(\$ |[\w.@~/:-]+(?: [\w.@~/:-]+)*\s?[%$#](?: |$))"#)

    let lines: [String]

    init(_ text: String) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { String($0) }
    }

    var endsAtPrompt: Bool { lines.last.map(Self.isPrompt) ?? false }

    var lastCommandOutput: ArraySlice<String> {
        let prompts = lines.indices.filter { Self.isPrompt(lines[$0]) }
        guard let last = prompts.last else { return lines.suffix(30) }
        if last == lines.count - 1 {
            let start = prompts.dropLast().last.map { $0 + 1 } ?? 0
            return lines[start..<last]
        }
        return lines[(last + 1)...]
    }

    func finishedOutput(of command: String) -> ArraySlice<String>? {
        guard endsAtPrompt,
              let line = lines.lastIndex(where: { Self.isPrompt($0) && $0.trimmingCharacters(in: .whitespaces).hasSuffix(command) }),
              line < lines.count - 1 else { return nil }
        return lines[(line + 1)..<(lines.count - 1)]
    }

    static func lastError(in output: ArraySlice<String>) -> String? {
        output.suffix(30).last(where: isError)
    }

    var lastError: String? {
        lastCommandOutput.suffix(30).last(where: Self.isError)
    }

    func tail(_ count: Int) -> String {
        lines.suffix(count).joined(separator: "\n")
    }

    static func isPrompt(_ line: String) -> Bool {
        matches(promptPattern, line)
    }

    static func isError(_ line: String) -> Bool {
        matches(errorPattern, line) && !isPrompt(line)
    }

    private static func matches(_ pattern: NSRegularExpression, _ line: String) -> Bool {
        pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }
}
