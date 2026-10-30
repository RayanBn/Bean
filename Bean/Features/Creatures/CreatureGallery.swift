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
            row("Create") { island(crew: [member(1), member(2)], phase: .create) }
            row("Split") { island(crew: [member(1), member(2), member(0, forming: 0.1)], birth: true) }
            row("Forming, then greeting") {
                HStack(spacing: 30) {
                    island(crew: [member(1), member(2), member(0, forming: 3)], newborn: true)
                    island(crew: [member(1), member(2), member(0)], newborn: true, hint: "Juno here. I keep your PRs moving, gently.")
                }
            }
            row("Drag: thread, then edge light") {
                HStack(spacing: 30) {
                    drag(tether: true)
                    drag(tether: false)
                }
            }
            row("Perched: bubble, folded, needs you") {
                HStack(spacing: -60) {
                    perched("3 PRs open here. #212 has waited since Tuesday.", mood: .idle)
                    perched("still on the onboarding doc", mood: .idle, folded: true)
                    perched("Want me to draft a nudge for #212?", mood: .needsYou)
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
                               birth: Bool = false, newborn: Bool = false, hint: String? = nil) -> some View {
        let model = NotchModel()
        model.notchSize = notch
        model.crew = crew
        model.hovering = plus
        model.gaze = gaze
        model.phase = phase
        model.say = say
        model.hint = hint
        if newborn || birth { model.newborn = crew.last?.id }
        if birth, let last = crew.last { model.birth = Birth(id: last.id, hue: hues[0], start: Date().addingTimeInterval(-0.42)) }
        model.ideas = [AgentIdea(label: "Keeps PRs moving", request: "a"), AgentIdea(label: "Remembers meetings", request: "bb"), AgentIdea(label: "Tames my inbox", request: "ccc")]
        model.draft = phase == .create ? "Someone who keeps my PRs moving" : ""
        let ear = phase == .create ? 0 : max(CrewLayout.beanEar(notch), CrewLayout.ear(count: crew.count, plus: model.showsPlus, notch: notch))
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

    private static func perched(_ text: String, mood: AgentActivity.Mood, folded: Bool = false) -> some View {
        let model = PerchModel()
        model.name = "Juno"
        model.look = .init(hue: hues[0], accessory: "none")
        model.mood = mood
        model.bubble = text
        model.hovered = !folded
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.14)).frame(width: 260, height: 40).offset(y: Perch.panelSize.height - Perch.seatDepth)
            PerchView(model: model, startFolded: folded, onDragStart: {}, onRelease: { _ in })
        }
        .frame(width: Perch.panelSize.width, height: Perch.panelSize.height + 40)
    }
}
