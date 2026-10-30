import AppKit
import SwiftUI

struct PageFeed {
    var journal: [UUID: [JournalEntry]] = [:]
    var doing: [UUID: String] = [:]
    var sessions: [UUID: [AgentWorker.DrivenSession]] = [:]
    var credits: AgentWorker.Credits?
    var missions: [UUID: AgentMission] = [:]
    var needsKey = false
    var needsAccessibility = false
    var notificationsOff = false
    var problem: String?
    var allPaused = false
    var spend: [UUID: AgentWorker.AgentSpend] = [:]
    var spentToday = 0.0
    var needs: [UUID: [AgentNeed]] = [:]
    var decisions: [UUID: [AgentDecision]] = [:]
    var summaries: [UUID: AwaySummary] = [:]
    var catalogue: [ConnectorEntry] = []
    var awaySince = Calendar.current.startOfDay(for: Date())
    var targets: [UUID: [AgentTarget]] = [:]
    var connectors: [UUID: [AgentConnectorInfo]] = [:]
    var abilities: [UUID: [AgentAbility]] = [:]
    var replying: Set<UUID> = []
}

struct PageActions {
    var select: (UUID) -> Void = { _ in }
    var pauseAll: () -> Void = {}
    var connectService: (String) -> Void = { _ in }
    var disconnectService: (String) -> Void = { _ in }
    var refreshConnectors: () async -> Void = {}
    var searchConnectors: (String) async -> [ConnectorEntry] = { _ in [] }
    var addConnector: (String) async throws -> ConnectorEntry? = { _ in nil }
    var setCredits: (Double) -> Void = { _ in }
    var requestAccessibility: () -> Void = {}
    var openNotificationSettings: () -> Void = {}
    var retry: () -> Void = {}
    var resume: () -> Void = {}
    var setBudget: (UUID, Double) -> Void = { _, _ in }
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
    var connect: (UUID, String) -> Void = { _, _ in }
    var removeTarget: (UUID, AgentTarget) -> Void = { _, _ in }
    var sendHome: (UUID) -> Void = { _ in }
    var delete: (UUID) -> Void = { _ in }
    var reveal: (UUID) -> Void = { _ in }
}

struct AgentsPageRoot: View {
    @ObservedObject var agents: Agents
    @ObservedObject var store: AgentStore
    @ObservedObject var worker: AgentWorker
    @ObservedObject private var settings = BeanSettings.shared
    @ObservedObject var catalogue: ConnectorCatalogue

