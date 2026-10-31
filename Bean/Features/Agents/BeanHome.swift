import SwiftUI

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
