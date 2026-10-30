import SwiftUI

struct AgentsView: View {
    @ObservedObject var agents: Agents
    @ObservedObject var store: AgentStore
    let onHeight: (CGFloat) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let id = agents.shown, let agent = store.agents.first(where: { $0.id == id }) {
                AgentCard(agent: agent, activity: store.activity[id] ?? AgentActivity(), folder: AgentFolder(agent, in: store),
                          onUnplug: { agents.unplug(id) }, onDelete: agent.isBean ? nil : { agents.delete(id) })
                    .transition(.scale(scale: 0.85, anchor: .topLeading).combined(with: .opacity))
            }
        }
        .padding(14)
        .frame(width: Agents.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in Color.clear.onAppear { onHeight(proxy.size.height) }.onChange(of: proxy.size.height) { _, height in onHeight(height) } })
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: agents.shown)
    }
}

struct AgentCard: View {
    static let ink = CreatureBubble.ink

    let agent: Agent
    let activity: AgentActivity
    let folder: AgentFolder
    let onUnplug: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        let palette = CreaturePalette(look: agent.look)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                CreatureView(look: agent.look, size: 24, pose: .peek, limbs: 0)
                    .frame(width: 36, height: 42)
                    .frame(width: 26, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name).font(NotchStyle.font(15, .semibold)).foregroundStyle(Self.ink)
                    Text(agent.role).font(NotchStyle.font(11.5)).foregroundStyle(Self.ink.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
                }
            }
            Part(title: agent.attachment.map { "Sees · \($0.appName)" } ?? "Sees", color: palette.deep) {
                Text(seeing).font(NotchStyle.font(12.5)).foregroundStyle(Self.ink.opacity(0.88)).fixedSize(horizontal: false, vertical: true)
            }
            Part(title: "Remembers", color: palette.deep) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) } label: {
                    HStack(spacing: 4) {
                        Text("\(agent.name)'s folder").font(NotchStyle.font(12.5)).foregroundStyle(Self.ink.opacity(0.88))
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Self.ink.opacity(0.4))
                    }
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 8) {
                if agent.attachment != nil {
                    Button(action: onUnplug) {
                        Label("Unplug", systemImage: "arrow.up.to.line").font(NotchStyle.font(11.5, .semibold))
                            .padding(.horizontal, 10).frame(height: 26)
                            .background(Capsule().fill(Self.ink.opacity(0.07)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Unplug")
                }
                if let onDelete { HoldToDelete(action: onDelete) }
            }
            .foregroundStyle(Self.ink.opacity(0.8))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(CreatureBubble.paper))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
    }

    private var seeing: String {
        guard agent.attachment != nil else { return agent.isBean ? "Nothing yet. Drag me onto a window and I'll watch it too." : "Nothing yet. Drag me onto any window." }
        if activity.mood == .reading && folder.understanding == nil { return "Reading…" }
        return folder.understanding ?? activity.bubble ?? "Nothing understood yet."
    }
}

private struct HoldToDelete: View {
    let action: () -> Void
    @State private var progress: CGFloat = 0
    @State private var holding = false

    var body: some View {
        Label("Hold to delete", systemImage: "trash")
            .font(NotchStyle.font(11.5, .semibold))
            .padding(.horizontal, 10).frame(height: 26)
            .background {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().strokeBorder(CreatureBubble.ink.opacity(0.12), lineWidth: 1)
                        Capsule().fill(Color(red: 0.95, green: 0.33, blue: 0.3).opacity(0.85)).frame(width: geo.size.width * progress)
                    }
                }
                .clipShape(Capsule())
            }
            .foregroundStyle(progress > 0.5 ? .white : CreatureBubble.ink.opacity(0.8))
            .contentShape(Capsule())
            .onLongPressGesture(minimumDuration: 1, maximumDistance: 20) {
                action()
            } onPressingChanged: { pressing in
                holding = pressing
                withAnimation(pressing ? .linear(duration: 1) : .spring(response: 0.3, dampingFraction: 0.8)) { progress = pressing ? 1 : 0 }
            }
            .accessibilityLabel("Delete")
            .accessibilityAction { action() }
    }
}

private struct Part<Content: View>: View {
    let title: String
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(NotchStyle.font(9.5, .bold)).tracking(0.8).foregroundStyle(color).lineLimit(1)
            content
        }
    }
}
