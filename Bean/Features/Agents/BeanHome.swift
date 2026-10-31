import SwiftUI

struct BeanHome: View {
    let bean: Agent
    let crew: [Agent]
    let feed: PageFeed
    let actions: PageActions
    var first = false
    @State private var expanded: [String: Bool] = [:]

    private var windows: [OpenWindow] { Array(feed.openWindows.prefix(6)) }
    private var thoughts: [(agent: Agent, thought: AgentWorker.Thought)] {
        crew.compactMap { agent in feed.thoughts[agent.id].map { (agent: agent, thought: $0) } }
            .sorted { $0.thought.at > $1.thought.at }
            .prefix(4).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if first {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AgentStrings.shown("I run your agents on your windows.")).font(.title3.weight(.semibold))
                    Text(AgentStrings.shown("Tell me a goal, or put an agent on a window. I decide who does what, and report once."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            group(AgentStrings.shown("On your Mac now"), open: first) {
                if windows.isEmpty {
                    Text(AgentStrings.shown("I see no open windows here. Open one and I can put an agent on it.")).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(windows, id: \.number) { window in
                    windowRow(window)
                }
            }
            group(AgentStrings.shown("Just decided"), open: true) {
                ForEach(feed.gate.suffix(4).reversed()) { gateRow($0) }
                if feed.gate.isEmpty && thoughts.isEmpty {
                    Text(AgentStrings.shown(crew.isEmpty ? "Nothing yet. Once an agent is on a window, you see here what it chooses to do, and when it chooses to wait."
                         : "Nothing yet. I decide when something changes in a window."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if feed.gate.isEmpty {
                    ForEach(thoughts, id: \.agent.id) { item in
                        thoughtRow(item.agent, item.thought)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("page-bean-home")
    }

    private func group(_ title: String, open: Bool, @ViewBuilder content: () -> some View) -> some View {
        let rows = content()
        return PageDisclosure(isExpanded: Binding(get: { expanded[title] ?? open }, set: { expanded[title] = $0 })) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        } content: {
            VStack(alignment: .leading, spacing: 8) { rows }.padding(.top, 6)
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
                Button(AgentStrings.shown("Put an Agent Here")) { actions.putAgent(window) }
                .controlSize(.small)
                .fixedSize()
                .accessibilityIdentifier("page-put-agent")
            }
        }
    }

    private func gateRow(_ entry: GateEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(GateWords.title(entry.decision)).font(.callout.weight(.medium))
                let place = [entry.app, entry.title].compactMap { $0 }.joined(separator: ": ")
                let line = [place, entry.detail ?? ""].filter { !$0.isEmpty }.joined(separator: ". ")
                if !line.isEmpty { Text(line).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            }
            Spacer(minLength: 8)
            Text(entry.at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary).fixedSize()
        }
    }

    private func thoughtRow(_ agent: Agent, _ thought: AgentWorker.Thought) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            PageDrop(look: agent.look, mood: .idle, size: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(AgentStrings.shown(thought.acted ? "%@ acted" : "%@ chose to wait", agent.name)).font(.callout.weight(.medium))
                if !thought.what.isEmpty {
                    Text(thought.what).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text(thought.at.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary).fixedSize()
        }
    }
}

struct PageDisclosure<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder let label: () -> Label
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    label()
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded { content() }
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
