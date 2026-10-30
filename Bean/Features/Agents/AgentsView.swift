import SwiftUI

struct AgentsView: View {
    @ObservedObject var agents: Agents
    @ObservedObject var store: AgentStore
    let onHeight: (CGFloat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch agents.screen {
            case .closed: EmptyView()
            case .choosing(let proposals): Choosing(agents: agents, proposals: proposals)
            case .agent(let id):
                if let agent = store.agents.first(where: { $0.id == id }) {
                    AgentCard(agents: agents, agent: agent, activity: store.activity[id] ?? AgentActivity(), folder: AgentFolder(agent, in: store))
                }
            }
        }
        .padding(18)
        .frame(width: Agents.width, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black))
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in Color.clear.onAppear { onHeight(proxy.size.height) }.onChange(of: proxy.size.height) { _, height in onHeight(height) } })
        .frame(maxHeight: .infinity, alignment: .top)
        .onExitCommand { agents.close() }
        .environment(\.colorScheme, .dark)
    }
}

private struct Choosing: View {
    @ObservedObject var agents: Agents
    let proposals: [AgentProposal]
    @FocusState private var typing: Bool

    var body: some View {
        Text("Bean").font(NotchStyle.font(12, .semibold)).foregroundStyle(NotchStyle.dim)
        Text("Here is who could help you on this Mac. Pick one, or tell me who you want.")
            .font(.system(size: 14)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
        ForEach(proposals) { proposal in
            Button { agents.pick(proposal) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(proposal.name).font(NotchStyle.font(14, .semibold)).foregroundStyle(.white)
                    Text(proposal.pitch).font(.system(size: 12)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
                    if !proposal.connectors.isEmpty {
                        Text(proposal.connectors.joined(separator: " · ")).font(NotchStyle.font(11, .medium)).foregroundStyle(NotchStyle.accent.opacity(0.8))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(proposal.name)
        }
        HStack(spacing: 8) {
            TextField("Or describe your own agent…", text: $agents.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .focused($typing)
                .onSubmit { agents.describe() }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Capsule().fill(.white.opacity(typing ? 0.14 : 0.08)))
            Button { agents.describe() } label: {
                Text("Create").font(NotchStyle.font(13, .semibold)).padding(.horizontal, 14).frame(height: 32)
                    .foregroundStyle(.black).background(Capsule().fill(NotchStyle.accent))
            }
            .buttonStyle(.plain)
            .disabled(agents.draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

private struct AgentCard: View {
    @ObservedObject var agents: Agents
    let agent: Agent
    let activity: AgentActivity
    let folder: AgentFolder
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color(hue: agent.look.hue, saturation: 0.65, brightness: 0.95)).frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name).font(NotchStyle.font(15, .semibold)).foregroundStyle(.white)
                Text(agent.role).font(.system(size: 12)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
        if let bubble = activity.bubble {
            Text("“\(bubble)”").font(.system(size: 13, weight: .medium)).italic().foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
        }
        if let attachment = agent.attachment {
            Section(title: "On \(attachment.appName)\(attachment.windowTitle.map { " · \($0)" } ?? "")") {
                Text(activity.mood == .reading ? "Reading…" : folder.understanding ?? "Nothing understood yet.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Section(title: "Not plugged in") {
                Text("Drag me from the notch onto a window.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.9))
            }
        }
        let connectors = folder.connectors
        if !connectors.isEmpty {
            Section(title: "Connectors") {
                Text(connectors.map { "\($0.name)\($0.status == .connected ? "" : " (to connect)")" }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.9))
            }
        }
        HStack(spacing: 8) {
            Spacer()
            if confirming {
                button("Cancel", primary: false) { confirming = false }
                button("Delete \(agent.name)", primary: true) { agents.delete(agent.id) }
            } else {
                button("Delete", primary: false) { confirming = true }
                if agent.attachment != nil { button("Unplug", primary: false) { agents.unplug(agent.id) } }
                button("Close", primary: true) { agents.close() }
            }
        }
        .padding(.top, 4)
    }

    private func button(_ label: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(NotchStyle.font(13, .semibold)).padding(.horizontal, 14).frame(height: 28)
                .foregroundStyle(primary ? .black : .white)
                .background(Capsule().fill(primary ? NotchStyle.accent : .white.opacity(0.14)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(NotchStyle.font(11, .semibold)).foregroundStyle(NotchStyle.dim).lineLimit(1)
            content
        }
    }
}
