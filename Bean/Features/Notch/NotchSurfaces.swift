import AppKit
import SwiftUI

struct NotchActions {
    var plus: () -> Void = {}
    var openPage: (UUID?) -> Void = { _ in }
    var row: (UUID) -> Void = { _ in }
    var crew: (UUID, CrewGesture) -> Void = { _, _ in }
    var submit: (String) -> Void = { _ in }
    var closeCompose: () -> Void = {}
    var answer: (NotchCard, String) -> Void = { _, _ in }
    var hide: (NotchCard) -> Void = { _ in }
    var connect: (NotchCard, String) -> Void = { _, _ in }
    var takeKeys: () -> Void = {}
    var expandLine: (NotchReport) -> Void = { _ in }
    var undo: (NotchReport.Item) -> Void = { _ in }
}

struct NotchSurfaceView: View {
    @ObservedObject var model: NotchModel
    let actions: NotchActions
    var onHeight: (CGFloat) -> Void = { _ in }

    var body: some View {
        Group {
            switch model.surface {
            case .rest:
                EmptyView()
            case .list:
                NotchList(roster: model.roster, actions: actions)
            case .compose:
                NotchCompose(model: model, actions: actions)
            case .making(let sentence):
                NotchMaking(sentence: sentence)
            case .ready(let item):
                NotchReady(item: item, actions: actions)
            case .card(let card, let more):
                NotchCardView(card: card, more: more, actions: actions).id(card.id)
            case .line(let report):
                NotchLineView(report: report, actions: actions)
            case .report(let report):
                NotchReportView(report: report, actions: actions)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(width: NotchController.panelWidth(model.surface), alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geo in
            Color.clear.onChange(of: geo.size.height, initial: true) { _, height in onHeight(height) }
        })
        .foregroundStyle(.white)
    }
}

private struct NotchButton: View {
    let title: String
    var primary = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(AgentStrings.shown(title))
                .font(.system(size: 12, weight: primary ? .semibold : .regular))
                .foregroundStyle(primary ? Color.black : .white)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(primary ? Color.white.opacity(hover ? 0.85 : 1) : Color.white.opacity(hover ? 0.24 : 0.14)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hover = $0 }
        .accessibilityLabel(AgentStrings.shown(title))
    }
}

private struct NotchQuietButton: View {
    let title: String
    var icon: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(AgentStrings.shown(title))
                if let icon { Image(systemName: icon).font(.system(size: 9, weight: .semibold)) }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(hover ? 0.95 : 0.6))
            .padding(.horizontal, 4)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hover = $0 }
        .accessibilityLabel(AgentStrings.shown(title))
    }
}

private struct OpenBean: View {
    var agent: UUID?
    let actions: NotchActions

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            NotchQuietButton(title: "Open Bean", icon: "arrow.up.right") { actions.openPage(agent) }
                .accessibilityIdentifier("notch-open-bean")
        }
    }
}

private struct NotchList: View {
    let roster: [RosterItem]
    let actions: NotchActions
    static let rows = 6

    private var header: String {
        var needs = 0, working = 0
        for item in roster {
            switch PageStatus(item.mood) {
            case .needsYou: needs += 1
            case .working: working += 1
            case .idle: break
            }
        }
        var parts: [String] = []
        if needs > 0 { parts.append(AgentStrings.shown("%d needs you", needs)) }
        if working > 0 { parts.append(AgentStrings.shown("%d working", working)) }
        return parts.isEmpty ? AgentStrings.shown("All quiet") : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(header)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(roster.contains { $0.mood == .needsYou } ? Color.orange : .white.opacity(0.6))
                .padding(.bottom, 4)
                .accessibilityIdentifier("notch-header")
            ForEach(roster.prefix(Self.rows)) { item in
                NotchRow(item: item, actions: actions)
            }
            if roster.count > Self.rows {
                Text(AgentStrings.shown("%d more", roster.count - Self.rows)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).padding(.leading, 34)
            }
            if roster.isEmpty {
                Text(AgentStrings.shown("Nothing on your windows yet. Press + to make an agent.")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            }
            OpenBean(actions: actions).padding(.top, 2)
        }
    }
}