    var body: some View {
        AgentsPage(agents: store.agents, activity: store.activity, feed: agents.feed, selected: agents.selected, creating: agents.creating,
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
    static let connectorsID = UUID(uuidString: "C0DE0000-0000-0000-0000-000000000001")!

    let agents: [Agent]
    let activity: [UUID: AgentActivity]
    let feed: PageFeed
    let selected: UUID?
    let creating: Bool
    var creationError: String?
    let actions: PageActions
    @AppStorage("agentsInspector", store: BeanDefaults.shared) private var inspector = true
    @State private var deleting: Agent?
    @State private var editingCredits = false

    private var agent: Agent? { agents.first { $0.id == selected } }
    private var bean: Agent? { agents.first(where: \.isBean) }
    private var crew: [Agent] { agents.filter { !$0.isBean } }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                banners
                detail.frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }
                .navigationTitle(creating ? "New Agent" : displayName)
                .navigationSubtitle(creating || agent.flatMap { feed.needs[$0.id]?.first } != nil ? "" : statusLine)
                .toolbar {
                    if !creating, agent != nil {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Settings", systemImage: "sidebar.right") { inspector.toggle() }
                                .help("Show or hide this agent's settings")
                        }
                    }
                }
        }
        .inspector(isPresented: Binding(get: { inspector && !creating && agent != nil }, set: { if !creating && agent != nil { inspector = $0 } })) {
            if let agent {
                AgentInspector(agent: agent, mission: feed.missions[agent.id], targets: feed.targets[agent.id] ?? [],
                               connectors: feed.connectors[agent.id] ?? [], allAbilities: feed.abilities[agent.id] ?? [], spend: feed.spend[agent.id], actions: actions)
                    .id(agent.id)
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
            }
        }
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

    private var displayName: String {
        if selected == Self.connectorsID { return "Connectors" }
        guard let agent else { return "Agents" }
        return agent.name.isEmpty ? "New Agent" : agent.name
    }

    private var statusLine: String {
        guard let agent else { return "" }
        return Self.line(of: agent, activity: activity[agent.id], feed: feed)
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
        if let doing = feed.doing[agent.id] { return doing }
        if activity?.mood == .sleeping { return "Daily budget reached" }
        if let need = feed.needs[agent.id]?.first { return need.question }
        if activity?.mood == .needsYou, let reason = activity?.bubble { return reason }
        if feed.missions[agent.id]?.paused == true { return agent.isBean ? "Standing by" : "Paused" }
        let open = feed.sessions[agent.id]?.count ?? 0
        if open > 0 { return open == 1 ? "1 open session" : "\(open) open sessions" }
        return nil
    }

    static func line(of agent: Agent, activity: AgentActivity?, feed: PageFeed) -> String {
        if let detail = detail(of: agent, activity: activity, feed: feed) { return detail }
        if agent.isBean { return "Ready" }
        guard let window = window(of: agent, feed: feed) else { return "Drag me onto a window" }
        return [window.app, window.title].compactMap { $0 }.joined(separator: ": ")
    }

    private var sidebar: some View {
        List(selection: Binding(get: { creating ? nil : selected }, set: { if let id = $0 { actions.select(id) } })) {
            if let bean {
                Section {
                    row(bean)
                }
            }
            Section("Agents") {
                ForEach(crew) { row($0) }
                if crew.isEmpty {
                    Text("Create an agent, then drag it onto a window.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Label("Connectors", systemImage: "link")
                    .badge(feed.catalogue.filter { $0.status == .connected }.count)
                    .tag(Self.connectorsID)
                    .accessibilityIdentifier("page-connectors")
            }
        }
        .listStyle(.sidebar)
        .confirmationDialog("Delete \(deleting?.name ?? "this agent")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let deleting { actions.delete(deleting.id) } }
        } message: { Text("Its folder, memory and journal are removed. This cannot be undone.") }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(creditsLine) { editingCredits = true }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Enter the balance shown in your provider's console")
                    .accessibilityIdentifier("page-credits")
                    .popover(isPresented: $editingCredits, arrowEdge: .top) {
                        CreditsForm(save: actions.setCredits) { editingCredits = false }
                    }
                Spacer()
                if !feed.allPaused {
                    Button("Pause All", systemImage: "pause.circle", action: actions.pauseAll)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Pause all agents. Nothing reads or spends until you resume.")
                        .accessibilityIdentifier("page-pause-all")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .toolbar {
            ToolbarItem {
                Button("New Agent", systemImage: "plus", action: actions.newAgent)
                    .accessibilityIdentifier("page-new-agent")
            }
        }
    }

    private func row(_ agent: Agent) -> some View {
        AgentRow(agent: agent, mood: Self.mood(of: agent, activity: activity[agent.id], feed: feed), window: Self.window(of: agent, feed: feed),
                 detail: Self.detail(of: agent, activity: activity[agent.id], feed: feed),
                 last: feed.journal[agent.id]?.last?.at, actions: actions)
            .badge(agent.isBean ? agents.filter { PageStatus(Self.mood(of: $0, activity: activity[$0.id], feed: feed)) == .needsYou }.count : 0)
            .tag(agent.id)
            .accessibilityIdentifier("page-agent-\(agent.name)")
            .contextMenu {
                Button("Show in Finder") { actions.reveal(agent.id) }
                if !agent.isBean { Button("Delete \(agent.name)…", role: .destructive) { deleting = agent } }
            }
    }

    private var creditsLine: String {
        guard let credits = feed.credits else { return "\(pageMoney(feed.spentToday)) spent today" }
        return "\(credits.estimate ? "About " : "")\(credits.left) of credits left"
    }

    @ViewBuilder private var detail: some View {
        if creating {
            NewAgentForm(error: creationError, canCancel: !agents.isEmpty, create: actions.create, cancel: actions.cancelNew)
        } else if selected == Self.connectorsID {
            ConnectorsPage(entries: feed.catalogue, agents: agents, actions: actions)
        } else if let agent {
            Conversation(agent: agent, crew: agents, activity: activity, feed: feed, actions: actions)
                .id(agent.id)
        } else {
            ContentUnavailableView("No agent selected", systemImage: "person.crop.circle")
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
            .help("Drag \(agent.name) onto a window")
            .accessibilityIdentifier("page-drag-\(agent.name)")
    }
}

private struct WindowLine: View {
    let agent: Agent
    let window: AgentTarget?
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        if let window {
            HStack(spacing: 4) {
                TargetIcon(target: window, size: 13)
                Text(window.title ?? window.app ?? window.name).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(agent.attachment == nil ? .tertiary : .secondary)
        } else {
            Label("Drag me onto a window", systemImage: "hand.draw")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(prominence == .increased ? Color.white : Color.accentColor)
                .lineLimit(1)
        }
    }
}

private struct AgentRow: View {
    let agent: Agent
    let mood: AgentActivity.Mood
    let window: AgentTarget?
    let detail: String?
    let last: Date?
    let actions: PageActions
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        HStack(spacing: 9) {
            if agent.isBean {
                PageDrop(look: agent.look, mood: mood, size: 26)
            } else {
                PageDrop(look: agent.look, mood: mood, size: 20)
                    .modifier(AgentDragHandle(agent: agent, actions: actions))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name.isEmpty ? "New Agent" : agent.name).fontWeight(agent.isBean ? .semibold : .regular)
                if !agent.isBean && !agent.name.isEmpty { WindowLine(agent: agent, window: window) }
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(prominence == .increased ? Color.white : mood == .needsYou ? Color.orange : .secondary).lineLimit(1)
                } else if agent.isBean {
                    Text("Ready").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let last {
                Text(Self.age(last)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }

    static func age(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1440 { return "\(minutes / 60)h" }
        return "\(minutes / 1440)d"
    }
}

private func pageMoney(_ value: Double) -> String { String(format: "$%.2f", value) }

private struct CreditsForm: View {
    let save: (Double) -> Void
    let done: () -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Credits left (from your provider's console)").font(.callout)
            HStack {
                TextField("Amount in dollars", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                    .accessibilityIdentifier("page-credits-field")
                Button("Save", action: submit).disabled(amount == nil)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private var amount: Double? {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "."))
    }

    private func submit() {
        guard let amount, amount >= 0 else { return }
        save(amount)
        done()
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

private struct AwayReport {
    struct Item: Identifiable {
        let agent: Agent
        let id: UUID
        let title: String
        let detail: String
        let at: Date
        var opens: UUID?
    }

    let since: Date
    let cost: Double
    let claude: Double
    let permissions: Int
    let waiting: [Item]
    let decided: [Item]
    let passed: [Item]
    let done: [Item]
    let stopped: [Item]
    let retried: [Item]

    init(agents: [Agent], feed: PageFeed) {
        since = feed.awaySince
        let summaries = agents.compactMap { agent in feed.summaries[agent.id].map { (agent, $0) } }
        cost = summaries.reduce(0) { $0 + $1.1.museSparkUSD }
        claude = summaries.reduce(0) { $0 + $1.1.claudeUSD }
        permissions = summaries.reduce(0) { $0 + $1.1.permissionsAnswered }
        func named(_ agent: Agent, _ why: String) -> String { why.isEmpty ? agent.name : "\(agent.name) · \(why)" }
        func newest(_ items: [Item]) -> [Item] { items.sorted { $0.at > $1.at } }
        waiting = newest(summaries.flatMap { agent, summary in
            summary.waiting.map { Item(agent: agent, id: $0.id, title: $0.question, detail: agent.name, at: $0.at) }
        })
        decided = newest(summaries.flatMap { agent, summary in
            summary.decided.map { Item(agent: agent, id: $0.id, title: $0.question.hasSuffix("?") ? "\($0.question) \($0.answer)" : "\($0.question): \($0.answer)", detail: named(agent, $0.why), at: $0.at) }
        })
        done = newest(summaries.flatMap { agent, summary in
            summary.done.map { Item(agent: agent, id: $0.id, title: $0.did, detail: named(agent, $0.why), at: $0.at) }
        })
        let entries = agents.flatMap { agent in (feed.journal[agent.id] ?? []).filter { $0.at >= feed.awaySince }.map { (agent, $0) } }
        passed = newest(entries.compactMap { agent, entry in
            guard entry.kind == .handoff, let to = entry.to, let target = agents.first(where: { $0.id == to }) else { return nil }
            return Item(agent: agent, id: entry.id, title: entry.did, detail: entry.why.isEmpty ? "To \(target.name)" : "To \(target.name) · \(entry.why)", at: entry.at, opens: to)
        })
        func worked(after entry: JournalEntry, of agent: Agent) -> Bool {
            entry.kind == .failed && entries.contains { $0.0.id == agent.id && $0.1.kind == .action && $0.1.at > entry.at }
        }
        func item(_ agent: Agent, _ entry: JournalEntry) -> Item {
            Item(agent: agent, id: entry.id, title: entry.did, detail: entry.result?.isEmpty == false ? "\(named(agent, entry.why)) · \(entry.result!.prefix(160))" : named(agent, entry.why), at: entry.at)
        }
        stopped = newest(entries.compactMap { agent, entry in
            guard entry.kind == .failed || entry.kind == .refused, !worked(after: entry, of: agent) else { return nil }
            return item(agent, entry)
        })
        retried = newest(entries.compactMap { agent, entry in worked(after: entry, of: agent) ? item(agent, entry) : nil })
    }

    var isEmpty: Bool { waiting.isEmpty && decided.isEmpty && passed.isEmpty && done.isEmpty && stopped.isEmpty && permissions == 0 }

    var summary: String {
        var parts: [String] = []
        if !decided.isEmpty { parts.append(decided.count == 1 ? "1 decision made for you" : "\(decided.count) decisions made for you") }
        if !done.isEmpty { parts.append(done.count == 1 ? "1 action done" : "\(done.count) actions done") }
        if !waiting.isEmpty { parts.append("\(waiting.count) waiting for you") }
        if !parts.isEmpty { return parts.joined(separator: ", ") + "." }
        if !stopped.isEmpty { return "Your agents stopped on \(stopped.count) actions." }
        return passed.isEmpty ? "Only small permissions were answered." : "Your agents passed work between them."
    }

    var costLine: String {
        var parts = ["\(pageMoney(cost)) Muse Spark"]
        if claude > 0 { parts.append("\(pageMoney(claude)) Claude") }
        return parts.joined(separator: ", ")
    }
}

private struct AwayCard: View {
    let report: AwayReport
    let actions: PageActions

    private var since: String {
        Calendar.current.isDateInToday(report.since) ? report.since.formatted(date: .omitted, time: .shortened) : report.since.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("While you were away").font(.caption).foregroundStyle(.secondary)
            Text(report.summary).font(.title3)
            Text("Since \(since) · \(report.costLine)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
            ForEach(report.waiting) { item in
                AwayRow(look: item.agent.look, title: item.title, detail: item.detail, date: nil) { actions.select(item.agent.id) }
            }
            AwaySection(title: "Decided for you", items: report.decided, open: true, actions: actions)
            if report.permissions > 0 {
                Text(report.permissions == 1 ? "1 small permission answered" : "\(report.permissions) small permissions answered").font(.callout).foregroundStyle(.secondary)
            }
            AwaySection(title: "Passed between agents", items: report.passed, open: true, actions: actions)
            AwaySection(title: "Done", items: report.done, open: false, actions: actions)
            AwaySection(title: "Stopped", items: report.stopped, open: false, actions: actions)
            AwaySection(title: "Failed, then worked", items: report.retried, open: false, actions: actions)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("page-away")
    }
}

private struct AwaySection: View {
    let title: String
    let items: [AwayReport.Item]
    let actions: PageActions
    @State private var open: Bool

    init(title: String, items: [AwayReport.Item], open: Bool, actions: PageActions) {
        self.title = title
        self.items = items
        self.actions = actions
        _open = State(initialValue: open)
    }

    var body: some View {
        if !items.isEmpty {
            DisclosureGroup("\(title) (\(items.count))", isExpanded: $open) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        AwayRow(look: item.agent.look, title: item.title, detail: item.detail, date: item.at) {
                            actions.select(item.opens ?? item.agent.id)
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
    }
}

private struct AwayRow: View {
    let look: Agent.Look
    let title: String
    let detail: String
    let date: Date?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                PageDrop(look: look, mood: .idle, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(2)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                if let date { Text(date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.tertiary) }
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct Conversation: View {
    let agent: Agent
    let crew: [Agent]
    let activity: [UUID: AgentActivity]
    let feed: PageFeed
    let actions: PageActions
    @State private var draft = ""
    @State private var deferred: UUID?
    @FocusState private var focused: Bool

    private var entries: [JournalEntry] {
        (feed.journal[agent.id] ?? []).filter { !($0.kind == .session && $0.did.hasPrefix("Decided")) && $0.kind != .stuck }.sorted { $0.at < $1.at }
    }
    private var decisions: [AgentDecision] { (feed.decisions[agent.id] ?? []).filter { $0.kind == .judgment } }
    private var sessions: [AgentWorker.DrivenSession] { feed.sessions[agent.id] ?? [] }
    private var name: String { agent.name.isEmpty ? "New Agent" : agent.name }
    private var need: AgentNeed? { feed.needs[agent.id]?.first }
    private var question: AgentNeed? { need.flatMap { $0.kind == .stuck || $0.kind == .decision || $0.kind == .setup ? $0 : nil } }
    private var budgetNeed: AgentNeed? { feed.needs[agent.id]?.first { $0.kind == .budget } }
    private var mood: AgentActivity.Mood { activity[agent.id]?.mood ?? .idle }
    private var reason: String? { activity[agent.id]?.bubble }
    private var window: AgentTarget? { AgentsPage.window(of: agent, feed: feed) }
    private var away: AwayReport? {
        guard agent.isBean else { return nil }
        let report = AwayReport(agents: crew, feed: feed)
        return report.isEmpty ? nil : report
    }

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
            if mood == .needsYou, need == nil, let reason {
                PageBanner(icon: "exclamationmark.circle.fill", text: reason) { EmptyView() }
            }
            if budgetNeed != nil || mood == .sleeping {
                PageBanner(icon: "gauge.with.dots.needle.100percent", text: "\(name) reached today's budget and paused. It resumes tomorrow.") {
                    if let spend = feed.spend[agent.id] {
                        Button("Add $1") { actions.setBudget(agent.id, spend.budget + 1) }.controlSize(.small).accessibilityIdentifier("page-raise-budget")
                    }
                }
            } else if let spend = feed.spend[agent.id], spend.budget > 0, spend.today / spend.budget >= 0.8 {
                PageBanner(icon: "gauge.with.dots.needle.67percent", text: "\(name) has used \(Int(spend.today / spend.budget * 100))% of today's budget. It pauses at 100%.") { EmptyView() }
            }
            if !agent.isBean, !agent.name.isEmpty, window == nil, question != nil || !(blocks.isEmpty && sessions.isEmpty) {
                HStack(spacing: 9) {
                    PageDrop(look: agent.look, mood: .idle, size: 18).modifier(AgentDragHandle(agent: agent, actions: actions))
                    Text("Drag me onto a window. That window becomes my work.").font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(.quaternary.opacity(0.5))
            }
            if blocks.isEmpty && sessions.isEmpty && away == nil {
                if question != nil {
                    Spacer(minLength: 0)
                } else if agent.isBean {
                    ContentUnavailableView {
                        Label("Bean runs your agents", systemImage: "sparkles")
                    } description: {
                        Text("Bean creates agents, puts them on your windows and runs them. Give it a goal, such as preparing Monday's client meeting, and it reports once.")
                    } actions: {
                        Button("Take Over") { actions.send(agent.id, "Take over") }
                            .buttonStyle(.borderedProminent)
                            .help("Bean keeps everything moving and answers for you while you are away")
                    }
                    .frame(maxHeight: .infinity)
                } else if agent.name.isEmpty {
                    ContentUnavailableView("Setting up \(name)", systemImage: "bubble.left.and.text.bubble.right",
                                           description: Text("The agent can be used as soon as its mission is written."))
                        .frame(maxHeight: .infinity)
                } else if let window {
                    ContentUnavailableView("\(name) is on \(window.title ?? window.app ?? window.name)", systemImage: "macwindow",
                                           description: Text("It works there in the background. Ask or correct it below."))
                        .frame(maxHeight: .infinity)
                } else {
                    VStack(spacing: 12) {
                        PageDrop(look: agent.look, mood: .idle, size: 54).modifier(AgentDragHandle(agent: agent, actions: actions))
                        Text("Drag me onto a window").font(.title2.weight(.semibold))
                        Text("A mail window, a spreadsheet, a web page: that window becomes \(name)'s work.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if !sessions.isEmpty { SessionsBlock(sessions: sessions) }
                        ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                            blockView(block, previous: index == 0 ? nil : blocks[index - 1])
                        }
                        if let away {
                            AwayCard(report: away, actions: actions)
                        }
                        if feed.replying.contains(agent.id) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("\(name) is replying").font(.callout).foregroundStyle(.secondary)
                            }
                            .padding(.leading, 2)
                        }
                    }
                    .padding(20)
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
                        Text(question.question).font(.callout).lineLimit(1)
                        Spacer()
                        Button("Answer") { deferred = nil }.controlSize(.small).accessibilityIdentifier("page-question-answer")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .padding(.horizontal, 14).padding(.top, 8)
                }
                if let doing = feed.doing[agent.id] {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(doing).font(.callout).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .padding(.horizontal, 14).padding(.top, 8)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(placeholder, text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...6)
                        .focused($focused)
                        .onSubmit(send)
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
        if previous.map({ !Calendar.current.isDate(Self.date(of: $0), inSameDayAs: date) }) ?? true {
            Text(Self.day(date)).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
        switch block {
        case .single(let entry):
            ThreadItem(entry: entry, agent: agent, crew: crew, undone: isUndone(entry), undo: { actions.undo(agent.id, entry.id) })
        case .decision(let decision):
            DecisionRow(decision: decision) { actions.correct(agent.id, decision.id, $0) }
        case .run(let list):
            DisclosureGroup("\(list.count) actions · \(list[list.count - 1].did)") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(list) { entry in
                        ActionRow(entry: entry, undone: isUndone(entry), undo: { actions.undo(agent.id, entry.id) })
                    }
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private func isUndone(_ entry: JournalEntry) -> Bool { entries.contains { $0.undoes == entry.id } }

    private var placeholder: String {
        if feed.doing[agent.id] != nil { return "Message \(name). It reads this after the current step." }
        return agent.isBean ? "Give Bean a goal, or ask anything" : "Ask or correct \(name)"
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
        actions.send(agent.id, text)
    }

    private static func day(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month())
    }
}

private struct ThreadItem: View {
    let entry: JournalEntry
    let agent: Agent
    let crew: [Agent]
    let undone: Bool
    let undo: () -> Void

    var body: some View {
        switch entry.kind {
        case .said:
            HStack {
                Spacer(minLength: 80)
                Text(entry.did)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        case .replied:
            HStack(alignment: .top, spacing: 9) {
                PageDrop(look: agent.look, mood: .idle, size: 16)
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.did).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let link = entry.link { LinkButton(link: link) }
                }
                Spacer(minLength: 60)
            }
        case .handoff:
            HandoffRow(entry: entry, agent: agent, crew: crew)
        default:
            ActionRow(entry: entry, undone: undone, undo: undo)
        }
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
                Text(entry.to == nil ? "From \(other?.name ?? "Bean")" : "Passed to \(other?.name ?? "an agent")").font(.caption).foregroundStyle(.secondary)
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
                Text(decision.state == .answered ? "Answered by you" : "On your behalf").font(.caption).foregroundStyle(.secondary)
                if let repo = decision.repo { Text("· \(repo)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                Text(decision.at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(decision.question).textSelection(.enabled)
            Text(decision.answer).fontWeight(.medium).textSelection(.enabled)
            if !decision.why.isEmpty {
                Text("Why: \(decision.why)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let correction = decision.correction {
                Label("Corrected: \(correction)", systemImage: "arrow.uturn.backward").font(.callout).foregroundStyle(.secondary)
            } else if decision.state == .decided {
                Button("Correct…") {
                    correcting.toggle()
                    fieldFocused = correcting
                }
                .controlSize(.small)
                .accessibilityIdentifier("page-correct")
            }
            if correcting {
                HStack {
                    TextField("What should the answer be?", text: $draft).textFieldStyle(.roundedBorder)
                        .focused($fieldFocused)
                        .onSubmit(send)
                    Button("Send", action: send).controlSize(.small).disabled(draft.isEmpty)
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

private struct SettingsPane {
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

private struct QuestionCard: View {
    let need: AgentNeed
    let name: String
    let more: Int
    let answer: (String) -> Void
    let later: () -> Void
    let connect: (String) -> Void
    @State private var choice: String?
    @State private var other = ""

    private var typed: String { other.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var preferred: String? { need.recommended ?? need.options.first }
    private var selected: String? { typed.isEmpty ? choice ?? preferred : typed }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(more > 0 ? "\(name) needs you · \(more) more after this" : "\(name) needs you").font(.caption).foregroundStyle(.secondary)
            Text(need.question).font(.headline)
            ForEach(need.options, id: \.self) { option in
                Button { choice = option; other = "" } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: selected == option ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selected == option ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option == preferred ? "\(option) (Recommended)" : option)
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
            TextField(need.options.isEmpty ? "Your answer" : "Other", text: $other).textFieldStyle(.roundedBorder)
                .onSubmit { if let selected { answer(selected) } }
                .accessibilityIdentifier("page-question-other")
            HStack {
                if let connector = need.connector {
                    Button("Connect") { connect(connector) }.fixedSize().accessibilityIdentifier("page-question-connect")
                }
                if let pane = SettingsPane(need) {
                    Button("Open Settings…") { NSWorkspace.shared.open(pane.url) }.fixedSize().accessibilityIdentifier("page-question-settings")
                }
                Spacer(minLength: 0)
                Button("Later", action: later).accessibilityIdentifier("page-question-later")
                Button("Skip") { answer("Skip this for now.") }
                Button("Send") { if let selected { answer(selected) } }
                    .accessibilityIdentifier("page-question-send")
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(14)
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
                            if entry.result != nil {
                                Button(open ? "Hide Details" : "Details") { open.toggle() }.controlSize(.small).fixedSize()
                            }
                            if let link = entry.link { LinkButton(link: link).fixedSize() }
                            if canUndo {
                                Button("Undo", action: undo)
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
    private var hasControls: Bool { entry.result != nil || entry.link != nil || canUndo }

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

private struct LinkButton: View {
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

private struct SessionsBlock: View {
    let sessions: [AgentWorker.DrivenSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Claude sessions").font(.caption).foregroundStyle(.secondary).padding(.bottom, 5)
            ForEach(sessions) { session in
                HStack(spacing: 8) {
                    Image(systemName: "terminal").foregroundStyle(.secondary).frame(width: 16)
                    Text(session.title).lineLimit(1)
                    Text(session.state).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if let link = session.link { LinkButton(link: link) }
                }
                .padding(.vertical, 5)
                if session.id != sessions.last?.id { Divider() }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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

private struct AgentInspector: View {
    let agent: Agent
    let mission: AgentMission?
    let targets: [AgentTarget]
    let connectors: [AgentConnectorInfo]
    let allAbilities: [AgentAbility]
    let spend: AgentWorker.AgentSpend?
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
        if agent.isBean { return "Bean runs your agents and answers for you when you take over." }
        let places = targets.map { $0.title ?? $0.name }
        let first = places.isEmpty ? "\(name) has nothing to work on yet." : "\(name) works on \(places.prefix(2).joined(separator: " and "))\(places.count > 2 ? " and \(places.count - 2) more" : "")."
        let risky = abilities.filter { $0.risk == .irreversible && !$0.allowed }.count
        return risky > 0 ? first + " It asks before anything irreversible." : first
    }

    var body: some View {
        Form {
            Text(summary).font(.callout).foregroundStyle(.secondary)
            if !agent.isBean {
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
            if let spend {
                Section {
                    Gauge(value: min(spend.today, max(spend.budget, 0.01)), in: 0...max(spend.budget, 0.01)) {
                        Text("\(pageMoney(spend.today)) spent").monospacedDigit()
                    }
                    .tint(spend.today >= spend.budget * 0.8 ? Color.orange : Color.accentColor)
                    Stepper("Daily limit: \(pageMoney(spend.budget))", value: Binding(get: { spend.budget }, set: { actions.setBudget(agent.id, $0) }), in: 0.5...50, step: 0.5)
                } header: { Text("Budget today") } footer: {
                    Text("Warns at 80%. Pauses at 100% until tomorrow.").font(.caption).foregroundStyle(.secondary)
                }
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
                            Text(ability.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .confirmationDialog("Allow \(ability.title)?", isPresented: Binding(get: { enabling?.id == ability.id }, set: { if !$0 { enabling = nil } })) {
                        Button("Allow", role: .destructive) { actions.setAbility(agent.id, ability.id, true) }
                    } message: { Text("\(name) will do this without asking, and it cannot be undone.") }
                }
    }
}

private struct TargetIcon: View {
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
