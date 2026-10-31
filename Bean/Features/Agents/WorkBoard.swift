import SwiftUI

struct WorkItem: Identifiable {
    enum State: CaseIterable {
        case waiting, running, finished, stopped

        var title: String {
            switch self {
            case .waiting: "Needs you"
            case .running: "Running"
            case .finished: "Finished"
            case .stopped: "Stopped"
            }
        }
    }

    let id: String
    let agent: Agent
    let title: String
    let state: State
    var step: String?
    var need: AgentNeed?
    var session: AgentWorker.DrivenSession?
    var steps: [String] = []
    var at: Date?

    static func all(agents: [Agent], feed: PageFeed) -> [WorkItem] {
        let found = agents.flatMap { items(of: $0, feed: feed) }
        let waiting = found.filter { $0.state == .waiting }.sorted { ($0.need?.at ?? .distantPast) < ($1.need?.at ?? .distantPast) }
        let running = found.filter { $0.state == .running }
        let ended = found.filter { $0.state == .finished || $0.state == .stopped }.sorted { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }
        return waiting + running + ended.prefix(8)
    }

    static func sessions(of agent: Agent, feed: PageFeed) -> [WorkItem] {
        items(of: agent, feed: feed).filter { $0.session != nil }
    }

    private static func items(of agent: Agent, feed: PageFeed) -> [WorkItem] {
        let asking = (feed.needs[agent.id] ?? []).filter { $0.kind == .stuck || $0.kind == .decision || $0.kind == .setup }
        let sessions = (feed.sessions[agent.id] ?? []).map { session in
            let need = asking.first { $0.session == session.id }
            let steps = (feed.decisions[agent.id] ?? []).filter { $0.session == session.id }
            let state: State = switch session.status {
            case .waiting, .running: need == nil ? .running : .waiting
            case .finished: .finished
            case .stopped: .stopped
            }
            return WorkItem(id: "session \(session.id)", agent: agent, title: session.task.map(firstLine) ?? session.repo, state: state,
                            step: need?.question ?? (session.status == .waiting ? nil : session.status == .stopped ? stopReason(session.step) : plainStep(session.step)), need: need, session: session,
                            steps: steps.suffix(6).map { $0.answer == "refused" ? AgentStrings.shown("Refused: %@", $0.question) : $0.question }, at: steps.last?.at ?? session.startedAt)
        }
        let held = Set(sessions.compactMap(\.need?.id))
        let questions = asking.filter { !held.contains($0.id) }.map { need in
            WorkItem(id: "need \(need.id)", agent: agent, title: need.task.map(firstLine) ?? AgentStrings.shown(need.question), state: .waiting, step: need.task == nil ? nil : AgentStrings.shown(need.question), need: need, at: need.at)
        }
        let journal = feed.journal[agent.id] ?? []
        var work: [WorkItem] = []
        if let doing = feed.doing[agent.id], !sessions.contains(where: { $0.state == .running }), asking.isEmpty {
            let since = feed.doingSince[agent.id] ?? .distantPast
            let steps = journal.filter { $0.at >= since && isStep($0) }.map(\.did)
            work.append(WorkItem(id: "doing \(agent.id)", agent: agent, title: firstLine(doing), state: .running, step: steps.last, steps: Array(steps.suffix(6)), at: since))
        }
        for ended in feed.endedWork where ended.agent == agent.id {
            guard !sessions.contains(where: { ($0.session?.startedAt).map { $0 >= ended.began && $0 <= ended.ended } == true }) else { continue }
            let steps = journal.filter { $0.at >= ended.began && $0.at <= ended.ended }
            let shown = steps.filter(isStep).map(\.did)
            work.append(WorkItem(id: "ended \(ended.id)", agent: agent, title: firstLine(ended.what), state: ended.stopped ? .stopped : .finished, step: shown.last, steps: Array(shown.suffix(6)), at: ended.ended))
        }
        return questions + sessions + work
    }

    private static func plainStep(_ step: String?) -> String? {
        step?.hasPrefix("Running ") == true ? AgentStrings.shown("Running a command") : step
    }

    private static func stopReason(_ step: String?) -> String {
        switch step {
        case "Stopped: refuse": AgentStrings.shown("Its work was refused")
        case "Stopped: paused": AgentStrings.shown("Paused")
        case "Stopped: budget": AgentStrings.shown("Daily budget reached")
        default: AgentStrings.shown("Stopped")
        }
    }

    private static func isStep(_ entry: JournalEntry) -> Bool {
        [.action, .refused, .failed, .session, .handoff].contains(entry.kind)
    }

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n").first.map(String.init) ?? text
    }
}

struct WorkBoard: View {
    let items: [WorkItem]
    var answersHere = true
    let maxHeight: CGFloat
    let actions: PageActions
    @State private var height: CGFloat = 0
    @State private var open: Set<String> = []
    @State private var answering: String?
    @State private var deferred: Set<String> = []
    @State private var endedOpen = true

