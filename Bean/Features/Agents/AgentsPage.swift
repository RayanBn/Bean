import AppKit
import SwiftUI

struct PageFeed {
    var journal: [UUID: [JournalEntry]] = [:]
    var doing: [UUID: String] = [:]
    var sessions: [UUID: [AgentWorker.DrivenSession]] = [:]
    var credits: AgentWorker.Credits?
    var missions: [UUID: AgentMission] = [:]
    var needsKey = false
    var targets: [UUID: [AgentTarget]] = [:]
    var connectors: [UUID: [AgentConnectorInfo]] = [:]
    var abilities: [UUID: [AgentAbility]] = [:]
    var replying: Set<UUID> = []
}

struct PageActions {
    var select: (UUID) -> Void = { _ in }
    var newAgent: () -> Void = {}
    var addKey: () -> Void = {}
    var cancelNew: () -> Void = {}
    var create: (String) -> Void = { _ in }
    var send: (UUID, String) -> Void = { _, _ in }
    var saveMission: (UUID, String) -> Void = { _, _ in }
    var undo: (UUID, UUID) -> Void = { _, _ in }
    var setAbility: (UUID, String, Bool) -> Void = { _, _, _ in }
    var connect: (UUID, String) -> Void = { _, _ in }
    var addTarget: (UUID, String) -> Void = { _, _ in }
    var removeTarget: (UUID, AgentTarget) -> Void = { _, _ in }
    var sendHome: (UUID) -> Void = { _ in }
    var delete: (UUID) -> Void = { _ in }
    var reveal: (UUID) -> Void = { _ in }
}

struct AgentsPageRoot: View {
    @ObservedObject var agents: Agents
    @ObservedObject var store: AgentStore
    @ObservedObject var worker: AgentWorker

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
        case .needsYou: self = .needsYou
        case .working, .reading, .forming: self = .working
        case .idle, .sleeping: self = .idle
        }
    }
}

struct AgentsPage: View {
    let agents: [Agent]
    let activity: [UUID: AgentActivity]
    let feed: PageFeed
    let selected: UUID?
    let creating: Bool
    var creationError: String?
    let actions: PageActions
    @AppStorage("agentsInspector") private var inspector = true

