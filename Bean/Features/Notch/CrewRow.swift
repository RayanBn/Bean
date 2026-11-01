import AppKit
import SwiftUI

enum CrewGesture {
    case lift
    case release(dragged: Bool)
}

enum CrewLayout {
    static let shown = 3
    static let inset: CGFloat = 6
    static let overflowWidth: CGFloat = 24
    static let hang: CGFloat = 10

    static func headSize(_ notch: CGSize) -> CGFloat { max(16, (notch.height * 0.66).rounded()) }
    static func slot(_ notch: CGSize) -> CGFloat { headSize(notch) + 3 }
    static func beanEar(_ notch: CGSize) -> CGFloat { inset + slot(notch) + 8 }
    static let pip: CGFloat = 6
    static let pipGap: CGFloat = 4

    static func signals(pips: Int, waiting: Int, done: Bool) -> CGFloat {
        let count = min(pips, maxPips) + (done ? 1 : 0)
        return CGFloat(count) * (pip + pipGap) + (waiting > 0 ? (waiting > 1 ? 20 : 12) : 0)
    }

    static let maxPips = 5

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
    let paused: Bool
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
                        .scaleEffect(unborn ? 0.92 : 1)
                        .opacity(model.lifted == member.id || unborn ? 0 : 1)
                        
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
                let b = CrewLayout.beanCenter(notch)
                BeanSeat(bean: model.bean, size: d, slot: slot, height: notch.height, lookAt: model.gaze, paused: paused,
                         lifted: model.lifted, birth: model.birth?.start, onGesture: onGesture)
                    .position(x: geo.size.width / 2 + b.x, y: notch.height / 2)
                NotchSignals(pips: model.pips, waiting: model.waiting, done: model.doneMark)
                    .position(x: geo.size.width / 2 + b.x + slot / 2 + 2 + CrewLayout.signals(pips: model.pips.count, waiting: model.waiting, done: model.doneMark) / 2, y: notch.height / 2)
                    .allowsHitTesting(false)
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

private struct NotchSignals: View {
    let pips: [NotchPip]
    let waiting: Int
    let done: Bool

    var body: some View {
        HStack(spacing: CrewLayout.pipGap) {
            if waiting > 0 {
                HStack(spacing: 2) {
                    Circle().fill(Color.orange).frame(width: 8, height: 8)
                    if waiting > 1 { Text("\(waiting)").font(NotchStyle.font(10, .bold)).foregroundStyle(Color.orange) }
                }
                .accessibilityElement()
                .accessibilityLabel("Needs you")
                .accessibilityIdentifier("notch-waiting")
            }
            ForEach(pips.prefix(CrewLayout.maxPips)) { pip in
                NotchPipView(pip: pip)
            }
            if done {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(Color.green)
                    .frame(width: CrewLayout.pip, height: CrewLayout.pip)
                    .accessibilityIdentifier("notch-done")
            }
        }
        .fixedSize()
    }
}

private struct NotchPipView: View {
    let pip: NotchPip

    var body: some View {
        let dot = Circle().fill(CreaturePalette(look: pip.look).body).frame(width: CrewLayout.pip, height: CrewLayout.pip)
        if pip.working {
            TimelineView(.animation(minimumInterval: 1 / 12)) { context in
                dot.opacity(0.7 + 0.3 * sin(context.date.timeIntervalSinceReferenceDate * 2.4))
            }
        } else {
            dot.opacity(0.85)
        }
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
        .accessibilityLabel("New Agent")
        .accessibilityIdentifier("bean-plus")
    }
}

struct CrewHead: View {
    let member: CrewMember
    let size: CGFloat
    let lookAt: CGSize?
    let onGesture: (UUID, CrewGesture) -> Void
    @State private var dragging = false
    @State private var hover = false

    var body: some View {
        let frame = CreatureView.frame(size)
        CreatureView(look: member.look, mood: member.mood, size: size, pose: .peek, limbs: 0, lookAt: lookAt)
            .frame(width: frame.width, height: frame.height)
            .offset(y: size * (0.5 - CreatureView.center.y / CreatureView.heightRatio) * CreatureView.heightRatio + size * 0.06)
            .frame(width: size, height: size)
            .background {
                if member.lit {
                    Circle().fill(CreaturePalette(look: member.look).body.opacity(0.6))
                        .frame(width: size * 1.3, height: size * 1.3)
                        .blur(radius: size * 0.22)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let app = member.app, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: size * 0.52, height: size * 0.52)
                        .offset(x: size * 0.14, y: size * 0.1)
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(hover ? 1.14 : 1, anchor: .center)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hover)
            .contentShape(Rectangle())
            .onHover { inside in
                hover = inside
                if inside { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
            }
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
