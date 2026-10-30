import AppKit
import SwiftUI

enum Paper {
    static let canvas = Color(red: 0.985, green: 0.978, blue: 0.965)
    static let side = Color(red: 0.955, green: 0.945, blue: 0.925)
    static let ink = Color(white: 0.09)

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

private struct StaticRenderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var staticRender: Bool {
        get { self[StaticRenderKey.self] }
        set { self[StaticRenderKey.self] = newValue }
    }
}

struct PageFeed {
    var journal: [UUID: [JournalEntry]] = [:]
    var doing: [UUID: String] = [:]
    var sessions: [UUID: [AgentWorker.DrivenSession]] = [:]
    var credits: AgentWorker.Credits?
    var missions: [UUID: AgentMission] = [:]
}

struct PageActions {
    var select: (UUID) -> Void = { _ in }
    var newAgent: () -> Void = {}
    var save: (AgentMission, UUID) -> Void = { _, _ in }
    var undo: (UUID, UUID) -> Void = { _, _ in }
    var sendHome: (UUID) -> Void = { _ in }
    var delete: (UUID) -> Void = { _ in }
    var reveal: (UUID) -> Void = { _ in }
}

struct AgentsPageRoot: View {
    @ObservedObject var agents: Agents
    @ObservedObject var store: AgentStore
    @ObservedObject var worker: AgentWorker

    var body: some View {
        AgentsPage(agents: store.agents, activity: store.activity, feed: agents.feed, selected: agents.selected, actions: PageActions(
            select: { agents.select($0) },
            newAgent: { agents.newAgent() },
            save: { agents.save($0, for: $1) },
            undo: { agents.undo($0, entry: $1) },
            sendHome: { agents.sendHome($0) },
            delete: { agents.delete($0) },
            reveal: { id in
                if let agent = store.agents.first(where: { $0.id == id }) {
                    NSWorkspace.shared.activateFileViewerSelecting([AgentFolder(agent, in: store).url])
                }
            }))
    }
}

struct AgentsPage: View {
    let agents: [Agent]
    let activity: [UUID: AgentActivity]
    let feed: PageFeed
    let selected: UUID?
    let actions: PageActions

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(agents: agents, activity: activity, feed: feed, selected: selected, actions: actions)
                .frame(width: 256)
            Rectangle().fill(Paper.ink.opacity(0.07)).frame(width: 1)
            if let id = selected, let agent = agents.first(where: { $0.id == id }) {
                AgentDetail(agent: agent, activity: activity[id] ?? AgentActivity(), mission: feed.missions[id],
                            journal: feed.journal[id] ?? [], doing: feed.doing[id], sessions: feed.sessions[id] ?? [], actions: actions)
                    .id(id)
            } else {
                Paper.canvas
            }
        }
        .foregroundStyle(Paper.ink)
        .background(Paper.canvas)
        .ignoresSafeArea()
        .environment(\.colorScheme, .light)
    }
}

private enum Status: CaseIterable {
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

private struct Sidebar: View {
    let agents: [Agent]
    let activity: [UUID: AgentActivity]
    let feed: PageFeed
    let selected: UUID?
    let actions: PageActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 40)
            ForEach(Status.allCases, id: \.self) { status in
                let group = agents.filter { Status(activity[$0.id]?.mood ?? .idle) == status }
                if !group.isEmpty {
                    Text(status.title.uppercased())
                        .font(Paper.font(10, .semibold)).tracking(0.5)
                        .foregroundStyle(Paper.ink.opacity(0.42))
                        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 4)
                    ForEach(group) { agent in
                        Button { actions.select(agent.id) } label: {
                            AgentRow(agent: agent, mood: activity[agent.id]?.mood ?? .idle, line: line(for: agent), selected: agent.id == selected)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(agent.name.isEmpty ? "New agent" : agent.name)
                        .accessibilityIdentifier("page-agent-\(agent.name)")
                    }
                }
            }
            Spacer(minLength: 0)
            Button(action: actions.newAgent) {
                HStack(spacing: 7) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    Text("New agent").font(Paper.font(12.5, .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Paper.ink.opacity(0.6))
                .padding(.horizontal, 18).frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("page-new-agent")
            HStack(spacing: 5) {
                Text("Credits").foregroundStyle(Paper.ink.opacity(0.4))
                if let credits = feed.credits {
                    Text("\(credits.estimate ? "about " : "")\(credits.left) left").foregroundStyle(Paper.ink.opacity(0.62))
                } else {
                    Text("not known yet").foregroundStyle(Paper.ink.opacity(0.4))
                }
            }
            .font(Paper.font(11))
            .padding(.horizontal, 18).padding(.bottom, 14).padding(.top, 2)
            .accessibilityIdentifier("page-credits")
        }
        .background(Paper.side)
    }

