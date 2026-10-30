import SwiftUI

enum NotchStyle {
    static let dim = Color.white.opacity(0.55)

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func width(of text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    static func height(of text: String, size: CGFloat, width: CGFloat) -> CGFloat {
        let rect = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                   attributes: [.font: NSFont.systemFont(ofSize: size)])
        return ceil(rect.height)
    }
}

struct NotchView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var settings = BeanSettings.shared
    let onTap: () -> Void
    let onCrew: (UUID, CrewGesture) -> Void
    let onPlus: () -> Void
    var onRoster: (UUID) -> Void = { _ in }

    var body: some View {
        let shape = NotchShape(metrics: model.shape, hasNotch: model.hasNotch)
        let notch = model.notchSize
        GeometryReader { geo in
            let mid = geo.size.width / 2
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .top) {
                    shape.fill(.black)
                        .shadow(color: model.calling?.opacity(0.9) ?? .clear, radius: 10, y: 2)
                        .animation(.easeInOut(duration: 0.5), value: model.calling)
                    Color.clear
                        .frame(width: model.shape.width, height: model.shape.height)
                        .offset(x: model.shape.offset)
                        .allowsHitTesting(false)
                        .accessibilityElement()
                        .accessibilityLabel("Bean")
                        .accessibilityIdentifier("bean-island")
                    content
                        .id(contentID)
                        .transition(.asymmetric(
                            insertion: .modifier(active: BlurFade(amount: 1), identity: BlurFade(amount: 0))
                                .animation(.easeOut(duration: 0.28).delay(0.09)),
                            removal: .opacity.animation(.easeIn(duration: 0.08))))
                        .frame(width: model.contentSize.width, height: model.contentSize.height, alignment: .top)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .mask(shape)
                }
                .contentShape(shape)
                .onTapGesture(perform: onTap)
                if let birth = model.birth {
                    let to = newbornPoint(birth.id, mid)
                    BirthGoo(birth: birth, from: point(CrewLayout.beanCenter(notch), mid), to: CGPoint(x: to.x, y: to.y + CrewLayout.hang), size: headSize)
                }
                if model.phase != .rest {
                    seat
                        .allowsHitTesting(false)
                        .position(point(CrewLayout.beanCenter(notch), mid, y: notch.height / 2))
                        .mask(shape)
                }
                if model.phase == .rest {
                    CrewRow(model: model, paused: settings.paused, onGesture: onCrew, onPlus: onPlus)
                        .transition(.opacity)
                }
                if model.phase == .rest, model.listOpen {
                    RosterList(roster: model.roster, onSelect: onRoster, onNew: onPlus)
                        .frame(width: model.shape.width - 2 * model.shape.flare)
                        .position(x: mid + model.shape.offset, y: notch.height + (model.shape.height - notch.height) / 2)
                        .transition(.opacity)
                }
            }
        }
    }

    private var headSize: CGFloat { CrewLayout.headSize(model.notchSize) }

    private var seat: some View {
        BeanSeat(bean: model.bean, size: headSize, slot: CrewLayout.slot(model.notchSize), height: model.notchSize.height,
                 lookAt: model.gaze, paused: settings.paused, lifted: model.lifted, birth: model.birth?.start, onGesture: onCrew)
    }


    private func point(_ c: CGPoint, _ mid: CGFloat, y: CGFloat? = nil) -> CGPoint {
        CGPoint(x: mid + c.x, y: y ?? c.y)
    }

    private func newbornPoint(_ id: UUID, _ mid: CGFloat) -> CGPoint {
        let index = min(model.crew.firstIndex { $0.id == id } ?? 0, CrewLayout.shown - 1)
        return point(CrewLayout.center(index: index, notch: model.notchSize), mid)
    }

    private var contentID: String {
        switch model.phase {
        case .message: model.messageID.uuidString
        case .rest: "rest"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .rest: Color.clear
        case .message: expanded { MessageBody(message: model.message) }
        }
    }

    private func expanded(@ViewBuilder _ body: () -> some View) -> some View {
        body()
            .padding(.top, model.topInset + (model.hasNotch ? 8 : 14))
            .padding(.horizontal, model.shape.flare + 20)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct RosterList: View {
    let roster: [RosterItem]
    let onSelect: (UUID) -> Void
    let onNew: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(roster) { item in
                RosterRow(action: { onSelect(item.id) }, label: item.name.isEmpty ? "New Agent" : item.name) {
                    let frame = CreatureView.frame(18)
                    CreatureView(look: item.look, mood: item.mood == .needsYou ? .idle : item.mood, size: 18, pose: .peek, limbs: 0)
                        .frame(width: frame.width, height: frame.height)
                        .frame(width: 20, height: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.name.isEmpty ? "New Agent" : item.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        Text(item.line).font(.system(size: 11)).foregroundStyle(item.mood == .needsYou ? Color.orange : .white.opacity(0.6)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            RosterRow(action: onNew, label: "New Agent") {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.7)).frame(width: 20)
                Text("New Agent").font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                Spacer(minLength: 0)
            }
            .accessibilityIdentifier("bean-plus")
        }
        .padding(.horizontal, 8)
    }
}

private struct RosterRow<Content: View>: View {
    let action: () -> Void
    let label: String
    @ViewBuilder let content: Content
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { content }
                .padding(.horizontal, 6)
                .frame(height: NotchController.rosterRow)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(hover ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(label)
    }
}

struct BeanSeat: View {
    let bean: CrewMember?
    let size: CGFloat
    let slot: CGFloat
    let height: CGFloat
    let lookAt: CGSize?
    let paused: Bool
    let lifted: UUID?
    let birth: Date?
    let onGesture: (UUID, CrewGesture) -> Void

    var body: some View {
        if let bean {
            CrewHead(member: paused ? CrewMember(id: bean.id, name: bean.name, look: bean.look, mood: .sleeping) : bean,
                     size: size, lookAt: lookAt, onGesture: onGesture)
                .frame(width: slot, height: height)
                .modifier(Squash(start: birth))
                .opacity(lifted == bean.id ? 0 : 1)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        } else {
            Circle()
                .strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [2, 2.5]))
                .frame(width: size * 0.6, height: size * 0.6)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

struct Squash: ViewModifier {
    let start: Date?

    func body(content: Content) -> some View {
        if let start {
            TimelineView(.animation) { context in
                let p = context.date.timeIntervalSince(start) / Birth.duration
                let s = p > 0 && p < 1 ? sin(min(p * 2.2, 1) * .pi) * (1 - p) : 0
                content.scaleEffect(x: 1 - 0.18 * s, y: 1 + 0.22 * s, anchor: .bottom)
                    .rotationEffect(.degrees(-14 * s), anchor: .bottom)
            }
        } else {
            content
        }
    }
}

struct BirthGoo: View {
    let birth: Birth
    let from: CGPoint
    let to: CGPoint
    let size: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            let p = min(1, max(0, context.date.timeIntervalSince(birth.start) / Birth.duration))
            let e = p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
            let head = CGPoint(x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e + sin(p * .pi) * size * 0.35)
            let d = size * (0.5 + 0.5 * e)
            let frame = CreatureView.frame(d)
            ZStack(alignment: .topLeading) {
                Goo(from: from, to: head, start: size * 0.3, end: d * 0.32, neck: max(0, 1 - p * 3.5))
                    .fill(LinearGradient(colors: [.white, CreaturePalette.pearl.body], startPoint: .top, endPoint: .bottom))
                CreatureView(look: Agent.Look(hue: birth.hue, accessory: "none"), mood: .forming(birth.start), size: d, pose: .peek, limbs: 0,
                             motion: CreatureMotion(time: context.date.timeIntervalSinceReferenceDate))
                    .frame(width: frame.width, height: frame.height)
                    .position(x: head.x, y: head.y + d * (0.5 * CreatureView.heightRatio - CreatureView.center.y + 0.06))
            }
            .opacity(p > 0 ? 1 : 0)
        }
        .allowsHitTesting(false)
    }
}

