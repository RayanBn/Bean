import Foundation

enum ActiveFolder {
    static let vsCodeBundleId = "com.microsoft.VSCode"

    static func guess(for trigger: Trigger) -> String? {
        if let cwd = trigger.cwd { return cwd }
        guard trigger.bundleId == vsCodeBundleId else { return nil }
        let folders = vsCodeFolders()
        if let name = trigger.windowTitle?.components(separatedBy: " — ").last?.trimmingCharacters(in: .whitespaces),
           let match = folders.first(where: { URL(fileURLWithPath: $0).lastPathComponent == name }) {
            return match
        }
        return folders.first
    }

    static func vsCodeFolders() -> [String] {
        let storage = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Code/User/globalStorage/storage.json")
        guard let data = try? Data(contentsOf: storage),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = json["windowsState"] as? [String: Any] else { return [] }
        let windows = [state["lastActiveWindow"]].compactMap { $0 as? [String: Any] } + (state["openedWindows"] as? [[String: Any]] ?? [])
        var seen = Set<String>()
        return windows.compactMap { ($0["folder"] as? String).flatMap(URL.init(string:))?.path }.filter { seen.insert($0).inserted }
    }
}
