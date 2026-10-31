import AppKit
import SwiftUI

struct WidgetSpec: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: BoardWidget
    var agent: UUID
    var session: String?
    var param: String?
    var x: Int
    var y: Int
    var w: Int
    var h: Int

    func overlaps(_ other: WidgetSpec) -> Bool {
        x < other.x + other.w && other.x < x + w && y < other.y + other.h && other.y < y + h
    }
}

enum BoardGrid {
    static let columns = 12
    static let rowHeight: CGFloat = 40
    static let headerHeight: CGFloat = 32
    static let gap: CGFloat = 8
    static let minWidth = 2
    static let minHeight = 3

    static func cellWidth(in width: CGFloat) -> CGFloat { max(40, (width - gap) / CGFloat(columns)) }

    static func rect(_ spec: WidgetSpec, in width: CGFloat) -> CGRect {
        let cell = cellWidth(in: width)
        return CGRect(x: gap + CGFloat(spec.x) * cell, y: gap + CGFloat(spec.y) * rowHeight, width: CGFloat(spec.w) * cell - gap, height: CGFloat(spec.h) * rowHeight - gap)
    }

    // As in Grafana's dashboards: what the moved panel lands on moves down, then every panel rises as far as it can.
    static func placing(_ moved: WidgetSpec, among widgets: [WidgetSpec]) -> [WidgetSpec] {
        var settled = [moved]
        for var widget in widgets.filter({ $0.id != moved.id }).sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            while let hit = settled.first(where: { $0.overlaps(widget) }) { widget.y = hit.y + hit.h }
            settled.append(widget)
        }
        return compacted(settled)
    }

    // A column left empty by a hidden widget goes to the columns that remain.
    static func filled(_ widgets: [WidgetSpec]) -> [WidgetSpec] {
        let edge = widgets.map { $0.x + $0.w }.max() ?? columns
        guard edge > 0, edge < columns else { return widgets }
        return widgets.map { widget in
            var wider = widget
            wider.x = widget.x * columns / edge
            wider.w = (widget.x + widget.w) * columns / edge - wider.x
            return wider
        }
    }

    static func compacted(_ widgets: [WidgetSpec]) -> [WidgetSpec] {
        var done: [WidgetSpec] = []
        for var widget in widgets.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            while widget.y > 0 {
                var higher = widget
                higher.y -= 1
                if done.contains(where: { $0.overlaps(higher) }) { break }
                widget = higher
            }
            done.append(widget)
        }
        return done
    }
}

@MainActor
final class BoardStore: ObservableObject {
    static let shared = BoardStore()
    static let allBoard = "all"
    private static let file = JSONLog.directory.appendingPathComponent("boards.json")

    @Published private(set) var saved: [String: [WidgetSpec]]
    private var defaults: [String: [WidgetSpec]] = [:]

    private init() {
        saved = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode([String: [WidgetSpec]].self, from: $0) } ?? [:]
    }

    func widgets(board: String, make: () -> (key: String, widgets: [WidgetSpec])) -> [WidgetSpec] {
        if let saved = saved[board] { return saved }
        let made = make()
        let key = "\(board) \(made.key)"
        if let known = defaults[key] { return known }
        defaults[key] = made.widgets
        return made.widgets
    }

    func save(_ widgets: [WidgetSpec], board: String) {
        saved[board] = widgets
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: Self.file, options: .atomic)
    }

    func reset(board: String) {
        saved[board] = nil
        try? JSONEncoder().encode(saved).write(to: Self.file, options: .atomic)
    }
}

struct BoardView<Content: View>: View {
    let widgets: [WidgetSpec]
    let save: ([WidgetSpec]) -> Void
    @ViewBuilder let content: (WidgetSpec) -> Content

    private enum Motion: Equatable {
        case move, right, bottom, corner
    }