private struct Goo: Shape {
    let from: CGPoint
    let to: CGPoint
    let start: CGFloat
    let end: CGFloat
    let neck: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(x: to.x - end, y: to.y - end, width: 2 * end, height: 2 * end))
        guard neck > 0 else { return p }
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let waist = min(start, end) * 0.45 * neck
        p.move(to: CGPoint(x: from.x, y: from.y - start * 0.8))
        p.addQuadCurve(to: CGPoint(x: to.x, y: to.y - end * 0.8), control: CGPoint(x: mid.x, y: mid.y - waist))
        p.addLine(to: CGPoint(x: to.x, y: to.y + end * 0.8))
        p.addQuadCurve(to: CGPoint(x: from.x, y: from.y + start * 0.8), control: CGPoint(x: mid.x, y: mid.y + waist))
        p.closeSubpath()
        return p
    }
}

struct BlurFade: ViewModifier {
    let amount: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(1 - amount)
            .blur(radius: 8 * amount)
            .scaleEffect(1 - 0.04 * amount, anchor: .top)
    }
}

struct MessageBody: View {
    static let textSize: CGFloat = 15
    let message: NotchMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bean").font(NotchStyle.font(12, .semibold)).foregroundStyle(NotchStyle.dim)
            Text(message.text)
                .font(.system(size: Self.textSize))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if !message.choices.isEmpty {
                HStack(spacing: 8) {
                    Spacer()
                    ForEach(message.choices) { choice in
                        Button(action: choice.action) {
                            Text(choice.label)
                                .font(NotchStyle.font(13, .semibold))
                                .padding(.horizontal, 14)
                                .frame(height: 28)
                                .foregroundStyle(choice.isPrimary ? .black : .white)
                                .background(Capsule().fill(choice.isPrimary ? .white : .white.opacity(0.14)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 6)
            }
        }
    }
}
