import SwiftUI

enum CrewGesture {
    case lift
    case release(dragged: Bool)
}

enum CrewLayout {
    static let shown = 3
    static let most = 6
    static let inset: CGFloat = 6
    static let overflowWidth: CGFloat = 24
    static let hang: CGFloat = 10

    static func headSize(_ notch: CGSize) -> CGFloat { max(16, (notch.height * 0.66).rounded()) }
    static func slot(_ notch: CGSize) -> CGFloat { headSize(notch) + 3 }
    static func beanEar(_ notch: CGSize) -> CGFloat { inset + slot(notch) + 8 }

    static func ear(count: Int, shown: Int, plus: Bool, notch: CGSize) -> CGFloat {
        let slots = CGFloat(shown + (plus ? 1 : 0))
        guard slots > 0 else { return 0 }
        return inset + slots * slot(notch) + (count > shown ? overflowWidth : 0) + 8
    }

    static func center(index: Int, notch: CGSize) -> CGPoint {
        let s = slot(notch)
        return CGPoint(x: -(notch.width / 2 + inset + s / 2 + CGFloat(index) * s), y: notch.height / 2 + headSize(notch) * 0.06)
    }

    static func plusCenter(count: Int, shown: Int, notch: CGSize) -> CGPoint {
        let c = center(index: shown, notch: notch)
        return CGPoint(x: c.x - (count > shown ? overflowWidth : 0), y: notch.height / 2)
    }

    static func beanCenter(_ notch: CGSize) -> CGPoint {
        CGPoint(x: notch.width / 2 + inset + slot(notch) / 2, y: notch.height / 2 + headSize(notch) * 0.06)
    }
}

struct CrewRow: View {
    @ObservedObject var model: NotchModel
    let onGesture: (UUID, CrewGesture) -> Void
    let onPlus: () -> Void

    var body: some View {
        let notch = model.notchSize
        GeometryReader { geo in
            let d = CrewLayout.headSize(notch)
            let slot = CrewLayout.slot(notch)
            ZStack(alignment: .topLeading) {
                let shown = model.shownCount
                ForEach(Array(model.crew.prefix(shown).enumerated()), id: \.element.id) { index, member in
                    let c = CrewLayout.center(index: index, notch: notch)
                    let hangs = model.newborn == member.id && model.lifted != member.id
                    let unborn = model.birth?.id == member.id
                    CrewHead(member: member, size: d, lookAt: model.gaze, onGesture: onGesture)
                        .frame(width: slot, height: notch.height)
                        .offset(y: hangs ? CrewLayout.hang : 0)
                        .scaleEffect(unborn ? 0.6 : 1)
                        .opacity(model.lifted == member.id || unborn ? 0 : 1)
                        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: unborn)
                        .position(x: geo.size.width / 2 + c.x, y: notch.height / 2)
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }
                if model.crew.count > shown {
                    let c = CrewLayout.center(index: shown, notch: notch)
                    Text("+\(model.crew.count - shown)")
                        .font(NotchStyle.font(11, .bold))
                        .foregroundStyle(NotchStyle.dim)
                        .position(x: geo.size.width / 2 + c.x + (slot - CrewLayout.overflowWidth) / 2, y: notch.height / 2)
                        .allowsHitTesting(false)
                }
                if model.showsPlus {
                    let c = CrewLayout.plusCenter(count: model.crew.count, shown: shown, notch: notch)
                    PlusButton(size: d * 0.86, action: onPlus)
                        .frame(width: slot, height: notch.height)
                        .position(x: geo.size.width / 2 + c.x, y: c.y)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: model.crew.map(\.id))
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: model.showsPlus)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: model.shownCount)
        .animation(.spring(response: 0.45, dampingFraction: 0.6), value: model.newborn)
    }
}

private struct PlusButton: View {
    let size: CGFloat
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.white.opacity(hover ? 0.24 : 0.14))
                Image(systemName: "plus").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .scaleEffect(hover ? 1.1 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
        .accessibilityLabel("New agent")
        .accessibilityIdentifier("bean-plus")
    }
}

struct CrewHead: View {
    let member: CrewMember
    let size: CGFloat
    let lookAt: CGSize?
    let onGesture: (UUID, CrewGesture) -> Void
    @State private var dragging = false

    var body: some View {
        let frame = CreatureView.frame(size)
        CreatureView(look: member.look, mood: member.mood, size: size, pose: .peek, limbs: 0, lookAt: lookAt)
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
            .accessibilityLabel(member.name.isEmpty ? "New agent" : member.name)
            .accessibilityIdentifier("agent-head-\(member.name)")
    }
}
