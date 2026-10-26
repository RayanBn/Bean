import Foundation

final class ShellWatcher {
    var onCommand: ((ShellCommand) -> Void)?

    let log: URL
    private var offset: UInt64 = 0
    private var timer: Timer?
    private var partial = Data()

    init(log: URL) {
        self.log = log
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        offset = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? UInt64) ?? 0
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.read() }
    }

    private func read() {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        offset += UInt64(data.count)
        partial.append(data)
        while let newline = partial.firstIndex(of: 0x0A) {
            let line = partial[partial.startIndex..<newline]
            partial.removeSubrange(partial.startIndex...newline)
            if let command = try? JSONDecoder().decode(ShellCommand.self, from: line) {
                onCommand?(command)
            }
        }
    }
}
