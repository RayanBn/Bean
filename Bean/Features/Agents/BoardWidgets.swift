import SwiftUI

struct WidgetContext {
    let spec: WidgetSpec
    let agent: Agent
    let items: [WorkItem]
    let activity: [UUID: AgentActivity]
    let everyone: [Agent]
    let feed: PageFeed
    let actions: PageActions
    var asksAbove = false

    var item: WorkItem? {
        if let session = spec.session { return items.first { $0.session?.id == session } }
        return items.first { $0.state == .waiting } ?? items.first { $0.session != nil } ?? items.first
    }
    var session: AgentWorker.DrivenSession? {
        if let session = spec.session { return feed.sessions[agent.id]?.first { $0.id == session } }
        return items.first { $0.session != nil }?.session
    }
}

// One case and its answers are all a new widget needs.
enum BoardWidget: String, Codable, CaseIterable, Identifiable {
    case action, plan, terminal, changes, github, linear, app, cost, connector, window, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .action: "Action"
        case .plan: "Plan"
        case .terminal: "Terminal"
        case .changes: "Changes"
        case .github: "GitHub"
        case .linear: "Linear"
        case .app: "App"
        case .cost: "Cost"
        case .connector: "Service"
        case .window: "Window"
        case .about: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .action: "bolt"
        case .plan: "list.bullet"
        case .terminal: "terminal"
        case .changes: "plusminus"
        case .github: "arrow.triangle.pull"
        case .linear: "checklist"
        case .app: "macwindow"
        case .cost: "dollarsign.circle"
        case .connector: "link"
        case .window: "macwindow.on.rectangle"
        case .about: "slider.horizontal.3"
        }
    }

    var size: (w: Int, h: Int) {
        switch self {
        case .action: (4, 14)
        case .plan: (4, 5)
        case .terminal: (6, 10)
        case .changes: (5, 10)
        case .github: (4, 9)
        case .linear, .connector: (4, 9)
        case .app, .window: (5, 11)
        case .cost: (3, 5)
        case .about: (4, 14)
        }
    }

    var isListedAlone: Bool { self != .connector && self != .window }

    func hasData(_ context: WidgetContext) -> Bool {
        switch self {
        case .action, .about, .cost: true
        case .plan: !PlanWidget.steps(for: context).isEmpty
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
                Conversation(agent: context.agent, crew: context.everyone, activity: context.activity, feed: context.feed, actions: context.actions, asksAbove: context.asksAbove)
            }
        case .plan: PlanWidget(context: context)
        case .terminal: if let session = context.session { TerminalWidget(context: context, session: session) }
        case .changes: if let session = context.session { ChangesWidget(context: context, session: session) }
        case .github: if let link = context.session?.pullRequest { GitHubWidget(link: link) }
        case .linear: if let ticket = LinearWidget.ticket(in: context) { LinearWidget(context: context, ticket: ticket) }
        case .app: if let attachment = context.agent.attachment { WindowWidget(attachment: attachment) }
        case .cost: CostWidget(context: context)
        case .connector:
            if let parts = context.spec.param?.split(separator: "|").map(String.init), parts.count == 2 {
                ConnectorWidget(server: parts[0], tool: parts[1], actions: context.actions)
            }
        case .window:
            if let attachment = context.spec.param.flatMap(Int.init).flatMap({ WindowWidget.attachment(for: $0, windows: context.feed.openWindows) }) {
                WindowWidget(attachment: attachment)
            }
        case .about: AgentInspector(agent: context.agent, mission: context.feed.missions[context.agent.id], targets: context.feed.targets[context.agent.id] ?? [], connectors: context.feed.connectors[context.agent.id] ?? [], allAbilities: context.feed.abilities[context.agent.id] ?? [], spend: context.feed.spend[context.agent.id], actions: context.actions)
        }
    }
}

enum BoardDefaults {
    static func work(_ agent: Agent, feed: PageFeed) -> [WorkItem] {
        let items = WorkItem.items(of: agent, feed: feed)
        return items.filter { $0.state == .waiting } + items.filter { $0.state == .running } + items.filter(\.isEnded)
    }

    static func board(for agent: Agent, feed: PageFeed) -> (key: String, widgets: [WidgetSpec]) {
        let coding = !(feed.sessions[agent.id] ?? []).isEmpty
        let id = agent.id
        let widgets: [WidgetSpec] = coding ? [
            WidgetSpec(kind: .action, agent: id, x: 0, y: 0, w: 4, h: 18),
            WidgetSpec(kind: .changes, agent: id, x: 4, y: 0, w: 4, h: 9),
            WidgetSpec(kind: .terminal, agent: id, x: 4, y: 9, w: 4, h: 9),
            WidgetSpec(kind: .linear, agent: id, x: 8, y: 0, w: 4, h: 8),
            WidgetSpec(kind: .github, agent: id, x: 8, y: 8, w: 4, h: 10),
        ] : [
            WidgetSpec(kind: .app, agent: id, x: 0, y: 0, w: 6, h: 10),
            WidgetSpec(kind: .action, agent: id, x: 0, y: 10, w: 6, h: 10),
            WidgetSpec(kind: .cost, agent: id, x: 6, y: 0, w: 6, h: 6),
            WidgetSpec(kind: .about, agent: id, x: 6, y: 6, w: 6, h: 14),
        ]
        return (coding ? "coding" : "plain", widgets)
    }

