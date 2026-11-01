import SwiftUI

// The one list of what can go on a board, in plain words.
struct BoardPicker: View {
    let context: WidgetContext
    let shownOnBoard: [BoardWidget]
    let choose: (BoardWidget, String?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section(String(format: "About %@", context.name)) {
                        ForEach(BoardWidget.forAnAgent) { kind in
                            row(title: kind.title, icon: kind.icon, blurb: kind.blurb(context.name), on: shownOnBoard.contains(kind), id: kind.rawValue) { choose(kind, nil) }
                        }
                        if context.ticket != nil {
                            row(title: WorkService.ticket.title, icon: WorkService.ticket.icon, blurb: "The ticket it works on, from your connected service.", on: false, id: WorkService.ticket.rawValue) { choose(.connector, WorkService.ticket.rawValue) }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Text("Drag a widget by its title to move it. Drag the gap between two widgets to resize them.")
                .font(.widgetSmall).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Font.widgetSmall.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 2)
            content()
        }
    }

    private func row(title: String, icon: String, blurb: String, on: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 24, height: 24)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(Font.widgetBody.weight(.medium))
                    Text(blurb).font(.widgetSmall).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                if on { Image(systemName: "checkmark").font(.widgetSmall).foregroundStyle(.secondary).help("Already on the board. You can add another.") }
            }
            .padding(.vertical, 1).padding(.horizontal, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("page-picker-\(id)")
    }
}
