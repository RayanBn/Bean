import Foundation

enum VisibleTerminal {
    static func start(_ command: String, in directory: String?) -> ToolOutput {
        if let blocked = Plan(steps: [PlanStep(title: "", command: command)], appBundleId: "terminal").blockedCommand {
            return ToolOutput(text: "blocked: \(blocked)", ok: false)
        }
        let folder = JSONLog.directory.appendingPathComponent("terminal", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("bean-\(Int(Date().timeIntervalSince1970 * 1000)).command")
        let cwd = directory.flatMap { FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath) ? ($0 as NSString).expandingTildeInPath : nil } ?? NSHomeDirectory()
        let body = """
        #!/bin/zsh -l
        cd \(quoted(cwd))
        print -P "%F{yellow}Bean runs:%f "\(quoted(command))
        \(command)
        exec zsh -l
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            return ToolOutput(text: "could not write the script: \(error.localizedDescription)", ok: false)
        }
        let opened = HiddenShell.run("open \(quoted(script.path))", timeout: 10)
        return opened.exit == 0
            ? ToolOutput(text: "started in a new terminal window in \(cwd)")
            : ToolOutput(text: "could not open a terminal: \(opened.output)", ok: false)
    }

    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
