import AppKit
import SwiftTerm
import SwiftUI

struct TerminalStart {
    let folder: String
    let executable: String
    let arguments: [String]
}

@MainActor
final class SessionTerminals: ObservableObject {
    final class Tab: NSObject, Identifiable, LocalProcessTerminalViewDelegate {
        let id = UUID()
        let title: String
        let view: LocalProcessTerminalView
        var onExit: (() -> Void)?

        init(title: String, view: LocalProcessTerminalView, onExit: (() -> Void)?) {
            self.title = title
            self.view = view
            self.onExit = onExit
        }

        nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async { [weak self] in
                self?.onExit?()
                self?.onExit = nil
            }
        }
    }

    static let shared = SessionTerminals()
    private static let hidden = ["MODEL_API_KEY", "OPENROUTER_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GH_TOKEN", "GITHUB_TOKEN"]

    @Published private(set) var tabs: [String: [Tab]] = [:]
    @Published var chosen: [String: UUID] = [:]

    func openShell(_ key: String, folder: String) {
        add(key, title: "Terminal", start: TerminalStart(folder: folder, executable: "/bin/zsh", arguments: ["-l"]))
    }

    func add(_ key: String, title: String, start: TerminalStart, onExit: (() -> Void)? = nil) {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let environment = ProcessInfo.processInfo.environment.filter { key, _ in !Self.hidden.contains(key) && !key.hasPrefix("BEAN_") && !key.hasPrefix("CLAUDE") }.map { "\($0.key)=\($0.value)" } + ["TERM=xterm-256color", "COLORTERM=truecolor"]
        let tab = Tab(title: title, view: view, onExit: onExit)
        view.processDelegate = tab
        view.startProcess(executable: start.executable, args: start.arguments, environment: environment, currentDirectory: start.folder)
        tabs[key, default: []].append(tab)
        chosen[key] = tab.id
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
