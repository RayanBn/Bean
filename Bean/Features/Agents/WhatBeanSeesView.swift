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
        if let focused = sees.focused {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text([focused.app, focused.window].compactMap { $0 }.joined(separator: ": ")).font(.headline)
                    Text("Text of the front window, with secrets hidden. It stays in memory and is never logged.").font(.callout).foregroundStyle(.secondary)
                    Text(focused.text.isEmpty ? "No text." : focused.text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(18)
            }
        } else {
            ContentUnavailableView("Nothing in front", systemImage: "eye", description: Text("Bean reads the front window when it is not off limits."))
        }
    }
}

enum GateWords {
    static func title(_ decision: String) -> String {
        switch decision {
        case "yes": "Looked into it"
        case "quiet": "Stayed quiet"
        case "offLimits": "Off limits"
        case "repeat": "Already seen"
        case "ownChange": "Its own change"
        case "paused": "Paused"
        case "museWorked": "Acted"
        case "museQuiet": "Chose to wait"
        default: decision
        }
    }
}
