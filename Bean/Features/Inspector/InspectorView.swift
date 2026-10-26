import SwiftUI

struct InspectorView: View {
    enum Section: String, CaseIterable, Identifiable {
        case now = "Now", apps = "Apps & windows", browser = "Browser", processes = "Processes & ports"
        case work = "Agents, files, commands", pipeline = "Decisions", events = "Event log"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .now: return "eye"
            case .apps: return "macwindow.on.rectangle"
            case .browser: return "globe"
            case .processes: return "cpu"
            case .work: return "hammer"
            case .pipeline: return "arrow.triangle.branch"
            case .events: return "list.bullet.rectangle"
            }
        }
    }

    @ObservedObject var model: InspectorModel
    @State private var section: Section? = .now

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    detail(section ?? .now)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(section?.rawValue ?? "")
            .navigationSubtitle(model.updatedAt.map { "Live · \($0.formatted(date: .omitted, time: .standard))" } ?? "Loading…")
        }
        .frame(minWidth: 860, minHeight: 560)
    }

    @ViewBuilder private func detail(_ section: Section) -> some View {
        if let inventory = model.inventory {
            switch section {
            case .now: now(inventory)
            case .apps: apps(inventory)
            case .browser: rows(inventory.tabs.map { ("\($0.isActive ? "● " : "")\($0.browser)", "\($0.title)\n\($0.url)") }, empty: "No tabs read.")
            case .processes: processes(inventory)
            case .work: work(inventory)
            case .pipeline: ForEach(["triggers", "gate", "brain", "actions"], id: \.self) { logBlock($0) }
            case .events: ForEach(["inventory", "signals", "shell"], id: \.self) { logBlock($0) }
            }
        } else {
            ProgressView()
        }
    }

    private func now(_ inventory: Inventory) -> some View {
        let system = inventory.system
        let active = inventory.apps.first { $0.isActive }
        return VStack(alignment: .leading, spacing: 14) {
            group("You are in") {
                fact("App", active?.name ?? "—")
                fact("Window", active?.windows.first { $0.isFocused }?.title ?? "—")
                fact("Idle", "\(Int(system.idleSeconds)) s")
                fact("Space", "\(system.activeSpace)")
                fact("Mic · camera", "\(system.micInUse ? "on" : "off") · \(system.cameraInUse ? "on" : "off")")
                fact("Locked · asleep", "\(system.locked ? "yes" : "no") · \(system.asleep ? "yes" : "no")")
            }
            group("Mac") {
                fact("Battery", system.battery ?? "—")
                fact("Network", system.network ?? "—")
                fact("Audio", [system.audioOutput, system.volume.map { "\($0) %" }].compactMap { $0 }.joined(separator: " · "))
                fact("Apps", "\(inventory.apps.count) visible, \(inventory.backgroundApps) in the background")
            }
            group("Text Bean reads in the focused window") {
                if let text = inventory.focusedText {
                    Text("\(text.app ?? "?") — \(text.window ?? "?") · \(text.text.count) characters in \(text.milliseconds) ms\(text.truncated ? " (truncated)" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(String(text.text.prefix(4000)))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text("Nothing readable in the focused window.").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func apps(_ inventory: Inventory) -> some View {
        group("\(inventory.apps.count) apps") {
            ForEach(inventory.apps, id: \.pid) { app in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(app.name).fontWeight(app.isActive ? .semibold : .regular)
                        Text(app.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                        if app.isHidden { Text("hidden").font(.caption).foregroundStyle(.secondary) }
                    }
                    ForEach(app.windows, id: \.id) { window in
                        Text("\(window.isFocused ? "▸ " : "  ")\(window.title.isEmpty ? "(untitled)" : window.title)\(window.space.map { "  · space \($0)" } ?? "")\(window.isMinimized ? "  · minimized" : "")")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                Divider()
            }
        }
    }

    private func processes(_ inventory: Inventory) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            rows(inventory.ports.map { ("Port \($0.port)", $0.process) }, title: "Listening ports", empty: "No listening ports.")
            rows(inventory.trackedProcesses.prefix(60).map { ($0.name, "pid \($0.pid) · \($0.arguments)") }, title: "Processes outside apps (newest first)", empty: "None.")
        }
    }

    private func work(_ inventory: Inventory) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            rows(inventory.agents.map { ($0.title, "\($0.state.rawValue) · \($0.cwd)") }, title: "Coding agent sessions", empty: "None.")
            rows(inventory.recentFiles.prefix(30).map { (URL(fileURLWithPath: $0).lastPathComponent, $0) }, title: "Recently changed files", empty: "None.")
            rows(inventory.commands.suffix(30).reversed().map { ("exit \($0.exit)", "\($0.cmd)\n\($0.cwd)") }, title: "Terminal commands", empty: "None yet: the zsh hook logs new terminals only.")
        }
    }

    private func logBlock(_ name: String) -> some View {
        group("\(name).jsonl") {
            let lines = model.lines[name] ?? []
            if lines.isEmpty { Text("Empty.").foregroundStyle(.secondary) }
            ForEach(lines.prefix(25)) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(line.time).foregroundStyle(.secondary)
                    Text(line.kind).fontWeight(.medium).frame(width: 120, alignment: .leading)
                    Text(line.summary).foregroundStyle(.secondary).lineLimit(2)
                }
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
            }
        }
    }

    private func rows(_ items: [(String, String)], title: String? = nil, empty: String) -> some View {
        group(title) {
            if items.isEmpty { Text(empty).foregroundStyle(.secondary) }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0).fontWeight(.medium)
                    Text(item.1).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Divider()
            }
        }
    }

    private func group(_ title: String?, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.headline) }
            content()
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
    }
}
