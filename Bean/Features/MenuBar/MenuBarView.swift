import SwiftUI

struct MenuBarView: View {
    @ObservedObject var settings: BeanSettings
    @ObservedObject var notch: NotchModel
    let openAgents: () -> Void
    let openSettings: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(nsImage: MenuBarController.glyph(paused: settings.paused))
                    .renderingMode(.template)
                    .foregroundStyle(settings.paused ? Color.secondary : Color.primary)
                    .scaleEffect(1.3)
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Bean").font(.system(size: 13, weight: .semibold))
                    Text(AgentStrings.shown(settings.paused ? "Paused" : "Running")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Running", isOn: Binding(get: { !settings.paused }, set: { settings.paused = !$0 }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .help(settings.paused ? "Resume" : "Pause")
            }
            Divider()
            VStack(spacing: 0) {
                menuButton(AgentStrings.shown("Open Bean"), action: openAgents)
                menuButton(AgentStrings.shown("Settings…"), shortcut: "⌘,", action: openSettings)
                menuButton(AgentStrings.shown("Quit Bean"), shortcut: "⌘Q") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 240)
    }

    private func menuButton(_ title: String, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                if let shortcut { Text(shortcut).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 4).frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
