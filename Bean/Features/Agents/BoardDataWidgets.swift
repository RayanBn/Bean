import AppKit
import ScreenCaptureKit
import SwiftUI

struct ChangesWidget: View {
    let context: WidgetContext
    let session: AgentWorker.DrivenSession
    @State private var changes: SessionChanges?
    @State private var chosen: String?

    private var sections: [(path: String, lines: [Substring])] {
        guard let changes else { return [] }
        return changes.diff.components(separatedBy: "\ndiff --git ").map { part in
            let lines = part.split(separator: "\n", omittingEmptySubsequences: false)
            let path = lines.first?.split(separator: " ").last.map { $0.hasPrefix("b/") ? String($0.dropFirst(2)) : String($0) } ?? ""
            return (path, lines)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let changes, !changes.files.isEmpty {
                VStack(spacing: 0) {
                    ForEach(changes.files) { file in
                        Button { chosen = file.path } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc").font(.widgetSmall).foregroundStyle(.tertiary)
                                Text((file.path as NSString).lastPathComponent).font(.widgetSmall).lineLimit(1).help(file.path)
                                Spacer(minLength: 4)
                                Text("+\(file.added)").font(.widgetSmall).foregroundStyle(.green)
                                if file.removed > 0 { Text("−\(file.removed)").font(.widgetSmall).foregroundStyle(.red) }
                            }
                            .padding(.horizontal, 10).frame(height: 22)
                            .background(selected == file.path ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("page-changes-file")
                    }
                }
                Divider()
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(shownLines.enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : String(line))
                                .font(.widgetMono)
                                .foregroundStyle(line.hasPrefix("@@") ? Color.secondary : Color.primary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(minWidth: 1200, minHeight: 17, alignment: .leading)
                                .padding(.horizontal, 8)
                                .background(line.hasPrefix("+") ? Color.green.opacity(0.16) : line.hasPrefix("-") ? Color.red.opacity(0.17) : .clear)
                        }
                    }
                }
            } else {
                Text(changes == nil ? "Reading the changes…" : "Nothing changed yet.").font(.widgetBody).foregroundStyle(.secondary).padding(10)
            }
        }
        .task(id: session.id) {
            while !Task.isCancelled {
                if let fresh = await context.actions.sessionChanges?(context.agent.id, session.id) { changes = fresh }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var selected: String? { chosen ?? changes?.files.first?.path }

    private var shownLines: [Substring] {
        guard let selected, let section = sections.first(where: { $0.path == selected }) else { return [] }
        return Array(section.lines.drop { !$0.hasPrefix("@@") }.prefix(3000))
    }
}

// Each step's state comes from what really happened to its hand-off and session, as a GitHub Actions job's does.
struct PlanWidget: View {
    let context: WidgetContext

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(context.feed.plan) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        mark(step.state)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.what).font(.widgetBody).fixedSize(horizontal: false, vertical: true)
                            Text([step.owner, step.waitingFor, step.missing].compactMap { $0 }.joined(separator: " · ")).font(.widgetSmall).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func mark(_ state: PlanStep.State) -> some View {
        switch state {
        case .toDo, .unknown: Image(systemName: "circle").font(.widgetSmall).foregroundStyle(.tertiary)
        case .doing: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").font(.widgetSmall).foregroundStyle(.green)
        case .blocked: Image(systemName: "exclamationmark.circle.fill").font(.widgetSmall).foregroundStyle(.orange)
        case .stopped: Image(systemName: "stop.circle").font(.widgetSmall).foregroundStyle(.secondary)
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

enum WorkService: String, CaseIterable, Identifiable {
    case pullRequest = "pull-request", ticket

    var id: String { rawValue }

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
            guard let link = context.session?.pullRequest else { return nil }
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

struct WindowWidget: View {
    let attachment: Attachment
    @State private var text: String?
    @State private var image: NSImage?
    @State private var gone = false

    var body: some View {
        Group {
            if let image {
                ScrollView {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            } else if let text {
                ScrollView { Text(text).font(.widgetBody).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                Text(gone ? "This window cannot be read, or it closed." : "Reading the window…").font(.widgetBody).foregroundStyle(.secondary).padding(10)
            }
        }
        .task(id: attachment.windowNumber) {
            while !Task.isCancelled {
                if OffLimits.match("\(attachment.appName) \(attachment.bundleId) \(attachment.windowTitle ?? "")") != nil {
                    text = nil
                    image = nil
                    gone = true
                    return
                }
                if CGPreflightScreenCaptureAccess(), let shot = await Self.capture(attachment.windowNumber) {
                    image = shot
                    try? await Task.sleep(for: .seconds(1))
                } else {
                    let attachment = attachment
                    let snapshot = await Task.detached { WindowSnapshot.read(attachment) }.value
                    text = snapshot?.text
                    gone = snapshot == nil
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    private static func capture(_ number: Int) async -> NSImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false), let window = content.windows.first(where: { Int($0.windowID) == number }) else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * 2)
        configuration.height = Int(window.frame.height * 2)
        guard let shot = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration) else { return nil }
        return NSImage(cgImage: shot, size: window.frame.size)
    }

    static func attachment(for number: Int, windows: [OpenWindow]) -> Attachment? {
        guard let window = windows.first(where: { $0.number == number }), isOpenToBoard(window) else { return nil }
        return Attachment(bundleId: window.bundleId, appName: window.app, pid: window.pid, windowNumber: window.number, windowTitle: window.title)
    }

    static func isOpenToBoard(_ window: OpenWindow) -> Bool {
        Skills.forApp(window.bundleId)?.sealed != true && OffLimits.match("\(window.app) \(window.bundleId) \(window.title ?? "")") == nil
    }
}