    private func line(for agent: Agent) -> String {
        let id = agent.id
        if agent.name.isEmpty { return "Getting ready" }
        if let doing = feed.doing[id] { return doing }
        if activity[id]?.mood == .needsYou, let reason = activity[id]?.bubble { return reason }
        if feed.missions[id]?.isActive == false, !agent.isBean { return "Waiting for a scope" }
        return feed.missions[id]?.mission.nilIfEmpty ?? agent.role
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct AgentRow: View {
    let agent: Agent
    let mood: AgentActivity.Mood
    let line: String
    let selected: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            PageDrop(look: agent.look, mood: mood, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name.isEmpty ? "New agent" : agent.name).font(Paper.font(13, .semibold)).foregroundStyle(Paper.ink.opacity(0.92))
                Text(line).font(Paper.font(11.5)).foregroundStyle(Paper.ink.opacity(0.52)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Paper.ink.opacity(selected ? 0.07 : hover ? 0.035 : 0)))
        .contentShape(Rectangle())
        .padding(.horizontal, 8)
        .onHover { hover = $0 }
    }
}

private struct PageDrop: View {
    let look: Agent.Look
    let mood: AgentActivity.Mood
    let size: CGFloat

    var body: some View {
        let frame = CreatureView.frame(size)
        CreatureView(look: look, mood: mood, size: size, pose: .peek, limbs: 0)
            .frame(width: frame.width, height: frame.height)
            .frame(width: size * 1.2, height: size * 1.3)
    }
}

private struct AgentDetail: View {
    let agent: Agent
    let activity: AgentActivity
    let mission: AgentMission?
    let journal: [JournalEntry]
    let doing: String?
    let sessions: [AgentWorker.DrivenSession]
    let actions: PageActions
    @Environment(\.staticRender) private var isStatic

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.top, 34)
            ScopeBar(mission: current, editable: !agent.name.isEmpty, save: { actions.save($0, agent.id) }).padding(.top, 14)
            NowBar(agent: agent, activity: activity, doing: doing, waiting: !agent.isBean && !current.isActive, sendHome: { actions.sendHome(agent.id) })
                .padding(.top, 16)
            if isStatic {
                content.padding(.top, 8)
                Spacer(minLength: 0)
            } else {
                ScrollView { content.padding(.bottom, 24) }
                    .scrollIndicators(.never)
                    .padding(.top, 8)
            }
            footer
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Paper.canvas)
    }

    private var current: AgentMission { mission ?? AgentMission(mission: "", scope: [], allowed: []) }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            PageDrop(look: agent.look, mood: activity.mood, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name.isEmpty ? "New agent" : agent.name).font(Paper.font(21, .semibold)).foregroundStyle(Paper.ink.opacity(0.92))
                MissionField(text: current.mission, placeholder: agent.isBean ? agent.role : "Give it a mission", save: {
                    var next = current
                    next.mission = $0
                    actions.save(next, agent.id)
                })
            }
        }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if agent.isBean || !sessions.isEmpty { SessionsList(sessions: sessions) }
            JournalList(entries: journal, undo: { actions.undo(agent.id, $0) })
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button { actions.reveal(agent.id) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder").font(.system(size: 10))
                    Text("Its folder").font(Paper.font(11.5, .medium))
                }
                .foregroundStyle(Paper.ink.opacity(0.45))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            if !agent.isBean { HoldToDelete { actions.delete(agent.id) } }
        }
        .padding(.vertical, 12)
    }
}

