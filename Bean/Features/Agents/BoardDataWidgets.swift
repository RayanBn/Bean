import AppKit
import SwiftUI

// What an agent changed, as sentences, with Undo where it can be undone.
struct ChangesWidget: View {
    let context: WidgetContext

    private var journal: [JournalEntry] { context.feed.journal[context.agent.id] ?? [] }
    private var undone: Set<UUID> { context.feed.undone[context.agent.id] ?? [] }
    private var changes: [JournalEntry] { journal.filter { $0.kind == .action || $0.kind == .undo || $0.kind == .refused }.sorted { $0.at > $1.at } }

    var body: some View {
        if changes.isEmpty {
            WidgetEmpty(icon: "plusminus", title: "Nothing changed yet", text: "Everything \(context.name) changes shows here, with Undo where it can be undone.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(changes) { entry in
                        ActionRow(entry: entry, undone: undone.contains(entry.id), undo: { context.actions.undo(context.agent.id, entry.id) })
                    }
                }
                .font(.widgetBody)
                .padding(10)
            }
        }
    }
}

// An agent's todo list: the steps it wrote for itself, under what Bean handed it. Bean's page shows Bean's own plan.
struct PlanWidget: View {
    private struct Row {
        let what: String
        let state: PlanStep.State
        var detail = ""
    }

    let context: WidgetContext

    private var agent: Agent { context.agent }
    private var fromBean: [Row] {
        context.feed.plan.filter { agent.isBean || $0.agent == agent.id }.map { step in
            Row(what: step.what, state: step.state, detail: [agent.isBean ? step.owner : nil, step.waitingFor, step.missing].compactMap { $0 }.joined(separator: " · "))
        }
    }
    private var own: [Row] {
        (context.feed.todos[agent.id] ?? []).map { Row(what: $0.step, state: Self.state($0.status.rawValue)) }
    }
    private var working: Bool { context.feed.doing[agent.id] != nil || context.feed.live[agent.id] != nil || context.feed.replying.contains(agent.id) }

    private static func state(_ status: String) -> PlanStep.State {
        switch status {
        case "completed", "done": .done
        case "in_progress": .doing
        default: .toDo
        }
    }

    var body: some View {
        let fromBean = fromBean, own = own, all = fromBean + own
        if all.isEmpty {
            Text("\(context.name) has no plan yet.").font(.widgetBody).foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            let current = own.contains { $0.state == .doing } ? fromBean.count + own.firstIndex { $0.state == .doing }! : all.firstIndex { $0.state == .doing }
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(all.filter { $0.state == .done }.count) of \(all.count) done").font(Font.widgetSmall.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 2)
                        ForEach(Array(all.enumerated()), id: \.offset) { index, row in
                            if !agent.isBean, !fromBean.isEmpty, index == 0 || index == fromBean.count {
                                Text(index == 0 ? "From Bean" : "Its steps").font(.widgetSmall).foregroundStyle(.secondary).padding(.top, index == 0 ? 0 : 6)
                            }
                            rowView(row, current: index == current).id(index)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: current) { _, index in
                    if let index { withAnimation { reader.scrollTo(index, anchor: .center) } }
                }
            }
        }
    }

    private func rowView(_ row: Row, current: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            mark(row.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.what)
                    .font(current ? Font.widgetBody.weight(.semibold) : .widgetBody)
                    .foregroundStyle(row.state == .done ? .secondary : .primary)
                    .strikethrough(row.state == .done, color: .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !row.detail.isEmpty { Text(row.detail).font(.widgetSmall).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(current ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 5))
    }

    // A step left in progress by a run that ended must not look like it is still moving.
    @ViewBuilder private func mark(_ state: PlanStep.State) -> some View {
        switch state {
        case .toDo, .unknown: Image(systemName: "circle").font(.widgetSmall).foregroundStyle(.tertiary)
        case .doing:
            if working { ProgressView().controlSize(.mini) } else { Image(systemName: "circle.dashed").font(.widgetSmall).foregroundStyle(.secondary) }
        case .done: Image(systemName: "checkmark.circle.fill").font(.widgetSmall).foregroundStyle(.green)
        case .blocked: Image(systemName: "exclamationmark.circle.fill").font(.widgetSmall).foregroundStyle(.orange)
        case .stopped: Image(systemName: "stop.circle").font(.widgetSmall).foregroundStyle(.secondary)
        }
    }
}

// Everything the agent did, newest first, with its finished runs folded.
struct HistoryWidget: View {
    private enum Line: Identifiable {
        case run(StepRun)
        case entry(JournalEntry)

        var id: String {
            switch self {
            case .run(let run): "run \(run.id)"
            case .entry(let entry): "entry \(entry.id)"
            }
        }

        var at: Date {
            switch self {
            case .run(let run): run.began
            case .entry(let entry): entry.at
            }
        }
    }

    let context: WidgetContext

    private var journal: [JournalEntry] { context.feed.journal[context.agent.id] ?? [] }
    private var undone: Set<UUID> { context.feed.undone[context.agent.id] ?? [] }

