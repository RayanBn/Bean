import Foundation

struct Signal: Codable {
    enum Kind: String, Codable { case appActivated, windowChanged, idleStarted, idleEnded }

    let at: Date
    let kind: Kind
    let app: String?
    let bundleId: String?
    let windowTitle: String?
    let idleSeconds: Double
}

final class SignalLog {
    let url: URL
    private let encoder: JSONEncoder
    private let handle: FileHandle?

    init() {
        let dir = ProcessInfo.processInfo.environment["BEAN_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Bean")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("signals.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
    }

    func append(_ signal: Signal) {
        guard var line = try? encoder.encode(signal) else { return }
        line.append(0x0A)
        handle?.write(line)
        FileHandle.standardOutput.write(line)
    }
}
