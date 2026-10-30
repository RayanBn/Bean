import SwiftUI

struct PerchAsk: Equatable {
    struct Choice: Equatable, Identifiable {
        let title: String
        let answer: String
        var id: String { title }
    }

    let need: UUID
    let text: String
    let choices: [Choice]

    init(_ need: AgentNeed) {
        self.need = need.id
        if need.consent != nil, need.options.count == 2 {
            text = AgentStrings.local("Listen to this call?")
            choices = [Choice(title: AgentStrings.local("Yes"), answer: need.options[0]), Choice(title: AgentStrings.local("Not now"), answer: need.options[1])]
        } else {
            text = need.question
            let short = need.options.filter { $0.count <= 18 }
            choices = short.count == need.options.count ? need.options.prefix(2).map { Choice(title: $0, answer: $0) } : []
        }
    }
}

struct PerchBubble: View {
    let ask: PerchAsk
    let answer: (String) -> Void
    let details: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ask.text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(ask.choices) { choice in
                    Button(choice.title) { answer(choice.answer) }
                        .fixedSize()
                        .accessibilityIdentifier("perch-answer-\(choice.title)")
                }
                Spacer(minLength: 0)
                Button(AgentStrings.local("Details"), action: details)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityIdentifier("perch-details")
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(width: PerchBubble.width, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.separator))
        .padding(12)
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }

    static let width: CGFloat = 230
}
