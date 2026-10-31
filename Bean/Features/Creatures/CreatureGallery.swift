import AppKit
import SwiftUI

enum CreatureGallery {
    static let notch = CGSize(width: 185, height: 32)
    static let hues = [0.47, 0.6, 0.11]

    @MainActor
    static func runIfRequested() -> Bool {
        if NotchGallery.runIfRequested() { return true }
        if let index = CommandLine.arguments.firstIndex(of: "--probe-menubar"), CommandLine.arguments.indices.contains(index + 1),
           ProcessInfo.processInfo.environment["BEAN_DATA_DIR"] != nil {
            renderMenuBar(to: CommandLine.arguments[index + 1])
            return true
        }
        if let index = CommandLine.arguments.firstIndex(of: "--probe-page"), CommandLine.arguments.indices.contains(index + 1) {
            renderPages(to: CommandLine.arguments[index + 1])
            return true
        }
        if let index = CommandLine.arguments.firstIndex(of: "--probe-icon"), CommandLine.arguments.indices.contains(index + 1) {
            let icon = ZStack {
                RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 824, height: 824)
                PageDrop(look: .pearl, mood: .idle, size: 460)
            }
            .frame(width: 1024, height: 1024)
            let renderer = ImageRenderer(content: icon)
            renderer.scale = 1
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { exit(1) }
            try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            exit(0)
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
                row("After a drop") { PerchLine(text: "Q4 plan: list what changes in it") }
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
    private static func renderMenuBar(to directory: String) {
        BeanDefaults.shared.set(true, forKey: "menuBarSettingsOpen")
        let settings = BeanSettings.shared
        let cases: [(AIProvider, String)] = [(.meta, "muse-spark-1.3-with-a-very-long-custom-model-name"), (.openRouter, "meta-llama/llama-4-maverick-with-a-long-suffix"), (.openAICompatible, "")]
        let window = OffscreenWindow(contentRect: NSRect(x: -9000, y: 0, width: 320, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentViewController = NSHostingController(rootView: MenuBarView(settings: settings, notch: NotchModel(), openAgents: {}, openSettings: {}, close: {}))
        window.setContentSize(NSSize(width: 320, height: 620))
        window.setFrameOrigin(NSPoint(x: -9000, y: 0))
        window.orderBack(nil)
        func shoot(_ index: Int) {
            guard index < cases.count else { exit(0) }
            settings.provider = cases[index].0
            settings.model = cases[index].1
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(directory)/menubar-\(index).png"))
                    print("wrote \(index)")
                }
                shoot(index + 1)
            }
        }
        shoot(0)
    }

    @MainActor
    private static func renderPages(to directory: String) {
        let scenes: [(String, NSAppearance.Name, Int, Bool)] = [("bean-light", .aqua, 0, false), ("mail-light", .aqua, 1, false), ("sheet-dark", .darkAqua, 2, false), ("nowindow-light", .aqua, 3, false), ("new-dark", .darkAqua, 0, true), ("sidebar-light", .aqua, -1, false), ("connectors-dark", .darkAqua, -2, false), ("connectors-light", .aqua, -2, false), ("first-dark", .darkAqua, -3, false), ("settings-ai", .aqua, -4, false), ("settings-off", .aqua, -5, false), ("settings-perm", .aqua, -6, false), ("settings-sees", .aqua, -7, false)]
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
        Agent(id: id, name: name, role: role, look: look, attachment: nil, createdAt: Date())
    }

    private static func page(selected: Int, creating: Bool) -> some View {
        let nora = agent("Nora", .init(hue: 0.47, accessory: "star"), "Sorts the mail and drafts the replies.")
        let robin = agent("Robin", .init(hue: 0.6, accessory: "bolt"), "Fills and checks the budget.")
        let iris = agent("Iris", .init(hue: 0.02, accessory: "none"), "Researches the client before the meeting.")
        let bean = agent("Bean", .pearl, "The brain. Runs your agents.", id: Agent.beanID)
        let agents = [bean, nora, robin, iris]
        func at(_ minutes: Double) -> Date { Date().addingTimeInterval(-minutes * 60) }
        var feed = PageFeed()
        feed.doing = [nora.id: "Drafting the reply to Northwind"]
        feed.missions = [
            nora.id: AgentMission(mission: "Sort my mail and draft the replies."),
            robin.id: AgentMission(mission: "Keep the Q4 budget filled in and flag what looks wrong."),
            iris.id: AgentMission(mission: "Research the client before Monday's meeting."),
            bean.id: AgentMission(mission: "Keep everything moving while I am away."),
        ]
        feed.journal[nora.id] = [
            JournalEntry(at: at(62), kind: .handoff, did: "Read the Northwind thread and list what they expect on Monday", why: "Needed for the meeting notes"),
            JournalEntry(at: at(40), kind: .action, did: "Sorted 14 new messages", why: "3 need a reply this week", result: "14 moved", link: "https://example.com/mail/1042", undo: "Move them back", undoCommand: "x"),
            JournalEntry(at: at(20), kind: .action, did: "Drafted the reply to Northwind", why: "They asked to confirm the time. Saved as a draft, not sent."),
            JournalEntry(at: at(4), kind: .said, did: "Don't touch anything from my bank.", why: ""),
            JournalEntry(at: at(3), kind: .replied, did: "Understood. Messages from your bank are excluded from now on.", why: ""),
        ]
        feed.journal[robin.id] = [
            JournalEntry(at: at(50), kind: .action, did: "Filled in the October column", why: "From the three invoices in the shared folder", undo: "Clear the column", undoCommand: "x"),
            JournalEntry(at: at(15), kind: .refused, did: "Did not delete the old sheet", why: "Deleting is off for this agent"),
            JournalEntry(at: at(8), kind: .said, did: "Why is travel so high?", why: ""),
            JournalEntry(at: at(7), kind: .replied, did: "One invoice appears twice in October. I marked both rows.", why: ""),
        ]
        feed.journal[bean.id] = [
            JournalEntry(at: at(70), kind: .said, did: "Prepare Monday's client meeting.", why: ""),
            JournalEntry(at: at(69), kind: .replied, did: "Nora reads the mail thread, Robin checks the budget, and I'll send you one summary.", why: ""),
            JournalEntry(at: at(62), kind: .handoff, did: "Read the Northwind thread and list what they expect on Monday", why: "Needed for the meeting notes", to: nora.id),
            JournalEntry(at: at(31), kind: .handoff, did: "Check the October figures Northwind asked about", why: "Nora found the question in their last message", to: robin.id),
        ]
        feed.targets = [
            nora.id: [AgentTarget(kind: .window, name: "Inbox", app: "Mail", title: "Inbox")],
            robin.id: [AgentTarget(kind: .window, name: "Q4 budget", app: "Numbers", title: "Q4 budget")],
        ]
        feed.connectors = [
            nora.id: [AgentConnectorInfo(name: "Mail", source: .mcp, status: .connected, usedFor: ["Reads messages and saves drafts"])],
            robin.id: [AgentConnectorInfo(name: "Numbers", source: .mcp, status: .connected, usedFor: ["Reads and fills the sheet"]),
                       AgentConnectorInfo(name: "Slack", source: .mcp, status: .toConnect, usedFor: ["Tells the team about a change"])],
        ]
        feed.abilities = [
            nora.id: [AgentAbility(id: "a", title: "Sort messages", detail: "Moves mail between folders", allowed: true, risk: .safe, source: "Mail"),
                      AgentAbility(id: "b", title: "Send messages", detail: "Off: drafts stay in your mailbox", allowed: false, risk: .outward, source: "Mail"),
                      AgentAbility(id: "c", title: "Delete messages", detail: "Removes them for good", allowed: false, risk: .irreversible, source: "Mail")],
            robin.id: [AgentAbility(id: "a", title: "Read the sheet", detail: "Values and formulas", allowed: true, risk: .safe, source: "Numbers"),
                       AgentAbility(id: "b", title: "Edit cells", detail: "Visible to everyone sharing the file", allowed: true, risk: .outward, source: "Numbers"),
                       AgentAbility(id: "c", title: "Delete sheets", detail: "Off: stops and asks", allowed: false, risk: .irreversible, source: "Numbers")],
        ]
        feed.awaySince = at(120)
        feed.needs[robin.id] = [AgentNeed(kind: .decision, question: "One invoice appears twice in October. Which one should stay?", options: ["Keep the first", "Keep both"],
                                          consequences: ["Keep the first": "Travel drops by $420 and the second row is cleared.", "Keep both": "Nothing changes; the total stays high."], recommended: "Keep the first")]
        feed.decisions[bean.id] = [
            AgentDecision(at: at(6), kind: .judgment, question: "Move the meeting to 10?", answer: "Yes", why: "Your calendar is free and you prefer mornings", confidence: 0.9),
            AgentDecision(at: at(4), kind: .judgment, question: "Share the draft with the whole team?", answer: "No, only with Sam", why: "It still has the internal figures", confidence: 0.8, state: .corrected, correction: "Share it with Sam and Ana"),
        ]
        for agent in [nora, robin, bean] {
            let journal = feed.journal[agent.id] ?? []
            feed.summaries[agent.id] = AwaySummary(since: at(120), decided: feed.decisions[agent.id] ?? [], permissionsAnswered: agent.isBean ? 7 : 0, waiting: feed.needs[agent.id] ?? [],
                                                   done: journal.filter { $0.kind == .action })
        }
        feed.needs[iris.id] = [AgentNeed(kind: .setup, question: "What should I research first? Tell me the client's name and what the meeting is about, so I can start with the right sources and report back before Monday.")]
        feed.catalogue = [
            ConnectorEntry(id: "granola", name: "Granola", summary: "Your meeting notes and transcripts.", audience: "everyone", status: .connected, usedBy: [bean.id, nora.id]),
            ConnectorEntry(id: "notion", name: "Notion", summary: "Pages and databases in your workspace.", audience: "everyone", status: .available, usedBy: []),
            ConnectorEntry(id: "canva", name: "Canva", summary: "Designs and presentations.", audience: "everyone", status: .connecting, usedBy: []),
            ConnectorEntry(id: "dropbox", name: "Dropbox", summary: "Your files and folders.", audience: "everyone", status: .failed("The sign-in was closed before it finished."), usedBy: []),
            ConnectorEntry(id: "monday", name: "monday.com", summary: "Boards and tasks.", audience: "everyone", status: .available, usedBy: []),
            ConnectorEntry(id: "linear", name: "Linear", summary: "Issues and projects.", audience: "developers", status: .connected, usedBy: [robin.id]),
            ConnectorEntry(id: "github", name: "GitHub", summary: "Issues, pull requests and code.", audience: "developers", status: .available, usedBy: []),
        ]
        feed.openWindows = [
            OpenWindow(number: 1, pid: 1, app: "Mail", bundleId: "com.apple.mail", title: "Inbox"),
            OpenWindow(number: 2, pid: 1, app: "Numbers", bundleId: "com.apple.iWork.Numbers", title: "Q4 budget"),
            OpenWindow(number: 3, pid: 1, app: "Safari", bundleId: "com.apple.Safari", title: "Northwind Trading: About"),
        ]
        feed.thoughts = [
            nora.id: AgentWorker.Thought(at: at(2), acted: true, what: "Drafting the reply to Northwind."),
            robin.id: AgentWorker.Thought(at: at(5), acted: false, what: "Nothing changed in the budget since the last check."),
        ]
        feed.listening = [nora.id: at(4)]
        feed.needs[iris.id] = [AgentNeed(kind: .decision, question: "Listen to this call?", options: ["This call only", "Not now", "Always listen here"], consequences: ["Always listen here": "Iris listens to every call on this window until you turn it off in its settings."], consent: "hearing", detail: "The sound stays on this Mac. The written transcript goes to Muse Spark (Meta). Tell the others on the call.")]
        if selected <= -4 {
            feed.sees.hidden = 2
            feed.sees.at = Date()
            feed.sees.apps = [.init(pid: 1, name: "Mail", bundleId: "com.apple.mail", isActive: true, windows: 1), .init(pid: 2, name: "Numbers", bundleId: "com.apple.iWork.Numbers", isActive: false, windows: 1), .init(pid: 3, name: "Safari", bundleId: "com.apple.Safari", isActive: false, windows: 1)]
            feed.sees.windows = [.init(number: 1, app: "Mail", bundleId: "com.apple.mail", title: "Inbox", agent: nora.id), .init(number: 2, app: "Numbers", bundleId: "com.apple.iWork.Numbers", title: "Q4 budget", agent: robin.id), .init(number: 3, app: "Safari", bundleId: "com.apple.Safari", title: "Northwind Trading: About", agent: nil)]
            feed.sees.tabs = [.init(app: "Safari", window: 1, tab: 1, title: "Northwind Trading: About", url: "https://example.com/about")]
            feed.sees.focused = .init(app: "Mail", window: "Inbox", text: "From: Dana Reyes\nSubject: Monday\nCan we move the meeting to 10?", behindBean: true)
            feed.gate = [GateEntry(event: "windowChanged", app: "Mail", title: "Inbox", decision: "quiet", by: "Strands", score: 0.12, ms: 84, detail: "Only the unread count changed")]
            let tabs: [SettingsTab] = [.ai, .offLimits, .permissions, .sees]
            return AgentsPage(agents: agents, activity: [:], feed: feed, selected: nil, settingsTab: tabs[-4 - selected], creating: false, actions: PageActions())
        }
        if selected == -3 {
            var empty = PageFeed()
            empty.openWindows = feed.openWindows
            return AgentsPage(agents: [bean], activity: [:], feed: empty, selected: bean.id, creating: false, actions: PageActions())
        }
        let activity: [UUID: AgentActivity] = [nora.id: AgentActivity(mood: .working), robin.id: AgentActivity(mood: .needsYou, bubble: "One invoice appears twice")]
        return AgentsPage(agents: agents, activity: activity, feed: feed, selected: selected < 0 ? nil : agents[selected].id, creating: creating, actions: PageActions())
    }

    private static func island(crew: [CrewMember], calling: Color? = nil) -> some View {
        let model = NotchModel()
        model.notchSize = notch
        model.crew = crew
        model.bean = CrewMember(id: Agent.beanID, name: "Bean", look: .pearl, mood: .idle)
        model.calling = calling
        let ear = max(CrewLayout.beanEar(notch), CrewLayout.ear(count: crew.count, shown: model.shownCount, plus: model.showsPlus, notch: notch))
        model.shape = .init(width: notch.width + 2 * ear + 12, height: notch.height, radius: 10, flare: 6)
        return NotchView(model: model, onTap: {}, onCrew: { _, _ in }, onPlus: {})
            .frame(width: 320, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private static func hoverList() -> some View {
        let model = NotchModel()
        model.notchSize = notch
        model.crew = [member(2, .needsYou), member(0, .working), member(1)]
        model.bean = CrewMember(id: Agent.beanID, name: "Bean", look: .pearl, mood: .idle)
        model.surface = .list
        model.roster = [RosterItem(id: UUID(), name: "Infra", look: look(2), mood: .needsYou, line: "Out of scope: acme/infra"),
                        RosterItem(id: UUID(), name: "Linear", look: look(0), mood: .working, line: "Claude session on LIN-42"),
                        RosterItem(id: UUID(), name: "GitHub", look: look(1), mood: .idle, line: "Idle"),
                        RosterItem(id: Agent.beanID, name: "Bean", look: .pearl, mood: .idle, line: "Idle")]
        model.shape = .init(width: 380, height: notch.height + 5 * NotchController.rosterRow + 10, radius: 18, flare: 6)
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
