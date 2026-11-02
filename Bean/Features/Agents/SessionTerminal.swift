import AppKit
import SwiftTerm
import SwiftUI

struct TerminalStart {
    let folder: String
    let executable: String
    let arguments: [String]
}

final class ShellView: LocalProcessTerminalView {
    private(set) var lastOutput = Date()
    private(set) var lastExit: Int32?
    fileprivate var seen: [String] = []
    fileprivate var exitMark: String?
    private var carry = ""

    override func dataReceived(slice: ArraySlice<UInt8>) {
        lastOutput = Date()
        if let exitMark {
            let text = carry + String(decoding: slice, as: UTF8.self)
            let parts = text.components(separatedBy: exitMark)
            if parts.count > 1, let code = parts.last?.split(separator: "\u{7}", omittingEmptySubsequences: false).first.flatMap({ Int32($0) }) { lastExit = code }
            carry = String(text.suffix(64))
        }
        super.dataReceived(slice: slice)
    }

    func forgetExit() {
        lastExit = nil
        carry = ""
    }
}

// How the shell tells Bean a command ended, loaded the way a terminal does it: before the person's own files run, so nothing is typed on screen. Only that one shell gets it.
private struct ShellIntegration {
    let arguments: [String]
    let environment: [String]
    let mark: String

    init?(shell: String) {
        let nonce = UUID().uuidString.prefix(8)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bean-shell-\(nonce)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hook = "__bean_mark() { printf '\\033]7770;\(nonce);%s\\007' $?; }"
        func write(_ name: String, _ text: String) { try? text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        mark = "\u{1b}]7770;\(nonce);"
        switch (shell as NSString).lastPathComponent {
        case "zsh":
            func passing(_ name: String, then: String = "") -> String {
                "ZDOTDIR=${__bean_home:-$HOME}\n[[ -f $ZDOTDIR/\(name) ]] && source $ZDOTDIR/\(name)\n__bean_home=${ZDOTDIR:-$HOME}\nZDOTDIR=\(folder.path)\n\(then)"
            }
            write(".zshenv", passing(".zshenv"))
            write(".zprofile", passing(".zprofile"))
            // The commands stay out of the person's history, and a ! in a command does not leave the shell waiting.
            write(".zshrc", passing(".zshrc", then: "unset HISTFILE\nsetopt NO_BANG_HIST\n\(hook)\nprecmd_functions=(__bean_mark $precmd_functions)\nPROMPT='$ '\nRPROMPT=''\n"))
            write(".zlogin", passing(".zlogin", then: "ZDOTDIR=$__bean_home\nunset __bean_home\n"))
            arguments = ["-l"]
            environment = ["ZDOTDIR=\(folder.path)"]
        case "bash":
            write("init.bash", "[ -f /etc/profile ] && . /etc/profile\nfor file in ~/.bash_profile ~/.bash_login ~/.profile; do [ -f \"$file\" ] && { . \"$file\"; break; }; done\nunset HISTFILE\nset +H\n\(hook)\nPROMPT_COMMAND=\"__bean_mark${PROMPT_COMMAND:+;$PROMPT_COMMAND}\"\nPS1='$ '\n")
            arguments = ["--init-file", folder.appendingPathComponent("init.bash").path, "-i"]
            environment = []
        default:
            return nil
        }
    }
}

// What the agent's terminal shows when it looks: what is new on it, and how the last command ended.
struct TerminalLook {
    let text: String
    let exit: Int32?
    let foreground: String?
    let folder: String?
    let ended: Bool
    let unfinished: Bool
    let asksForSecret: Bool
}

@MainActor
final class SessionTerminals: ObservableObject {
    final class Tab: NSObject, Identifiable, LocalProcessTerminalViewDelegate {
        let id = UUID()
        let title: String
        let view: ShellView
        var onExit: (() -> Void)?
        var running = true
        var marksExit = false

        init(title: String, view: ShellView, onExit: (() -> Void)?) {
            self.title = title
            self.view = view
            self.onExit = onExit
        }

        nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async { [weak self] in
                self?.running = false
                self?.onExit?()
                self?.onExit = nil
            }
        }
    }

