import AppKit
import SwiftUI

struct PageFeed {
    var journal: [UUID: [JournalEntry]] = [:]
    var doing: [UUID: String] = [:]
    var sessions: [UUID: [AgentWorker.DrivenSession]] = [:]
    var missions: [UUID: AgentMission] = [:]
    var needsKey = false
    var needsAccessibility = false
    var notificationsOff = false
    var problem: String?
    var allPaused = false
    var needs: [UUID: [AgentNeed]] = [:]
    var decisions: [UUID: [AgentDecision]] = [:]
    var summaries: [UUID: AwaySummary] = [:]
    var catalogue: [ConnectorEntry] = []
    var openWindows: [OpenWindow] = []
    var listening: [UUID: Date] = [:]
    var gate: [GateEntry] = []
    var sees = WhatBeanSees()
    var thoughts: [UUID: AgentWorker.Thought] = [:]
    var awaySince = Calendar.current.startOfDay(for: Date())
    var awayEnded = Date()
    var targets: [UUID: [AgentTarget]] = [:]
    var connectors: [UUID: [AgentConnectorInfo]] = [:]
    var abilities: [UUID: [AgentAbility]] = [:]
    var replying: Set<UUID> = []
    var doingSince: [UUID: Date] = [:]
    var endedWork: [AgentWorker.EndedWork] = []
    var windowText: [UUID: String] = [:]
    var sessionEvents: [String: [SessionEvent]] = [:]
    var plan: [PlanStep] = []
}

struct PageActions {
    var select: (UUID) -> Void = { _ in }
    var openSettings: () -> Void = {}
    var closeSettings: () -> Void = {}
    var pauseAll: () -> Void = {}
    var setLook: (UUID, Agent.Look) -> Void = { _, _ in }
    var setSettingsTab: (SettingsTab) -> Void = { _ in }
    var watchSees: (Bool) -> Void = { _ in }
    var putAgent: (OpenWindow) -> Void = { _ in }
    var connectService: (String) -> Void = { _ in }
    var disconnectService: (String) -> Void = { _ in }
    var refreshConnectors: () async -> Void = {}
    var searchConnectors: (String) async -> [ConnectorEntry] = { _ in [] }
    var addConnector: (String) async throws -> ConnectorEntry? = { _ in nil }
    var requestAccessibility: () -> Void = {}
    var openNotificationSettings: () -> Void = {}
    var retry: () -> Void = {}
    var resume: () -> Void = {}
    var answer: (UUID, UUID, String) -> Void = { _, _, _ in }
    var correct: (UUID, UUID, String) -> Void = { _, _, _ in }
    var beginDrag: (UUID) -> Void = { _ in }
    var endDrag: () -> Void = {}
    var newAgent: () -> Void = {}
    var addKey: () -> Void = {}
    var cancelNew: () -> Void = {}
    var create: (String) -> Void = { _ in }
    var send: (UUID, String) -> Void = { _, _ in }
    var saveMission: (UUID, String) -> Void = { _, _ in }
    var rename: (UUID, String) -> Void = { _, _ in }
    var undo: (UUID, UUID) -> Void = { _, _ in }
    var setAbility: (UUID, String, Bool) -> Void = { _, _, _ in }
    var senses: (UUID) -> [SenseRow] = { _ in [] }
    var setSense: (UUID, String, Bool) -> Void = { _, _, _ in }
    var connect: (UUID, String) -> Void = { _, _ in }
    var removeTarget: (UUID, AgentTarget) -> Void = { _, _ in }
    var sendHome: (UUID) -> Void = { _ in }
    var delete: (UUID) -> Void = { _ in }
    var reveal: (UUID) -> Void = { _ in }
    var refreshWork: () -> Void = {}
    var setLanguage: (String?) -> Void = { _ in }
    var stopSession: ((UUID, String) -> Void)?
    var openSessionInTerminal: ((UUID, String) -> String?)?
    var sendToSession: ((UUID, String, String) -> String?)?
    var takeOver: ((UUID, String) async -> SessionTakeOver?)?
    var endTakeOver: ((UUID, String) -> Void)?
    var sessionChanges: ((UUID, String) async -> SessionChanges?)?
    var connectedServices: (() async -> [String])?
    var connectorReads: ((String) async -> [String])?
    var readConnector: ((String, String, JSONArgs) async -> ToolOutput)?
}

struct AgentsPageRoot: View {
    @ObservedObject var agents: Agents
    @ObservedObject var store: AgentStore
    @ObservedObject var worker: AgentWorker
    @ObservedObject private var settings = BeanSettings.shared
    @ObservedObject var catalogue: ConnectorCatalogue

    var body: some View {
        AgentsPage(agents: store.agents, activity: store.activity, feed: agents.feed, selected: agents.selected, settingsTab: agents.settingsTab, settingsOpen: agents.settingsOpen, creating: agents.creating,
                   creationError: agents.creationError, actions: agents.actions)
    }
}

enum PageStatus: CaseIterable {
    case needsYou, working, idle

    var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .idle: "Idle"
        }
    }

    init(_ mood: AgentActivity.Mood) {
        switch mood {
        case .needsYou, .sleeping: self = .needsYou
        case .working, .reading, .forming: self = .working
        case .idle: self = .idle
        }
    }
}

struct AgentsPage: View {
    private static let barHeight: CGFloat = 31

    let agents: [Agent]
    let activity: [UUID: AgentActivity]
    let feed: PageFeed
    let selected: UUID?
    var settingsTab = SettingsTab.general
    var settingsOpen = false
    let creating: Bool
    var creationError: String?
    let actions: PageActions
    @State private var frames: [UUID: CGRect] = [:]
    @State private var services: [(server: String, tools: [String])] = []
    @State private var settingsFor: Agent?
    @AppStorage("chatWidth", store: BeanDefaults.shared) private var chatWidth = 380.0

