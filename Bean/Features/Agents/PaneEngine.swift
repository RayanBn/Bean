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
        if let saved = saved[agent] { return saved }
        if let started = started[agent] { return started }
        let first = PaneNode.pane(PaneSpec(kind: .action, agent: agent))
        started[agent] = first
        return first
    }

    func set(_ node: PaneNode, for agent: UUID, keep: Bool = true) {
        saved[agent] = node
        if keep { write() }
    }

    func write() {
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: Self.file, options: .atomic)
    }

    // A new pane takes half of the largest pane, along its longer side.
    func add(_ spec: PaneSpec, for agent: UUID, frames: [UUID: CGRect]) {
        let node = layout(for: agent)
        let target = node.panes.max { (frames[$0.id]?.area ?? 0) < (frames[$1.id]?.area ?? 0) }
        guard let target else { return set(.pane(spec), for: agent) }
        let frame = frames[target.id] ?? .zero
        set(node.placing(spec, at: target.id, frame.height > frame.width ? .bottom : .right), for: agent)
    }

    func close(_ id: UUID, for agent: UUID) {
        set(layout(for: agent).removing(id) ?? .pane(PaneSpec(kind: .action, agent: agent)), for: agent)
    }

    func move(_ id: UUID, onto target: UUID, _ zone: PaneZone, for agent: UUID) {
        let node = layout(for: agent)
        guard id != target, let moved = node.panes.first(where: { $0.id == id }), let other = node.panes.first(where: { $0.id == target }) else { return }
        if zone == .center {
            let swapped = node.placing(PaneSpec(id: UUID(), kind: other.kind, agent: other.agent, param: other.param), at: id, .center)
            set(swapped.placing(moved, at: target, .center), for: agent)
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
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.18))
                        .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1))
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
    @State private var last: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: vertical ? nil : 1, height: vertical ? 1 : nil)
            .overlay {
                Color.clear
                    .frame(width: vertical ? nil : 9, height: vertical ? 9 : nil)
                    .contentShape(Rectangle())
                    .onHover { if $0 { (vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let now = vertical ? value.translation.height : value.translation.width
                            change(now - last, false)
                            last = now
                        }
                        .onEnded { _ in
                            change(0, true)
                            last = 0
                        })
            }
    }
}

struct PaneHeader<Accessory: View>: View {
    let title: String
    let icon: String
    let grab: AnyGesture<Void>
    let close: () -> Void
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(title).font(Font.widgetSmall.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .gesture(grab)
            .accessibilityIdentifier("page-pane-grab")
            accessory()
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .medium)) }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel(AgentStrings.shown("Close"))
                .accessibilityIdentifier("page-pane-close")
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .overlay(alignment: .bottom) { Divider() }
    }
}
