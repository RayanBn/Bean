import SwiftUI

struct WhatBeanSeesView: View {
    enum Section: String, CaseIterable, Identifiable {
        case now = "Now", apps = "Apps", windows = "Windows", tabs = "Browser Tabs", commands = "Commands", decisions = "Decisions"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .now: "eye"
            case .apps: "square.grid.2x2"
            case .windows: "macwindow.on.rectangle"
            case .tabs: "globe"
            case .commands: "terminal"
            case .decisions: "arrow.triangle.branch"
            }
        }
    }

    let sees: WhatBeanSees
    let decisions: [GateEntry]
    @State var section: Section = .now

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $section) {
                    ForEach(Section.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("sees-section")
                Spacer()
                Text("Live, updated \(sees.at.formatted(date: .omitted, time: .standard))\(sees.hidden > 0 ? ". \(sees.hidden) off limits, hidden" : "")")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            detail.frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder private var detail: some View {
        switch section {
        case .now: now
        case .apps:
            Table(sees.apps) {
                TableColumn("App", value: \.name)
                TableColumn("Bundle") { Text($0.bundleId).foregroundStyle(.secondary) }
                TableColumn("Windows") { Text("\($0.windows)").monospacedDigit() }.width(70)
                TableColumn("Front") { Text($0.isActive ? "Yes" : "") }.width(50)
            }
        case .windows:
            Table(sees.windows) {
                TableColumn("App", value: \.app).width(min: 100, ideal: 140)
                TableColumn("Title") { Text($0.title ?? "No title") }
                TableColumn("Agent") { Text($0.agent == nil ? "" : "Yes") }.width(50)
            }
        case .tabs:
            if sees.tabs.isEmpty {
                ContentUnavailableView("No tabs", systemImage: "globe", description: Text("Bean lists the front browser's tabs once you have allowed it to control that browser."))
            } else {
                Table(sees.tabs) {
                    TableColumn("Title", value: \.title)
                    TableColumn("Address") { Text($0.url).foregroundStyle(.secondary) }
                }
            }
        case .commands:
            if sees.commands.isEmpty {
                ContentUnavailableView("No commands", systemImage: "terminal", description: Text("The commands agents run appear here."))
            } else {
                Table(sees.commands) {
                    TableColumn("Time") { Text($0.at.formatted(date: .omitted, time: .standard)).monospacedDigit() }.width(80)
                    TableColumn("Command", value: \.command)
                    TableColumn("Exit") { Text("\($0.exit)").monospacedDigit() }.width(40)
                    TableColumn("Folder") { Text($0.directory).foregroundStyle(.secondary) }
                }
            }
        case .decisions:
            if decisions.isEmpty {
                ContentUnavailableView("No decisions yet", systemImage: "arrow.triangle.branch", description: Text("Each time something changes on this Mac, the decision appears here, including when Bean stays quiet."))
            } else {
                Table(decisions.reversed()) {
                    TableColumn("Time") { Text($0.at.formatted(date: .omitted, time: .standard)).monospacedDigit() }.width(70)
                    TableColumn("Event", value: \.event).width(min: 80, ideal: 110)
                    TableColumn("Where") { Text([$0.app, $0.title].compactMap { $0 }.joined(separator: ": ")).help([$0.app, $0.title].compactMap { $0 }.joined(separator: ": ")) }
                    TableColumn("Decision") { Text(GateWords.title($0.decision)) }.width(min: 90, ideal: 110)
                    TableColumn("By", value: \.by).width(70)
                    TableColumn("Score") { Text($0.score.map { String(format: "%.2f", $0) } ?? "").monospacedDigit() }.width(45)
                    TableColumn("ms") { Text($0.ms.map(String.init) ?? "").monospacedDigit() }.width(45)
                    TableColumn("Detail") { Text($0.detail ?? "").foregroundStyle(.secondary).help($0.detail ?? "") }
                }
            }
        }
    }

    @ViewBuilder private var now: some View {
        if sees.focused == nil && sees.apps.isEmpty && sees.windows.isEmpty && decisions.isEmpty {
            ContentUnavailableView("Nothing open yet", systemImage: "eye", description: Text("Everything Bean can see on this Mac appears here."))
        } else {
            Form {
                if let focused = sees.focused {
                    SwiftUI.Section(focused.behindBean ? "Last in Front" : "In Front") {
                        Text([focused.app, focused.window].compactMap { $0 }.joined(separator: ": ")).font(.headline)
                        Text(focused.text.isEmpty ? "No text could be read from this window." : focused.text)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(8)
                            .textSelection(.enabled)
                            .foregroundStyle(focused.text.isEmpty ? .secondary : .primary)
                    }
                }
                summary("Apps", count: sees.apps.count, .apps) {
                    Text(sees.apps.map(\.name).joined(separator: ", "))
                }
                summary("Windows", count: sees.windows.count, .windows) {
                    ForEach(sees.windows.prefix(5)) { window in
                        LabeledContent(window.title ?? "No title", value: window.app).lineLimit(1)
                    }
                }
                summary("Browser Tabs", count: sees.tabs.count, .tabs) {
                    ForEach(sees.tabs.prefix(5)) { tab in
                        LabeledContent(tab.title, value: tab.url).lineLimit(1)
                    }
                }
                summary("Last Decisions", count: decisions.count, .decisions) {
                    ForEach(decisions.suffix(3).reversed()) { entry in
                        LabeledContent(GateWords.title(entry.decision), value: [entry.app, entry.title].compactMap { $0 }.joined(separator: ": ")).lineLimit(1)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    @ViewBuilder private func summary(_ title: String, count: Int, _ target: Section, @ViewBuilder rows: () -> some View) -> some View {
        if count > 0 {
            SwiftUI.Section {
                rows()
            } header: {
                HStack {
                    Text("\(title) (\(count))")
                    Spacer()
                    Button("See All") { section = target }
                        .buttonStyle(.link)
                        .controlSize(.small)
                        .accessibilityIdentifier("sees-all-\(target.id)")
                }
            }
        }
    }
}

enum GateWords {
    static func title(_ decision: String) -> String {
        let english = switch decision {
        case "yes": "Looked into it"
        case "quiet": "Stayed quiet"
        case "offLimits": "Off limits"
        case "repeat": "Already seen"
        case "ownChange": "Its own change"
        case "noContent": "Nothing to read in it"
        case "paused": "Paused"
        case "museWorked": "Acted"
        case "museQuiet": "Chose to wait"
        default: decision
        }
        return AgentStrings.shown(english)
    }
}
