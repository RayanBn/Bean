import AppKit
import SwiftUI

struct PaneSpec: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: BoardWidget
    var agent: UUID
    var param: String?
}

enum PaneZone { case left, right, top, bottom, center }

// Panes tile the whole space as a tree of splits, as VS Code's editor groups do.
indirect enum PaneNode: Codable, Equatable {
    case pane(PaneSpec)
    case split(id: UUID, vertical: Bool, ratio: Double, first: PaneNode, second: PaneNode)

    var panes: [PaneSpec] {
        switch self {
        case .pane(let spec): [spec]
        case .split(_, _, _, let first, let second): first.panes + second.panes
        }
    }

    func removing(_ id: UUID) -> PaneNode? {
        switch self {
        case .pane(let spec): return spec.id == id ? nil : self
        case .split(let split, let vertical, let ratio, let first, let second):
            guard let left = first.removing(id) else { return second }
            guard let right = second.removing(id) else { return first }
            return .split(id: split, vertical: vertical, ratio: ratio, first: left, second: right)
        }
    }

    func placing(_ new: PaneSpec, at target: UUID, _ zone: PaneZone) -> PaneNode {
        switch self {
        case .pane(let spec):
            guard spec.id == target else { return self }
            switch zone {
            case .center: return .pane(new)
            case .left: return .split(id: UUID(), vertical: false, ratio: 0.5, first: .pane(new), second: self)
            case .right: return .split(id: UUID(), vertical: false, ratio: 0.5, first: self, second: .pane(new))
            case .top: return .split(id: UUID(), vertical: true, ratio: 0.5, first: .pane(new), second: self)
            case .bottom: return .split(id: UUID(), vertical: true, ratio: 0.5, first: self, second: .pane(new))
            }
        case .split(let split, let vertical, let ratio, let first, let second):
            return .split(id: split, vertical: vertical, ratio: ratio, first: first.placing(new, at: target, zone), second: second.placing(new, at: target, zone))
        }
    }

    func updating(_ id: UUID, _ change: (inout PaneSpec) -> Void) -> PaneNode {
        switch self {
        case .pane(var spec):
            if spec.id == id { change(&spec) }
            return .pane(spec)
        case .split(let split, let vertical, let ratio, let first, let second):
            return .split(id: split, vertical: vertical, ratio: ratio, first: first.updating(id, change), second: second.updating(id, change))
        }
    }

    func resizing(_ id: UUID, ratio new: Double) -> PaneNode {
        switch self {
        case .pane: return self
        case .split(let split, let vertical, let ratio, let first, let second):
            return .split(id: split, vertical: vertical, ratio: split == id ? new : ratio, first: first.resizing(id, ratio: new), second: second.resizing(id, ratio: new))
        }
    }

    func ratio(of id: UUID) -> Double? {
        switch self {
        case .pane: return nil
        case .split(let split, _, let ratio, let first, let second):
            return split == id ? ratio : first.ratio(of: id) ?? second.ratio(of: id)
        }
    }

    func swapping(_ a: PaneSpec, with b: PaneSpec) -> PaneNode {
        switch self {
        case .pane(let spec): return .pane(spec.id == a.id ? b : spec.id == b.id ? a : spec)
        case .split(let split, let vertical, let ratio, let first, let second):
            return .split(id: split, vertical: vertical, ratio: ratio, first: first.swapping(a, with: b), second: second.swapping(a, with: b))
        }
    }
}

@MainActor
final class PaneStore: ObservableObject {
    static let shared = PaneStore()
    private static let file = JSONLog.directory.appendingPathComponent("panes.json")

    @Published private var saved: [UUID: PaneNode]
    private var started: [UUID: PaneNode] = [:]

    private init() {
        saved = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode([UUID: PaneNode].self, from: $0) } ?? [:]
    }

    func layout(for agent: UUID) -> PaneNode {
        saved[agent] ?? started[agent] ?? .pane(PaneSpec(kind: .picker, agent: agent))
    }

    // Who has never arranged a board still sees several widgets, so the page shows that it is made of them.
    func begin(_ agent: UUID, with first: @autoclosure () -> PaneNode) {
        if saved[agent] == nil, started[agent] == nil { started[agent] = first() }
    }

    func reset(_ agent: UUID) {
        saved[agent] = nil
        started[agent] = nil
        write()
    }

    func set(_ node: PaneNode, for agent: UUID, keep: Bool = true) {
        saved[agent] = node
        if keep { write() }
    }

    func write() {
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: Self.file, options: .atomic)
    }

    // A new pane fills an empty one, or takes half of the largest pane along its longer side.
    func add(_ spec: PaneSpec, for agent: UUID, frames: [UUID: CGRect]) {
        let node = layout(for: agent)
        if let empty = node.panes.first(where: { $0.kind == .picker }) { return set(node.placing(spec, at: empty.id, .center), for: agent) }
        let target = node.panes.max { (frames[$0.id]?.area ?? 0) < (frames[$1.id]?.area ?? 0) }
        guard let target else { return set(.pane(spec), for: agent) }
        let frame = frames[target.id] ?? .zero
        set(node.placing(spec, at: target.id, frame.height > frame.width ? .bottom : .right), for: agent)
    }

    func close(_ id: UUID, for agent: UUID) {
        set(layout(for: agent).removing(id) ?? .pane(PaneSpec(kind: .picker, agent: agent)), for: agent)
    }

    func move(_ id: UUID, onto target: UUID, _ zone: PaneZone, for agent: UUID) {
        let node = layout(for: agent)
        guard id != target, let moved = node.panes.first(where: { $0.id == id }), let other = node.panes.first(where: { $0.id == target }) else { return }
        if zone == .center {
            set(node.swapping(moved, with: other), for: agent)
        } else if let rest = node.removing(id) {
            set(rest.placing(moved, at: target, zone), for: agent)
        }
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}