    private var agent: Agent? { agents.first { $0.id == selected } }
    private var bean: Agent? { agents.first(where: \.isBean) }
    private var crew: [Agent] { agents.filter { !$0.isBean } }
    private var work: [WorkItem] { WorkItem.all(agents: crew + (bean.map { [$0] } ?? []), feed: feed) }
    private var waiting: [WorkItem] { work.filter { $0.state == .waiting && !$0.agent.isBean } }
    private var boardAgent: Agent? {
        if let agent, !agent.isBean { return agent }
        return waiting.first?.agent ?? crew.first
    }
    private var windows: [OpenWindow] { feed.openWindows.filter(WindowWidget.isOpenToBoard) }

    var body: some View {
        HStack(spacing: 0) {
            chat.frame(width: chatWidth)
            Rectangle()
                .fill(.separator)
                .frame(width: 1)
                .overlay {
                    Color.clear.frame(width: 9)
                        .contentShape(Rectangle())
                        .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                        .gesture(DragGesture(coordinateSpace: .global).onChanged { value in
                            chatWidth = min(560, max(280, value.location.x))
                        })
                        .accessibilityIdentifier("page-chat-divider")
                }
            VStack(spacing: 0) {
                topBar
                Divider()
                banners.clipped()
                stage.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 900, minHeight: 520)
        .ignoresSafeArea()
        .sheet(item: $settingsFor) { member in
            VStack(spacing: 0) {
                AgentInspector(agent: member, mission: feed.missions[member.id], targets: feed.targets[member.id] ?? [], connectors: feed.connectors[member.id] ?? [], allAbilities: feed.abilities[member.id] ?? [], actions: actions)
                Divider()
                HStack { Spacer(); Button("Done") { settingsFor = nil }.keyboardShortcut(.defaultAction) }.padding(10)
            }
            .frame(width: 440, height: 620)
        }
        .task(id: work.contains { $0.state == .running }) {
            guard work.contains(where: { $0.state == .running }) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                actions.refreshWork()
            }
        }
        .task {
            while !Task.isCancelled {
                var found: [(server: String, tools: [String])] = []
                for server in await actions.connectedServices?() ?? [] {
                    let tools = await actions.connectorReads?(server) ?? []
                    if !tools.isEmpty { found.append((server, tools)) }
                }
                services = found
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    @ViewBuilder private var chat: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Spacer().frame(width: 72)
                if let bean { PageDrop(look: bean.look, mood: .idle, size: 15) }
                Text("Bean").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: actions.openSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Settings (⌘,)")
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("page-settings-open")
                    .padding(.trailing, 10)
            }
            .frame(height: Self.barHeight)
            Divider()
            if let bean {
                Conversation(agent: bean, crew: agents, activity: activity, feed: feed, actions: actions)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(crew) { agentTab($0) }
                }
                .padding(.horizontal, 8)
            }
            if crew.count > 5 {
                Menu {
                    ForEach(crew) { member in
                        Button { actions.select(member.id) } label: { Label(member.name, systemImage: feed.needs[member.id]?.contains(where: \.asksTheUser) == true ? "exclamationmark.circle.fill" : "circle") }
                    }
                } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(AgentStrings.shown("All agents"))
                .accessibilityIdentifier("page-agents-list")
            }
            if let next = waiting.first(where: { $0.agent.id != boardAgent?.id }) {
                Button(AgentStrings.shown("%@ needs you", next.agent.name)) { actions.select(next.agent.id) }
                    .controlSize(.small)
                    .accessibilityIdentifier("page-next-need")
            }
            if !settingsOpen { addMenu }
            if let boardAgent, !settingsOpen {
                Menu { agentMenu(boardAgent) } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel(AgentStrings.shown("More"))
                    .accessibilityIdentifier("page-agent-menu")
                    .padding(.trailing, 10)
            }
        }
        .frame(height: Self.barHeight)
    }

    private var addMenu: some View {
        Menu {
            if let boardAgent {
                let context = WidgetContext(spec: PaneSpec(kind: .action, agent: boardAgent.id), agent: boardAgent, items: BoardDefaults.work(boardAgent, feed: feed), activity: activity, everyone: agents, feed: feed, actions: actions)
                ForEach(BoardWidget.allCases.filter(\.isListedAlone)) { kind in
                    if kind.hasData(context) {
                        Button { add(kind, param: nil) } label: { Label(AgentStrings.shown(kind.title), systemImage: kind.icon) }
                    }
                }
                Divider()
                Menu(AgentStrings.shown("Open Windows")) {
                    ForEach(windows, id: \.number) { window in
                        Button([window.app, window.title].compactMap { $0 }.joined(separator: ": ")) { add(.window, param: String(window.number)) }
                    }
                    if windows.isEmpty { Text(AgentStrings.shown("No windows are open.")) }
                }
                if !services.isEmpty {
                    Menu(AgentStrings.shown("Services")) {
                        ForEach(services, id: \.server) { service in
                            Menu(service.server) {
                                ForEach(service.tools, id: \.self) { tool in
                                    Button(tool) { add(.connector, param: "\(service.server)|\(tool)") }
                                }
                            }
                        }
                    }
                }
                Divider()
            }
            Button("New Agent…", action: actions.newAgent).accessibilityIdentifier("page-new-agent")
            if !windows.isEmpty {
                Menu(AgentStrings.shown("Put an Agent On")) {
                    ForEach(windows, id: \.number) { window in
                        Button([window.app, window.title].compactMap { $0 }.joined(separator: ": ")) { actions.putAgent(window) }
                    }
                }
            }
        } label: {
            Label(AgentStrings.shown("Add"), systemImage: "plus").labelStyle(.titleAndIcon).font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("page-add")
    }

    private func add(_ kind: BoardWidget, param: String?) {
        guard let boardAgent else { return }
        PaneStore.shared.add(PaneSpec(kind: kind, agent: boardAgent.id, param: param), for: boardAgent.id, frames: frames)
    }

    @ViewBuilder private func agentMenu(_ member: Agent) -> some View {
        Button(AgentStrings.shown("Agent Settings…")) { settingsFor = member }.accessibilityIdentifier("page-agent-settings")
        Button("Show in Finder") { actions.reveal(member.id) }
        Divider()
        Button("Delete \(member.name)…", role: .destructive) { actions.delete(member.id) }
    }

    private func agentTab(_ member: Agent) -> some View {
        let state = BoardDefaults.work(member, feed: feed).first?.state
        return Button { actions.select(member.id) } label: {
            HStack(spacing: 5) {
                PageDrop(look: member.look, mood: .idle, size: 14).modifier(AgentDragHandle(agent: member, actions: actions))
                Text(member.name.isEmpty ? "New Agent" : member.name).font(.system(size: 12, weight: .medium))
                if state == .waiting {
                    Circle().fill(.orange).frame(width: 7, height: 7)
                } else if state == .running {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(boardAgent?.id == member.id ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("page-agent-\(member.name)")
        .contextMenu { agentMenu(member) }
    }

    @ViewBuilder private var banners: some View {
        if feed.needsKey {
            PageBanner(icon: "key.fill", text: "Bean needs an API key to run agents.") {
                Button("Add Key…", action: actions.addKey).controlSize(.small)
            }
        } else if let problem = feed.problem {
            PageBanner(icon: "exclamationmark.triangle.fill", text: problem) {
                Button("Retry", action: actions.retry).controlSize(.small)
                Button("Change Key…", action: actions.addKey).controlSize(.small)
            }
        }
        if feed.needsAccessibility {
            PageBanner(icon: "hand.raised.fill", text: "Bean needs Accessibility to read the window an agent is on. It reads nothing else.") {
                Button("Allow…", action: actions.requestAccessibility).controlSize(.small)
            }
        }
        if feed.notificationsOff {
            PageBanner(icon: "bell.slash.fill", text: "Bean's notifications are off.") {
                Button("Open Settings…", action: actions.openNotificationSettings).controlSize(.small)
            }
        }
        if feed.allPaused {
            PageBanner(icon: "pause.circle.fill", text: "All agents are paused. They read nothing and make no model calls.") {
                Button("Resume", action: actions.resume).controlSize(.small)
            }
        }
    }

    static func window(of agent: Agent, feed: PageFeed) -> AgentTarget? {
        if let attachment = agent.attachment {
            return AgentTarget(kind: .window, name: attachment.windowTitle ?? attachment.appName, app: attachment.appName, title: attachment.windowTitle)
        }
        return feed.targets[agent.id]?.last { $0.kind == .window }
    }

    static func mood(of agent: Agent, activity: AgentActivity?, feed: PageFeed) -> AgentActivity.Mood {
        feed.needs[agent.id]?.isEmpty == false ? .needsYou : activity?.mood ?? .idle
    }

    static func detail(of agent: Agent, activity: AgentActivity?, feed: PageFeed) -> String? {
        if agent.name.isEmpty { return "Setting up" }
        if feed.listening[agent.id] != nil { return "Recording this call" }
        if let doing = feed.doing[agent.id] { return doing.split(separator: "\n").first.map(String.init) ?? doing }
        if activity?.mood == .sleeping { return "Stopped for today" }
        if let need = feed.needs[agent.id]?.first { return need.question }
        if activity?.mood == .needsYou, let reason = activity?.bubble { return reason }
        let open = feed.sessions[agent.id]?.filter { $0.status == .running || $0.status == .waiting }.count ?? 0
        if open > 0 { return open == 1 ? "1 open session" : "\(open) open sessions" }
        return nil
    }

    static func line(of agent: Agent, activity: AgentActivity?, feed: PageFeed) -> String {
        if let detail = detail(of: agent, activity: activity, feed: feed) { return detail }
        if agent.isBean { return "Ready" }
        guard let window = window(of: agent, feed: feed) else { return "Drag me onto a window" }
        return [window.app, window.title].compactMap { $0 }.joined(separator: ": ")
    }

    @ViewBuilder private var stage: some View {
        if creating {
            NewAgentForm(error: creationError, canCancel: !agents.isEmpty, create: actions.create, cancel: actions.cancelNew)
        } else if settingsOpen {
            SettingsPage(tab: settingsTab, agents: agents, feed: feed, actions: actions)
        } else if let boardAgent {
            PaneStage(agent: boardAgent, everyone: agents, activity: activity, feed: feed, actions: actions, frames: $frames)
                .id(boardAgent.id)
        } else {
            ContentUnavailableView(AgentStrings.shown("No agents yet"), systemImage: "person.2", description: Text(AgentStrings.shown("Tell Bean a goal in the chat, and its agents appear here.")))
        }
    }
}

struct PageDrop: View {
    let look: Agent.Look
    let mood: AgentActivity.Mood
    let size: CGFloat

    var body: some View {
        let frame = CreatureView.frame(size)
        CreatureView(look: look, mood: mood == .needsYou ? .idle : mood, size: size, pose: .peek, limbs: 0)
            .frame(width: frame.width, height: frame.height)
            .frame(width: size * 1.15, height: size * 1.25)
            .overlay(alignment: .bottomTrailing) {
                if mood == .needsYou {
                    Circle().fill(.orange).frame(width: size * 0.42, height: size * 0.42)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 1))
                }
            }
    }
}

private struct AgentDragHandle: ViewModifier {
    let agent: Agent
    let actions: PageActions
    @GestureState private var dragging = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .updating($dragging) { _, started, _ in
                    guard !started else { return }
                    started = true
                    DispatchQueue.main.async { actions.beginDrag(agent.id) }
                }
                .onEnded { _ in actions.endDrag() })
            .onTapGesture { actions.select(agent.id) }
            .help("Drag \(agent.name) onto a window")
            .accessibilityIdentifier("page-drag-\(agent.name)")
    }
}

