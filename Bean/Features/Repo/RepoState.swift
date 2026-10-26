import Foundation

struct RepoState: Codable {
    let root: String
    let branch: String?
    let changedFiles: [String]
    let lastCommit: String?
    let ci: String?

    static let protectedFolders = ["Documents", "Desktop", "Downloads"].map { NSHomeDirectory() + "/" + $0 }
    static let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }

    var summary: String {
        var parts = ["Repo: \(URL(fileURLWithPath: root).lastPathComponent) on branch \(branch ?? "?")"]
        parts.append(changedFiles.isEmpty ? "no uncommitted changes" : "\(changedFiles.count) changed files: \(changedFiles.prefix(8).joined(separator: ", "))")
        if let lastCommit { parts.append("last commit: \(lastCommit)") }
        if let ci { parts.append("latest CI run: \(ci)") }
        return parts.joined(separator: "; ")
    }

    static func read(at path: String) -> RepoState? {
        guard !protectedFolders.contains(where: { path.hasPrefix($0) }),
              let root = run("/usr/bin/git", ["-C", path, "rev-parse", "--show-toplevel"]), !root.isEmpty else { return nil }
        let status = run("/usr/bin/git", ["-C", root, "status", "--porcelain"]) ?? ""
        let changed = status.split(separator: "\n").map { String($0.dropFirst(3)) }
        var ci: String?
        if let gh, run("/usr/bin/git", ["-C", root, "remote", "get-url", "origin"])?.contains("github.com") == true,
           let json = run(gh, ["run", "list", "-L", "1", "--json", "status,conclusion,workflowName,headBranch"], in: root, timeout: 3),
           let latest = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])?.first {
            let outcome = (latest["conclusion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (latest["status"] as? String ?? "?")
            ci = "\(outcome) (\(latest["workflowName"] as? String ?? "?") on \(latest["headBranch"] as? String ?? "?"))"
        }
        return RepoState(
            root: root,
            branch: run("/usr/bin/git", ["-C", root, "branch", "--show-current"]),
            changedFiles: changed,
            lastCommit: run("/usr/bin/git", ["-C", root, "log", "-1", "--format=%h %s"]),
            ci: ci
        )
    }

    private static func run(_ executable: String, _ arguments: [String], in directory: String? = nil, timeout: TimeInterval = 2) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}
