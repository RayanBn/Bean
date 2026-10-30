import AppKit
import SwiftUI

enum CreatureGallery {
    static let notch = CGSize(width: 185, height: 32)
    static let hues = [0.47, 0.6, 0.11]

    @MainActor
    static func runIfRequested() -> Bool {
        if let index = CommandLine.arguments.firstIndex(of: "--probe-page"), CommandLine.arguments.indices.contains(index + 1) {
            renderPages(to: CommandLine.arguments[index + 1])
            return true
        }
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-creature-gallery"), CommandLine.arguments.indices.contains(index + 1) else { return false }
        let sheet = VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .top, spacing: 24) {
                row("Notch: idle") { island(crew: [member(0), member(1)]) }
                row("Notch: working") { island(crew: [member(0, .working), member(1)]) }
                row("Notch: stuck") { island(crew: [member(2, .needsYou), member(1)], calling: CreaturePalette(hue: hues[2]).body) }
                row("Notch: hover") { hoverList() }
            }
            HStack(alignment: .top, spacing: 24) {
                row("Drag") { drag() }
                row("At work on a window") { perched(.working) }
                row("Stuck on a window") { perched(.needsYou) }
            }
        }
        .padding(28)
        .background(LinearGradient(colors: [Color(red: 0.36, green: 0.4, blue: 0.62), Color(red: 0.62, green: 0.44, blue: 0.42)], startPoint: .top, endPoint: .bottom))
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { exit(1) }
        try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        print("wrote \(CommandLine.arguments[index + 1])")
        exit(0)
    }

    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    @MainActor
    private static func renderPages(to directory: String) {
        let scenes: [(String, NSAppearance.Name, Int, Bool)] = [("linear-light", .aqua, 0, false), ("github-dark", .darkAqua, 1, false), ("bean-light", .aqua, 3, false), ("new-dark", .darkAqua, 0, true)]
        var windows: [NSWindow] = []
        for (i, scene) in scenes.enumerated() {
            let host = NSHostingController(rootView: page(selected: scene.2, creating: scene.3))
            host.sizingOptions = []
            let window = OffscreenWindow(contentRect: NSRect(x: -9000, y: Double(i) * 800, width: 1120, height: 680),
                                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.toolbarStyle = .unified
            window.appearance = NSAppearance(named: scene.1)
            window.contentViewController = host
            window.setContentSize(NSSize(width: 1120, height: 680))
            window.setFrameOrigin(NSPoint(x: -9000, y: Double(i) * 800))
            window.orderBack(nil)
            windows.append(window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            for (window, scene) in zip(windows, scenes) {
                guard window.frame.minX < -8000, let view = window.contentView?.superview,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(directory)/\(scene.0).png"))
                print("wrote \(scene.0)")
            }
            exit(0)
        }
    }

    private static func row(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.8))
            content()
        }
    }

    private static func look(_ i: Int) -> Agent.Look { Agent.Look(hue: hues[i], accessory: "none") }

    private static func member(_ i: Int, _ mood: AgentActivity.Mood = .idle) -> CrewMember {
        CrewMember(id: UUID(), name: ["Linear", "GitHub", "Infra"][i], look: look(i), mood: mood)
    }

    private static func agent(_ name: String, _ look: Agent.Look, _ role: String, id: UUID = UUID()) -> Agent {
        Agent(id: id, name: name, role: role, personality: "", look: look, connectors: [], attachment: nil, createdAt: Date())
    }

    private static func page(selected: Int, creating: Bool) -> some View {
        let linear = agent("Linear", look(0), "Starts tickets as Claude sessions.")
        let github = agent("GitHub", look(1), "Reviews pull requests.")
        let infra = agent("Infra", look(2), "Keeps dependencies current.")
        let bean = agent("Bean", .pearl, "Stands in for you in your Claude sessions.", id: Agent.beanID)
        let agents = [linear, github, infra, bean]
        func at(_ minutes: Double) -> Date { Date().addingTimeInterval(-minutes * 60) }
        var feed = PageFeed()
        feed.credits = AgentWorker.Credits(left: "$110", estimate: true)
        feed.doing = [linear.id: "Claude session on LIN-42", github.id: "Reviewing PR #7"]
        feed.missions = [
            linear.id: AgentMission(mission: "Start Linear tickets as Claude sessions and carry them to a pull request.", scope: ["Personal Linear"], allowed: []),
            github.id: AgentMission(mission: "Review pull requests and mark them ready when they pass.", scope: ["RayanBn/bean-demo-prs"], allowed: []),
            infra.id: AgentMission(mission: "Keep the infrastructure dependencies current.", scope: ["acme/api"], allowed: []),
            bean.id: AgentMission(mission: "Answer my Claude sessions while I am away.", scope: [], allowed: []),
        ]
        feed.journal[linear.id] = [
            JournalEntry(at: at(62), kind: .said, did: "What happened with the bug tickets this morning?", why: ""),
            JournalEntry(at: at(61), kind: .replied, did: "Started the two oldest. LIN-41 is in review; LIN-42 is still running.", why: ""),
            JournalEntry(at: at(40), kind: .action, did: "Moved LIN-41 to In Review", why: "PR #7 is open and its checks pass", link: "https://github.com/RayanBn/bean-demo-prs/pull/7", undo: "Move back", undoCommand: "x"),
            JournalEntry(at: at(20), kind: .session, did: "Started a Claude session on LIN-42", why: "Oldest open ticket labelled bug", link: "https://linear.app/x/issue/LIN-42"),
            JournalEntry(at: at(4), kind: .said, did: "Leave anything touching billing alone.", why: ""),
            JournalEntry(at: at(3), kind: .replied, did: "Understood. Billing tickets are excluded from now on.", why: ""),
        ]
        feed.journal[github.id] = [
            JournalEntry(at: at(50), kind: .action, did: "Reviewed PR #7 and requested one change", why: "The retry loop has no upper bound", link: "https://github.com/RayanBn/bean-demo-prs/pull/7", undo: "Delete the review", undoCommand: "x"),
            JournalEntry(at: at(15), kind: .refused, did: "Did not merge PR #6", why: "Merging is off for this agent"),
            JournalEntry(at: at(8), kind: .said, did: "Why not PR #6?", why: ""),
            JournalEntry(at: at(7), kind: .replied, did: "It passes, but merging is off. Turn on Merge pull requests to let me do it.", why: ""),
        ]
        feed.journal[bean.id] = [
            JournalEntry(at: at(31), kind: .session, did: "Refused the session's plan to rewrite the store", why: "Larger than the task; you rejected the same approach on Tuesday"),
            JournalEntry(at: at(6), kind: .session, did: "Answered \u{201C}Keep the old API?\u{201D}: no", why: "The ticket asks to replace it"),
        ]
        feed.sessions[bean.id] = [
            AgentWorker.DrivenSession(id: "a", title: "RayanBn/bean-demo-prs", state: "On fix-retries, $0.40 so far"),
            AgentWorker.DrivenSession(id: "b", title: "Bean", state: "On agents-page, $1.10 so far"),
        ]
        feed.targets = [
            linear.id: [AgentTarget(kind: .project, name: "Personal Linear")],
            github.id: [AgentTarget(kind: .repo, name: "RayanBn/bean-demo-prs"), AgentTarget(kind: .window, name: "w", app: "Safari", title: "Add a dark theme token · PR #2")],
            bean.id: [AgentTarget(kind: .session, name: "Fix webhook retries"), AgentTarget(kind: .session, name: "Agents page")],
        ]
        feed.connectors = [
            linear.id: [AgentConnectorInfo(name: "Linear", source: .mcp, status: .connected, usedFor: ["Reads and updates tickets"]),
                        AgentConnectorInfo(name: "Claude Code", source: .cli, status: .connected, usedFor: ["Runs coding sessions"])],
            github.id: [AgentConnectorInfo(name: "gh", source: .cli, status: .connected, usedFor: ["Reads and comments on pull requests"]),
                        AgentConnectorInfo(name: "Slack", source: .mcp, status: .toConnect, usedFor: ["Tells the author about a review"])],
            bean.id: [AgentConnectorInfo(name: "Claude Code", source: .cli, status: .connected, usedFor: ["Answers your sessions"])],
        ]
        feed.abilities = [
            linear.id: [AgentAbility(id: "a", title: "Update tickets", detail: "Status, labels and comments", allowed: true, risk: .outward, source: "Linear"),
                        AgentAbility(id: "b", title: "Start coding sessions", detail: "Up to $1 per session", allowed: true, risk: .safe, source: "Claude Code"),
                        AgentAbility(id: "c", title: "Delete tickets", detail: "Removes the ticket for everyone", allowed: false, risk: .irreversible, source: "Linear")],
            github.id: [AgentAbility(id: "a", title: "Read pull requests", detail: "Diffs, checks and comments", allowed: true, risk: .safe, source: "gh"),
                        AgentAbility(id: "b", title: "Comment and review", detail: "Visible to your team", allowed: true, risk: .outward, source: "gh"),
                        AgentAbility(id: "c", title: "Mark pull requests ready", detail: "Visible to your team", allowed: true, risk: .outward, source: "gh"),
                        AgentAbility(id: "d", title: "Merge pull requests", detail: "Off: stops at ready for review", allowed: false, risk: .irreversible, source: "gh")],
        ]
        let activity: [UUID: AgentActivity] = [linear.id: AgentActivity(mood: .working), github.id: AgentActivity(mood: .working), infra.id: AgentActivity(mood: .needsYou, bubble: "Out of scope: acme/infra")]
        return AgentsPage(agents: agents, activity: activity, feed: feed, selected: agents[selected].id, creating: creating, actions: PageActions())
    }

    private static func island(crew: [CrewMember], calling: Color? = nil) -> some View {
        let model = NotchModel()
        model.notchSize = notch
        model.crew = crew
        model.bean = CrewMember(id: Agent.beanID, name: "Bean", look: .pearl, mood: .idle)
        model.calling = calling
        let ear = max(CrewLayout.beanEar(notch), CrewLayout.ear(count: crew.count, shown: model.shownCount, plus: model.showsPlus, notch: notch))
        model.shape = .init(width: notch.width + 2 * ear + 12, height: notch.height, radius: 10, flare: 6)
        model.contentSize = CGSize(width: model.shape.width, height: model.shape.height)
        return NotchView(model: model, onTap: {}, onCrew: { _, _ in }, onPlus: {})
            .frame(width: 320, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private static func hoverList() -> some View {
        let model = NotchModel()
        model.notchSize = notch
        model.crew = [member(2, .needsYou), member(0, .working), member(1)]
        model.bean = CrewMember(id: Agent.beanID, name: "Bean", look: .pearl, mood: .idle)
        model.listOpen = true
        model.roster = [RosterItem(id: UUID(), name: "Infra", look: look(2), mood: .needsYou, line: "Out of scope: acme/infra"),
                        RosterItem(id: UUID(), name: "Linear", look: look(0), mood: .working, line: "Claude session on LIN-42"),
                        RosterItem(id: UUID(), name: "GitHub", look: look(1), mood: .idle, line: "Idle"),
                        RosterItem(id: Agent.beanID, name: "Bean", look: .pearl, mood: .idle, line: "Idle")]
        model.shape = .init(width: 380, height: notch.height + 5 * NotchController.rosterRow + 10, radius: 18, flare: 6)
        model.contentSize = CGSize(width: model.shape.width, height: model.shape.height)
        return NotchView(model: model, onTap: {}, onCrew: { _, _ in }, onPlus: {})
            .frame(width: 420, height: model.shape.height + 10)
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
        model.name = "GitHub"
        model.look = look(1)
        model.mood = mood
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.14)).frame(width: 260, height: 40).offset(y: Perch.seatRow)
            PerchView(model: model, onDragStart: {}, onRelease: { _ in })
        }
        .frame(width: 280, height: Perch.seatRow + 40, alignment: .top)
    }
}