private struct MissionField: View {
    let text: String
    let placeholder: String
    let save: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool
    @Environment(\.staticRender) private var isStatic

    var body: some View {
        Group {
            if isStatic {
                Text(text.isEmpty ? placeholder : text).foregroundStyle(Paper.ink.opacity(text.isEmpty ? 0.4 : 0.6))
            } else {
                TextField("", text: $draft, prompt: Text(placeholder).foregroundStyle(Paper.ink.opacity(0.4)), axis: .vertical)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Paper.ink.opacity(focused ? 0.9 : 0.6))
                    .focused($focused)
                    .onSubmit { focused = false }
                    .onAppear { draft = text }
                    .onChange(of: text) { _, new in if !focused { draft = new } }
                    .onChange(of: focused) { _, now in
                        let clean = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !now, clean != text { save(clean) }
                    }
                    .accessibilityIdentifier("page-mission")
            }
        }
        .font(Paper.font(13))
    }
}

private struct ScopeBar: View {
    let mission: AgentMission
    let editable: Bool
    let save: (AgentMission) -> Void
    @State private var adding = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(mission.scope, id: \.self) { name in
                PagePill(text: name, on: true, removable: editable) {
                    var next = mission
                    next.scope.removeAll { $0 == name }
                    save(next)
                }
            }
            if editable {
                if adding {
                    TextField("", text: $draft, prompt: Text("Repo or project").foregroundStyle(Paper.ink.opacity(0.35)))
                        .textFieldStyle(.plain)
                        .font(Paper.font(11.5, .medium))
                        .frame(width: 130)
                        .focused($focused)
                        .onSubmit(add)
                        .onChange(of: focused) { _, now in if !now { add() } }
                        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } }
                        .accessibilityIdentifier("page-add-scope")
                } else {
                    Button { adding = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus").font(.system(size: 8.5, weight: .bold))
                            Text(mission.scope.isEmpty ? "Add a repo or project" : "Add").font(Paper.font(11.5, .medium))
                        }
                        .foregroundStyle(Paper.ink.opacity(0.5))
                        .padding(.horizontal, 6).frame(height: 22)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("page-add-scope-button")
                }
            }
            Rectangle().fill(Paper.ink.opacity(0.1)).frame(width: 1, height: 14).padding(.horizontal, 3)
            ForEach(mission.allowed, id: \.self) { PagePill(text: $0, on: true) }
            Toggle2(label: "Merge", on: mission.mayMerge, enabled: editable) {
                var next = mission
                next.mayMerge.toggle()
                save(next)
            }
            Toggle2(label: "Deploy", on: mission.mayDeploy, enabled: editable) {
                var next = mission
                next.mayDeploy.toggle()
                save(next)
            }
            Toggle2(label: "Run sessions", on: mission.mayRunSessions, enabled: editable) {
                var next = mission
                next.mayRunSessions.toggle()
                save(next)
            }
        }
    }

    private func add() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        adding = false
        guard !name.isEmpty, !mission.scope.contains(name) else { return }
        var next = mission
        next.scope.append(name)
        save(next)
    }
}

private struct Toggle2: View {
    let label: String
    let on: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { PagePill(text: label, on: on, mark: true) }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .accessibilityLabel(label)
            .accessibilityValue(on ? "allowed" : "not allowed")
    }
}

private struct PagePill: View {
    let text: String
    var on = true
    var mark = false
    var removable = false
    var remove: () -> Void = {}
    @State private var hover = false

    var body: some View {
        HStack(spacing: 4) {
            if mark { Image(systemName: on ? "checkmark" : "minus").font(.system(size: 8, weight: .bold)) }
            Text(text).font(Paper.font(11.5, .medium)).lineLimit(1)
            if removable && hover {
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(text)")
            }
        }
        .foregroundStyle(Paper.ink.opacity(on ? 0.75 : 0.36))
        .padding(.horizontal, 9).frame(height: 22)
        .background(Capsule().fill(Paper.ink.opacity(on ? 0.06 : 0)))
        .overlay(Capsule().strokeBorder(Paper.ink.opacity(on ? 0 : 0.14), lineWidth: 0.8))
        .fixedSize()
        .onHover { hover = $0 }
    }
}

