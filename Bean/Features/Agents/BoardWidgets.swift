import SwiftUI

struct WidgetContext {
    let spec: PaneSpec
    let agent: Agent
    let items: [WorkItem]
    let activity: [UUID: AgentActivity]
    let everyone: [Agent]
    let feed: PageFeed
    let actions: PageActions

    var item: WorkItem? { items.first { $0.state == .waiting } ?? items.first { $0.session != nil } ?? items.first }
    var session: AgentWorker.DrivenSession? { items.first { $0.session != nil }?.session }
    var name: String { agent.name.isEmpty ? "This agent" : agent.name }

    var ticket: String? {
        let text = ([session?.task, item?.title] + (feed.journal[agent.id] ?? []).suffix(40).map(\.did)).compactMap { $0 }.joined(separator: " ")
        return text.firstMatch(of: /\b[A-Z]{2,6}-\d{1,5}\b/).map { String($0.0) }
    }

    var appChoices: [OpenWindow] {
        var seen = Set<String>()
        return feed.openWindows.filter { Skills.forApp($0.bundleId)?.sealed != true && OffLimits.match("\($0.app) \($0.bundleId) \($0.title ?? "")") == nil && seen.insert($0.bundleId.isEmpty ? $0.app : $0.bundleId).inserted }
    }
}

// One case and its answers are all a new widget needs. A widget with nothing to show still opens, and says what fills it.
enum BoardWidget: String, Codable, CaseIterable, Identifiable {
    case action, plan, changes, terminal, files, memory, history, connector, picker

    static let forAnAgent: [BoardWidget] = [.action, .plan, .changes, .terminal, .files, .memory, .history]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .action: "Now"
        case .plan: "Plan"
        case .changes: "Changes"
        case .terminal: "Terminal"
        case .files: "Files"
        case .memory: "Memory"
        case .history: "History"
        case .connector: "Service"
        case .picker: "Add a widget"
        }
    }

    var icon: String {
        switch self {
        case .action: "bolt"
        case .plan: "list.bullet"
        case .changes: "plusminus"
        case .terminal: "terminal"
        case .files: "folder"
        case .memory: "brain"
        case .history: "clock"
        case .connector: "link"
        case .picker: "plus"
        }
    }

    func blurb(_ name: String) -> String {
        switch self {
        case .action: "What \(name) is doing right now. Talk to it here."
        case .plan: "The steps it plans, with the one it is on."
        case .changes: "What it changed, in your apps and in files, with Undo where it can."
        case .terminal: "A real shell in its folder. You type, your Mac runs it."
        case .files: "The folder it works in. Open any file and read it here."
        case .memory: "What it keeps between runs, in plain files you can read."
        case .history: "Everything it did, run by run."
        case .connector: "Live data from a service you connected."
        case .picker: "Every kind of widget, explained."
        }
    }

    @MainActor @ViewBuilder func view(_ context: WidgetContext, frames: [UUID: CGRect]) -> some View {
        switch self {
        case .action:
            if context.session != nil {
                ActionWidget(context: context)
            } else {
                Conversation(agent: context.agent, crew: context.everyone, activity: context.activity, feed: context.feed, actions: context.actions)
            }
        case .history: HistoryWidget(context: context)
        case .plan: PlanWidget(context: context)
        case .terminal: TerminalWidget(context: context)
        case .changes: ChangesWidget(context: context)
        case .files: FilesWidget(context: context)
        case .memory: MemoryWidget(context: context)
        case .connector: ConnectorPane(context: context)
        case .picker:
            BoardPicker(context: context, shownOnBoard: PaneStore.shared.layout(for: context.spec.agent).panes.map(\.kind)) { kind, param in
                PaneStore.shared.add(PaneSpec(kind: kind, agent: context.spec.agent, param: param), for: context.spec.agent, frames: frames)
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
    }
}

struct AppIcon: View {
    let bundleId: String
    let size: CGFloat

    private var image: NSImage {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application)
    }

    var body: some View {
        Image(nsImage: image).resizable().frame(width: size, height: size)
    }
}

