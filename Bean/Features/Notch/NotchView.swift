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
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

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
                if model.phase != .create, let birth = model.birth {
                    let to = newbornPoint(birth.id, mid)
                    BirthGoo(birth: birth, from: point(CrewLayout.beanCenter(notch), mid), to: CGPoint(x: to.x, y: to.y + CrewLayout.hang), size: headSize)
                }
                seat
                    .position(point(CrewLayout.beanCenter(notch), mid, y: notch.height / 2))
                    .mask(shape)
                if model.phase == .rest {
                    CrewRow(model: model, onGesture: onCrew, onPlus: onPlus)
                        .transition(.opacity)
                    if let hint = model.hint, let id = model.newborn {
                        let p = newbornPoint(id, mid)
                        CreatureBubble(text: hint, tailOnLeft: true, below: true)
                            .fixedSize()
                            .frame(width: 240, height: 90, alignment: .topLeading)
                            .position(x: p.x - 16 + 120, y: p.y + CrewLayout.hang + headSize * 0.62 + 12 + 45)
                            .transition(.scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity))
                            .allowsHitTesting(false)
                    }
                    if let say = model.say {
                        let p = point(CrewLayout.beanCenter(notch), mid)
                        CreatureBubble(text: say, tailOnLeft: true, below: true)
                            .fixedSize()
                            .frame(width: 240, height: 90, alignment: .topLeading)
                            .position(x: p.x - 16 + 120, y: notch.height + 10 + 45)
                            .transition(.scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity))
                            .allowsHitTesting(false)
                    }
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: model.hint)
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: model.say)
        }
    }

    private var headSize: CGFloat { CrewLayout.headSize(model.notchSize) }

    @ViewBuilder private var seat: some View {
        if let bean = model.bean {
            CrewHead(member: settings.paused ? CrewMember(id: bean.id, name: bean.name, look: bean.look, mood: .sleeping) : bean,
                     size: headSize, lookAt: beanGaze, onGesture: onCrew)
                .frame(width: CrewLayout.slot(model.notchSize), height: model.notchSize.height)
                .modifier(Squash(start: model.birth?.start))
                .opacity(model.lifted == bean.id ? 0 : 1)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        } else {
            Circle()
                .strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [2, 2.5]))
                .frame(width: headSize * 0.6, height: headSize * 0.6)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private var beanGaze: CGSize? {
        guard model.phase == .create else { return model.gaze }
        return CGSize(width: -0.9 + min(0.9, Double(model.draft.count) / 30), height: 1)
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
        case .create: "create"
        case .rest: "rest"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .rest: Color.clear
        case .create: expanded { CreateBody(model: model, onSubmit: onSubmit, onCancel: onCancel) }
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
            .opacity(p > 0 && p < 1 ? 1 : 0)
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

private struct CreateBody: View {
    @ObservedObject var model: NotchModel
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                TextField("", text: $model.draft, prompt: Text("Describe your agent…").foregroundStyle(.white.opacity(0.38)))
                    .textFieldStyle(.plain)
                    .font(NotchStyle.font(15, .medium))
                    .foregroundStyle(.white)
                    .focused($focused)
                    .onSubmit { onSubmit(model.draft) }
                    .onExitCommand(perform: onCancel)
                    .accessibilityIdentifier("bean-describe")
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(model.draft.isEmpty ? 0.22 : 0.7))
            }
            .frame(height: 26)
            if !model.ideas.isEmpty {
                HStack(spacing: 6) {
                    ForEach(model.ideas) { idea in
                        Button { onSubmit(idea.request) } label: { IdeaChip(idea: idea) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(idea.label)
                    }
                }
                .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.ideas)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

private struct IdeaChip: View {
    let idea: AgentIdea
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(CreaturePalette(hue: idea.hue).body).frame(width: 7, height: 7)
            Text(idea.label).font(NotchStyle.font(12, .medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(.white.opacity(hover ? 0.16 : 0.09)))
        .contentShape(Capsule())
        .onHover { hover = $0 }
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