private struct PageBanner<Actions: View>: View {
    let icon: String
    let text: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(.orange)
                Text(text)
                Spacer()
                actions
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.orange.opacity(0.12))
            .background(.background)
            Divider()
        }
    }
}

struct Conversation: View {
    let agent: Agent
    let crew: [Agent]
    let activity: [UUID: AgentActivity]
    let feed: PageFeed
    let actions: PageActions
    @State private var draft = ""
    @State private var deferred: UUID?
    @State private var awaySeen = false
    @State private var showingAway = false
    @FocusState private var focused: Bool
    @StateObject private var guess = WindowGuess()

    private var entries: [JournalEntry] {
        let all = (feed.journal[agent.id] ?? []).sorted { $0.at < $1.at }
        let kept = all.indices.filter { isForReading(all[$0], before: all[($0 + 1)...]) }.map { all[$0] }.filter { !agent.isBean || $0.kind == .replied || ($0.kind == .said && !$0.isPlacement(of: agent)) }
        return kept.indices.filter { $0 == 0 || kept[$0].did != kept[$0 - 1].did || kept[$0].kind != kept[$0 - 1].kind }.map { kept[$0] }
    }

    private func isForReading(_ entry: JournalEntry, before later: ArraySlice<JournalEntry>) -> Bool {
        switch entry.kind {
        case .stuck: later.first { $0.kind == .stuck || ($0.kind == .said && !$0.isPlacement(of: agent)) }?.kind == .said
        case .session: !entry.did.hasPrefix("Decided")
        case .handoff: entry.isBrief || !(agent.isBean && entry.to == nil)
        case .action: entry.did != "Alerted you with a script notification"
        default: true
        }
    }
    private var decisions: [AgentDecision] { agent.isBean ? [] : (feed.decisions[agent.id] ?? []).filter { $0.kind == .judgment } }
    private var sessions: [AgentWorker.DrivenSession] { feed.sessions[agent.id] ?? [] }
    private var name: String { agent.name.isEmpty ? "New Agent" : agent.name }
    private var need: AgentNeed? { feed.needs[agent.id]?.first }
    private var question: AgentNeed? { feed.needs[agent.id]?.first(where: \.asksTheUser) }
    private var away: AwayReport? {
        guard agent.isBean, !awaySeen, feed.awayEnded.timeIntervalSince(feed.awaySince) >= AwayReport.shortestAway else { return nil }
        let report = AwayReport(agents: crew, feed: feed)
        return report.isEmpty ? nil : report
    }
    private var waitingAgents: [Agent] {
        guard agent.isBean else { return [] }
        return crew.filter { !$0.isBean && feed.needs[$0.id]?.contains(where: \.asksTheUser) == true }
    }
    private var stopped: AgentNeed? { feed.needs[agent.id]?.first { $0.kind == .budget } }
    private var mood: AgentActivity.Mood { activity[agent.id]?.mood ?? .idle }
    private var reason: String? { activity[agent.id]?.bubble }
    private var window: AgentTarget? { AgentsPage.window(of: agent, feed: feed) }