private struct NowBar: View {
    let agent: Agent
    let activity: AgentActivity
    let doing: String?
    let waiting: Bool
    let sendHome: () -> Void

    var body: some View {
        let palette = CreaturePalette(look: agent.look)
        let needs = activity.mood == .needsYou
        HStack(spacing: 8) {
            Circle().fill(dotted ? palette.body : Paper.ink.opacity(0.2)).frame(width: 7, height: 7)
                .shadow(color: dotted ? palette.body : .clear, radius: 3)
            Text(needs ? "Needs you" : dotted ? "Now" : "Idle").font(Paper.font(12, .semibold)).foregroundStyle(Paper.ink.opacity(0.5))
            Text(line).font(Paper.font(13.5, .medium)).foregroundStyle(Paper.ink.opacity(dotted ? 0.9 : 0.55)).lineLimit(2)
            Spacer(minLength: 0)
            if let attachment = agent.attachment {
                Button(action: sendHome) {
                    Text("On \(attachment.appName) · Send home").font(Paper.font(11.5, .medium)).foregroundStyle(Paper.ink.opacity(0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send home")
            }
        }
        .padding(.horizontal, 12).frame(minHeight: 38)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(needs ? palette.body.opacity(0.16) : Paper.ink.opacity(0.04)))
    }

    private var dotted: Bool {
        switch Status(activity.mood) {
        case .needsYou, .working: true
        case .idle: false
        }
    }

    private var line: String {
        if agent.name.isEmpty { return "Getting ready" }
        if let doing { return doing }
        if dotted, let bubble = activity.bubble { return bubble }
        if waiting { return "Add a repo or project and it starts." }
        return activity.bubble ?? "Nothing right now. Drag it onto something to give it work."
    }
}

private struct SessionsList: View {
    let sessions: [AgentWorker.DrivenSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DayTitle(text: "Sessions it drives")
            if sessions.isEmpty {
                Text("None right now.").font(Paper.font(13)).foregroundStyle(Paper.ink.opacity(0.45)).padding(.vertical, 6)
            }
            ForEach(sessions) { session in
                HStack(spacing: 10) {
                    Image(systemName: "terminal").font(.system(size: 10, weight: .semibold)).foregroundStyle(Paper.ink.opacity(0.42)).frame(width: 14)
                    Text(session.title).font(Paper.font(13, .medium)).foregroundStyle(Paper.ink.opacity(0.88)).lineLimit(1)
                    Text(session.state).font(Paper.font(12)).foregroundStyle(Paper.ink.opacity(0.48)).lineLimit(1)
                    Spacer(minLength: 0)
                    if let link = session.link { LinkPill(link: link) }
                }
                .padding(.vertical, 7)
                Rectangle().fill(Paper.ink.opacity(0.08)).frame(height: 1)
            }
        }
    }
}

private struct DayTitle: View {
    let text: String

    var body: some View {
        Text(text).font(Paper.font(12, .semibold)).foregroundStyle(Paper.ink.opacity(0.42)).padding(.top, 14).padding(.bottom, 2)
    }
}

private struct JournalList: View {
    let entries: [JournalEntry]
    let undo: (UUID) -> Void

    var body: some View {
        let undone = Set(entries.compactMap(\.undoes))
        let days = Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.at) }.sorted { $0.key > $1.key }
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                DayTitle(text: "Journal")
                Text("Nothing yet. What it does will show here.").font(Paper.font(13)).foregroundStyle(Paper.ink.opacity(0.45)).padding(.vertical, 6)
            }
            ForEach(days, id: \.key) { day, items in
                DayTitle(text: Self.title(day))
                ForEach(Array(items.sorted { $0.at > $1.at }.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Rectangle().fill(Paper.ink.opacity(0.08)).frame(height: 1) }
                    JournalRow(entry: entry, undone: undone.contains(entry.id), undo: { undo(entry.id) })
                }
            }
        }
    }

    private static func title(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month())
    }
}

