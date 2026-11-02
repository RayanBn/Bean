import SwiftUI

struct AwayReport {
    struct Item: Identifiable {
        let agent: Agent
        let id: UUID
        let title: String
        let detail: String
        let at: Date
        var opens: UUID?
    }

    let since: Date
    let permissions: Int
    let waiting: [Item]
    let decided: [Item]
    let passed: [Item]
    let done: [Item]
    let stopped: [Item]
    let retried: [Item]

    static let shortestAway: TimeInterval = 600

    init(agents: [Agent], feed: PageFeed) {
        since = feed.awaySince
        let summaries = agents.compactMap { agent in feed.summaries[agent.id].map { (agent, $0) } }
        permissions = summaries.reduce(0) { $0 + $1.1.permissionsAnswered }
        func named(_ agent: Agent, _ why: String) -> String { why.isEmpty ? agent.name : "\(agent.name) · \(why)" }
        func newest(_ items: [Item]) -> [Item] { items.sorted { $0.at > $1.at } }
        waiting = newest(summaries.flatMap { agent, summary in
            summary.waiting.map { Item(agent: agent, id: $0.id, title: $0.question, detail: agent.name, at: $0.at) }
        })
        decided = newest(summaries.flatMap { agent, summary in
            summary.decided.filter { $0.at <= feed.awayEnded }.map { Item(agent: agent, id: $0.id, title: $0.question.hasSuffix("?") ? "\($0.question) \($0.answer)" : "\($0.question): \($0.answer)", detail: named(agent, $0.why), at: $0.at) }
        })
        done = newest(summaries.flatMap { agent, summary in
            summary.done.filter { $0.at <= feed.awayEnded }.map { Item(agent: agent, id: $0.id, title: $0.did, detail: named(agent, $0.why), at: $0.at) }
        })
        let entries = agents.flatMap { agent in (feed.journal[agent.id] ?? []).filter { $0.at >= feed.awaySince && $0.at <= feed.awayEnded }.map { (agent, $0) } }
        passed = newest(entries.compactMap { agent, entry in
            guard entry.kind == .handoff, let to = entry.to, let target = agents.first(where: { $0.id == to }) else { return nil }
            return Item(agent: agent, id: entry.id, title: entry.headline, detail: entry.why.isEmpty ? String(format: "To %@", target.name) : String(format: "To %@ · %@", target.name, entry.why), at: entry.at, opens: to)
        })
        func worked(after entry: JournalEntry, of agent: Agent) -> Bool {
            entry.kind == .failed && entries.contains { $0.0.id == agent.id && $0.1.kind == .action && $0.1.at > entry.at }
        }
        func item(_ agent: Agent, _ entry: JournalEntry) -> Item {
            Item(agent: agent, id: entry.id, title: entry.did, detail: entry.forPerson?.isEmpty == false ? "\(named(agent, entry.why)) · \(entry.forPerson!.prefix(160))" : named(agent, entry.why), at: entry.at)
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
        if !decided.isEmpty { parts.append(decided.count == 1 ? "1 decision made for you" : String(format: "%d decisions made for you", decided.count)) }
        if !done.isEmpty { parts.append(done.count == 1 ? "1 action done" : String(format: "%d actions done", done.count)) }
        if !waiting.isEmpty { parts.append(String(format: "%d waiting for you", waiting.count)) }
        if !parts.isEmpty { return parts.joined(separator: ", ") + "." }
        if !stopped.isEmpty { return String(format: "Your agents stopped on %d actions.", stopped.count) }
        return (passed.isEmpty ? "Only small permissions were answered." : "Bean handed out work.")
    }
}

struct AwayCard: View {
    let report: AwayReport
    let actions: PageActions

    private var since: String {
        Calendar.current.isDateInToday(report.since) ? report.since.formatted(date: .omitted, time: .shortened) : report.since.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(AgentStrings.locale))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("While you were away").font(.caption).foregroundStyle(.secondary)
            Text(report.summary).font(.title3)
            Text(String(format: "Since %@", since)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            ForEach(report.waiting) { item in
                AwayRow(look: item.agent.look, title: item.title, detail: item.detail, date: nil) { actions.select(item.agent.id) }
            }
            AwaySection(title: "Decided for you", items: report.decided, open: false, actions: actions)
            if report.permissions > 0 {
                Text(report.permissions == 1 ? "1 small permission answered" : String(format: "%d small permissions answered", report.permissions)).font(.callout).foregroundStyle(.secondary)
            }
            AwaySection(title: "Passed between agents", items: report.passed, open: false, actions: actions)
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
            PageDisclosure(isExpanded: $open) {
                Text(String(format: "%@ (%d)", title, items.count))
            } content: {
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

