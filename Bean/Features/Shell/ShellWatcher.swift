import Foundation

final class ShellWatcher {
    var onCommand: ((ShellCommand) -> Void)?

    let log: URL
    private var offset: UInt64 = 0
    private var source: DispatchSourceFileSystemObject?
    private var partial = Data()

    init(log: URL) {
        self.log = log
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }
        offset = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? UInt64) ?? 0
    }

    func start() {
        let descriptor = open(log.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.extend, .write], queue: .main)
        source.setEventHandler { [weak self] in self?.read() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    static func lastCommands(in log: URL, count: Int) -> [ShellCommand] {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 20000 ? size - 20000 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return data.split(separator: 0x0A).suffix(count).compactMap { try? JSONDecoder().decode(ShellCommand.self, from: $0) }
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
