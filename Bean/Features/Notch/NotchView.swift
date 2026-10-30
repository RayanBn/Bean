import SwiftUI

enum NotchStyle {
    static let accent = Color(red: 0.30, green: 0.98, blue: 0.56)
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

    var body: some View {
        let shape = NotchShape(metrics: model.shape, hasNotch: model.hasNotch)
        ZStack(alignment: .top) {
            shape.fill(.black)
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
            BeanEyes(mood: mood, pokes: model.pokes)
                .offset(x: model.notchSize.width / 2 + BeanEyes.inset + BeanEyes.pairWidth / 2)
                .frame(height: model.notchSize.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .mask(shape)
                .allowsHitTesting(false)
            if model.phase == .rest {
                CrewRow(crew: model.crew, lifted: model.lifted, notch: model.notchSize, onGesture: onCrew)
                    .mask(shape)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(shape)
        .onTapGesture(perform: onTap)
    }

    private var mood: EyeMood {
        model.phase == .rest && settings.paused ? .asleep : EyeMood(model.phase)
    }

    private var contentID: String {
        switch model.phase {
        case .message: model.messageID.uuidString
        default: model.phase.key
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .rest: compact(Color.clear)
        case .notice(let word): compact(Text(word).font(NotchStyle.font(13, .semibold)).foregroundStyle(.white))
        case .thinking(let text): expanded { ThinkingRow(text: text ?? "Thinking") }
        case .message: expanded { MessageBody(message: model.message) }
        case .done(let text): compact(HStack(spacing: 6) { DoneCheck(); Text(text).font(NotchStyle.font(13, .semibold)).foregroundStyle(.white) })
        }
    }

    private func compact(_ left: some View) -> some View {
        HStack(spacing: 0) {
            left.frame(maxWidth: .infinity)
            Color.clear.frame(width: model.notchSize.width)
            Color.clear.frame(maxWidth: .infinity)
        }
        .padding(.horizontal, model.shape.flare + (model.hasNotch ? 2 : 6))
        .frame(height: model.hasNotch ? model.notchSize.height : model.contentSize.height)
    }

    private func expanded(@ViewBuilder _ body: () -> some View) -> some View {
        body()
            .padding(.top, model.topInset + (model.hasNotch ? 8 : 14))
            .padding(.horizontal, model.shape.flare + 20)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

struct DoneCheck: View {
    @State private var bounce = 0

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(NotchStyle.accent)
            .symbolEffect(.bounce, value: bounce)
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { bounce += 1 } }
    }
}

struct ShimmerText: View {
    let text: String
    let font: Font

    var body: some View {
        TimelineView(.animation) { context in
            let p = CGFloat((context.date.timeIntervalSinceReferenceDate / 1.8).truncatingRemainder(dividingBy: 1))
            Text(text)
                .font(font)
                .foregroundStyle(LinearGradient(colors: [.white.opacity(0.4), .white, .white.opacity(0.4)],
                                                startPoint: UnitPoint(x: 2.4 * p - 1.2, y: 0.5),
                                                endPoint: UnitPoint(x: 2.4 * p - 0.2, y: 0.5)))
        }
    }
}

struct ThinkingOrb: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3) { i in
                    let s = 0.5 + 0.5 * sin(t * 2 * .pi / 1.1 - Double(i) * 0.9)
                    Circle()
                        .fill(NotchStyle.accent)
                        .frame(width: 5, height: 5)
                        .opacity(0.35 + 0.65 * s)
                        .offset(y: -2.5 * s)
                }
            }
        }
    }
}

struct ThinkingRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ThinkingOrb()
            ShimmerText(text: text, font: NotchStyle.font(14, .medium))
            Spacer(minLength: 0)
        }
        .frame(height: 22)
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
                                .background(Capsule().fill(choice.isPrimary ? NotchStyle.accent : .white.opacity(0.14)))
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