    private enum Block: Identifiable {
        case single(JournalEntry)
        case run([JournalEntry])
        case decision(AgentDecision)

        var id: UUID {
            switch self {
            case .single(let entry): entry.id
            case .run(let entries): entries[0].id
            case .decision(let decision): decision.id
            }
        }
    }

    private var blocks: [Block] {
        var result: [Block] = [], run: [JournalEntry] = []
        func flush() {
            if run.count >= 3 { result.append(.run(run)) } else { result += run.map(Block.single) }
            run = []
        }
        var pending = decisions.sorted { $0.at < $1.at }
        for entry in entries {
            while let next = pending.first, next.at <= entry.at {
                flush()
                result.append(.decision(next))
                pending.removeFirst()
            }
            if entry.kind == .action || entry.kind == .refused {
                run.append(entry)
            } else {
                flush()
                result.append(.single(entry))
            }
        }
        flush()
        return result + pending.map(Block.decision)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let since = feed.listening[agent.id] {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    Text(AgentStrings.shown("Recording this call since %@", since.formatted(date: .omitted, time: .shortened)))
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.red.opacity(0.12))
                .accessibilityIdentifier("page-recording")
            }
            if mood == .needsYou, need == nil, let reason {
                PageBanner(icon: "exclamationmark.circle.fill", text: reason) { EmptyView() }
            }
            if stopped != nil || mood == .sleeping {
                PageBanner(icon: "moon.zzz", text: AgentStrings.shown("%@ did too much today and stopped. It resumes tomorrow.", name)) { EmptyView() }
            }
            if !agent.isBean, !agent.name.isEmpty, window == nil, question != nil || !(blocks.isEmpty && sessions.isEmpty) {
                HStack(spacing: 9) {
                    PageDrop(look: agent.look, mood: .idle, size: 18).modifier(AgentDragHandle(agent: agent, actions: actions))
                    Text(AgentStrings.shown("Drag me onto a window. That window becomes my work.")).font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(.quaternary.opacity(0.5))
            }
            if blocks.isEmpty && sessions.isEmpty {
                if agent.isBean {
                    VStack(spacing: 6) {
                        Text(AgentStrings.shown("I run your agents on your windows.")).font(.title3.weight(.semibold))
                        Text(AgentStrings.shown("Tell me a goal, or put an agent on a window. I decide who does what, and report once.")).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if question != nil {
                    Spacer(minLength: 0)
                } else if agent.name.isEmpty {
                    ContentUnavailableView(AgentStrings.shown("Setting up %@", name), systemImage: "bubble.left.and.text.bubble.right",
                                           description: Text(AgentStrings.shown("The agent can be used as soon as its mission is written.")))
                        .frame(maxHeight: .infinity)
                } else if let window {
                    ContentUnavailableView(AgentStrings.shown("%@ is on %@", name, window.title ?? window.app ?? window.name), systemImage: "macwindow",
                                           description: Text(AgentStrings.shown("It works there in the background. Ask or correct it below.")))
                        .frame(maxHeight: .infinity)
                } else {
                    VStack(spacing: 12) {
                        PageDrop(look: agent.look, mood: .idle, size: 54).modifier(AgentDragHandle(agent: agent, actions: actions))
                        Text(AgentStrings.shown("Drag me onto a window")).font(.title2.weight(.semibold))
                        Text(AgentStrings.shown("A mail window, a spreadsheet, a web page: that window becomes %@'s work.", name))
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                            blockView(block, previous: index == 0 ? nil : blocks[index - 1])
                        }
                        if feed.replying.contains(agent.id) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(AgentStrings.shown("%@ is replying", name)).font(.callout).foregroundStyle(.secondary)
                            }
                            .padding(.leading, 2)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: agent.isBean ? 760 : .infinity)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom)
            }
            if let question, deferred != question.id {
                QuestionCard(need: question, name: name, more: (feed.needs[agent.id]?.count ?? 1) - 1, answer: { actions.answer(agent.id, question.id, $0) },
                             later: { deferred = question.id }, connect: actions.connectService)
                    .id(question.id)
            } else {
                if let question {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        Text(AgentStrings.shown(question.question)).font(.callout).lineLimit(1)
                        Spacer()
                        Button(AgentStrings.shown("Answer")) { deferred = nil }.controlSize(.small).accessibilityIdentifier("page-question-answer")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .padding(.horizontal, 14).padding(.top, 8)
                }
                if !agent.isBean, let doing = feed.doing[agent.id] {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(doing).font(.callout).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .padding(.horizontal, 14).padding(.top, 8)
                }
                if let away {
                    Button { showingAway = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary)
                            Text(AgentStrings.shown("While you were away")).font(.callout)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("page-chat-away")
                    .popover(isPresented: $showingAway, arrowEdge: .top) {
                        ScrollView { AwayCard(report: away, actions: actions).padding(10) }.frame(width: 420, height: 440)
                            .onDisappear { awaySeen = true }
                    }
                }
                ForEach(waitingAgents) { member in
                    Button { actions.select(member.id) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(.orange).frame(width: 7, height: 7)
                            Text(AgentStrings.shown("%@ needs one answer", member.name)).font(.callout)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14).padding(.top, 8)
                    .accessibilityIdentifier("page-chat-need")
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(placeholder, text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .focused($focused)
                        .onSubmit(send)
                        .onChange(of: draft) { if agent.isBean { guess.typed(draft, windows: feed.openWindows) } }
                        .onChange(of: agent.id) { guess.clear() }
                        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in guess.clear() }
                        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in guess.clear() }
                        .accessibilityIdentifier("page-composer")
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                            .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send")
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
                .padding(14)
                .disabled(agent.name.isEmpty)
            }
        }
    }

    @ViewBuilder private func blockView(_ block: Block, previous: Block?) -> some View {
        let date = Self.date(of: block)
        if !agent.isBean, previous.map({ !Calendar.current.isDate(Self.date(of: $0), inSameDayAs: date) }) ?? true {
            Text(Self.day(date)).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
        switch block {
        case .single(let entry):
            ThreadItem(entry: entry, agent: agent, crew: crew, undone: isUndone(entry), undo: { actions.undo(agent.id, entry.id) })
        case .decision(let decision):
            DecisionRow(decision: decision) { actions.correct(agent.id, decision.id, $0) }
        case .run(let list):
            ActionRun(list: list, isUndone: isUndone, undo: { actions.undo(agent.id, $0) })
        }
    }

    private func isUndone(_ entry: JournalEntry) -> Bool { entries.contains { $0.undoes == entry.id } }

    private var placeholder: String {
        if !agent.isBean, feed.doing[agent.id] != nil { return AgentStrings.shown("Message %@. It reads this after the current step.", name) }
        return agent.isBean ? AgentStrings.shown("Give Bean a goal, or ask anything") : AgentStrings.shown("Ask or correct %@", name)
    }

    private static func date(of block: Block) -> Date {
        switch block {
        case .decision(let decision): decision.at
        case .single(let entry): entry.at
        case .run(let list): list[0].at
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        actions.send(agent.id, guess.confirm(text))
    }

    private static func day(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return AgentStrings.shown("Today") }
        if Calendar.current.isDateInYesterday(date) { return AgentStrings.shown("Yesterday") }
        return date.formatted(.dateTime.weekday(.wide).day().month().locale(AgentStrings.locale))
    }
}