    static func all(_ crew: [Agent]) -> (key: String, widgets: [WidgetSpec]) {
        let width = BoardGrid.columns / max(1, min(crew.count, 3))
        let perRow = BoardGrid.columns / width
        let widgets = crew.enumerated().map { index, agent in
            WidgetSpec(kind: .action, agent: agent.id, x: (index % perRow) * width, y: (index / perRow) * 14, w: width, h: 14)
        }
        return (crew.map(\.id.uuidString).joined(), widgets)
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
                        Text(item.title).font(.callout.weight(.medium)).lineLimit(1).help(item.title)
                        Text(AgentStrings.shown(item.state.title)).font(.caption).foregroundStyle(item.state == .waiting ? Color.orange : .secondary)
                    }
                    Spacer(minLength: 4)
                    if let session = item.session, session.costUSD > 0 {
                        Text(pageMoney(session.costUSD)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if !item.isEnded, let session = item.session, session.status != .takenOver, let stop = context.actions.stopSession {
                        Button(AgentStrings.shown("Stop"), systemImage: "stop.fill") { stop(agent.id, session.id) }
                            .controlSize(.small)
                            .accessibilityIdentifier("page-work-stop")
                    }
                }
                LiveSteps(item: item)
                if !context.asksAbove, let need = item.need {
                    QuestionCard(need: need, name: agent.name, more: 0, inset: 0, answer: { context.actions.answer(agent.id, need.id, $0) }, later: {}, connect: context.actions.connectService)
                        .id(need.id)
                }
            } else {
                Text(AgentStrings.shown("Nothing to do yet")).font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            TalkField(hint: AgentStrings.shown("Tell %@ something", agent.name)) { text in
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
                        Button(AgentStrings.shown(tab.title)) { terminals.chosen[key] = tab.id }
                            .buttonStyle(.plain)
                            .font(.caption.weight(terminals.chosen[key] == tab.id ? .semibold : .regular))
                        Button { terminals.close(key, tab: tab.id) } label: { Image(systemName: "xmark").font(.system(size: 8)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel(AgentStrings.shown("Close"))
                    }
                    .padding(.horizontal, 6).frame(height: 20)
                    .background(terminals.chosen[key] == tab.id ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 5))
                }
                Button { terminals.openShell(key, folder: session.folder) } label: { Image(systemName: "plus").font(.caption) }
                    .buttonStyle(.plain)
                    .disabled(!hasFolder)
                    .help(AgentStrings.shown("New terminal in this session's folder"))
                    .accessibilityLabel(AgentStrings.shown("New terminal"))
                    .accessibilityIdentifier("page-terminal-new")
                Spacer()
                if session.status != .takenOver, let takeOver = context.actions.takeOver {
                    Button(AgentStrings.shown("Take Over"), systemImage: "arrow.right.circle") {
                        startingTakeOver = true
                        Task { @MainActor in
                            if let start = await takeOver(context.agent.id, session.id) {
                                problem = nil
                                let agent = context.agent.id, id = session.id, end = context.actions.endTakeOver
                                terminals.add(key, title: "Take Over", start: TerminalStart(folder: start.folder, executable: start.command[0], arguments: Array(start.command.dropFirst()))) { end?(agent, id) }
                            } else {
                                problem = AgentStrings.shown("This session cannot be taken over yet.")
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
                    if !hasFolder { Text(AgentStrings.shown("This session's folder is gone.")).font(.caption).foregroundStyle(.tertiary) }
                    if let problem { Text(problem).font(.caption).foregroundStyle(.orange) }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if !tabs.isEmpty || hasFolder {
                Text(AgentStrings.shown("Take Over stops Bean's work on this session. Here you drive it yourself, and Bean's limits no longer apply. Claude may first ask you to trust its folder: only you can answer that."))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(2).padding(.horizontal, 8).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { if tabs.isEmpty, hasFolder { terminals.openShell(key, folder: session.folder) } }
    }
}

struct BoardCatalogue: View {
    let agents: [Agent]
    let fixedAgent: Agent?
    let feed: PageFeed
    let actions: PageActions
    let add: (BoardWidget, UUID, String?) -> Void
    @State private var chosen: UUID?
    @State private var services: [(server: String, tools: [String])] = []

    private var agent: Agent? { fixedAgent ?? agents.first { $0.id == chosen } ?? agents.first }
    private var windows: [OpenWindow] { feed.openWindows.filter(WindowWidget.isOpenToBoard) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if fixedAgent == nil {
                    Picker(AgentStrings.shown("Agent"), selection: Binding(get: { agent?.id }, set: { chosen = $0 })) {
                        ForEach(agents) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("page-catalogue-agent")
                }
                if let agent {
                    ForEach(BoardWidget.allCases.filter(\.isListedAlone)) { kind in
                        let context = WidgetContext(spec: WidgetSpec(kind: kind, agent: agent.id, x: 0, y: 0, w: 1, h: 1), agent: agent, items: BoardDefaults.work(agent, feed: feed), activity: [:], everyone: agents, feed: feed, actions: actions)
                        if kind.hasData(context) {
                            row(AgentStrings.shown(kind.title), kind.icon, id: kind.rawValue) { add(kind, agent.id, nil) }
                        }
                    }
                    if !services.isEmpty {
                        Divider().padding(.vertical, 2)
                        Text(AgentStrings.shown("Services")).font(.caption).foregroundStyle(.secondary)
                        ForEach(services, id: \.server) { service in
                            ForEach(service.tools, id: \.self) { tool in
                                row("\(service.server): \(tool)", BoardWidget.connector.icon, id: "connector") { add(.connector, agent.id, "\(service.server)|\(tool)") }
                            }
                        }
                    }
                    if !windows.isEmpty {
                        Divider().padding(.vertical, 2)
                        Text(AgentStrings.shown("Windows")).font(.caption).foregroundStyle(.secondary)
                        ForEach(windows, id: \.number) { window in
                            row([window.app, window.title].compactMap { $0 }.joined(separator: ": "), BoardWidget.window.icon, id: "window") { add(.window, agent.id, String(window.number)) }
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 280, height: 380)
        .task {
            var found: [(server: String, tools: [String])] = []
            for server in await actions.connectedServices?() ?? [] {
                let tools = await actions.connectorReads?(server) ?? []
                if !tools.isEmpty { found.append((server, tools)) }
            }
            services = found
        }
    }

    private func row(_ title: String, _ icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .help(title)
        .accessibilityIdentifier("page-catalogue-\(id)")
    }
}

struct BoardPage: View {
    let boardID: String
    let bean: Agent?
    let crew: [Agent]
    let activity: [UUID: AgentActivity]
    let feed: PageFeed
    let actions: PageActions
    @ObservedObject private var store = BoardStore.shared

    private var everyone: [Agent] { crew + (bean.map { [$0] } ?? []) }

    private var widgets: [WidgetSpec] {
        store.widgets(board: boardID) {
            if boardID == BoardStore.allBoard { return BoardDefaults.all(BoardPage.ordered(crew, feed: feed)) }
            guard let agent = everyone.first(where: { $0.id.uuidString == boardID }) else { return ("none", []) }
            return BoardDefaults.board(for: agent, feed: feed)
        }
    }

    private func context(_ spec: WidgetSpec) -> WidgetContext? {
        everyone.first { $0.id == spec.agent }.map { WidgetContext(spec: spec, agent: $0, items: BoardDefaults.work($0, feed: feed), activity: activity, everyone: everyone, feed: feed, actions: actions, asksAbove: boardID != BoardStore.allBoard) }
    }

    // A widget with no real data stays out of sight, and a board nobody arranged closes the gap it leaves.
    private var shown: [WidgetSpec] {
        let live = widgets.filter { spec in context(spec).map { spec.kind.hasData($0) } ?? false }
        return store.saved[boardID] == nil ? BoardGrid.compacted(BoardGrid.filled(live)) : live
    }

    static func ordered(_ crew: [Agent], feed: PageFeed) -> [Agent] {
        func rank(_ agent: Agent) -> Int {
            switch BoardDefaults.work(agent, feed: feed).first?.state {
            case .waiting: 0
            case .running: 1
            case .finished, .stopped: 2
            case nil: 3
            }
        }
        return crew.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    var body: some View {
        BoardView(widgets: shown, save: { store.save($0, board: boardID) }) { spec in
            if let context = context(spec) {
                let agent = context.agent
                WidgetChrome(title: AgentStrings.shown(spec.kind.title), icon: spec.kind.icon, agent: boardID == BoardStore.allBoard ? agent : nil, close: { store.save(BoardGrid.compacted(widgets.filter { $0.id != spec.id }), board: boardID) }) {
                    EmptyView()
                } content: {
                    spec.kind.view(context)
                }
            }
        }
    }

    func add(_ kind: BoardWidget, agent: UUID, param: String?) {
        let size = kind.size
        store.save(BoardGrid.placing(WidgetSpec(kind: kind, agent: agent, param: param, x: 0, y: 0, w: size.w, h: size.h), among: widgets), board: boardID)
    }
}