private struct NotchRow: View {
    let item: RosterItem
    let actions: NotchActions
    @State private var hover = false

    private var icon: NSImage? { item.app.flatMap { NSRunningApplication(processIdentifier: $0)?.icon } }

    var body: some View {
        HStack(spacing: 9) {
            CrewHead(member: CrewMember(id: item.id, name: item.name, look: item.look, mood: item.mood == .needsYou ? .idle : item.mood), size: 20, lookAt: nil, onGesture: actions.crew)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name.isEmpty ? AgentStrings.shown("New agent") : item.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(AgentStrings.shown(item.line))
                    .font(.system(size: 11))
                    .foregroundStyle(item.mood == .needsYou ? Color.orange : .white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let place = item.place {
                HStack(spacing: 4) {
                    if let icon { Image(nsImage: icon).resizable().frame(width: 13, height: 13) }
                    Text(place).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.65)).lineLimit(1).truncationMode(.tail)
                }
                .padding(.horizontal, 6)
                .frame(height: 19)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.1)))
                .frame(maxWidth: 150, alignment: .trailing)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: NotchController.rosterRow)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hover ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { actions.row(item.id) }
        .onHover { hover = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notch-row-\(item.name)")
    }
}

private struct NotchCompose: View {
    @ObservedObject var model: NotchModel
    let actions: NotchActions
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TextField("", text: $model.draft, prompt: Text(AgentStrings.shown("What should this agent do?")).foregroundColor(.white.opacity(0.45)))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.12)))
                .onSubmit { actions.submit(model.draft) }
                .onExitCommand(perform: actions.closeCompose)
                .accessibilityIdentifier("notch-compose")
            Text(model.composeError ?? AgentStrings.shown("One sentence. Return makes it, Esc closes."))
                .font(.system(size: 11))
                .foregroundStyle(model.composeError == nil ? .white.opacity(0.55) : Color.orange)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            for _ in 0..<4 where !focused {
                focused = true
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
    }
}

private struct NotchMaking: View {
    let sentence: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).colorScheme(.dark)
            VStack(alignment: .leading, spacing: 1) {
                Text(AgentStrings.shown("Bean is making your agent")).font(.system(size: 12.5, weight: .semibold))
                Text(sentence).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
        }
    }
}

private struct NotchReady: View {
    let item: RosterItem
    let actions: NotchActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Wiggle {
                    CrewHead(member: CrewMember(id: item.id, name: item.name, look: item.look, mood: .idle), size: 42, lookAt: nil, onGesture: actions.crew)
                }
                .frame(width: 50, height: 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AgentStrings.shown("%@ is ready", item.name)).font(.system(size: 14, weight: .semibold))
                    Text(AgentStrings.shown(item.line)).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.65)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 5) {
                Image(systemName: "arrow.down").font(.system(size: 11, weight: .bold))
                Text(AgentStrings.shown("Drag %@ onto any window", item.name)).font(.system(size: 12.5, weight: .semibold))
            }
            .accessibilityIdentifier("notch-drag-hint")
        }
    }
}

private struct Wiggle<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content.phaseAnimator([0.0, 1, -0.8, 0.5, -0.3, 0, 0]) { view, phase in
            view
                .rotationEffect(.degrees(9 * phase), anchor: .top)
                .offset(y: -3 * abs(phase))
        } animation: { phase in
            phase == 0 ? .easeInOut(duration: 0.9) : .easeInOut(duration: 0.11)
        }
    }
}

private struct NotchCardView: View {
    let card: NotchCard
    let more: Int
    let actions: NotchActions
    @State private var reply = ""
    @State private var typing = false
    @FocusState private var focused: Bool

