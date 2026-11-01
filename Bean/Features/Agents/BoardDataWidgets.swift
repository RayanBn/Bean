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

struct PullRequestFacts: Equatable {
    struct Check: Equatable, Identifiable {
        var id: String { name }
        let name: String
        let state: String
    }
    var title = ""
    var state = ""
    var isDraft = false
    var review = ""
    var from = ""
    var into = ""
    var checks: [Check] = []

    static func read(_ link: String) -> PullRequestFacts? {
        let quoted = "'" + link.replacingOccurrences(of: "'", with: "") + "'"
        let result = HiddenShell.run("gh pr view \(quoted) --json title,state,isDraft,reviewDecision,headRefName,baseRefName,statusCheckRollup", timeout: 20)
        guard result.exit == 0, let json = (try? JSONSerialization.jsonObject(with: Data(result.output.utf8))) as? [String: Any] else { return nil }
        let checks = (json["statusCheckRollup"] as? [[String: Any]] ?? []).map { check in
            Check(name: check["name"] as? String ?? check["context"] as? String ?? "Check", state: (check["conclusion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? check["state"] as? String ?? check["status"] as? String ?? "")
        }
        return PullRequestFacts(title: json["title"] as? String ?? "", state: json["state"] as? String ?? "", isDraft: json["isDraft"] as? Bool ?? false, review: json["reviewDecision"] as? String ?? "", from: json["headRefName"] as? String ?? "", into: json["baseRefName"] as? String ?? "", checks: checks)
    }
}

struct GitHubWidget: View {
    let link: String
    @State private var facts: PullRequestFacts?
    @State private var failed = false

    private var number: String { URL(string: link)?.lastPathComponent ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let facts {
                HStack(spacing: 6) {
                    Text("#\(number)").font(.widgetMono).foregroundStyle(.secondary)
                    Text(facts.isDraft ? "Draft" : facts.state.capitalized).font(Font.widgetSmall.weight(.medium)).padding(.horizontal, 5).padding(.vertical, 1).background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    Spacer(minLength: 0)
                }
                Text(facts.title).font(Font.widgetBody.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text("\(facts.from) → \(facts.into)").font(.widgetMono).foregroundStyle(.secondary).lineLimit(1)
                Divider()
                if facts.checks.isEmpty {
                    Text("No checks on this pull request.").font(.widgetSmall).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(facts.checks) { check in
                            HStack(spacing: 6) {
                                mark(check.state)
                                Text(check.name).font(.widgetSmall).lineLimit(1)
                                Spacer(minLength: 4)
                            }
                        }
                    }
                }
                if !facts.review.isEmpty {
                    Text(facts.review.replacingOccurrences(of: "_", with: " ").capitalized).font(.widgetSmall).foregroundStyle(.secondary)
                }
            } else {
                Text(failed ? "GitHub did not answer." : "Reading the pull request…").font(.widgetBody).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            LinkButton(link: link).accessibilityIdentifier("page-github-open")
        }
        .padding(10)
        .task(id: link) {
            while !Task.isCancelled {
                let link = link
                let fresh = await Task.detached { PullRequestFacts.read(link) }.value
                facts = fresh ?? facts
                failed = fresh == nil
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    @ViewBuilder private func mark(_ state: String) -> some View {
        switch state.uppercased() {
        case "SUCCESS", "NEUTRAL", "SKIPPED": Image(systemName: "checkmark.circle.fill").font(.widgetSmall).foregroundStyle(.green)
        case "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED": Image(systemName: "xmark.circle.fill").font(.widgetSmall).foregroundStyle(.red)
        default: ProgressView().controlSize(.mini)
        }
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

enum ConnectorRows {
    struct Row: Identifiable {
        let id: Int
        let title: String
        let detail: String
    }

    private static let titleKeys = ["title", "name", "subject", "summary", "identifier", "id"]
    private static let detailKeys = ["identifier", "status", "state", "stateName", "assignee", "priority", "updatedAt", "url"]

    static func rows(_ text: String) -> [Row]? {
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
}

struct ConnectorWidget: View {
    let server: String
    let tool: String
    var arguments: JSONArgs = [:]
    let actions: PageActions
    var every: Duration = .seconds(60)
    @State private var text: String?
    @State private var failed = false

    var body: some View {
        Group {
            if let text {
                if let rows = ConnectorRows.rows(text) {
                    List(rows) { row in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title).font(.widgetBody).lineLimit(2)
                            if !row.detail.isEmpty { Text(row.detail).font(.widgetSmall).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                    .listStyle(.plain)
                } else {
                    ScrollView { Text(text).font(.widgetSmall).foregroundStyle(failed ? Color.orange : .primary).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading) }
                }
            } else {
                Text(String(format: "Reading %@…", server)).font(.widgetBody).foregroundStyle(.secondary).padding(10)
            }
        }
        .task(id: server + tool) {
            while !Task.isCancelled {
                if let output = await actions.readConnector?(server, tool, arguments) {
                    text = OffLimits.redact(output.text).text
                    failed = !output.ok
                }
                try? await Task.sleep(for: every)
            }
        }
    }
}

struct LinearWidget: View {
    let context: WidgetContext
    let ticket: String
    @State private var server: String?

    var body: some View {
        Group {
            if let server {
                ConnectorWidget(server: server, tool: "get_issue", arguments: ["id": ticket], actions: context.actions, every: .seconds(30))
            } else {
                Text("Linear is not connected.").font(.widgetBody).foregroundStyle(.secondary).padding(10)
            }
        }
        .task {
            let connected = await context.actions.connectedServices?() ?? []
            server = connected.first { $0.lowercased().contains("linear") }
        }
    }

    static func ticket(in context: WidgetContext) -> String? {
        let text = ([context.session?.task, context.item?.title] + (context.feed.journal[context.agent.id] ?? []).suffix(40).map(\.did)).compactMap { $0 }.joined(separator: " ")
        return text.firstMatch(of: /\b[A-Z]{2,6}-\d{1,5}\b/).map { String($0.0) }
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
        window.bundleId != "com.anthropic.claudefordesktop" && OffLimits.match("\(window.app) \(window.bundleId) \(window.title ?? "")") == nil
    }
}
