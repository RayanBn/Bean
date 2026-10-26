import AppKit

enum BrowserProbe {
    static func runIfRequested() -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-browser") else { return false }
        let bundleId = CommandLine.arguments.dropFirst(index + 1).first
        let app = bundleId.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first } ?? NSWorkspace.shared.frontmostApplication
        guard let app, let id = app.bundleIdentifier else {
            print("no app for \(bundleId ?? "frontmost")")
            return true
        }
        let (page, timing) = Probe.measure { BrowserReader.current(bundleId: id, pid: app.processIdentifier) }
        print("app=\(id) \(timing)")
        print(page.map(Probe.json) ?? "nil")
        return true
    }
}

enum Probe {
    static func measure<T>(runs: Int = 20, _ read: () -> T) -> (T, String) {
        var result = read()
        var times: [Double] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            result = read()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        times.sort()
        return (result, String(format: "runs=%d median=%.1fms max=%.1fms", runs, times[runs / 2], times[runs - 1]))
    }

    static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "unencodable"
    }
}
