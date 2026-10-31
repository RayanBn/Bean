import Foundation

struct LoggedEvent: Codable, Equatable {
    var at = Date()
    let type: String
    var app: String?
    var bundleId: String?
    var window: Int?
    var title: String?
}

// Every OS event, at no model call. It stays on this Mac: nothing reads it for the cloud, and it holds no text from inside a window.
final class EventLog {
    static let shared = EventLog(folder: JSONLog.directory.appendingPathComponent("Events"))
    private static let keepDays = 30
    private static let dayLimit = 5_000_000
    private static let day: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        return format
    }()

    private let folder: URL
    private let queue = DispatchQueue(label: "dev.rayanbn.Bean.eventlog", qos: .utility)
    private let encoder: JSONEncoder
    private var open: (day: String, handle: FileHandle, size: Int)?

    init(folder: URL) {
        self.folder = folder
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func add(_ signal: SenseSignal, offLimits: Bool, sealed: Bool) {
        let event = offLimits ? LoggedEvent(at: signal.at, type: signal.type)
            : LoggedEvent(at: signal.at, type: signal.type, app: signal.app, bundleId: signal.bundleId, window: signal.window, title: sealed ? nil : signal.title)
        queue.async { [self] in write(event) }
    }

    private func write(_ event: LoggedEvent) {
        let name = Self.day.string(from: event.at)
        if open?.day != name { rollTo(name, now: event.at) }
        guard let current = open, current.size < Self.dayLimit, var line = try? encoder.encode(event) else { return }
        line.append(0x0A)
        current.handle.write(line)
        open?.size += line.count
    }

    private func rollTo(_ name: String, now: Date) {
        try? open?.handle.close()
        let url = folder.appendingPathComponent("\(name).jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { open = nil; return }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        open = (name, handle, size)
        prune(now: now)
    }

    func prune(now: Date) {
        let oldest = Self.day.string(from: now.addingTimeInterval(-Double(Self.keepDays) * 86400))
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "jsonl" {
            if file.deletingPathExtension().lastPathComponent < oldest { try? FileManager.default.removeItem(at: file) }
        }
    }

    func flush() { queue.sync {} }
}
