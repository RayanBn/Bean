import Foundation

/// Attributes a window to a project from what it points at: paths go to their repository (worktrees to the main one) or folder,
/// URLs and titles to the project they name. Nothing here knows any app.
enum ProjectGraph {
    private static var roots: [String: String] = [:]
    private static let home = NSHomeDirectory()

    private static let systemPrefixes = ["/dev/", "/System/", "/Library/", "/usr/", "/bin/", "/sbin/", "/opt/", "/private/var/", "/Applications/"]

    static func root(of path: String) -> String? {
        guard !systemPrefixes.contains(where: path.hasPrefix), !path.contains(".app/"), !path.hasPrefix(home + "/."), !path.hasPrefix(home + "/Library/") else { return nil }
        var directory = path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) else { return nil }
        if !isDirectory.boolValue { directory = (directory as NSString).deletingLastPathComponent }
        if let known = roots[directory] { return known }
        let common = HiddenShell.capture("/usr/bin/git", ["-C", directory, "rev-parse", "--path-format=absolute", "--git-common-dir"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var root = directory
        if let common, common.hasPrefix("/") {
            root = common.hasSuffix("/.git") ? String(common.dropLast(5)) : (common as NSString).deletingLastPathComponent
        }
        guard root != home, root != "/", !root.hasPrefix("/private/var"), !root.hasPrefix("/System") else { return nil }
        roots[directory] = root
        return root
    }

    static func paths(of window: SavedWindow, windowsOfApp: Int) -> [String] {
        var found: [String] = []
        if let document = window.facts.document { found.append(document) }
        for value in window.content?.handle.values ?? [:].values {
            if value.hasPrefix("/") { found.append(value) }
            if value.hasPrefix("file://"), let path = URL(string: value)?.path { found.append(path) }
        }
        let shells = Set(window.facts.processes.filter { $0.tty != nil }.compactMap(\.cwd).compactMap(root(of:)))
        if found.isEmpty, windowsOfApp == 1, shells.count == 1, let only = shells.first { found.append(only) }
        return found
    }

    static func urls(of window: SavedWindow) -> [String] {
        (window.content?.handle.values.map { $0 } ?? []).filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
    }

    static func project(of window: SavedWindow, windowsOfApp: Int, known: [ProjectState]) -> String? {
        var weights: [String: Int] = [:]
        for root in paths(of: window, windowsOfApp: windowsOfApp).compactMap(root(of:)) {
            weights[root, default: 0] += FileManager.default.fileExists(atPath: root + "/.git") ? 2 : 1
        }
        if let best = weights.max(by: { ($0.value, $0.key.count) < ($1.value, $1.key.count) })?.key { return best }
        let text = ([window.facts.title, window.content?.description ?? ""] + urls(of: window)).joined(separator: " ").lowercased()
        let named = known.filter { project in
            let name = project.name.lowercased()
            return name.count >= 3 && text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: name))\\b", options: .regularExpression) != nil
        }
        return named.count == 1 ? named[0].root : nil
    }
}