    @State private var moving: UUID?
    @State private var motion = Motion.move
    @State private var travel = CGSize.zero

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: proxy.size.width, height: height(in: proxy.size))
                    if let shadow {
                        let rect = BoardGrid.rect(shadow, in: proxy.size.width)
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                    ForEach(widgets) { spec in
                        tile(spec, width: proxy.size.width)
                    }
                }
            }
        }
        .accessibilityIdentifier("page-board")
    }

    private func height(in size: CGSize) -> CGFloat {
        let rows = (widgets + (shadow.map { [$0] } ?? [])).map { $0.y + $0.h }.max() ?? 0
        return max(size.height, CGFloat(rows + 1) * BoardGrid.rowHeight)
    }

    private func tile(_ spec: WidgetSpec, width: CGFloat) -> some View {
        let rect = BoardGrid.rect(spec, in: width)
        let active = moving == spec.id
        let shift = active && motion == .move ? travel : .zero
        let grow = active && motion != .move ? CGSize(width: motion == .bottom ? 0 : travel.width, height: motion == .right ? 0 : travel.height) : .zero
        return content(spec)
            .frame(width: max(120, rect.width + grow.width), height: max(100, rect.height + grow.height))
            .overlay(alignment: .top) {
                Color.clear.frame(height: BoardGrid.headerHeight).padding(.trailing, 64)
                    .contentShape(Rectangle())
                    .gesture(drag(spec, .move, width: width))
                    .onHover { if $0 { NSCursor.openHand.push() } else { NSCursor.pop() } }
                    .accessibilityIdentifier("page-widget-move-\(spec.kind.rawValue)")
            }
            .overlay(alignment: .trailing) { handle(spec, .right, width: width, cursor: .resizeLeftRight).frame(width: 9).padding(.vertical, 14).offset(x: 5) }
            .overlay(alignment: .bottom) { handle(spec, .bottom, width: width, cursor: .resizeUpDown).frame(height: 9).padding(.horizontal, 14).offset(y: 5) }
            .overlay(alignment: .bottomTrailing) { handle(spec, .corner, width: width, cursor: .crosshair).frame(width: 15, height: 15).offset(x: 5, y: 5) }
            .shadow(color: .black.opacity(active ? 0.3 : 0), radius: active ? 14 : 0, y: active ? 5 : 0)
            .offset(x: rect.minX + shift.width, y: rect.minY + shift.height)
            .zIndex(active ? 10 : 0)
    }

    private func handle(_ spec: WidgetSpec, _ kind: Motion, width: CGFloat, cursor: NSCursor) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(drag(spec, kind, width: width))
            .onHover { if $0 { cursor.push() } else { NSCursor.pop() } }
            .accessibilityIdentifier("page-widget-resize-\(spec.kind.rawValue)")
    }

    private func drag(_ spec: WidgetSpec, _ kind: Motion, width: CGFloat) -> some SwiftUI.Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                moving = spec.id
                motion = kind
                travel = value.translation
                cellWidth = BoardGrid.cellWidth(in: width)
            }
            .onEnded { _ in
                if let result = shadow { save(BoardGrid.placing(result, among: widgets)) }
                moving = nil
                travel = .zero
            }
    }

    @State private var cellWidth: CGFloat = 80

    private var shadow: WidgetSpec? {
        guard let moving, var spec = widgets.first(where: { $0.id == moving }) else { return nil }
        let across = Int((travel.width / cellWidth).rounded())
        let down = Int((travel.height / BoardGrid.rowHeight).rounded())
        switch motion {
        case .move:
            spec.x = min(max(0, spec.x + across), BoardGrid.columns - spec.w)
            spec.y = max(0, spec.y + down)
        case .right:
            spec.w = min(max(BoardGrid.minWidth, spec.w + across), BoardGrid.columns - spec.x)
        case .bottom:
            spec.h = max(BoardGrid.minHeight, spec.h + down)
        case .corner:
            spec.w = min(max(BoardGrid.minWidth, spec.w + across), BoardGrid.columns - spec.x)
            spec.h = max(BoardGrid.minHeight, spec.h + down)
        }
        return spec
    }
}

struct WidgetChrome<Accessory: View, Content: View>: View {
    let title: String
    let icon: String
    var agent: Agent?
    let close: () -> Void
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal").font(.system(size: 9)).foregroundStyle(.tertiary)
                if let agent { PageDrop(look: agent.look, mood: .idle, size: 13) }
                Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
                Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                accessory()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .medium)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(AgentStrings.shown("Close"))
                    .accessibilityIdentifier("page-widget-close")
            }
            .padding(.horizontal, 10)
            .frame(height: BoardGrid.headerHeight)
            .background(.quaternary.opacity(0.35))
            Divider()
            content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
