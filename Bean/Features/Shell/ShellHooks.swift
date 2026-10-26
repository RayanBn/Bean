import Foundation

struct ShellCommand: Codable {
    let cmd: String
    let exit: Int
    let cwd: String
    let start: Double
    let end: Double
    let term: String?

    var appName: String? {
        switch term {
        case "Apple_Terminal": return "Terminal"
        case "iTerm.app": return "iTerm2"
        case "vscode": return "VS Code"
        case "ghostty": return "Ghostty"
        case "WarpTerminal": return "Warp"
        default: return term
        }
    }

    var bundleId: String? {
        switch term {
        case "Apple_Terminal": return "com.apple.Terminal"
        case "iTerm.app": return "com.googlecode.iterm2"
        case "vscode": return "com.microsoft.VSCode"
        case "ghostty": return "com.mitchellh.ghostty"
        case "WarpTerminal": return "dev.warp.Warp-Stable"
        default: return nil
        }
    }
}

enum ShellHooks {
    static let marker = "# Bean: terminal commands and exit codes, kept on this Mac"
    static let declinedKey = "BeanShellHooksDeclined"

    static var zshrc: URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["BEAN_ZSHRC"] { return URL(fileURLWithPath: path) }
        let home = environment["ZDOTDIR"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent(".zshrc")
    }

    static func snippet(for log: URL) -> URL {
        log.deletingLastPathComponent().appendingPathComponent("bean.zsh")
    }

    static func isInstalled() -> Bool {
        (try? String(contentsOf: zshrc, encoding: .utf8))?.contains(marker) ?? false
    }

    static func install(logTo log: URL) throws {
        let script = snippet(for: log)
        try source(log: log).write(to: script, atomically: true, encoding: .utf8)
        guard !isInstalled() else { return }
        let line = "\n\(marker)\n[[ -r '\(script.path)' ]] && source '\(script.path)'\n"
        if let handle = try? FileHandle(forWritingTo: zshrc) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try handle.close()
        } else {
            try line.write(to: zshrc, atomically: true, encoding: .utf8)
        }
    }

    private static func source(log: URL) -> String {
        #"""
        zmodload zsh/datetime
        typeset -g __bean_cmd="" __bean_start=""
        __bean_json() {
          local s=${1[1,500]}
          s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/ }; s=${s//$'\t'/ }; s=${s//$'\r'/ }
          print -rn -- "\"$s\""
        }
        __bean_preexec() { __bean_cmd=$1; __bean_start=$EPOCHREALTIME }
        __bean_precmd() {
          local code=$?
          [[ -z $__bean_cmd ]] && return
          if [[ ! ${(L)__bean_cmd} =~ '(passw|token|secret|api[_-]?key)' ]]; then
            print -r -- "{\"cmd\":$(__bean_json $__bean_cmd),\"exit\":$code,\"cwd\":$(__bean_json $PWD),\"start\":$__bean_start,\"end\":$EPOCHREALTIME,\"term\":$(__bean_json ${TERM_PROGRAM:-unknown})}" >> 'LOG'
          fi
          __bean_cmd=""
        }
        autoload -Uz add-zsh-hook
        add-zsh-hook preexec __bean_preexec
        add-zsh-hook precmd __bean_precmd

        """#.replacingOccurrences(of: "'LOG'", with: "'\(log.path)'")
    }
}