    private var agent: Agent? { agents.first { $0.id == selected } }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .safeAreaInset(edge: .top, spacing: 0) {
                    if feed.needsKey {
                        VStack(spacing: 0) {
                            HStack(spacing: 8) {
                                Image(systemName: "key.fill").foregroundStyle(.orange)
                                Text("Bean needs an API key to run agents.")
                                Spacer()
                                Button("Add Key…", action: actions.addKey).controlSize(.small)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(.orange.opacity(0.12))
                            Divider()
                        }
                    }
                }
                .navigationTitle(creating ? "New Agent" : displayName)
                .navigationSubtitle(creating ? "" : statusLine)
                .toolbar {
                    if !creating, agent != nil {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Settings", systemImage: "sidebar.right") { inspector.toggle() }
                                .help("Show or hide this agent's settings")
                        }
                    }
                }
        }
        .inspector(isPresented: Binding(get: { inspector && !creating && agent != nil }, set: { inspector = $0 })) {
            if let agent {
                AgentInspector(agent: agent, mission: feed.missions[agent.id], targets: feed.targets[agent.id] ?? [],
                               connectors: feed.connectors[agent.id] ?? [], abilities: feed.abilities[agent.id] ?? [], actions: actions)
                    .id(agent.id)
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
            }
        }
    }

    private var displayName: String {
        guard let agent else { return "Agents" }
        return agent.name.isEmpty ? "New Agent" : agent.name
    }

    private var statusLine: String {
        guard let agent else { return "" }
        return Self.status(of: agent, activity: activity[agent.id], feed: feed)
    }

    static func status(of agent: Agent, activity: AgentActivity?, feed: PageFeed) -> String {
        if agent.name.isEmpty { return "Setting up" }
        if let doing = feed.doing[agent.id] { return doing }
        if activity?.mood == .needsYou, let reason = activity?.bubble { return reason }
        return PageStatus(activity?.mood ?? .idle).title
    }

    private var sidebar: some View {
        List(selection: Binding(get: { creating ? nil : selected }, set: { if let id = $0 { actions.select(id) } })) {
            ForEach(PageStatus.allCases, id: \.self) { status in
                let group = agents.filter { PageStatus(activity[$0.id]?.mood ?? .idle) == status }
                if !group.isEmpty {
                    Section(status.title) {
                        ForEach(group) { agent in
                            AgentRow(agent: agent, mood: activity[agent.id]?.mood ?? .idle,
                                     line: Self.status(of: agent, activity: activity[agent.id], feed: feed) == status.title ? (feed.missions[agent.id]?.mission ?? agent.role) : Self.status(of: agent, activity: activity[agent.id], feed: feed))
                                .tag(agent.id)
                                .accessibilityIdentifier("page-agent-\(agent.name)")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        .safeAreaInset(edge: .bottom) {
            if let creditsLine {
                HStack {
                    Text(creditsLine).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("page-credits")
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .toolbar {
            ToolbarItem {
                Button("New Agent", systemImage: "plus", action: actions.newAgent)
                    .keyboardShortcut("n")
                    .accessibilityIdentifier("page-new-agent")
            }
        }
    }

    private var creditsLine: String? {
        guard let credits = feed.credits else { return nil }
        return "\(credits.estimate ? "About " : "")\(credits.left) of credits left"
    }

    @ViewBuilder private var detail: some View {
        if creating {
            NewAgentForm(error: creationError, canCancel: !agents.isEmpty, create: actions.create, cancel: actions.cancelNew)
        } else if let agent {
            Conversation(agent: agent, mood: activity[agent.id]?.mood ?? .idle, reason: activity[agent.id]?.bubble, feed: feed, actions: actions)
                .id(agent.id)
        } else {
            ContentUnavailableView("No agent selected", systemImage: "person.crop.circle", description: Text("Select an agent, or create one."))
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

private struct AgentRow: View {
    let agent: Agent
    let mood: AgentActivity.Mood
    let line: String

    var body: some View {
        HStack(spacing: 9) {
            PageDrop(look: agent.look, mood: mood, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name.isEmpty ? "New Agent" : agent.name)
                Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .help(line)
        .accessibilityElement(children: .combine)
    }
}

private struct Conversation: View {
    let agent: Agent
    let mood: AgentActivity.Mood
    let reason: String?
    let feed: PageFeed
    let actions: PageActions
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var entries: [JournalEntry] { (feed.journal[agent.id] ?? []).sorted { $0.at < $1.at } }
    private var sessions: [AgentWorker.DrivenSession] { feed.sessions[agent.id] ?? [] }
    private var name: String { agent.name.isEmpty ? "New Agent" : agent.name }

    var body: some View {
        VStack(spacing: 0) {
            if mood == .needsYou, let reason {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(reason)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(.orange.opacity(0.12))
                Divider()
            }
            if entries.isEmpty && sessions.isEmpty {
                ContentUnavailableView(agent.name.isEmpty ? "Setting up \(name)" : "No activity yet",
                                       systemImage: "bubble.left.and.text.bubble.right",
                                       description: Text(agent.name.isEmpty ? "The agent can be used as soon as its mission is written." : "Write to \(name) below, or drag it from the notch onto a window."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if !sessions.isEmpty { SessionsBlock(sessions: sessions) }
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if index == 0 || !Calendar.current.isDate(entries[index - 1].at, inSameDayAs: entry.at) {
                                Text(Self.day(entry.at)).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                            }
                            ThreadItem(entry: entry, look: agent.look, undone: entries.contains { $0.undoes == entry.id }, undo: { actions.undo(agent.id, entry.id) })
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
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message \(name)", text: $draft, axis: .vertical)
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
    let look: Agent.Look
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
                PageDrop(look: look, mood: .idle, size: 16)
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.did).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let link = entry.link { LinkButton(link: link) }
                }
                Spacer(minLength: 60)
            }
        default:
            ActionRow(entry: entry, undone: undone, undo: undo)
        }
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
                }
                Spacer(minLength: 8)
                Text(entry.at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                if entry.result != nil {
                    Button(open ? "Hide Details" : "Details") { open.toggle() }.controlSize(.small)
                }
                if let link = entry.link { LinkButton(link: link) }
                if entry.undoCommand != nil && !undone {
                    Button("Undo", action: undo)
                        .controlSize(.small)
                        .help(entry.undo ?? "Undo this action")
                        .accessibilityIdentifier("page-undo")
                }
            }
            if open, let result = entry.result {
                Text(result).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var icon: String {
        switch entry.kind {
        case .action: "checkmark.circle"
        case .refused: "hand.raised"
        case .failed: "exclamationmark.triangle"
        case .stuck: "exclamationmark.circle"
        case .undo: "arrow.uturn.backward.circle"
        case .session: "terminal"
        case .said, .replied: "text.bubble"
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
        return Int(last) != nil ? "#\(last)" : last
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
            TextField("For example: review my pull requests and mark them ready when they pass", text: $mission, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .focused($focused)
                .onSubmit(submit)
                .accessibilityIdentifier("page-new-mission")
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
    let abilities: [AgentAbility]
    let actions: PageActions
    @State private var missionDraft = ""
    @State private var confirming = false
    @State private var enabling: AgentAbility?
    @State private var showRoutine = false
    @State private var targetDraft = ""
    @FocusState private var editing: Bool

    private var name: String { agent.name.isEmpty ? "This agent" : agent.name }

    var body: some View {
        Form {
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
                    }
                }
                if targets.isEmpty {
                    Text("Nothing yet. Name a repo or project below or in the conversation, or drag \(name) onto a window.").font(.caption).foregroundStyle(.secondary)
                }
                TextField("Add a repository or project", text: $targetDraft)
                    .labelsHidden()
                    .onSubmit {
                        let text = targetDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        targetDraft = ""
                        if !text.isEmpty { actions.addTarget(agent.id, text) }
                    }
                    .accessibilityIdentifier("page-add-target")
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
                    DisclosureGroup("Routine: \(abilities.filter { $0.risk == .safe }.count) abilities", isExpanded: $showRoutine) {
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

    var body: some View {
        if let app = target.app, let icon = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == app })?.icon {
            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
        } else {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
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
