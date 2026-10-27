import Foundation

final class JSONLog {
    let url: URL
    private let encoder: JSONEncoder
    private let handle: FileHandle?

    static let directory = ProcessInfo.processInfo.environment["BEAN_DATA_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Bean")

    init(name: String) {
        let dir = Self.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("\(name).jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
    }

    func append<T: Encodable>(_ value: T) {
        guard var line = try? encoder.encode(value) else { return }
        line.append(0x0A)
        handle?.write(line)
        FileHandle.standardOutput.write(line)
    }
}
