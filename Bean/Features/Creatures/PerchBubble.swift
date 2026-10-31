import SwiftUI

struct PerchLine: View {
    let text: String
    static let seconds: TimeInterval = 6
    static let width: CGFloat = 300

    var body: some View {
        Text(AgentStrings.shown(text))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: min(NotchStyle.width(of: AgentStrings.shown(text), size: 12, weight: .medium) + 2, Self.width), alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.separator))
            .padding(12)
            .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
            .accessibilityIdentifier("perch-line")
    }
}
