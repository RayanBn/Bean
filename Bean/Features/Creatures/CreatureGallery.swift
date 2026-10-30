import AppKit
import SwiftUI

enum CreatureGallery {
    static let notch = CGSize(width: 185, height: 32)
    static let hues = [0.47, 0.6, 0.11]

    @MainActor
    static func runIfRequested() -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-creature-gallery"), CommandLine.arguments.indices.contains(index + 1) else { return false }
        let sheet = VStack(alignment: .leading, spacing: 26) {
            row("The page") { page() }
            row("The page, on Bean") { page(selected: 3) }
            HStack(alignment: .top, spacing: 24) {
                row("Notch: idle") { island(crew: [member(0), member(1)]) }
                row("Notch: working") { island(crew: [member(0, .working), member(1)]) }
                row("Notch: stuck") { island(crew: [member(2, .needsYou), member(1)], calling: CreaturePalette(hue: hues[2]).body) }
            }
            HStack(alignment: .top, spacing: 24) {
                row("Create: empty") { island(crew: [member(1)], phase: .create) }
                row("Create: mission and scope") { island(crew: [member(1)], phase: .create, draft: "Review my PRs and mark them ready when they are good", scope: ["bean-demo-prs"], suggest: ["acme/api"]) }
            }
            HStack(alignment: .top, spacing: 24) {
                row("Drag: take care of this") { drag() }
                row("At work on a window") { perched(.working) }
                row("Stuck on a window") { perched(.needsYou) }
            }
        }
        .padding(28)
        .background(LinearGradient(colors: [Color(red: 0.36, green: 0.4, blue: 0.62), Color(red: 0.62, green: 0.44, blue: 0.42)], startPoint: .top, endPoint: .bottom))
        .environment(\.staticRender, true)
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { exit(1) }
        try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        print("wrote \(CommandLine.arguments[index + 1])")
        exit(0)
    }

    private static func row(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.8))
            content()
        }
    }

    private static func look(_ i: Int) -> Agent.Look { Agent.Look(hue: hues[i], accessory: "none") }

    private static func member(_ i: Int, _ mood: AgentActivity.Mood = .idle) -> CrewMember {
        CrewMember(id: UUID(), name: ["Juno", "Pip", "Kit"][i], look: look(i), mood: mood)
    }

    private static func agent(_ name: String, _ look: Agent.Look, _ role: String, id: UUID = UUID()) -> Agent {
        Agent(id: id, name: name, role: role, personality: "", look: look, connectors: [], attachment: nil, createdAt: Date())
    }

    private static func page(selected: Int = 1) -> some View {
        let agents = [agent("Kit", look(2), "Keeps the infra tidy."), agent("Juno", look(0), "Starts tickets."), agent("Pip", look(1), "Reviews PRs."),
                      agent("Bean", .pearl, "Your main agent. It drives your Claude sessions while you are away.", id: Agent.beanID)]
        let now = Date()
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        var feed = PageFeed()
        feed.credits = AgentWorker.Credits(left: "$12.40", estimate: true)
        feed.doing = [agents[1].id: "Claude session on LIN-42 is writing the retry fix", agents[2].id: "Reviewing PR #7"]
        feed.missions = [
            agents[0].id: AgentMission(mission: "Keep the infra dependencies up to date.", scope: ["acme/api"], allowed: []),
            agents[1].id: AgentMission(mission: "Start Linear tickets as Claude sessions and carry them to a PR.", scope: ["bean-demo-prs", "Personal Linear"], allowed: []),
            agents[2].id: AgentMission(mission: "Review PRs and mark them ready when they are good.", scope: ["bean-demo-prs"], allowed: []),
        ]
        feed.journal[agents[1].id] = [
            JournalEntry(at: at(3), kind: .action, did: "Moved LIN-41 to In Review. PR #7 is open and its checks pass.", why: "The session finished and the tests pass.", link: "https://github.com/RayanBn/bean-demo-prs/pull/7", undo: "Move it back", undoCommand: "x"),
            JournalEntry(at: at(22), kind: .session, did: "Accepted the session's fix for LIN-41.", why: "It matches the ticket.", result: "12 tests passed"),
            JournalEntry(at: at(40), kind: .refused, did: "Did not push to main.", why: "Merging is off for this agent."),
            JournalEntry(at: at(54), kind: .action, did: "Started LIN-42 and LIN-41, the two oldest tickets labelled bug.", why: ""),
        ]
        feed.journal[Agent.beanID] = [
            JournalEntry(at: at(6), kind: .session, did: "Answered \u{201C}Keep the old API?\u{201D}: no, the ticket asks to replace it.", why: "You refused the same thing on Tuesday."),
            JournalEntry(at: at(31), kind: .session, did: "Refused the session's plan to rewrite the store.", why: "Too large for this task."),
        ]
        feed.sessions[Agent.beanID] = [
            AgentWorker.DrivenSession(id: "a", title: "Fix webhook retries", state: "Waiting on a test run"),
            AgentWorker.DrivenSession(id: "b", title: "Agents page", state: "Working"),
        ]
        let activity: [UUID: AgentActivity] = [agents[0].id: AgentActivity(mood: .needsYou, bubble: "Out of scope: acme/infra"), agents[1].id: AgentActivity(mood: .working), agents[2].id: AgentActivity(mood: .working)]
        return AgentsPage(agents: agents, activity: activity, feed: feed, selected: agents[selected].id, actions: PageActions())
            .frame(width: 960, height: 620)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private static func island(crew: [CrewMember], phase: NotchPhase = .rest, calling: Color? = nil, draft: String = "", scope: [String] = [], suggest: [String] = []) -> some View {
        let model = NotchModel()
        model.notchSize = notch
        model.crew = crew
        model.bean = CrewMember(id: Agent.beanID, name: "Bean", look: .pearl, mood: .idle)
        model.phase = phase
        model.calling = calling
        model.draft = draft
        model.scope = scope
        model.scopeSuggestions = suggest
        model.ideas = [AgentIdea(label: "Keeps PRs moving", request: "a"), AgentIdea(label: "Remembers meetings", request: "bb")]
        let ear = phase == .create ? 0 : max(CrewLayout.beanEar(notch), CrewLayout.ear(count: crew.count, shown: model.shownCount, plus: model.showsPlus, notch: notch))
        let rows: CGFloat = draft.isEmpty ? 11 + 24 : 2 * (9 + 24)
        model.shape = phase == .create
            ? .init(width: NotchController.createWidth + 28, height: notch.height + 8 + 26 + rows + 16, radius: 24, flare: 14)
            : .init(width: notch.width + 2 * ear + 12, height: notch.height, radius: 10, flare: 6)
        model.contentSize = CGSize(width: model.shape.width, height: model.shape.height)
        return NotchView(model: model, onTap: {}, onCrew: { _, _ in }, onPlus: {}, onSubmit: { _ in }, onCancel: {})
            .frame(width: phase == .create ? 500 : 320, height: phase == .create ? 150 : 60)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private static func drag() -> some View {
        let model = DragStageModel()
        model.look = look(1)
        model.visible = true
        model.size = DragStage.heldSize * 0.8
        model.limbs = 1
        model.grip = CGPoint(x: 90, y: 40)
        model.highlight = CGRect(x: 20, y: 120, width: 300, height: 60)
        model.motion = CreatureMotion(time: 0.3, swing: 0.1, flail: 0.4)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.13)).frame(width: 300, height: 60).position(x: 170, y: 150)
            DragStageView(model: model)
        }
        .frame(width: 340, height: 180)
    }

    private static func perched(_ mood: AgentActivity.Mood) -> some View {
        let model = PerchModel()
        model.name = "Pip"
        model.look = look(1)
        model.mood = mood
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.14)).frame(width: 260, height: 40).offset(y: Perch.seatRow)
            PerchView(model: model, onDragStart: {}, onRelease: { _ in })
        }
        .frame(width: 280, height: Perch.seatRow + 40, alignment: .top)
    }
}