enum BoardDefaults {
    static func work(_ agent: Agent, feed: PageFeed) -> [WorkItem] {
        let items = WorkItem.items(of: agent, feed: feed)
        let ended = items.filter(\.isEnded).sorted { ($0.session?.startedAt ?? $0.at ?? .distantPast) > ($1.session?.startedAt ?? $1.at ?? .distantPast) }
        return items.filter { $0.state == .waiting } + items.filter { $0.state == .running } + ended
    }

    // What matters most about this agent goes beside what it is doing.
    static func first(for agent: Agent, feed: PageFeed) -> PaneNode {
        let onCode = feed.sessions[agent.id]?.isEmpty == false
        let (top, bottom): (BoardWidget, BoardWidget) = onCode ? (.changes, .terminal) : (.plan, .changes)
        func pane(_ kind: BoardWidget) -> PaneNode { .pane(PaneSpec(kind: kind, agent: agent.id)) }
        return .split(id: UUID(), vertical: false, ratio: 0.5, first: pane(.action), second: .split(id: UUID(), vertical: true, ratio: 0.55, first: pane(top), second: pane(bottom)))
    }
}

// The one shape of a widget with nothing in it: what it is, what fills it, and the step that fills it.
struct WidgetEmpty<Action: View>: View {
    let icon: String
    let title: String
    let text: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 20, weight: .light)).foregroundStyle(.tertiary).padding(.bottom, 2)
            Text(title).font(Font.system(size: 13, weight: .medium)).multilineTextAlignment(.center)
            Text(text).font(.widgetBody).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 300).fixedSize(horizontal: false, vertical: true)
            action().padding(.top, 6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension WidgetEmpty where Action == EmptyView {
    init(icon: String, title: String, text: String) {
        self.init(icon: icon, title: title, text: text) { EmptyView() }
    }
}

// Says what the agent is, where it is, and what it is doing, in one read.
struct AgentHeadline: View {
    let context: WidgetContext

    private var agent: Agent { context.agent }
    private var feed: PageFeed { context.feed }
    private var asking: AgentNeed? { feed.needs[agent.id]?.first(where: \.asksTheUser) }
    private var running: Bool { context.items.contains { $0.state == .running } || feed.live[agent.id] != nil }

    private var state: (word: String, line: String?) {
        if let asking { return ("Needs you", asking.question) }
        if feed.allPaused { return ("Paused", "All agents are paused.") }
        if feed.stopped.contains(agent.id) { return ("Stopped", "It waits until you press Resume.") }
        if running { return ("Working", AgentsPage.detail(of: agent, activity: context.activity[agent.id], feed: feed) ?? context.item?.title) }
        if agent.attachment != nil { return ("Idle", "It acts when its job calls for it.") }
        if context.session != nil { return ("Idle", "Its last session has ended.") }
        return ("Idle", AgentsPage.recent(of: agent, feed: feed) ?? "It has no app to work on yet.")
    }

    private var job: String {
        let goal = feed.missions[agent.id]?.mission ?? ""
        return goal.isEmpty ? agent.role : goal
    }

    var body: some View {
        HStack(spacing: 10) {
            PageDrop(look: agent.look, mood: asking == nil ? .idle : .needsYou, size: 24).modifier(AgentDragHandle(agent: agent, actions: context.actions))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if running && asking == nil { ProgressView().controlSize(.mini) }
                    Text(state.word).font(.system(size: 13, weight: .semibold)).foregroundStyle(asking == nil ? Color.primary : Color.orange).fixedSize()
                    if let line = state.line { Text(line).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1).help(line) }
                }
                .accessibilityIdentifier("page-headline-state")
                Text(job).font(.widgetSmall).foregroundStyle(.secondary).lineLimit(1).help(job)
            }
            Spacer(minLength: 8)
            place
            if running, asking == nil {
                Button("Stop", systemImage: "stop.fill") { context.actions.stopWork(agent.id) }.controlSize(.small).accessibilityIdentifier("page-headline-stop")
            } else if feed.stopped.contains(agent.id) {
                Button("Resume", systemImage: "play.fill") { context.actions.resumeWork(agent.id) }.controlSize(.small).accessibilityIdentifier("page-headline-resume")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private var place: some View {
        Menu {
            ForEach(context.appChoices, id: \.number) { window in
                Button(window.app) { context.actions.putOnApp(agent.id, window) }
            }
            if context.appChoices.isEmpty { Text("No apps are open.") }
            if agent.attachment != nil {
                Divider()
                Button(String(format: "Take %@ off %@", context.name, agent.attachment?.appName ?? "")) { context.actions.sendHome(agent.id) }
            }
        } label: {
            if let attachment = agent.attachment {
                Label { Text(String(format: "On %@", attachment.appName)) } icon: { AppIcon(bundleId: attachment.bundleId, size: 14) }
            } else {
                Label("Put on an App", systemImage: "arrow.down.to.line")
            }
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .help(agent.attachment == nil ? "Pick an app, or drag this agent's drop onto one." : "Where this agent works. Pick another app to move it.")
        .accessibilityIdentifier("page-headline-place")
    }
}

// Every widget of an agent, by name, one click away. A click shows it on the board, another click takes it off.
struct WidgetBar: View {
    let context: WidgetContext
    let panes: [PaneSpec]
    let toggle: (BoardWidget) -> Void
    let add: (BoardWidget, String?) -> Void
    @State private var filesChanged: (added: Int, removed: Int)?
    @State private var picking = false

    private var changeCount: Int { (context.feed.journal[context.agent.id] ?? []).filter { $0.kind == .action }.count }

    private func isOn(_ kind: BoardWidget) -> Bool { panes.contains { $0.kind == kind && $0.agent == context.agent.id } }

    var body: some View {
        HStack(spacing: 2) {
            ViewThatFits(in: .horizontal) {
                chips(named: true)
                chips(named: false)
            }
            Spacer(minLength: 6)
            Button { picking = true } label: {
                Label("Add Widget", systemImage: "plus").font(.widgetBody.weight(.medium))
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .fixedSize()
            .help("See every kind of widget")
            .accessibilityIdentifier("page-add")
            .popover(isPresented: $picking, arrowEdge: .bottom) {
                BoardPicker(context: context, shownOnBoard: panes.filter { $0.agent == context.agent.id }.map(\.kind)) { kind, param in
                    picking = false
                    add(kind, param)
                }
                .frame(width: 420, height: 390)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .task(id: context.session?.id) {
            guard let session = context.session else { filesChanged = nil; return }
            while !Task.isCancelled {
                await PageVisibility.wait()
                if let fresh = await context.actions.sessionChanges?(context.agent.id, session.id) { filesChanged = (fresh.added, fresh.removed) }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func chips(named: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(BoardWidget.forAnAgent) { kind in
                Button { toggle(kind) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: kind.icon).font(.system(size: 11))
                        if named { Text(kind.title).font(.widgetBody) }
                        if kind == .changes { changeBadge }
                    }
                    .foregroundStyle(isOn(kind) ? Color.primary : Color.secondary)
                    .padding(.horizontal, named ? 7 : 6).frame(height: 22)
                    .background(isOn(kind) ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("\(kind.title): \(kind.blurb(context.name))")
                .accessibilityLabel(kind.title)
                .accessibilityIdentifier("page-chip-\(kind.rawValue)")
            }
        }
    }

    @ViewBuilder private var changeBadge: some View {
        if let filesChanged, filesChanged.added + filesChanged.removed > 0 {
            Text("+\(filesChanged.added)").font(.widgetSmall).foregroundStyle(.green)
            Text("−\(filesChanged.removed)").font(.widgetSmall).foregroundStyle(.red)
        } else if changeCount > 0 {
            Text("\(changeCount)").font(.widgetSmall).foregroundStyle(.secondary)
        }
    }
}

struct ActionWidget: View {
    let context: WidgetContext
    @State private var problem: String?

    private var item: WorkItem? { context.item }
    private var agent: Agent { context.agent }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item {
                HStack(spacing: 6) {
                    WorkMark(state: item.state).controlSize(.small)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.title).font(Font.widgetBody.weight(.medium)).lineLimit(1).help(item.title)
                        Text(item.state.title).font(.widgetSmall).foregroundStyle(item.state == .waiting ? Color.orange : .secondary)
                    }
                    Spacer(minLength: 4)
                    if !item.isEnded, let session = item.session, session.status != .takenOver, let stop = context.actions.stopSession {
                        Button("Stop", systemImage: "stop.fill") { stop(agent.id, session.id) }
                            .controlSize(.small)
                            .accessibilityIdentifier("page-work-stop")
                    } else if item.state == .stopped, context.feed.stopped.contains(agent.id) {
                        Button("Resume", systemImage: "play.fill") { context.actions.resumeWork(agent.id) }
                            .controlSize(.small)
                            .accessibilityIdentifier("page-work-resume")
                    }
                }
                if let tasks = item.session?.tasks, !tasks.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(tasks) { task in
                            Label(task.subject, systemImage: task.status == "completed" ? "checkmark.circle" : task.status == "in_progress" ? "circle.dashed" : "circle").font(.widgetSmall).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                LiveSteps(item: item)
                if let need = item.need {
                    QuestionCard(need: need, name: agent.name, more: 0, inset: 0, answer: { context.actions.answer(agent.id, need.id, $0) }, later: {}, connect: context.actions.connectService)
                        .id(need.id)
                }
            } else {
                Text("Nothing to do yet").font(.widgetBody).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if let problem { Text(problem).font(.widgetSmall).foregroundStyle(.orange) }
            TalkField(hint: String(format: "Tell %@ something", agent.name)) { text in
                if let session = item?.session, let send = context.actions.sendToSession {
                    problem = send(agent.id, session.id, text)
                } else {
                    context.actions.send(agent.id, text)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// A shell belongs to a place, not to a running session: it opens in the agent's folder as soon as the widget shows.
struct TerminalWidget: View {
    let context: WidgetContext
    @ObservedObject private var terminals = SessionTerminals.shared
    @State private var place: AgentPlace?
    @State private var problem: String?
    @State private var startingTakeOver = false

    private var key: String { context.spec.id.uuidString }
    private var tabs: [SessionTerminals.Tab] { terminals.tabs[key] ?? [] }
    private var session: AgentWorker.DrivenSession? { context.session }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    HStack(spacing: 4) {
                        Button(tab.title) { terminals.chosen[key] = tab.id }
                            .buttonStyle(.plain)
                            .font(.caption.weight(terminals.chosen[key] == tab.id ? .semibold : .regular))
                        Button { terminals.close(key, tab: tab.id) } label: { Image(systemName: "xmark").font(.system(size: 8)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Close")
                    }
                    .padding(.horizontal, 6).frame(height: 20)
                    .background(terminals.chosen[key] == tab.id ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 5))
                }
                Button { if let place { terminals.openShell(key, folder: place.path) } } label: { Image(systemName: "plus").font(.widgetSmall) }
                    .buttonStyle(.plain)
                    .disabled(place == nil)
                    .help("New terminal in this folder")
                    .accessibilityLabel("New terminal")
                    .accessibilityIdentifier("page-terminal-new")
                Spacer(minLength: 8)
                if let place {
                    Text(place.shortPath).font(.widgetMono).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head).help("\(place.words): \(place.path)")
                        .accessibilityIdentifier("page-terminal-folder")
                }
                if let session, session.status != .takenOver, let takeOver = context.actions.takeOver {
                    Button("Take Over", systemImage: "arrow.right.circle") {
                        startingTakeOver = true
                        Task { @MainActor in
                            if let start = await takeOver(context.agent.id, session.id) {
                                problem = nil
                                let agent = context.agent.id, id = session.id, end = context.actions.endTakeOver
                                terminals.add(key, title: "Take Over", start: TerminalStart(folder: start.folder, executable: start.command[0], arguments: Array(start.command.dropFirst()))) { end?(agent, id) }
                            } else {
                                problem = "This session cannot be taken over yet."
                            }
                            startingTakeOver = false
                        }
                    }
                    .controlSize(.small)
                    .disabled(!FileManager.default.fileExists(atPath: session.folder) || startingTakeOver)
                    .help("Stops Bean's work on this session, and you drive it here. Bean's limits no longer apply. The coding tool may first ask you to trust its folder: only you can answer that.")
                    .accessibilityIdentifier("page-terminal-takeover")
                }
            }
            .padding(.horizontal, 8).frame(height: 28)
            Divider()
            if let tab = tabs.first(where: { $0.id == terminals.chosen[key] }) {
                TerminalHost(view: tab.view).id(tab.id)
            } else if place != nil {
                WidgetEmpty(icon: "terminal", title: "No terminal open", text: "Open one to run commands in \(context.name)'s folder.") {
                    Button("New Terminal") { if let place { terminals.openShell(key, folder: place.path) } }.controlSize(.small)
                }
            } else {
                Color.clear
            }
            if let problem { Text(problem).font(.widgetSmall).foregroundStyle(.orange).padding(6) }
        }
        .task(id: session?.folder) {
            guard let first = await AgentPlaces.read(context).first else { return }
            place = first
            if tabs.isEmpty { terminals.openShell(key, folder: first.path) }
        }
    }
}

struct PaneStage: View {
    let agent: Agent
    let everyone: [Agent]
    let activity: [UUID: AgentActivity]
    let feed: PageFeed
    let actions: PageActions
    @Binding var frames: [UUID: CGRect]
    @ObservedObject private var store = PaneStore.shared

    private func context(_ spec: PaneSpec) -> WidgetContext {
        let owner = everyone.first { $0.id == spec.agent } ?? agent
        return WidgetContext(spec: spec, agent: owner, items: BoardDefaults.work(owner, feed: feed), activity: activity, everyone: everyone, feed: feed, actions: actions)
    }

    private var panes: [PaneSpec] { store.layout(for: agent.id).panes }

    var body: some View {
        let own = context(PaneSpec(kind: .picker, agent: agent.id))
        VStack(spacing: 0) {
            AgentHeadline(context: own)
            WidgetBar(context: own, panes: panes, toggle: toggle, add: add).padding(.bottom, 3)
            board.padding(3).background(.quaternary.opacity(0.35))
        }
        .onAppear { store.begin(agent.id, with: BoardDefaults.first(for: agent, feed: feed)) }
    }

    private var board: some View {
        PaneBoard(agent: agent.id, store: store, frames: $frames) { spec, grab in
            let context = context(spec)
            let others = everyone.filter { !$0.isBean }
            VStack(spacing: 0) {
                PaneHeader(title: title(spec, context), icon: spec.param.flatMap(WorkService.init)?.icon ?? spec.kind.icon, keepsAccessory: context.agent.id != agent.id, grab: grab, close: { close(spec) }) {
                    if others.count > 1, spec.kind != .picker { Menu {
                        ForEach(others) { member in
                            Button(member.name) { store.set(store.layout(for: agent.id).updating(spec.id) { $0.agent = member.id }, for: agent.id) }
                        }
                    } label: {
                        Text(context.agent.name).font(.widgetSmall)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Which agent this widget follows")
                    .accessibilityIdentifier("page-pane-agent") }
                }
                spec.kind.view(context, frames: frames).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.separator))
            .padding(3)
        }
    }

    private func close(_ spec: PaneSpec) {
        SessionTerminals.shared.closeAll(spec.id.uuidString)
        store.close(spec.id, for: agent.id)
    }

    private func add(_ kind: BoardWidget, _ param: String?) {
        store.add(PaneSpec(kind: kind, agent: agent.id, param: param), for: agent.id, frames: frames)
    }

    private func toggle(_ kind: BoardWidget) {
        let shown = panes.filter { $0.kind == kind && $0.agent == agent.id }
        if shown.isEmpty { add(kind, nil) } else { shown.forEach(close) }
    }

    private func title(_ spec: PaneSpec, _ context: WidgetContext) -> String {
        if spec.kind == .connector, let param = spec.param { return WorkService(rawValue: param)?.title ?? param.replacingOccurrences(of: "|", with: ": ") }
        return spec.kind.title
    }
}