private struct JournalRow: View {
    let entry: JournalEntry
    let undone: Bool
    let undo: () -> Void
    @State private var open = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(entry.at.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Paper.ink.opacity(0.36)).frame(width: 40, alignment: .leading)
            Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint).frame(width: 14)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.did).font(Paper.font(13)).foregroundStyle(Paper.ink.opacity(undone ? 0.42 : 0.86))
                    .strikethrough(undone, color: Paper.ink.opacity(0.3))
                    .fixedSize(horizontal: false, vertical: true)
                if !entry.why.isEmpty {
                    Text(entry.why).font(Paper.font(12)).foregroundStyle(Paper.ink.opacity(0.48)).fixedSize(horizontal: false, vertical: true)
                }
                if entry.link != nil || canUndo || entry.result != nil {
                    HStack(spacing: 8) {
                        if let link = entry.link { LinkPill(link: link) }
                        if entry.result != nil {
                            Button { open.toggle() } label: {
                                Text(open ? "Hide result" : "Result").font(Paper.font(11, .semibold)).foregroundStyle(Paper.ink.opacity(0.45))
                            }
                            .buttonStyle(.plain)
                        }
                        if canUndo {
                            Button(action: undo) {
                                Text(entry.undo.map { "Undo: \($0)" } ?? "Undo").font(Paper.font(11, .semibold)).foregroundStyle(Paper.ink.opacity(0.55))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("page-undo")
                        }
                    }
                    .padding(.top, 1)
                }
                if open, let result = entry.result {
                    Text(result).font(.system(size: 11, design: .monospaced)).foregroundStyle(Paper.ink.opacity(0.65))
                        .textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Paper.ink.opacity(0.045)))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private var canUndo: Bool { entry.undoCommand != nil && !undone }

    private var icon: String {
        switch entry.kind {
        case .action: "checkmark"
        case .refused: "hand.raised"
        case .failed: "exclamationmark.triangle"
        case .stuck: "questionmark"
        case .undo: "arrow.uturn.backward"
        case .session: "text.bubble"
        }
    }

    private var tint: Color {
        switch entry.kind {
        case .failed, .stuck: Color(red: 0.8, green: 0.36, blue: 0.2)
        default: Paper.ink.opacity(0.42)
        }
    }
}

private struct LinkPill: View {
    let link: String

    var body: some View {
        Button {
            if let url = URL(string: link), url.scheme == "https" || url.scheme == "http" { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 3) {
                Text(label).font(Paper.font(11, .medium)).lineLimit(1)
                Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Paper.ink.opacity(0.7))
            .padding(.horizontal, 8).frame(height: 21)
            .background(Capsule().fill(Paper.ink.opacity(0.06)))
            .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var label: String {
        guard let url = URL(string: link) else { return link }
        let last = url.lastPathComponent
        if last.isEmpty || last == "/" { return url.host ?? link }
        return Int(last) != nil ? "#\(last)" : last
    }
}

private struct HoldToDelete: View {
    let action: () -> Void
    @State private var progress: CGFloat = 0

    var body: some View {
        Label("Hold to delete", systemImage: "trash")
            .font(Paper.font(11.5, .medium))
            .padding(.horizontal, 10).frame(height: 24)
            .background {
                GeometryReader { geo in
                    Capsule().fill(Color(red: 0.92, green: 0.33, blue: 0.28).opacity(0.85)).frame(width: geo.size.width * progress)
                }
                .clipShape(Capsule())
            }
            .foregroundStyle(progress > 0.5 ? .white : Paper.ink.opacity(0.45))
            .contentShape(Capsule())
            .onLongPressGesture(minimumDuration: 1, maximumDistance: 20) {
                action()
            } onPressingChanged: { pressing in
                withAnimation(pressing ? .linear(duration: 1) : .spring(response: 0.3, dampingFraction: 0.8)) { progress = pressing ? 1 : 0 }
            }
            .accessibilityLabel("Delete")
            .accessibilityAction { action() }
    }
}