private struct ThreadItem: View {
    static func pullRequests(in entry: JournalEntry) -> [String] {
        var links = entry.did.matches(of: /https:\/\/[^\s)]+\/pull\/\d+/).map { String($0.0) }
        if let link = entry.link, !links.contains(link) { links.append(link) }
        return links.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    let entry: JournalEntry
    let agent: Agent
    let crew: [Agent]
    let undone: Bool
    let undo: () -> Void

    var body: some View {
        switch entry.kind {
        case .said where entry.isPlacement(of: agent):
            note(AgentStrings.shown("%@ is now on %@", agent.name, place))
        case .handoff where entry.isBrief && entry.to == nil:
            BriefRow(entry: entry, crew: crew, bean: agent)
        case .handoff where entry.isBrief:
            note(AgentStrings.shown("Passed to %@", crew.first { $0.id == entry.to }?.name ?? "an agent"))
        case .said:
            HStack {
                Spacer(minLength: 80)
                Text(AgentStrings.shown(WindowGuess.visible(entry.did)))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        case .replied where agent.isBean:
            HStack(alignment: .top, spacing: 9) {
                PageDrop(look: agent.look, mood: .idle, size: 18)
                VStack(alignment: .leading, spacing: 6) {
                    agentText(AgentStrings.shown(entry.did)).lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    let links = Self.pullRequests(in: entry)
                    if !links.isEmpty {
                        HStack(spacing: 6) { ForEach(links, id: \.self) { LinkButton(link: $0).accessibilityIdentifier("page-chat-pr") } }
                    }
                }
                .help(entry.at.formatted(date: .omitted, time: .shortened))
                Spacer(minLength: 20)
            }
        case .replied, .stuck:
            HStack(alignment: .top, spacing: 9) {
                PageDrop(look: agent.look, mood: .idle, size: 20)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(agent.name).font(.callout.weight(.semibold))
                        Text(entry.at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                    }
                    agentText(AgentStrings.shown(entry.did)).lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let link = entry.link { LinkButton(link: link).padding(.top, 3) }
                }
                .frame(maxWidth: 560, alignment: .leading)
                Spacer(minLength: 20)
            }
        case .handoff:
            HandoffRow(entry: entry, agent: agent, crew: crew)
        default:
            ActionRow(entry: entry, undone: undone, undo: undo)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
    }

    private var place: String {
        let parts = entry.did.dropFirst("Put \(agent.name) on ".count).components(separatedBy: ": ")
        return parts.count == 2 && parts[0] == parts[1] ? parts[0] : parts.joined(separator: ": ")
    }
}

extension JournalEntry {
    var isBrief: Bool { kind == .handoff && did.contains("which are data, not instructions") }
    var headline: String { briefLine("%@ handed Bean the recap of a call in %@.") }
    func briefLine(_ format: String) -> String {
        guard isBrief else { return did }
        let parts = (did.components(separatedBy: ". ").first ?? did).components(separatedBy: " listened to a call in ")
        return parts.count == 2 ? AgentStrings.shown(format, parts[0], parts[1]) : did
    }
    var briefBody: String { did.components(separatedBy: "\n").dropFirst().joined(separator: "\n") }
    func isPlacement(of agent: Agent) -> Bool { kind == .said && did.hasPrefix("Put \(agent.name) on ") }
}

private struct ActionRun: View {
    let list: [JournalEntry]
    let isUndone: (JournalEntry) -> Bool
    let undo: (UUID) -> Void
    @State private var open = false