    static let shared = SessionTerminals()
    private static let inherited: Set<String> = ["HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR", "LANG", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING"]
    private static let historyLines = 20000
    private static let agentWidth: CGFloat = 1200

    @Published private(set) var tabs: [String: [Tab]] = [:]
    @Published var chosen: [String: UUID] = [:]

    private static var loginShell: String {
        getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) } ?? "/bin/zsh"
    }

    static func key(of agent: UUID) -> String { "agent \(agent.uuidString)" }

    func openShell(_ key: String, folder: String) {
        add(key, title: "Terminal", start: TerminalStart(folder: folder, executable: Self.loginShell, arguments: ["-l"]))
    }

    // The login shell builds the person's environment itself, as in their own terminal, so nothing of Bean's process reaches it.
    @discardableResult
    func add(_ key: String, title: String, start: TerminalStart, extra: [String] = [], width: CGFloat = 480, exitMark: String? = nil, onExit: (() -> Void)? = nil) -> Tab {
        let view = ShellView(frame: NSRect(x: 0, y: 0, width: width, height: 300))
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.getTerminal().changeHistorySize(Self.historyLines)
        let environment = ProcessInfo.processInfo.environment.filter { key, _ in Self.inherited.contains(key) || key.hasPrefix("LC_") }.map { "\($0.key)=\($0.value)" } + ["TERM=xterm-256color", "COLORTERM=truecolor"] + extra
        view.exitMark = exitMark
        let tab = Tab(title: title, view: view, onExit: onExit)
        tab.marksExit = exitMark != nil
        view.processDelegate = tab
        view.startProcess(executable: start.executable, args: start.arguments, environment: environment, currentDirectory: start.folder)
        tabs[key, default: []].append(tab)
        chosen[key] = tab.id
        return tab
    }

    func closeAll(_ key: String) {
        tabs[key]?.map(\.id).forEach { close(key, tab: $0) }
        tabs[key] = nil
    }

    func close(_ key: String, tab: UUID) {
        guard let found = tabs[key]?.first(where: { $0.id == tab }) else { return }
        found.view.terminate()
        found.onExit?()
        found.onExit = nil
        tabs[key]?.removeAll { $0.id == tab }
        if chosen[key] == tab { chosen[key] = tabs[key]?.last?.id }
    }

    func agentTab(of agent: UUID) -> Tab? {
        tabs[Self.key(of: agent)]?.first { $0.running }
    }

    // One per agent, and it stays between calls and runs. A new one shows on the agent's board, so the person sees what it runs.
    func agentTab(of agent: UUID, folder: String) async -> Tab {
        if let open = agentTab(of: agent) { return open }
        closeAll(Self.key(of: agent))
        let shell = Self.loginShell
        let integration = ShellIntegration(shell: shell)
        let extra = ["PAGER=cat", "GIT_PAGER=cat", "GIT_EDITOR=:", "GIT_MERGE_AUTOEDIT=no"] + (integration?.environment ?? [])
        let tab = add(Self.key(of: agent), title: "Agent", start: TerminalStart(folder: folder, executable: shell, arguments: integration?.arguments ?? ["-l"]), extra: extra, width: Self.agentWidth, exitMark: integration?.mark)
        PaneStore.shared.showTerminal(of: agent)
        let began = Date()
        if tab.marksExit {
            while Date().timeIntervalSince(began) < 15, tab.running, tab.view.lastExit == nil { try? await Task.sleep(for: .milliseconds(50)) }
        } else {
            while Date().timeIntervalSince(began) < 5, tab.view.lastOutput < began || Date().timeIntervalSince(tab.view.lastOutput) < 0.4 { try? await Task.sleep(for: .milliseconds(100)) }
        }
        _ = look(at: tab)
        return tab
    }

    func reset(agent: UUID) {
        if let tab = agentTab(of: agent), let group = Self.foregroundGroup(of: tab) { kill(-group, SIGKILL) }
        closeAll(Self.key(of: agent))
    }

    // Pasted, so a tab cannot trigger completion and several lines stay one command.
    func enter(_ text: String, in tab: Tab, newline: Bool = true) {
        tab.view.forgetExit()
        let pasted = tab.view.getTerminal().bracketedPasteMode ? "\u{1b}[200~\(text.replacingOccurrences(of: "\u{1b}", with: ""))\u{1b}[201~" : text
        tab.view.send(txt: pasted + (newline ? "\r" : ""))
    }

    func press(_ key: String, in tab: Tab) -> Bool {
        let name = key.uppercased()
        if name.hasPrefix("C-"), name.count == 3, let letter = name.last?.asciiValue, (64...95).contains(letter) {
            tab.view.send([letter - 64])
            return true
        }
        let named = ["ENTER": "\r", "TAB": "\t", "ESC": "\u{1b}", "BS": "\u{7f}", "UP": "\u{1b}[A", "DOWN": "\u{1b}[B", "RIGHT": "\u{1b}[C", "LEFT": "\u{1b}[D", "HOME": "\u{1b}[H", "END": "\u{1b}[F", "PGUP": "\u{1b}[5~", "PGDN": "\u{1b}[6~"]
        guard let keys = named[name] else { return false }
        tab.view.send(txt: keys)
        return true
    }

    func interrupt(agent: UUID) {
        if let tab = agentTab(of: agent), Self.foregroundGroup(of: tab) != nil { tab.view.send([3]) }
    }

    func stop(_ tab: Tab) async {
        tab.view.send([3])
        for signal in [SIGTERM, SIGKILL] {
            for _ in 0..<20 where Self.foregroundGroup(of: tab) != nil { try? await Task.sleep(for: .milliseconds(100)) }
            guard let group = Self.foregroundGroup(of: tab) else { return }
            kill(-group, signal)
        }
    }

    func programRunning(in tab: Tab) -> String? { Self.foregroundName(of: tab) }

    // The shell's mark says a command ended. A shell without one only shows it holds the terminal again, which between two commands of one line lasts an instant.
    func settle(_ tab: Tab, typed: Date, seconds: Double, stop: () -> Bool) async {
        let ends = Date().addingTimeInterval(seconds)
        var promptsInARow = 0
        while Date() < ends, tab.running, !stop() {
            promptsInARow = Self.foregroundGroup(of: tab) == nil ? promptsInARow + 1 : 0
            let quiet = Date().timeIntervalSince(max(tab.view.lastOutput, typed)) > 0.3
            if quiet, promptsInARow >= 2, tab.marksExit ? tab.view.lastExit != nil : true { return }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    func look(at tab: Tab) -> TerminalLook {
        let terminal = tab.view.getTerminal()
        let text = terminal.getText(start: Position(col: 0, row: 0), end: Position(col: terminal.cols, row: Int.max / 2))
        var lines = text.components(separatedBy: "\n").map { $0.replacing(/\s+$/, with: "") }
        while lines.last?.isEmpty == true { lines.removeLast() }
        let same = zip(tab.view.seen, lines).prefix { $0 == $1 }.count
        tab.view.seen = lines
        let program = Self.foregroundName(of: tab)
        // A full-screen program redraws in place, so what is new means nothing without the rest of its screen.
        let fresh = terminal.isCurrentBufferAlternate ? lines[...] : lines[same...]
        return TerminalLook(text: fresh.joined(separator: "\n"), exit: tab.view.lastExit, foreground: program, folder: Self.folder(of: tab), ended: !tab.running, unfinished: tab.running && tab.marksExit && program == nil && tab.view.lastExit == nil, asksForSecret: program != nil && Self.hidesWhatIsTyped(tab))
    }

    private static func foregroundGroup(of tab: Tab) -> pid_t? {
        guard tab.running, let process = tab.view.process else { return nil }
        let group = tcgetpgrp(process.childfd)
        return group > 0 && group != process.shellPid ? group : nil
    }

    // Lines still read whole with nothing echoed: what a password prompt does, and a full-screen program does not.
    private static func hidesWhatIsTyped(_ tab: Tab) -> Bool {
        guard let process = tab.view.process else { return false }
        var modes = termios()
        guard tcgetattr(process.childfd, &modes) == 0 else { return false }
        return modes.c_lflag & tcflag_t(ECHO) == 0 && modes.c_lflag & tcflag_t(ICANON) != 0
    }

    private static func foregroundName(of tab: Tab) -> String? {
        guard let group = foregroundGroup(of: tab) else { return nil }
        var name = [CChar](repeating: 0, count: 256)
        return proc_name(group, &name, UInt32(name.count)) > 0 ? String(cString: name) : "a program"
    }

    private static func folder(of tab: Tab) -> String? {
        guard tab.running, let process = tab.view.process else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(process.shellPid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }
}

struct TerminalHost: NSViewRepresentable {
    final class Box: NSView {
        override func layout() {
            super.layout()
            subviews.first?.frame = bounds.insetBy(dx: 6, dy: 3)
        }
    }

    let view: LocalProcessTerminalView

    func makeNSView(context: Context) -> Box { Box() }

    func updateNSView(_ box: Box, context: Context) {
        let dark = context.environment.colorScheme == .dark
        let background = dark ? NSColor(white: 0.1, alpha: 1) : NSColor(white: 0.99, alpha: 1)
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = dark ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.12, alpha: 1)
        box.wantsLayer = true
        box.layer?.backgroundColor = background.cgColor
        guard view.superview !== box else { return }
        box.subviews.forEach { $0.removeFromSuperview() }
        box.addSubview(view)
        box.needsLayout = true
    }
}
