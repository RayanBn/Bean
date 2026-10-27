import SwiftUI

struct OffLimitsEditor: View {
    @Binding var items: [String]
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !items.isEmpty {
                Flow(spacing: 4) {
                    ForEach(items, id: \.self) { item in chip(item) }
                }
            }
            TextField("Add a site, app or name", text: $draft)
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .onSubmit(add)
        }
        .padding(.horizontal, 10).padding(.bottom, 6)
    }

    private func chip(_ item: String) -> some View {
        HStack(spacing: 3) {
            Text(item).font(.system(size: 11)).lineLimit(1)
            Button {
                withAnimation(.snappy(duration: 0.15)) { items.removeAll { $0 == item } }
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(item)")
        }
        .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    private func add() {
        let item = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !item.isEmpty, !items.contains(where: { $0.caseInsensitiveCompare(item) == .orderedSame }) else { return }
        withAnimation(.snappy(duration: 0.15)) { items.append(item) }
    }
}

private struct Flow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0; var y: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row(y: rows[rows.count - 1].y + rows[rows.count - 1].height + spacing))
            }
            let gap = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