    private var lines: [Line] {
        let runs = StepRun.all(steps: context.feed.steps[context.agent.id] ?? [], journal: journal, live: context.feed.live[context.agent.id]).filter { !$0.isEmpty }
        let inRuns = Set(runs.flatMap(\.changes).map(\.id))
        let told: [JournalEntry.Kind] = [.action, .refused, .failed, .undo, .said, .replied, .handoff, .notice, .stuck, .session]
        let entries = journal.filter { told.contains($0.kind) && !inRuns.contains($0.id) && !($0.kind == .session && $0.did.hasPrefix("Decided")) }
        return (runs.map(Line.run) + entries.map(Line.entry)).sorted { $0.at > $1.at }
    }

    var body: some View {
        let lines = lines
        if lines.isEmpty {
            WidgetEmpty(icon: "clock", title: "Nothing yet", text: "Each time \(context.name) works, the run shows here: what it looked at, what it said, what it changed.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        if index == 0 || !Calendar.current.isDate(line.at, inSameDayAs: lines[index - 1].at) {
                            Text(line.at.formatted(date: .abbreviated, time: .omitted)).font(Font.widgetSmall.weight(.semibold)).foregroundStyle(.secondary).padding(.top, index == 0 ? 0 : 6)
                        }
                        view(line)
                    }
                }
                .font(.widgetBody)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func view(_ line: Line) -> some View {
        switch line {
        case .run(let run):
            RunView(run: run, isUndone: { undone.contains($0.id) }, undo: { context.actions.undo(context.agent.id, $0) })
        case .entry(let entry):
            ActionRow(entry: entry, undone: undone.contains(entry.id), undo: { context.actions.undo(context.agent.id, entry.id) })
        }
    }
}

struct ServicePage {
    enum Mark { case passed, failed, waiting }
    struct Row: Identifiable {
        let id: Int
        let title: String
        var detail = ""
        var mark: Mark? = nil
    }
    struct Head {
        let tag: String
        let badge: String
        let title: String
        let line: String
        let noRows: String
        let note: String
    }
    var head: Head? = nil
    var rows: [Row]? = nil
    var text = ""
    var failed = false
}

extension ServicePage {
    private static let titleKeys = ["title", "name", "subject", "summary", "identifier", "id"]
    private static let detailKeys = ["identifier", "status", "state", "stateName", "assignee", "priority", "updatedAt", "url"]

    init(_ output: ToolOutput) {
        let text = OffLimits.redact(output.text).text
        self.init(rows: Self.rows(text), text: text, failed: !output.ok)
    }

