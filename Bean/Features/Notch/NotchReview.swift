import SwiftUI

struct NotchCard: Identifiable {
    let id: UUID
    let title: String
    let detail: String
    let quote: String?
    let symbol: String?
    var isOn: Bool

    init(id: UUID = UUID(), title: String, detail: String, quote: String? = nil, symbol: String? = nil, isOn: Bool = true) {
        self.id = id
        self.title = title
        self.detail = detail
        self.quote = quote
        self.symbol = symbol
        self.isOn = isOn
    }
}

struct NotchReview {
    let text: String
    var cards: [NotchCard]
    let confirm: String
    let onConfirm: ([UUID]) -> Void
    let onDismiss: () -> Void
}

struct ReviewBody: View {
    static let width: CGFloat = 520
    static let maxCardsHeight: CGFloat = 300
    private static let cardPadding: CGFloat = 10
    private static let cardSpacing: CGFloat = 6

    let review: NotchReview
    let toggle: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bean").font(NotchStyle.font(12, .semibold)).foregroundStyle(NotchStyle.dim)
            Text(review.text)
                .font(.system(size: MessageBody.textSize))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.vertical) {
                VStack(spacing: Self.cardSpacing) {
                    ForEach(review.cards) { card in CardRow(card: card) { toggle(card.id) } }
                }
            }
            .scrollIndicators(.never)
            .frame(height: min(Self.cardsHeight(review.cards), Self.maxCardsHeight))
            HStack(spacing: 8) {
                Spacer()
                ReviewButton(label: "Not now", isPrimary: false, action: review.onDismiss)
                let chosen = review.cards.filter(\.isOn).map(\.id)
                ReviewButton(label: chosen.count > 1 ? "\(review.confirm) (\(chosen.count))" : review.confirm, isPrimary: true) {
                    review.onConfirm(chosen)
                }
                .disabled(chosen.isEmpty)
                .opacity(chosen.isEmpty ? 0.4 : 1)
                .accessibilityLabel(review.confirm)
            }
            .padding(.top, 6)
        }
    }

    static func height(_ review: NotchReview) -> CGFloat {
        let text = NotchStyle.height(of: review.text, size: MessageBody.textSize, width: width - 40)
        return 16 + 8 + text + 8 + min(cardsHeight(review.cards), maxCardsHeight) + 8 + 6 + 28
    }

    static func cardsHeight(_ cards: [NotchCard]) -> CGFloat {
        cards.map(cardHeight).reduce(0, +) + CGFloat(max(cards.count - 1, 0)) * cardSpacing
    }

    private static func cardHeight(_ card: NotchCard) -> CGFloat {
        let textWidth = width - 40 - 2 * cardPadding - 18 - 10 - (card.symbol == nil ? 0 : 26)
        let detail = card.detail.isEmpty ? 0 : 2 + NotchStyle.height(of: card.detail, size: 12, width: textWidth)
        let quote = card.quote.map { 3 + min(NotchStyle.height(of: "“\($0)”", size: 11, width: textWidth), 28) } ?? 0
        return 2 * cardPadding + 17 + detail + quote
    }

    private struct CardRow: View {
        let card: NotchCard
        let toggle: () -> Void

        var body: some View {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: card.isOn ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(card.isOn ? NotchStyle.accent : .white.opacity(0.3))
                        .frame(width: 18)
                        .contentTransition(.symbolEffect(.replace))
                    if let symbol = card.symbol {
                        Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(NotchStyle.dim).frame(width: 16).padding(.top, 1)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.title).font(NotchStyle.font(13, .semibold)).foregroundStyle(.white)
                        if !card.detail.isEmpty {
                            Text(card.detail).font(.system(size: 12)).foregroundStyle(NotchStyle.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let quote = card.quote {
                            Text("“\(quote)”").font(.system(size: 11).italic()).foregroundStyle(.white.opacity(0.42))
                                .lineLimit(2).padding(.top, 1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(ReviewBody.cardPadding)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(card.isOn ? NotchStyle.accent.opacity(0.10) : .white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(card.isOn ? NotchStyle.accent.opacity(0.35) : .clear, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(card.title)
            .accessibilityAddTraits(card.isOn ? .isSelected : [])
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: card.isOn)
        }
    }

    private struct ReviewButton: View {
        let label: String
        let isPrimary: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(label)
                    .font(NotchStyle.font(13, .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .foregroundStyle(isPrimary ? .black : .white)
                    .background(Capsule().fill(isPrimary ? NotchStyle.accent : .white.opacity(0.14)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

struct RecordingDot: View {
    var body: some View {
        TimelineView(.animation) { context in
            let s = 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 2)
            Circle()
                .fill(Color(red: 1, green: 0.27, blue: 0.23))
                .frame(width: 6, height: 6)
                .opacity(0.65 + 0.35 * s)
        }
        .frame(width: 6, height: 6)
        .accessibilityElement()
        .accessibilityLabel("Recording call")
    }
}
