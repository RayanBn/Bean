import Foundation

enum StepsProbe {
    static func runIfRequested() -> Bool {
        if let index = CommandLine.arguments.firstIndex(of: "--probe-ui") {
            let bundleId = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : nil
            print(AXTree.describe(Locator(bundleId: bundleId)))
            exit(0)
        }
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-steps"), index + 1 < CommandLine.arguments.count,
              let data = FileManager.default.contents(atPath: CommandLine.arguments[index + 1]),
              let steps = try? JSONDecoder().decode([Step].self, from: data) else { return false }
        let mode: Channels.Mode = CommandLine.arguments.contains("--background") ? .background : .takeover
        Task { @MainActor in
            for step in steps {
                let outcome = await Channels.shared.perform(step, mode: mode)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                print(String(decoding: (try? encoder.encode(outcome)) ?? Data(), as: UTF8.self))
                if !outcome.ok { exit(1) }
            }
            exit(0)
        }
        return true
    }
}
