import SwiftUI

enum CrewGesture {
    case lift
    case release(dragged: Bool)
}

enum CrewLayout {
    static let shown = 3
    static let inset: CGFloat = 6
    static let overflowWidth: CGFloat = 24

    static func headSize(_ notch: CGSize) -> CGFloat { max(16, (notch.height * 0.66).rounded()) }
    static func slot(_ notch: CGSize) -> CGFloat { headSize(notch) + 3 }

    static func ear(count: Int, notch: CGSize) -> CGFloat {
        guard count > 0 else { return 0 }
        return inset + CGFloat(min(count, shown)) * slot(notch) + (count > shown ? overflowWidth : 0) + 8
    }

    static func center(index: Int, notch: CGSize) -> CGPoint {
        let s = slot(notch)
        return CGPoint(x: -(notch.width / 2 + inset + s / 2 + CGFloat(index) * s), y: notch.height / 2 + headSize(notch) * 0.06)
    }
}

struct CrewRow: View {
    let crew: [CrewMember]
    let lifted: UUID?
    let notch: CGSize
    let onGesture: (UUID, CrewGesture) -> Void

    var body: some View {
        GeometryReader { geo in
            let d = CrewLayout.headSize(notch)
            let slot = CrewLayout.slot(notch)
            ZStack(alignment: .topLeading) {
                ForEach(Array(crew.prefix(CrewLayout.shown).enumerated()), id: \.element.id) { index, member in
                    let c = CrewLayout.center(index: index, notch: notch)
                    CrewHead(member: member, size: d, onGesture: onGesture)
                        .frame(width: slot, height: notch.height)
                        .opacity(lifted == member.id ? 0 : 1)
                        .position(x: geo.size.width / 2 + c.x, y: notch.height / 2)
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }
                if crew.count > CrewLayout.shown {
                    let c = CrewLayout.center(index: CrewLayout.shown, notch: notch)
                    Text("+\(crew.count - CrewLayout.shown)")
                        .font(NotchStyle.font(11, .bold))
                        .foregroundStyle(NotchStyle.dim)
                        .position(x: geo.size.width / 2 + c.x + (slot - CrewLayout.overflowWidth) / 2, y: notch.height / 2)
                        .allowsHitTesting(false)
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: crew.map(\.id))
    }
}

private struct CrewHead: View {
    let member: CrewMember
    let size: CGFloat
    let onGesture: (UUID, CrewGesture) -> Void
    @State private var dragging = false

    var body: some View {
        let frame = CreatureView.frame(size)
        CreatureView(look: member.look, mood: member.mood, size: size, pose: .peek, limbs: 0)
            .frame(width: frame.width, height: frame.height)
            .offset(y: size * (0.5 - CreatureView.center.y / CreatureView.heightRatio) * CreatureView.heightRatio + size * 0.06)
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    guard !dragging, hypot(value.translation.width, value.translation.height) > 3 else { return }
                    dragging = true
                    onGesture(member.id, .lift)
                }
                .onEnded { _ in
                    onGesture(member.id, .release(dragged: dragging))
                    dragging = false
                })
            .accessibilityElement()
            .accessibilityLabel(member.name)
            .accessibilityIdentifier("agent-head-\(member.name)")
    }
}
