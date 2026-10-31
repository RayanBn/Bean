import AppKit
import SwiftUI

struct WorkStep: Identifiable, Equatable {
    enum Kind { case said, you, read, edit, command, note }
    let id: String
    let kind: Kind
    let text: String
    var detail: String?
    var failed = false
    var running = false
}

struct WorkItem: Identifiable {
    enum State: CaseIterable {
        case waiting, running, finished, stopped

        var title: String {
            switch self {
            case .waiting: "Needs you"
            case .running: "Working"
            case .finished: "Done"
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
    var events: [SessionEvent] = []
    var plainSteps: [WorkStep] = []
    var at: Date?

    var steps: [WorkStep] {
        events.isEmpty ? plainSteps : events.suffix(400).compactMap(Self.step)
    }

    var isEnded: Bool { state == .finished || state == .stopped }

    static func all(agents: [Agent], feed: PageFeed) -> [WorkItem] {
        let found = agents.flatMap { items(of: $0, feed: feed) }
        let waiting = found.filter { $0.state == .waiting }.sorted { ($0.need?.at ?? .distantPast) < ($1.need?.at ?? .distantPast) }
        let running = found.filter { $0.state == .running }
        let ended = found.filter(\.isEnded).sorted { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }
        return waiting + running + ended.prefix(8)
    }

    static func items(of agent: Agent, feed: PageFeed) -> [WorkItem] {
        let asking = (feed.needs[agent.id] ?? []).filter(\.asksTheUser)
        let sessions = (feed.sessions[agent.id] ?? []).map { session in
            let need = asking.first { $0.session == session.id }
            let decided = (feed.decisions[agent.id] ?? []).filter { $0.session == session.id }
            let state: State = switch session.status {
            case .waiting, .running, .takenOver: need == nil ? .running : .waiting
            case .finished, .handedBack: .finished
            case .stopped: .stopped
            }
            return WorkItem(id: "session \(session.id)", agent: agent, title: session.task.map(firstLine) ?? session.repo, state: state,
                            step: need?.question ?? (session.status == .waiting ? nil : session.status == .stopped ? stopReason(session.step) : plainStep(session.step)), need: need, session: session,
                            events: feed.sessionEvents[session.id] ?? [], plainSteps: decided.map(step), at: feed.sessionEvents[session.id]?.last?.at ?? decided.last?.at ?? session.startedAt)
        }
        let held = Set(sessions.compactMap(\.need?.id))
        let questions = asking.filter { !held.contains($0.id) }.map { need in
            WorkItem(id: "need \(need.id)", agent: agent, title: need.task.map(firstLine) ?? AgentStrings.shown(need.question), state: .waiting, step: need.task == nil ? nil : AgentStrings.shown(need.question), need: need, at: need.at)
        }
        let journal = feed.journal[agent.id] ?? []
        var work: [WorkItem] = []
        if let doing = feed.doing[agent.id], !sessions.contains(where: { $0.state == .running }), asking.isEmpty {
            let since = feed.doingSince[agent.id] ?? .distantPast
            let steps = journal.filter { $0.at >= since && isStep($0) }
            work.append(WorkItem(id: "doing \(agent.id)", agent: agent, title: firstLine(doing), state: .running, step: steps.last?.did, plainSteps: steps.map(step), at: since))
        }
        for ended in feed.endedWork where ended.agent == agent.id {
            guard !sessions.contains(where: { ($0.session?.startedAt).map { $0 >= ended.began && $0 <= ended.ended } == true }) else { continue }
            let steps = journal.filter { $0.at >= ended.began && $0.at <= ended.ended && isStep($0) }
            work.append(WorkItem(id: "ended \(ended.id)", agent: agent, title: firstLine(ended.what), state: ended.stopped ? .stopped : .finished, step: steps.last?.did, plainSteps: steps.map(step), at: ended.ended))
        }
        return questions + sessions + work
    }

    private static func step(_ event: SessionEvent) -> WorkStep? {
        let id = "e\(event.id)"
        switch event.kind {
        case .text: return WorkStep(id: id, kind: .said, text: event.text)
        case .user: return WorkStep(id: id, kind: .you, text: event.text)
        case .standIn, .question: return WorkStep(id: id, kind: .note, text: event.text)
        case .task, .ended: return nil
        case .tool:
            let failed = event.toolState == .failed || event.toolState == .refused
            switch event.tool {
            case "Read": return WorkStep(id: id, kind: .read, text: (event.text as NSString).lastPathComponent, detail: event.output, failed: failed)
            case "Edit", "Write": return WorkStep(id: id, kind: .edit, text: (event.text as NSString).lastPathComponent, detail: event.output, failed: failed)
            case "Bash": return WorkStep(id: id, kind: .command, text: event.text, detail: event.output, failed: failed, running: event.toolState == .running)
            default: return WorkStep(id: id, kind: .note, text: [event.tool, event.text].compactMap { $0 }.joined(separator: ": "), detail: event.output, failed: failed)
            }
        }
    }

    private static func step(_ decision: AgentDecision) -> WorkStep {
        let refused = decision.answer == "refused"
        guard decision.kind == .permission else { return WorkStep(id: decision.id.uuidString, kind: .said, text: decision.question, detail: decision.why.isEmpty ? nil : decision.why) }
        let words = decision.question.split(separator: " ", maxSplits: 1).map(String.init)
        let kind: WorkStep.Kind = words.first == "edit" ? .edit : words.first == "read" ? .read : .command
        return WorkStep(id: decision.id.uuidString, kind: kind, text: kind == .command || words.count < 2 ? decision.question : words[1], detail: refused ? AgentStrings.shown("Refused: %@", decision.why) : nil, failed: refused)
    }

    private static func step(_ entry: JournalEntry) -> WorkStep {
        let detail = [entry.why, entry.result ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
        return WorkStep(id: entry.id.uuidString, kind: entry.kind == .session ? .said : .note, text: entry.did, detail: detail.isEmpty ? nil : detail, failed: entry.kind == .failed || entry.kind == .refused)
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

extension AgentNeed {
    var asksTheUser: Bool { kind == .stuck || kind == .decision || kind == .setup }
}

struct WorkMark: View {
    let state: WorkItem.State

    var body: some View {
        switch state {
        case .waiting: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .running: ProgressView().controlSize(.small)
        case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .stopped: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }
}

struct StepRow: View {
    let step: WorkStep
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if step.detail != nil { withAnimation(.easeOut(duration: 0.12)) { open.toggle() } }
            } label: {
                switch step.kind {
                case .said, .note:
                    Text(step.text).font(.callout).foregroundStyle(step.failed ? Color.orange : .primary).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                case .you:
                    HStack {
                        Spacer(minLength: 30)
                        Text(step.text).font(.callout).foregroundStyle(.white).padding(.horizontal, 9).padding(.vertical, 5).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                case .read: file("doc.text", "Read")
                case .edit: file("pencil", "Edited")
                case .command:
                    Text(step.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(step.failed ? Color.orange : .primary)
                        .lineLimit(open ? nil : 2)
                        .multilineTextAlignment(.leading)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
            .buttonStyle(.plain)
            if open, let detail = step.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func file(_ icon: String, _ verb: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.tertiary).frame(width: 15)
            Text(AgentStrings.shown(verb)).foregroundStyle(.secondary)
            Text(step.text).font(.system(.caption, design: .monospaced)).foregroundStyle(step.failed ? Color.orange : .primary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

struct LiveSteps: View {
    let item: WorkItem

    private var current: String? {
        guard item.state == .running, let step = item.step, step != item.steps.last?.text else { return nil }
        return step
    }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    ForEach(item.steps) { StepRow(step: $0) }
                    if let current {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text(current).font(.callout.weight(.medium)).lineLimit(2)
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { reader.scrollTo("end", anchor: .bottom) }
            .onChange(of: item.steps.count) { _, _ in withAnimation(.easeOut(duration: 0.15)) { reader.scrollTo("end", anchor: .bottom) } }
        }
    }
}

struct WorkingWindow: View {
    let agent: Agent
    let window: AgentTarget
    let text: String?
    let abilities: [AgentAbility]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    TargetIcon(target: window, size: 14)
                    Text(window.title ?? window.app ?? window.name).font(.caption.weight(.medium)).lineLimit(1)
                }
                if let text {
                    Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            if !abilities.contains(where: { $0.risk == .irreversible && $0.allowed }) {
                Text(AgentStrings.shown("It will not send anything without you.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct TalkField: View {
    let hint: String
    let send: (String) -> Void
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 6) {
            TextField(hint, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .onSubmit(submit)
                .accessibilityIdentifier("page-talk")
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill").font(.title3).foregroundStyle(draft.isEmpty ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(draft.isEmpty)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        send(text)
    }
}