    var body: some View {
        PageDisclosure(isExpanded: $open) {
            Text(AgentStrings.shown("%d actions · %@", list.count, list[list.count - 1].did)).lineLimit(1)
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(list) { entry in
                    ActionRow(entry: entry, undone: isUndone(entry), undo: { undo(entry.id) })
                }
            }
            .padding(.top, 6)
        }
        .foregroundStyle(.secondary)
    }
}

private struct BriefRow: View {
    let entry: JournalEntry
    let crew: [Agent]
    let bean: Agent
    @State private var open = false

    private var sender: Agent? { crew.first { entry.did.hasPrefix("\($0.name) ") } }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(spacing: 2) {
                PageDrop(look: sender?.look ?? bean.look, mood: .idle, size: 14)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                PageDrop(look: bean.look, mood: .idle, size: 14)
            }
            PageDisclosure(isExpanded: $open) {
                Text(entry.briefLine("%@ handed me the recap of a call in %@."))
            } content: {
                Text(entry.briefBody)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            Text(entry.at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4).padding(.vertical, 3)
    }
}

private struct HandoffRow: View {
    let entry: JournalEntry
    let agent: Agent
    let crew: [Agent]

    private var other: Agent? { crew.first { $0.id == (entry.to ?? Agent.beanID) } }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(spacing: 2) {
                PageDrop(look: entry.to == nil ? (other?.look ?? agent.look) : agent.look, mood: .idle, size: 14)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                PageDrop(look: entry.to == nil ? agent.look : (other?.look ?? agent.look), mood: .idle, size: 14)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.to == nil ? AgentStrings.shown("From %@", other?.name ?? "Bean") : AgentStrings.shown("Passed to %@", other?.name ?? "an agent")).font(.caption).foregroundStyle(.secondary)
                Text(entry.did).textSelection(.enabled)
                if !entry.why.isEmpty { Text(entry.why).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Spacer(minLength: 8)
            Text(entry.at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4).padding(.vertical, 3)
    }
}

