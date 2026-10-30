import SwiftUI

struct BeanHome: View {
    let bean: Agent
    let crew: [Agent]
    let feed: PageFeed
    let actions: PageActions
    var first = false

    private var standingBy: Bool { feed.missions[bean.id]?.paused != false }
    private var windows: [OpenWindow] { Array(feed.openWindows.prefix(6)) }
    private var thoughts: [(agent: Agent, thought: AgentWorker.Thought)] {
        crew.compactMap { agent in feed.thoughts[agent.id].map { (agent: agent, thought: $0) } }
            .sorted { $0.thought.at > $1.thought.at }
            .prefix(4).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(first ? "I run your agents on your windows." : standingBy ? "I'm standing by." : "I'm looking after things.")
                    .font(.title3.weight(.semibold))
                Text(first ? "Tell me a goal, or put an agent on a window. I decide who does what, and report once."
                     : standingBy ? "Tell me a goal, or say Take Over when you leave and I answer for you."
                     : "I keep your agents moving and answer for you. Say I'm Back when you return.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(standingBy ? "Take Over" : "I'm Back") { actions.send(bean.id, standingBy ? "Take over" : "I'm back") }
                    .buttonStyle(.borderedProminent)
                    .help("While you are away, Bean keeps everything moving and answers for you")
                    .accessibilityIdentifier("page-take-over")
                Button("New Agent", action: actions.newAgent)
            }
            group("On your Mac now") {
                if windows.isEmpty {
                    Text("I see no open windows here. Open one and I can put an agent on it.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(windows, id: \.number) { window in
                    windowRow(window)
                }
            }
            group("Just decided") {
                if thoughts.isEmpty {
                    Text(crew.isEmpty ? "Nothing yet. Once an agent is on a window, you see here what it chooses to do, and when it chooses to wait."
                         : "Nothing yet. I decide when something changes in a window.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(thoughts, id: \.agent.id) { item in
                    thoughtRow(item.agent, item.thought)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("page-bean-home")
    }

    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func windowRow(_ window: OpenWindow) -> some View {
        HStack(spacing: 8) {
            TargetIcon(target: AgentTarget(kind: .window, name: window.title ?? window.app, app: window.app, title: window.title))
            VStack(alignment: .leading, spacing: 0) {
                Text(window.title ?? window.app).lineLimit(1)
                if window.title != nil { Text(window.app).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if let agent = crew.first(where: { $0.attachment?.windowNumber == window.number }) {
                HStack(spacing: 4) {
                    PageDrop(look: agent.look, mood: .idle, size: 14)
                    Text(agent.name).font(.callout).foregroundStyle(.secondary)
                }
                .fixedSize()
            } else {
                Button("Put an Agent Here") {
                    actions.send(bean.id, "Put an agent on this window: \(window.app), \(window.title ?? "no title").")
                }
                .controlSize(.small)
                .fixedSize()
                .accessibilityIdentifier("page-put-agent")
            }
        }
    }

    private func thoughtRow(_ agent: Agent, _ thought: AgentWorker.Thought) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            PageDrop(look: agent.look, mood: .idle, size: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(thought.acted ? "\(agent.name) acted" : "\(agent.name) chose to wait").font(.callout.weight(.medium))
                if !thought.what.isEmpty {
                    Text(thought.what).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text(thought.at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary).fixedSize()
        }
    }
}

struct LookEditor: View {
    let agent: Agent
    let actions: PageActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Array(Agent.Look.hues.enumerated()), id: \.offset) { index, hue in
                    Button {
                        actions.setLook(agent.id, .init(hue: hue, accessory: agent.look.accessory))
                    } label: {
                        Circle().fill(CreaturePalette(hue: hue).body)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.primary.opacity(abs(hue - agent.look.hue) < 0.01 ? 0.8 : 0), lineWidth: 2))
                            .padding(1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Color \(index + 1)")
                    .accessibilityIdentifier("page-look-color-\(index)")
                }
            }
            HStack(spacing: 6) {
                ForEach(Agent.Look.accessories, id: \.self) { mark in
                    Button {
                        actions.setLook(agent.id, .init(hue: agent.look.hue, accessory: mark))
                    } label: {
                        Image(systemName: Agent.Look.symbol(for: mark) ?? "circle.slash")
                            .foregroundStyle(Color.primary)
                            .frame(width: 26, height: 24)
                            .background {
                                if agent.look.accessory == mark {
                                    RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.14))
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(mark == "none" ? "No mark" : mark)
                    .accessibilityIdentifier("page-look-mark-\(mark)")
                }
            }
        }
    }
}
