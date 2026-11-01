import SwiftUI

// The one list of what can go on a board: every kind in plain words, any window by its picture, each connected service.
struct BoardPicker: View {
    let context: WidgetContext
    let shownOnBoard: [BoardWidget]
    let choose: (BoardWidget, String?) -> Void
    @State private var search = ""
    @State private var pictures: [Int: NSImage] = [:]
    @State private var services: [(server: String, tools: [String])] = []

    private var windows: [OpenWindow] { context.feed.openWindows.filter { BoardWindows.isOpen($0) && matches("\($0.app) \($0.title ?? "")") } }
    private var kinds: [BoardWidget] { BoardWidget.forAnAgent.filter { matches("\($0.title) \($0.blurb(context.name))") } }
    private var workServices: [WorkService] { WorkService.allCases.filter { matches("\($0.title) \($0.blurb)") } }

    private func matches(_ words: String) -> Bool {
        let wanted = search.trimmingCharacters(in: .whitespaces)
        return wanted.isEmpty || words.localizedCaseInsensitiveContains(wanted)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search widgets and windows", text: $search)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(8)
                .accessibilityIdentifier("page-picker-search")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !kinds.isEmpty || !workServices.isEmpty {
                        section(String(format: "About %@", context.name)) {
                            ForEach(kinds) { kind in
                                row(title: kind.title, icon: kind.icon, blurb: kind.blurb(context.name), on: shownOnBoard.contains(kind), id: kind.rawValue) { choose(kind, nil) }
                            }
                            ForEach(workServices) { service in
                                row(title: service.title, icon: service.icon, blurb: service.blurb, on: false, id: service.rawValue) { choose(.connector, service.rawValue) }
                            }
                        }
                    }
                    if !windows.isEmpty {
                        section("Any window on your Mac") {
                            Text(SpaceWindows.picturesWork ? "Keep an eye on a window, live, or hand its app to \(context.name)." : "Keep an eye on a window, or hand its app to \(context.name). Turn on Screen Recording for live pictures.")
                                .font(.widgetSmall).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.bottom, 2)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                                ForEach(windows, id: \.number) { tile($0) }
                            }
                        }
                    }
                    section("Your services") {
                        ForEach(services, id: \.server) { service in
                            ForEach(service.tools.filter { matches("\(service.server) \($0)") }, id: \.self) { tool in
                                row(title: AbilityFinder.humanized(tool), icon: BoardWidget.connector.icon, blurb: "From \(service.server), kept up to date.", on: false, id: tool) { choose(.connector, "\(service.server)|\(tool)") }
                            }
                        }
                        if services.isEmpty {
                            Button("Connect a Service…", action: context.actions.openSettings).controlSize(.small).accessibilityIdentifier("page-picker-connect")
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Text("Drag a widget by its title to move it. Drag the gap between two widgets to resize them.")
                .font(.widgetSmall).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            var found: [(server: String, tools: [String])] = []
            for server in await context.actions.connectedServices?() ?? [] {
                let tools = await context.actions.connectorReads?(server) ?? []
                if !tools.isEmpty { found.append((server, tools)) }
            }
            services = found
        }
        .task {
            for window in context.feed.openWindows.filter(BoardWindows.isOpen).prefix(16) where !Task.isCancelled {
                if let picture = await WindowPictures.shared.picture(of: window.number, width: 200) { pictures[window.number] = picture }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Font.widgetSmall.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 2)
            content()
        }
    }

    private func row(title: String, icon: String, blurb: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 24, height: 24)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(Font.widgetBody.weight(.medium))
                    Text(blurb).font(.widgetSmall).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                if on { Image(systemName: "checkmark").font(.widgetSmall).foregroundStyle(.secondary).help("Already on the board. You can add another.") }
            }
            .padding(.vertical, 1).padding(.horizontal, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("page-picker-\(id)")
    }

    private func tile(_ window: OpenWindow) -> some View {
        Button { choose(.window, String(window.number)) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if let picture = pictures[window.number] {
                        Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        AppIcon(bundleId: window.bundleId, size: 28)
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 62)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                HStack(spacing: 4) {
                    AppIcon(bundleId: window.bundleId, size: 12)
                    Text(window.app).font(Font.widgetSmall.weight(.medium)).lineLimit(1)
                }
                Text(window.title ?? "Untitled").font(.widgetSmall).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help([window.app, window.title].compactMap { $0 }.joined(separator: ": "))
        .accessibilityIdentifier("page-picker-window")
    }
}

extension WorkService {
    var blurb: String {
        switch self {
        case .pullRequest: "The pull request it opened: its state and checks."
        case .ticket: "The ticket it works on, from your connected service."
        }
    }
}
