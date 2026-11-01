import SwiftUI

// A light passing over the words says this is happening now. With reduced motion the words stay still.
struct LiveText: View {
    let text: String
    var base: Color = .secondary
    var light: Color = .primary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Text(text).foregroundStyle(light)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 20)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                let center = phase * 1.8 - 0.4
                Text(text).foregroundStyle(LinearGradient(colors: [base, light, base], startPoint: UnitPoint(x: center - 0.3, y: 0.5), endPoint: UnitPoint(x: center + 0.3, y: 0.5)))
            }
        }
    }
}

// A live clock shows that a slow step is still running and not stuck. Short steps show none.
struct StepClock: View {
    let since: Date
    var from: TimeInterval = 3

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = context.date.timeIntervalSince(since)
            Text(seconds >= from ? StepRun.clock(seconds) : " ").monospacedDigit()
        }
    }
}

struct RunView: View {
    let run: StepRun
    var showsTask = true
    let isUndone: (JournalEntry) -> Bool
    let undo: (UUID) -> Void
    @State private var opened: Bool?

    private var open: Bool { opened ?? run.isLive }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showsTask, !run.task.isEmpty {
                Text(run.task).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(run.task)
            }
            if !run.isLive {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { opened = !open }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).frame(width: 16)
                            .rotationEffect(.degrees(open ? 90 : 0))
                        Text(open ? run.seconds.map { "Worked for \(StepRun.clock($0))" } ?? "Worked" : run.summary).foregroundStyle(.secondary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if !open, let seconds = run.seconds { Text(StepRun.clock(seconds)).font(.caption2).foregroundStyle(.tertiary).fixedSize() }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("page-run-summary")
            }
            if open {
                ForEach(run.rows) { row in rowView(row) }
                if let live = run.live { LiveRow(step: live) }
            } else {
                ForEach(run.changes) { change($0) }
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder private func rowView(_ row: StepRun.Row) -> some View {
        switch row {
        case .steps(let list): StepGroupRow(steps: list)
        case .said(let step): Text(step.words).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.vertical, 2)
        case .change(let entry): change(entry)
        }
    }

    private func change(_ entry: JournalEntry) -> some View {
        ActionRow(entry: entry, undone: isUndone(entry), undo: { undo(entry.id) })
    }
}

private struct LiveRow: View {
    let step: LiveStep

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            ProgressView().controlSize(.mini).frame(width: 16)
            LiveText(text: step.words).fontWeight(.medium).lineLimit(1).transaction { $0.animation = nil }.accessibilityIdentifier("page-run-live")
            Spacer(minLength: 8)
            StepClock(since: step.since).font(.caption2).foregroundStyle(.tertiary).fixedSize()
        }
        .padding(.top, 1)
    }
}

private struct StepGroupRow: View {
    let steps: [AgentStep]
    @State private var open = false

    private var nowhere: Bool { steps.allSatisfy { $0.kind == .skipped } }
    private var opens: Bool { steps.count > 1 || steps[0].detail?.isEmpty == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                if opens { withAnimation(.easeOut(duration: 0.12)) { open.toggle() } }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: nowhere ? "minus" : icon).font(.caption).foregroundStyle(.tertiary).frame(width: 16)
                    Text(StepRun.label(steps)).foregroundStyle(nowhere ? .secondary : .primary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    if opens {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary).rotationEffect(.degrees(open ? 90 : 0))
                    }
                    Spacer(minLength: 8)
                    Text(steps[steps.count - 1].at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.quaternary).fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("page-run-step")
            if open {
                if steps.count > 1 {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(steps) { StepLine(step: $0) }
                    }
                    .padding(.leading, 23)
                } else if let detail = steps[0].detail {
                    StepDetail(text: detail).padding(.leading, 23)
                }
            }
        }
    }

    private var icon: String {
        switch steps[0].family {
        case .tab, .window: "doc.text"
        case .service, .check: "magnifyingglass"
        case .learned: "book"
        case nil: "eye"
        }
    }
}

private struct StepLine: View {
    let step: AgentStep
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                if step.detail != nil { withAnimation(.easeOut(duration: 0.12)) { open.toggle() } }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(step.words).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    if step.detail != nil {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary).rotationEffect(.degrees(open ? 90 : 0))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open, let detail = step.detail { StepDetail(text: detail) }
        }
    }
}

private struct StepDetail: View {
    let text: String

    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(14).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true).padding(.bottom, 3)
    }
}

// In Bean's chat, an agent's finished work is one line that opens that agent.
struct CrewRunRow: View {
    let agent: Agent
    let run: StepRun
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                PageDrop(look: agent.look, mood: .idle, size: 14).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                (Text(agent.name).fontWeight(.medium) + Text(" ") + Text(run.changes.isEmpty ? run.summary.lowercasedFirst : run.summary.lowercasedFirst + ", made \(run.changes.count) change\(run.changes.count == 1 ? "" : "s")").foregroundColor(.secondary))
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                Text(run.began.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary).fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .help(String(format: "Open %@", agent.name))
        .accessibilityIdentifier("page-chat-crew-run")
    }
}

// Above Bean's composer, one row per agent at work.
struct CrewLiveRow: View {
    let agent: Agent
    let step: LiveStep
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 7) {
                PageDrop(look: agent.look, mood: .working, size: 14)
                Text(agent.name).font(.callout.weight(.medium)).lineLimit(1).fixedSize()
                LiveText(text: step.words).font(.callout).lineLimit(1).transaction { $0.animation = nil }
                Spacer(minLength: 6)
                StepClock(since: step.since).font(.caption2).foregroundStyle(.tertiary).fixedSize()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("page-chat-crew-live")
    }
}

extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
