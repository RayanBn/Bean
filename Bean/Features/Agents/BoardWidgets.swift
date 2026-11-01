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
}

// One case and its answers are all a new widget needs.
enum BoardWidget: String, Codable, CaseIterable, Identifiable {
    case action, history, terminal, changes, github, linear, plan, app, connector, window

    var id: String { rawValue }

    var title: String {
        switch self {
        case .action: "Action"
        case .history: "History"
        case .plan: "Plan"
        case .terminal: "Terminal"
        case .changes: "Changes"
        case .github: "GitHub"
        case .linear: "Linear"
        case .app: "App"
        case .connector: "Service"
        case .window: "Window"
        }
    }

    var icon: String {
        switch self {
        case .action: "bolt"
        case .history: "clock"
        case .plan: "list.bullet"
        case .terminal: "terminal"
        case .changes: "plusminus"
        case .github: "arrow.triangle.pull"
        case .linear: "checklist"
        case .app: "macwindow"
        case .connector: "link"
        case .window: "macwindow.on.rectangle"
        }
    }

    var isListedAlone: Bool { self != .connector && self != .window }

    func hasData(_ context: WidgetContext) -> Bool {
        switch self {
        case .action: true
        case .history: context.session != nil
        case .plan: !context.feed.plan.isEmpty
        case .terminal, .changes: context.session != nil
        case .github: context.session?.pullRequest != nil
        case .linear: LinearWidget.ticket(in: context) != nil
        case .app: context.agent.attachment != nil
        case .connector: context.spec.param != nil
        case .window: context.spec.param.flatMap(Int.init).flatMap { WindowWidget.attachment(for: $0, windows: context.feed.openWindows) } != nil
        }
    }

    @ViewBuilder func view(_ context: WidgetContext) -> some View {
        switch self {
        case .action:
            if context.session != nil {
                ActionWidget(context: context)
            } else {
                Conversation(agent: context.agent, crew: context.everyone, activity: context.activity, feed: context.feed, actions: context.actions)
            }
        case .history: Conversation(agent: context.agent, crew: context.everyone, activity: context.activity, feed: context.feed, actions: context.actions)
        case .plan: PlanWidget(context: context)
        case .terminal: if let session = context.session { TerminalWidget(context: context, session: session) }
        case .changes: if let session = context.session { ChangesWidget(context: context, session: session) }
        case .github: if let link = context.session?.pullRequest { GitHubWidget(link: link) }
        case .linear: if let ticket = LinearWidget.ticket(in: context) { LinearWidget(context: context, ticket: ticket) }
        case .app: if let attachment = context.agent.attachment { WindowWidget(attachment: attachment) }
        case .connector:
            if let parts = context.spec.param?.split(separator: "|").map(String.init), parts.count == 2 {
                ConnectorWidget(server: parts[0], tool: parts[1], actions: context.actions)
            }
        case .window:
            if let attachment = context.spec.param.flatMap(Int.init).flatMap({ WindowWidget.attachment(for: $0, windows: context.feed.openWindows) }) {
                WindowWidget(attachment: attachment)
            }
        }
    }
}

enum BoardDefaults {
    static func work(_ agent: Agent, feed: PageFeed) -> [WorkItem] {
        let items = WorkItem.items(of: agent, feed: feed)
        let ended = items.filter(\.isEnded).sorted { ($0.session?.startedAt ?? $0.at ?? .distantPast) > ($1.session?.startedAt ?? $1.at ?? .distantPast) }
        return items.filter { $0.state == .waiting } + items.filter { $0.state == .running } + ended
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

struct TerminalWidget: View {
    let context: WidgetContext
    let session: AgentWorker.DrivenSession
    @ObservedObject private var terminals = SessionTerminals.shared
    @State private var problem: String?
    @State private var startingTakeOver = false

    private var key: String { context.spec.id.uuidString }
    private var tabs: [SessionTerminals.Tab] { terminals.tabs[key] ?? [] }
    private var hasFolder: Bool { FileManager.default.fileExists(atPath: session.folder) }

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
                Button { terminals.openShell(key, folder: session.folder) } label: { Image(systemName: "plus").font(.widgetSmall) }
                    .buttonStyle(.plain)
                    .disabled(!hasFolder)
                    .help("New terminal in this session's folder")
                    .accessibilityLabel("New terminal")
                    .accessibilityIdentifier("page-terminal-new")
                Spacer()
                if session.status != .takenOver, let takeOver = context.actions.takeOver {
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
                    .disabled(!hasFolder || startingTakeOver)
                    .accessibilityIdentifier("page-terminal-takeover")
                }
            }
            .padding(.horizontal, 8).frame(height: 28)
            Divider()
            if let tab = tabs.first(where: { $0.id == terminals.chosen[key] }) {
                TerminalHost(view: tab.view).id(tab.id)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if !hasFolder { Text("This session's folder is gone.").font(.widgetSmall).foregroundStyle(.tertiary) }
                    if let problem { Text(problem).font(.widgetSmall).foregroundStyle(.orange) }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if !tabs.isEmpty || hasFolder {
                Text("Take Over stops Bean's work on this session. Here you drive it yourself, and Bean's limits no longer apply. The coding tool may first ask you to trust its folder: only you can answer that.")
                    .font(.widgetSmall).foregroundStyle(.tertiary).lineLimit(2).padding(.horizontal, 8).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { if tabs.isEmpty, hasFolder { terminals.openShell(key, folder: session.folder) } }
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

    var body: some View {
        PaneBoard(agent: agent.id, store: store, frames: $frames) { spec, grab in
            let owner = everyone.first { $0.id == spec.agent } ?? agent
            let context = WidgetContext(spec: spec, agent: owner, items: BoardDefaults.work(owner, feed: feed), activity: activity, everyone: everyone, feed: feed, actions: actions)
            VStack(spacing: 0) {
                PaneHeader(title: title(spec, context), icon: spec.kind.icon, grab: grab, close: { store.close(spec.id, for: agent.id) }) {
                    if everyone.filter({ !$0.isBean }).count > 1 { Menu {
                        ForEach(everyone.filter { !$0.isBean }) { member in
                            Button(member.name) { store.set(store.layout(for: agent.id).updating(spec.id) { $0.agent = member.id }, for: agent.id) }
                        }
                    } label: {
                        Text(owner.name).font(.widgetSmall)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityIdentifier("page-pane-agent") }
                }
                if spec.kind.hasData(context) {
                    spec.kind.view(context).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    Text(spec.kind == .window ? "This window is closed, or off limits." : "Nothing here yet.").font(.widgetBody).foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private func title(_ spec: PaneSpec, _ context: WidgetContext) -> String {
        if spec.kind == .window, let number = spec.param.flatMap(Int.init), let window = feed.openWindows.first(where: { $0.number == number }) {
            return window.app
        }
        if spec.kind == .connector, let param = spec.param { return param.replacingOccurrences(of: "|", with: ": ") }
        return spec.kind.title
    }
}