private struct DecisionRow: View {
    let decision: AgentDecision
    let correct: (String) -> Void
    @State private var correcting = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "person.fill.checkmark").foregroundStyle(.secondary).frame(width: 16)
                Text(AgentStrings.shown(decision.state == .answered ? "Answered by you" : "On your behalf")).font(.caption).foregroundStyle(.secondary)
                if let repo = decision.repo { Text("· \(repo)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                Text(decision.at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(decision.question).textSelection(.enabled)
            Text(decision.answer).fontWeight(.medium).textSelection(.enabled)
            if !decision.why.isEmpty {
                Text(AgentStrings.shown("Why: %@", decision.why)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let correction = decision.correction {
                Label(AgentStrings.shown("Corrected: %@", correction), systemImage: "arrow.uturn.backward").font(.callout).foregroundStyle(.secondary)
            } else if decision.state == .decided {
                Button(AgentStrings.shown("Correct…")) {
                    correcting.toggle()
                    fieldFocused = correcting
                }
                .controlSize(.small)
                .accessibilityIdentifier("page-correct")
            }
            if correcting {
                HStack {
                    TextField(AgentStrings.shown("What should the answer be?"), text: $draft).textFieldStyle(.roundedBorder)
                        .focused($fieldFocused)
                        .onSubmit(send)
                    Button(AgentStrings.shown("Send"), action: send).controlSize(.small).disabled(draft.isEmpty)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func send() {
        guard !draft.isEmpty else { return }
        correct(draft)
        draft = ""
        correcting = false
    }
}

struct SettingsPane {
    let url: URL

    init?(_ need: AgentNeed) {
        let text = need.question.lowercased()
        let panes = [("automati", "?Privacy_Automation"), ("control of", "?Privacy_Automation"), ("contrôle de", "?Privacy_Automation"),
                     ("accessibilit", "?Privacy_Accessibility"), ("screen recording", "?Privacy_ScreenCapture"), ("enregistrement de l", "?Privacy_ScreenCapture"),
                     ("full disk", "?Privacy_AllFiles"), ("system settings", ""), ("réglages système", "")]
        guard let pane = need.settingsPane.map({ "?\($0)" }) ?? panes.first(where: { text.contains($0.0) })?.1,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security\(pane)") else { return nil }
        self.url = url
    }
}

struct QuestionCard: View {
    let need: AgentNeed
    let name: String
    let more: Int
    var about: String?
    var inset: CGFloat = 14
    let answer: (String) -> Void
    let later: () -> Void
    let connect: (String) -> Void
    @State private var choice: String?
    @State private var other = ""

    private var typed: String { other.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var preferred: String? { need.recommended ?? need.options.first }
    private var selected: String? { typed.isEmpty ? choice ?? preferred : typed }

    var body: some View {
        if need.consent != nil { consent } else { card }
    }

    private var consent: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(AgentStrings.shown("%@ needs you", name)).font(.caption).foregroundStyle(.secondary)
            Text(AgentStrings.shown(need.question)).font(.headline)
            if let detail = need.detail {
                Text(AgentStrings.shown(detail)).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                ForEach(need.options, id: \.self) { option in
                    Button(AgentStrings.shown(option)) { answer(option) }.fixedSize()
                }
                Spacer(minLength: 0)
            }
            .accessibilityIdentifier("page-call-consent")
            ForEach(need.options.filter { need.consequences?[$0] != nil }, id: \.self) { option in
                Text(AgentStrings.shown("%@: %@", AgentStrings.shown(option), need.consequences?[option] ?? "")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(inset)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(([more > 0 ? AgentStrings.shown("%@ needs you · %d more after this", name, more) : AgentStrings.shown("%@ needs you", name)] + [about].compactMap { $0 }).joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(AgentStrings.shown(need.question)).font(.headline)
            ForEach(need.options, id: \.self) { option in
                Button { choice = option; other = "" } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: selected == option ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selected == option ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option == preferred ? AgentStrings.shown("%@ (Recommended)", AgentStrings.shown(option)) : AgentStrings.shown(option))
                            if let consequence = need.consequences?[option] {
                                Text(consequence).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("page-option-\(need.options.firstIndex(of: option) ?? 0)")
            }
            TextField(AgentStrings.shown(need.options.isEmpty ? "Your answer" : "Other"), text: $other).textFieldStyle(.roundedBorder)
                .onSubmit { if let selected { answer(selected) } }
                .accessibilityIdentifier("page-question-other")
            HStack {
                if let connector = need.connector {
                    Button(AgentStrings.shown("Connect")) { connect(connector) }.fixedSize().accessibilityIdentifier("page-question-connect")
                }
                if let pane = SettingsPane(need) {
                    Button(AgentStrings.shown("Open Settings…")) { NSWorkspace.shared.open(pane.url) }.fixedSize().accessibilityIdentifier("page-question-settings")
                }
                Spacer(minLength: 0)
                Button(AgentStrings.shown("Later"), action: later).accessibilityIdentifier("page-question-later")
                Button(AgentStrings.shown("Skip")) { answer(AgentWorker.skipAnswer) }
                Button(AgentStrings.shown("Send")) { if let selected { answer(selected) } }
                    .accessibilityIdentifier("page-question-send")
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(inset)
    }
}

private struct ActionRow: View {
    let entry: JournalEntry
    let undone: Bool
    let undo: () -> Void
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.did).strikethrough(undone).foregroundStyle(undone ? .secondary : .primary).textSelection(.enabled)
                    if !entry.why.isEmpty { Text(entry.why).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    if hasControls {
                        HStack(spacing: 6) {
                            if hasResult {
                                Button(AgentStrings.shown(open ? "Hide Details" : "Details")) { open.toggle() }.controlSize(.small).fixedSize()
                            }
                            if let link = entry.link { LinkButton(link: link).fixedSize() }
                            if canUndo {
                                Button(AgentStrings.shown("Undo"), action: undo)
                                    .controlSize(.small)
                                    .fixedSize()
                                    .help(entry.undo ?? "Undo this action")
                                    .accessibilityIdentifier("page-undo")
                            }
                        }
                        .padding(.top, 3)
                    }
                }
                Spacer(minLength: 8)
                Text(entry.at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary).fixedSize()
            }
            if open, let result = entry.result {
                Text(result).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 3)
    }

    private var canUndo: Bool { (entry.undoCommand != nil || entry.undoText != nil) && !undone }
    private var hasResult: Bool { entry.result?.isEmpty == false }
    private var hasControls: Bool { hasResult || entry.link != nil || canUndo }

    private var icon: String {
        switch entry.kind {
        case .action: "checkmark.circle"
        case .refused: "hand.raised"
        case .failed: "exclamationmark.triangle"
        case .stuck: "exclamationmark.circle"
        case .undo: "arrow.uturn.backward.circle"
        case .session: "terminal"
        case .said, .replied, .handoff: "text.bubble"
        }
    }

    private var tint: Color {
        switch entry.kind {
        case .failed, .stuck: .orange
        default: .secondary
        }
    }
}

struct LinkButton: View {
    let link: String

    var body: some View {
        Button(label, systemImage: "arrow.up.right") {
            if let url = URL(string: link), url.scheme == "https" || url.scheme == "http" { NSWorkspace.shared.open(url) }
        }
        .controlSize(.small)
        .help(link)
    }

    private var label: String {
        guard let url = URL(string: link) else { return link }
        let last = url.lastPathComponent
        if last.isEmpty || last == "/" { return url.host ?? link }
        if Int(last) != nil { return "#\(last)" }
        return last.count > 24 ? "\(last.prefix(23))…" : last
    }
}

private struct NewAgentForm: View {
    let error: String?
    let canCancel: Bool
    let create: (String) -> Void
    let cancel: () -> Void
    @State private var mission = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What should this agent do?").font(.title2.weight(.semibold))
            TextField("For example: sort my mail and draft the replies", text: $mission, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .focused($focused)
                .onSubmit(submit)
                .accessibilityIdentifier("page-new-mission")
            Text("Then drag it onto a window: mail, a spreadsheet, a web page, any app.").font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                if canCancel { Button("Cancel", action: cancel).keyboardShortcut(.cancelAction) }
                Button("Create", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(mission.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(maxWidth: 480)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true } }
    }

    private func submit() {
        let text = mission.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        create(text)
    }
}

struct AgentInspector: View {
    let agent: Agent
    let mission: AgentMission?
    let targets: [AgentTarget]
    let connectors: [AgentConnectorInfo]
    let allAbilities: [AgentAbility]
    let actions: PageActions
    @State private var missionDraft = ""
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool
    @State private var confirming = false
    @State private var enabling: AgentAbility?
    @State private var showRoutine = false
    @FocusState private var editing: Bool

    private var name: String { agent.name.isEmpty ? "This agent" : agent.name }
    private var abilities: [AgentAbility] {
        allAbilities.filter { ability in !allAbilities.contains { $0.id.hasPrefix(ability.id + " ") } }
    }

    private var summary: String {
        if agent.isBean { return "Bean runs your agents and answers for you." }
        let places = targets.map { $0.title ?? $0.name }
        let first = places.isEmpty ? "\(name) has nothing to work on yet." : "\(name) works on \(places.prefix(2).joined(separator: " and "))\(places.count > 2 ? " and \(places.count - 2) more" : "")."
        let risky = abilities.filter { $0.risk == .irreversible && !$0.allowed }.count
        return risky > 0 ? first + " It asks before anything irreversible." : first
    }

    var body: some View {
        Form {
            Text(summary).font(.callout).foregroundStyle(.secondary)
            if !agent.isBean {
                Section("Look") {
                    LookEditor(agent: agent, actions: actions)
                }
                Section("Name") {
                    TextField("Name", text: $nameDraft)
                        .labelsHidden()
                        .focused($nameFocused)
                        .onSubmit { actions.rename(agent.id, nameDraft) }
                        .onChange(of: nameFocused) { _, focused in if !focused { actions.rename(agent.id, nameDraft) } }
                        .onAppear { nameDraft = agent.name }
                        .onChange(of: agent.name) { _, new in nameDraft = new }
                        .accessibilityIdentifier("page-name")
                }
            }
            Section("Mission") {
                TextField("Mission", text: $missionDraft, prompt: Text(agent.role), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(2...6)
                    .focused($editing)
                    .onAppear { missionDraft = mission?.mission ?? "" }
                    .onChange(of: mission?.mission) { _, new in if !editing { missionDraft = new ?? "" } }
                    .onChange(of: editing) { _, now in
                        if !now, missionDraft != (mission?.mission ?? "") { actions.saveMission(agent.id, missionDraft) }
                    }
                    .accessibilityIdentifier("page-mission")
            }
            Section {
                ForEach(targets) { target in
                    HStack(spacing: 8) {
                        TargetIcon(target: target)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(target.title ?? target.name).lineLimit(1)
                            if let app = target.app { Text(app).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer()
                        if let link = target.link { LinkButton(link: link) }
                        Button("Remove \(target.name)", systemImage: "minus.circle") { actions.removeTarget(agent.id, target) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("page-remove-\(target.kind.rawValue)")
                    }
                }
                if targets.isEmpty {
                    Text(agent.isBean ? "Bean works through its agents." : "Nothing yet. Drag \(name) onto a window.").font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Works on") }
            Section {
                ForEach(connectors) { connector in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(connector.name)
                            Text(Self.describe(connector)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        switch connector.status {
                        case .connected: Text("Connected").font(.caption).foregroundStyle(.secondary)
                        case .toConnect: Button("Connect") { actions.connect(agent.id, connector.id) }.controlSize(.small)
                        case .failed: Button("Reconnect") { actions.connect(agent.id, connector.id) }.controlSize(.small)
                        }
                    }
                }
                if connectors.isEmpty {
                    Text("Bean finds connectors when the mission needs them.").font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Connectors") }
            SensesSection(rows: actions.senses(agent.id)) { actions.setSense(agent.id, $0, $1) }
            if abilities.isEmpty {
                Section("Can do without asking") {
                    Text("Abilities appear here once \(name) has found its tools. Until then it only reads.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                abilityGroup(.irreversible, "Irreversible, off by default")
                abilityGroup(.outward, "Visible to others")
                Section {
                    DisclosureGroup("Routine (\(abilities.filter { $0.risk == .safe }.count))", isExpanded: $showRoutine) {
                        abilityRows(abilities.filter { $0.risk == .safe })
                    }
                } footer: { Text("Reading and other actions with no outside effect.").font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                if let attachment = agent.attachment {
                    LabeledContent("Working on \(attachment.appName)") { Button("Send Home") { actions.sendHome(agent.id) }.controlSize(.small) }
                }
                Button("Show in Finder") { actions.reveal(agent.id) }
                if !agent.isBean {
                    Button("Delete \(name)…", role: .destructive) { confirming = true }
                        .confirmationDialog("Delete \(name)?", isPresented: $confirming) {
                            Button("Delete", role: .destructive) { actions.delete(agent.id) }
                        } message: { Text("Its folder, memory and journal are removed. This cannot be undone.") }
                }
            }
        }
        .formStyle(.grouped)
    }

    private static func describe(_ connector: AgentConnectorInfo) -> String {
        let source: String
        switch connector.source {
        case .mcp: source = "Connector"
        case .cli: source = "Command line"
        case .app: source = "App on this Mac"
        }
        return ([connector.usedFor.joined(separator: ", ")].filter { !$0.isEmpty } + [source]).joined(separator: " · ")
    }

    @ViewBuilder private func abilityGroup(_ risk: AgentAbility.Risk, _ title: String) -> some View {
        let group = abilities.filter { $0.risk == risk }
        if !group.isEmpty {
            Section(title) { abilityRows(group) }
        }
    }

    @ViewBuilder private func abilityRows(_ group: [AgentAbility]) -> some View {
                ForEach(group) { ability in
                    Toggle(isOn: Binding(get: { ability.allowed }, set: { on in
                        if on && ability.risk == .irreversible { enabling = ability } else { actions.setAbility(agent.id, ability.id, on) }
                    })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ability.title)
                            Text(AbilityFinder.opensMerge(ability.id) ? "Merging stays with you. No agent can do it." : ability.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(AbilityFinder.opensMerge(ability.id))
                    .confirmationDialog("Allow \(ability.title)?", isPresented: Binding(get: { enabling?.id == ability.id }, set: { if !$0 { enabling = nil } })) {
                        Button("Allow", role: .destructive) { actions.setAbility(agent.id, ability.id, true) }
                    } message: { Text("\(name) will do this without asking, and it cannot be undone.") }
                }
    }
}

struct TargetIcon: View {
    let target: AgentTarget
    var size: CGFloat = 18

    var body: some View {
        if let app = target.app, let icon = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == app })?.icon {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: size)
        }
    }

    private var symbol: String {
        switch target.kind {
        case .repo: "chevron.left.forwardslash.chevron.right"
        case .project: "folder"
        case .window: "macwindow"
        case .session: "terminal"
        }
    }
}
