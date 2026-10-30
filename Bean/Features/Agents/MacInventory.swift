import AppKit

struct MacInventory {
    let installed: [String]
    let running: [String]

    static func scan() -> MacInventory {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", home.appendingPathComponent("Applications").path]
        let installed = folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
        }
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName)
        return MacInventory(installed: Array(Set(installed)).sorted(), running: Array(Set(running)).sorted())
    }

    var summary: String {
        "Running apps: \(running.joined(separator: ", "))\nInstalled apps: \(installed.joined(separator: ", "))"
    }
}