    private var head: CrewMember { CrewMember(id: card.id, name: card.name, look: card.look, mood: .idle) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                let frame = CreatureView.frame(20)
                CreatureView(look: card.look, mood: .idle, size: 20, pose: .peek, limbs: 0)
                    .frame(width: frame.width, height: frame.height)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(AgentStrings.shown(card.title))
                        .font(.system(size: 13.5, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("notch-card-title")
                    if let saw = card.saw {
                        Text(AgentStrings.shown(saw))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("notch-card-saw")
                    }
                }
                Spacer(minLength: 0)
                if more > 0 {
                    Text(AgentStrings.shown("%d more", more))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Capsule().fill(.white.opacity(0.1)))
                        .fixedSize()
                }
            }
            if card.stacked {
                VStack(spacing: 4) {
                    ForEach(Array(card.choices.enumerated()), id: \.element.id) { index, choice in
                        NotchChoiceRow(choice: choice, primary: index == 0) { actions.answer(card, choice.answer) }
                    }
                }
            }
            if card.replies || typing {
                TextField("", text: $reply, prompt: Text(AgentStrings.shown("Your answer")).foregroundColor(.white.opacity(0.45)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($focused)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.12)))
                    .simultaneousGesture(TapGesture().onEnded {
                        actions.takeKeys()
                        focused = true
                    })
                    .onSubmit {
                        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { actions.answer(card, text) }
                    }
                    .accessibilityIdentifier("notch-card-reply")
            }
            HStack(spacing: 6) {
                if !card.stacked {
                    ForEach(Array(card.choices.enumerated()), id: \.element.id) { index, choice in
                        NotchButton(title: choice.title, primary: index == 0) { actions.answer(card, choice.answer) }
                    }
                }
                if let connector = card.connector {
                    NotchButton(title: "Connect", primary: card.choices.isEmpty) { actions.connect(card, connector) }
                }
                if let settings = card.settings {
                    NotchButton(title: "Open Settings", primary: card.choices.isEmpty) { NSWorkspace.shared.open(settings) }
                }
                Spacer(minLength: 0)
                if card.canSkip { NotchQuietButton(title: "Skip") { actions.answer(card, AgentWorker.skipAnswer) } }
                NotchQuietButton(title: "Hide") { actions.hide(card) }
            }
        }
    }
}

private struct NotchChoiceRow: View {
    let choice: NotchCard.Choice
    let primary: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(AgentStrings.shown(choice.title)).font(.system(size: 12.5, weight: primary ? .semibold : .regular))
                if let detail = choice.detail {
                    Text(AgentStrings.shown(detail)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hover ? 0.2 : primary ? 0.14 : 0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(AgentStrings.shown(choice.title))
    }
}

private struct NotchLineView: View {
    let report: NotchReport
    let actions: NotchActions

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: report.isReturn ? "arrow.uturn.backward" : "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(report.isReturn ? Color.white.opacity(0.7) : Color.green)
            Text(AgentStrings.shown(report.line))
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("notch-line")
            Spacer(minLength: 4)
            if let link = report.link {
                NotchQuietButton(title: "Open", icon: "arrow.up.right") { NSWorkspace.shared.open(link) }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { actions.expandLine(report) }
        .accessibilityElement(children: .contain)
    }
}

private struct NotchReportView: View {
    let report: NotchReport
    let actions: NotchActions
    @State private var undone: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(AgentStrings.shown(report.line)).font(.system(size: 13, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("notch-report-line")
                Spacer(minLength: 6)
                if let link = report.link {
                    NotchQuietButton(title: "Open", icon: "arrow.up.right") { NSWorkspace.shared.open(link) }
                }
            }
            .padding(.bottom, 3)
            ForEach(report.items.prefix(6)) { item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: undone.contains(item.id) ? "arrow.uturn.backward" : "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(undone.contains(item.id) ? Color.white.opacity(0.5) : Color.green)
                    Text(AgentStrings.shown(item.text)).font(.system(size: 12)).strikethrough(undone.contains(item.id)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    if item.undo != nil, !undone.contains(item.id) {
                        NotchQuietButton(title: "Undo") {
                            undone.insert(item.id)
                            actions.undo(item)
                        }
                    }
                }
            }
            OpenBean(actions: actions).padding(.top, 2)
        }
    }
}