    private var waiting: [WorkItem] { items.filter { $0.state == .waiting } }
    private var running: [WorkItem] { items.filter { $0.state == .running } }
    private var ended: [WorkItem] { items.filter { $0.state == .finished || $0.state == .stopped } }
    private var asked: WorkItem? {
        guard answersHere else { return nil }
        return waiting.first { $0.id == answering } ?? waiting.first { !deferred.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !waiting.isEmpty { group(.waiting, waiting) }
                    if !running.isEmpty { group(.running, running) }
                    if !ended.isEmpty {
                        PageDisclosure(isExpanded: $endedOpen) {
                            header(.finished, ended.count)
                        } content: {
                            rows(ended).padding(.top, 4)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
            .frame(height: min(height, maxHeight))
            Divider()
        }
        .accessibilityIdentifier("page-work")
    }

    private func group(_ state: WorkItem.State, _ list: [WorkItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            header(state, list.count)
            rows(list)
        }
    }

    private func header(_ state: WorkItem.State, _ count: Int) -> some View {
        HStack(spacing: 5) {
            Text(AgentStrings.shown(state.title)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("\(count)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
        }
    }

    private func rows(_ list: [WorkItem]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(list) { item in
                if asked?.id == item.id, let need = item.need {
                    QuestionCard(need: need, name: item.agent.name, more: 0, about: item.title == AgentStrings.shown(need.question) ? nil : item.title,
                                 inset: 0, answer: { actions.answer(item.agent.id, need.id, $0) },
                                 later: { deferred.insert(item.id); answering = nil }, connect: actions.connectService)
                        .id(need.id)
                } else {
                    WorkRow(item: item, open: Binding(get: { open.contains(item.id) }, set: { if $0 { open.insert(item.id) } else { open.remove(item.id) } }),
                            answer: answersHere && item.need != nil ? { answering = item.id; deferred.remove(item.id) } : nil, actions: actions)
                }
            }
        }
    }
}

private struct WorkRow: View {
    let item: WorkItem
    @Binding var open: Bool
    let answer: (() -> Void)?
    let actions: PageActions
    @State private var terminalProblem: String?

    private var line: String {
        [item.agent.name, item.step].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        mark.frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.callout.weight(.medium)).lineLimit(1).help(item.title)
                            HStack(spacing: 4) {
                                PageDrop(look: item.agent.look, mood: .idle, size: 11)
                                Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        if let cost = item.session?.costUSD, cost > 0 {
                            Text(pageMoney(cost)).font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                        }
                        if let at = item.at, item.state != .running {
                            Text(at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary).fixedSize()
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(AgentStrings.shown(item.state.title)): \(item.title)")
                .accessibilityIdentifier("page-work-row")
                if let answer {
                    Button(AgentStrings.shown("Answer"), action: answer).controlSize(.small).accessibilityIdentifier("page-work-answer")
                }
                if let link = item.session?.pullRequest { LinkButton(link: link).accessibilityIdentifier("page-work-pr") }
            }
            if open { details.padding(.leading, 24) }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var mark: some View {
        switch item.state {
        case .waiting: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .running: ProgressView().controlSize(.small)
        case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .stopped: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let session = item.session {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 2) {
                    GridRow {
                        Text(AgentStrings.shown("Project")).foregroundStyle(.tertiary)
                        Text(session.repo).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if !session.branch.isEmpty {
                        GridRow {
                            Text(AgentStrings.shown("Branch")).foregroundStyle(.tertiary)
                            Text(session.branch).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                .font(.caption)
            }
            ForEach(Array(item.steps.enumerated()), id: \.offset) { _, step in
                Text(step).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
            if item.session == nil && item.steps.isEmpty {
                Text(AgentStrings.shown("No steps yet.")).font(.caption).foregroundStyle(.tertiary)
            }
            if let session = item.session {
                HStack(spacing: 8) {
                    if let openIn = actions.openSessionInTerminal {
                        Button(AgentStrings.shown("Open in Terminal")) { terminalProblem = openIn(item.agent.id, session.id) }
                            .accessibilityIdentifier("page-work-terminal")
                    }
                    if item.state == .running || item.state == .waiting, let stop = actions.stopSession {
                        Button(AgentStrings.shown("Stop")) { stop(item.agent.id, session.id) }.accessibilityIdentifier("page-work-stop")
                    }
                }
                .controlSize(.small)
                if actions.openSessionInTerminal != nil {
                    Text(AgentStrings.shown("Open in Terminal stops Bean's work on this session. There you drive it yourself, and Bean's limits no longer apply. Claude may first ask you to trust its folder: only you can answer that."))
                        .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                if let terminalProblem {
                    Text(terminalProblem).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