    private static func rows(_ text: String) -> [Row]? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return nil }
        var list = json as? [[String: Any]]
        if list == nil, let object = json as? [String: Any] {
            list = object.values.compactMap { $0 as? [[String: Any]] }.first ?? [object]
        }
        return list?.prefix(200).enumerated().map { index, item in
            let title = titleKeys.compactMap { item[$0] as? String }.first ?? "\(index + 1)"
            let detail = detailKeys.compactMap { key -> String? in
                let value = item[key].flatMap { ($0 as? String) ?? (($0 as? [String: Any])?["name"] as? String) }
                return value == title ? nil : value
            }.prefix(3).joined(separator: " · ")
            return Row(id: index, title: title, detail: detail)
        }
    }

    static func pullRequest(_ link: String) -> ServicePage {
        guard let pull = PullRequestLink(link), CodeHost.answers(pull.host) else { return ServicePage(text: "This pull request cannot be read from here.", failed: true) }
        let result = HiddenShell.run("gh pr view \(CodeHost.quoted(link)) --json title,state,isDraft,reviewDecision,headRefName,baseRefName,statusCheckRollup", timeout: 20)
        guard result.exit == 0, let json = (try? JSONSerialization.jsonObject(with: Data(result.output.utf8))) as? [String: Any] else { return ServicePage(text: "\(pull.host) did not answer.", failed: true) }
        let string = { (key: String) in json[key] as? String ?? "" }
        let checks = (json["statusCheckRollup"] as? [[String: Any]] ?? []).enumerated().map { index, check in
            let state = (check["conclusion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? check["state"] as? String ?? check["status"] as? String ?? ""
            return Row(id: index, title: check["name"] as? String ?? check["context"] as? String ?? "Check", mark: mark(state))
        }
        let head = Head(tag: "#\(pull.number)", badge: json["isDraft"] as? Bool == true ? "Draft" : string("state").capitalized, title: string("title"), line: "\(string("headRefName")) → \(string("baseRefName"))", noRows: "No checks on this pull request.", note: string("reviewDecision").replacingOccurrences(of: "_", with: " ").capitalized)
        return ServicePage(head: head, rows: checks)
    }

    private static func mark(_ state: String) -> Mark {
        switch state.uppercased() {
        case "SUCCESS", "NEUTRAL", "SKIPPED": .passed
        case "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED": .failed
        default: .waiting
        }
    }
}

enum WorkService: String {
    case pullRequest = "pull-request", ticket

    var title: String {
        switch self {
        case .pullRequest: "Pull Request"
        case .ticket: "Ticket"
        }
    }

    var icon: String {
        switch self {
        case .pullRequest: "arrow.triangle.pull"
        case .ticket: "checklist"
        }
    }
}

struct ServiceSource {
    let id: String
    let name: String
    var every: Duration = .seconds(60)
    var link: String? = nil
    let read: () async -> ServicePage?

    private static let ticketTool = "get_issue"

    static func of(_ context: WidgetContext) -> ServiceSource? {
        guard let param = context.spec.param else { return nil }
        if let service = WorkService(rawValue: param) { return work(service, context) }
        let parts = param.split(separator: "|").map(String.init)
        guard parts.count == 2 else { return nil }
        let actions = context.actions
        return ServiceSource(id: param, name: parts[0]) {
            guard let output = await actions.readConnector?(parts[0], parts[1], [:]) else { return nil }
            return ServicePage(output)
        }
    }

    static func work(_ service: WorkService, _ context: WidgetContext) -> ServiceSource? {
        switch service {
        case .pullRequest:
            guard let link = (context.feed.journal[context.agent.id] ?? []).compactMap(\.link).last(where: { $0.contains("/pull/") }) else { return nil }
            return ServiceSource(id: link, name: "the pull request", every: .seconds(30), link: link) {
                await Task.detached { ServicePage.pullRequest(link) }.value
            }
        case .ticket:
            guard let ticket = context.ticket else { return nil }
            let actions = context.actions
            return ServiceSource(id: ticket, name: ticket, every: .seconds(30)) {
                var last: ServicePage?
                for server in await actions.connectedServices?() ?? [] {
                    guard await actions.connectorReads?(server).contains(ticketTool) == true, let output = await actions.readConnector?(server, ticketTool, ["id": ticket]) else { continue }
                    if output.ok { return ServicePage(output) }
                    last = ServicePage(output)
                }
                return last ?? ServicePage(text: "No connected service can read tickets.")
            }
        }
    }
}

struct ConnectorWidget: View {
    let source: ServiceSource
    @State private var page: ServicePage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if let page {
                    if let head = page.head {
                        headed(head, rows: page.rows ?? [])
                    } else if let rows = page.rows {
                        List(rows) { row in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.title).font(.widgetBody).lineLimit(2)
                                if !row.detail.isEmpty { Text(row.detail).font(.widgetSmall).foregroundStyle(.secondary).lineLimit(1) }
                            }
                        }
                        .listStyle(.plain)
                    } else {
                        ScrollView { Text(page.text).font(.widgetSmall).foregroundStyle(page.failed ? Color.orange : .primary).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                } else {
                    Text(String(format: "Reading %@…", source.name)).font(.widgetBody).foregroundStyle(.secondary).padding(10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let link = source.link {
                LinkButton(link: link).padding([.horizontal, .bottom], 10).accessibilityIdentifier("page-service-open")
            }
        }
        .task(id: source.id) {
            while !Task.isCancelled {
                await PageVisibility.wait()
                if let fresh = await source.read(), !fresh.failed || page?.head == nil { page = fresh }
                try? await Task.sleep(for: source.every)
            }
        }
    }

    private func headed(_ head: ServicePage.Head, rows: [ServicePage.Row]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(head.tag).font(.widgetMono).foregroundStyle(.secondary)
                Text(head.badge).font(Font.widgetSmall.weight(.medium)).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                Spacer(minLength: 0)
            }
            Text(head.title).font(Font.widgetBody.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Text(head.line).font(.widgetMono).foregroundStyle(.secondary).lineLimit(1)
            Divider()
            if rows.isEmpty {
                Text(head.noRows).font(.widgetSmall).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(rows) { row in
                        HStack(spacing: 6) {
                            mark(row.mark)
                            Text(row.title).font(.widgetSmall).lineLimit(1)
                            Spacer(minLength: 4)
                        }
                    }
                }
            }
            if !head.note.isEmpty {
                Text(head.note).font(.widgetSmall).foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    @ViewBuilder private func mark(_ mark: ServicePage.Mark?) -> some View {
        switch mark {
        case .passed: Image(systemName: "checkmark.circle.fill").font(.widgetSmall).foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").font(.widgetSmall).foregroundStyle(.red)
        case .waiting, nil: ProgressView().controlSize(.mini)
        }
    }
}

// A service widget that has nothing to read says what fills it.
struct ConnectorPane: View {
    let context: WidgetContext

    var body: some View {
        if let source = ServiceSource.of(context) {
            ConnectorWidget(source: source)
        } else {
            switch context.spec.param.flatMap(WorkService.init) {
            case .pullRequest:
                WidgetEmpty(icon: WorkService.pullRequest.icon, title: "No pull request yet", text: "When \(context.name) opens one, its checks and state show here.")
            case .ticket:
                WidgetEmpty(icon: WorkService.ticket.icon, title: "No ticket yet", text: "When \(context.name) works on a ticket, it shows here.")
            case nil:
                WidgetEmpty(icon: "link", title: "This service is not available", text: "Connect it in Settings, then add it again.") {
                    Button("Open Settings", action: context.actions.openSettings).controlSize(.small)
                }
            }
        }
    }
}