struct PaneBoard<Content: View>: View {
    let agent: UUID
    @ObservedObject var store: PaneStore
    @Binding var frames: [UUID: CGRect]
    @ViewBuilder let content: (PaneSpec, _ grab: AnyGesture<Void>) -> Content

    @State private var moving: UUID?
    @State private var over: (id: UUID, zone: PaneZone)?

    var body: some View {
        node(store.layout(for: agent))
            .coordinateSpace(name: "panes")
            .overlay(alignment: .topLeading) {
                if let over, let frame = frames[over.id] {
                    let rect = Self.zoneRect(frame, over.zone)
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
            }
    }

    private func node(_ node: PaneNode) -> AnyView {
        switch node {
        case .pane(let spec):
            return AnyView(content(spec, AnyGesture(grab(spec).map { _ in () }))
                .opacity(moving == spec.id ? 0.55 : 1)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("panes")) } action: { frames[spec.id] = $0 })
        case .split(let id, let vertical, let ratio, let first, let second):
            return AnyView(GeometryReader { proxy in
                let total = vertical ? proxy.size.height : proxy.size.width
                let lead = max(0, total * ratio - 0.5)
                if vertical {
                    VStack(spacing: 0) {
                        self.node(first).frame(height: lead)
                        divider(id, vertical: true, total: total)
                        self.node(second).frame(maxHeight: .infinity)
                    }
                } else {
                    HStack(spacing: 0) {
                        self.node(first).frame(width: lead)
                        divider(id, vertical: false, total: total)
                        self.node(second).frame(maxWidth: .infinity)
                    }
                }
            })
        }
    }

    private func divider(_ id: UUID, vertical: Bool, total: CGFloat) -> some View {
        PaneDivider(vertical: vertical) { change, ended in
            let tree = store.layout(for: agent)
            guard let ratio = tree.ratio(of: id), total > 0 else { return }
            let least = (vertical ? 100 : 180) / total
            store.set(tree.resizing(id, ratio: min(1 - least, max(least, ratio + change / total))), for: agent, keep: ended)
        } equalize: {
            store.set(store.layout(for: agent).resizing(id, ratio: 0.5), for: agent)
        }
    }

    private func grab(_ spec: PaneSpec) -> some SwiftUI.Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("panes"))
            .onChanged { value in
                moving = spec.id
                over = Self.target(at: value.location, frames: frames, except: spec.id)
            }
            .onEnded { _ in
                if let over { store.move(spec.id, onto: over.id, over.zone, for: agent) }
                moving = nil
                over = nil
            }
    }

    private static func target(at point: CGPoint, frames: [UUID: CGRect], except: UUID) -> (id: UUID, zone: PaneZone)? {
        guard let (id, frame) = frames.first(where: { $0.value.contains(point) }), id != except else { return nil }
        let x = (point.x - frame.minX) / max(frame.width, 1), y = (point.y - frame.minY) / max(frame.height, 1)
        if x < 0.25 { return (id, .left) }
        if x > 0.75 { return (id, .right) }
        if y < 0.25 { return (id, .top) }
        if y > 0.75 { return (id, .bottom) }
        return (id, .center)
    }

    private static func zoneRect(_ frame: CGRect, _ zone: PaneZone) -> CGRect {
        switch zone {
        case .center: frame
        case .left: CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right: CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .top: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .bottom: CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        }
    }
}

private struct PaneDivider: View {
    let vertical: Bool
    let change: (CGFloat, Bool) -> Void
    let equalize: () -> Void
    @State private var last: CGFloat = 0
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        Color.clear
            .frame(width: vertical ? nil : 6, height: vertical ? 6 : nil)
            .overlay {
                Capsule()
                    .fill(hovering || dragging ? Color.accentColor : .clear)
                    .frame(width: vertical ? 36 : 3, height: vertical ? 3 : 36)
                    .animation(.easeOut(duration: 0.12), value: hovering)
            }
            .overlay {
                Color.clear
                    .frame(width: vertical ? nil : 11, height: vertical ? 11 : nil)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        if inside { (vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push() } else { NSCursor.pop() }
                    }
                    .onTapGesture(count: 2, perform: equalize)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            dragging = true
                            let now = vertical ? value.translation.height : value.translation.width
                            change(now - last, false)
                            last = now
                        }
                        .onEnded { _ in
                            change(0, true)
                            last = 0
                            dragging = false
                        })
                    .help("Drag to resize. Double-click to make both sides even.")
                    .accessibilityIdentifier("page-pane-divider")
            }
    }
}

struct PaneHeader<Accessory: View>: View {
    let title: String
    let icon: String
    var keepsAccessory = false
    let grab: AnyGesture<Void>
    let close: () -> Void
    @ViewBuilder let accessory: () -> Accessory
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal").font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(title).font(Font.widgetBody.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
            .gesture(grab)
            .help("Drag to move this widget")
            .accessibilityIdentifier("page-pane-grab")
            if hovering || keepsAccessory { accessory() }
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .medium)).frame(width: 16, height: 16).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Close this widget")
                .accessibilityLabel("Close")
                .accessibilityIdentifier("page-pane-close")
        }
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(height: 28)
        .onHover { hovering = $0 }
        .overlay(alignment: .bottom) { Divider() }
    }
}
