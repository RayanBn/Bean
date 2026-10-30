import AppKit
import SwiftUI

enum CreatureGallery {
    static let notch = CGSize(width: 185, height: 32)
    static let hues = [0.47, 0.93, 0.6]

    @MainActor
    static func runIfRequested() -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-creature-gallery"), CommandLine.arguments.indices.contains(index + 1) else { return false }
        let sheet = VStack(alignment: .leading, spacing: 26) {
            row("Rest, first run") { island(crew: [], plus: true, say: "Hi! Tap + to make your first agent.") }
            row("Rest, hover") { island(crew: [member(1), member(2)], plus: true, gaze: CGSize(width: -0.8, height: 0.6)) }
            row("Five agents, hover, Bean out") {
                island(crew: (0..<5).map { member($0 % 3) }, plus: true, beanOut: true)
            }
            row("Create") { island(crew: [member(1), member(2)], phase: .create) }
            row("Split") { island(crew: [member(0, forming: 0.1), member(1), member(2)], birth: true) }
            row("Forming, then greeting") {
                HStack(spacing: 30) {
                    island(crew: [member(0, forming: 3), member(1), member(2)], newborn: true)
                    island(crew: [member(0), member(1), member(2)], newborn: true, hint: "Juno here. I keep your PRs moving, gently.")
                }
            }
            row("Drag: thread, then edge light") {
                HStack(spacing: 30) {
                    drag(tether: true)
                    drag(tether: false)
                }
            }
            row("Plugged in: a badge after the window buttons. Quiet, hover, needs you, two agents") {
                HStack(spacing: 24) {
                    perched([("", .idle)])
                    perched([("3 PRs open here. #212 has waited since Tuesday.", .idle)], talking: true)
                    perched([("Want me to draft a nudge for #212?", .needsYou)])
                    perched([("", .idle), ("", .reading)])
                }
            }
            row("Card") {
                AgentCard(agent: agent(0, name: "Juno", attached: true),
                          activity: AgentActivity(mood: .idle, bubble: nil),
                          folder: AgentFolder(url: URL(fileURLWithPath: "/tmp/none")),
                          onUnplug: {}, onDelete: {})
                    .frame(width: Agents.width - 28)
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

    private static func row(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.8))
            content()
        }
    }

    private static func agent(_ i: Int, name: String = "", attached: Bool = false) -> Agent {
        Agent(id: UUID(), name: name.isEmpty ? ["Juno", "Pip", "Mo"][i] : name, role: "Keeps your PRs moving, gently.", personality: "",
              look: .init(hue: hues[i], accessory: "none"), connectors: [],
              attachment: attached ? Attachment(bundleId: "", appName: "Code", pid: 0, windowNumber: 0, windowTitle: nil) : nil, createdAt: Date())
    }

    private static func member(_ i: Int, forming: Double? = nil) -> CrewMember {
        CrewMember(id: UUID(), name: ["Juno", "Pip", "Mo"][i], look: .init(hue: hues[i], accessory: "none"),
                   mood: forming.map { .forming(Date().addingTimeInterval(-$0)) } ?? .idle)
    }

    private static func island(crew: [CrewMember], plus: Bool = false, phase: NotchPhase = .rest, gaze: CGSize? = nil, say: String? = nil,
                               birth: Bool = false, newborn: Bool = false, hint: String? = nil, beanOut: Bool = false) -> some View {
        let model = NotchModel()
        model.notchSize = notch
        model.crew = crew
        model.bean = beanOut ? nil : CrewMember(id: Agent.beanID, name: "Bean", look: .pearl, mood: .idle)
        model.hovering = plus
        model.gaze = gaze
        model.phase = phase
        model.say = say
        model.hint = hint
        if newborn || birth { model.newborn = crew.first?.id }
        if birth, let first = crew.first { model.birth = Birth(id: first.id, hue: hues[0], start: Date().addingTimeInterval(-0.5)) }
        model.ideas = [AgentIdea(label: "Keeps PRs moving", request: "a"), AgentIdea(label: "Remembers meetings", request: "bb"), AgentIdea(label: "Tames my inbox", request: "ccc")]
        model.draft = phase == .create ? "Someone who keeps my PRs moving" : ""
        let ear = phase == .create ? 0 : max(CrewLayout.beanEar(notch), CrewLayout.ear(count: crew.count, shown: model.shownCount, plus: model.showsPlus, notch: notch))
        model.shape = phase == .create
            ? .init(width: NotchController.createWidth + 28, height: notch.height + 8 + 26 + 11 + 24 + 16, radius: 24, flare: 14)
            : .init(width: notch.width + 2 * ear + 12, height: notch.height, radius: 10, flare: 6)
        model.contentSize = CGSize(width: model.shape.width, height: model.shape.height)
        return ZStack(alignment: .top) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: notch.height)
            NotchView(model: model, onTap: {}, onCrew: { _, _ in }, onPlus: {}, onSubmit: { _ in }, onCancel: {})
        }
        .frame(width: 520, height: phase == .create ? 140 : 110)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private static func drag(tether: Bool) -> some View {
        let model = DragStageModel()
        model.look = .init(hue: hues[0], accessory: "none")
        model.visible = true
        model.size = DragStage.heldSize * 0.8
        model.limbs = 1
        model.grip = CGPoint(x: 150, y: tether ? 70 : 60)
        model.tether = tether ? CGPoint(x: 190, y: 8) : nil
        model.highlight = tether ? nil : CGRect(x: 30, y: 150, width: 300, height: 60)
        model.motion = CreatureMotion(time: 0.3, swing: 0.1, flail: 0.4)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(.black).frame(width: 240, height: 10).position(x: 190, y: 5)
            RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.13)).frame(width: 300, height: 60).position(x: 180, y: 180)
            DragStageView(model: model)
        }
        .frame(width: 360, height: 210)
    }

    private static func perched(_ agents: [(String, AgentActivity.Mood)], talking: Bool = false) -> some View {
        let panel = Perch.panelSize
        let spot = CGPoint(x: Perch.fallback.center.x - Perch.gap - Perch.badge / 2, y: Perch.fallback.center.y)
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) {
                        Circle().fill($0).frame(width: 12, height: 12)
                    }
                    Spacer()
                    Text("api — pulls.ts").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                    Spacer()
                }
                .padding(.leading, 20).padding(.trailing, 60)
                .frame(height: 32)
                .background(Color(white: 0.18))
                Color(white: 0.11)
            }
            .frame(width: 340, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            ForEach(Array(agents.enumerated()), id: \.offset) { i, agent in
                let model = PerchModel()
                let _ = (model.name = "Juno", model.look = Agent.Look(hue: hues[i], accessory: "none"), model.mood = agent.1, model.bubble = agent.0.isEmpty ? nil : agent.0)
                PerchView(model: model, alwaysTalking: talking, onDragStart: {}, onRelease: { _ in })
                    .frame(width: panel.width, height: panel.height)
                    .offset(x: spot.x + Perch.gap + Perch.badge / 2 + CGFloat(i) * (Perch.badge + Perch.gap) - panel.width / 2, y: spot.y - Perch.seatInset)
            }
        }
        .frame(width: 340, height: 150, alignment: .topLeading)
    }
}
