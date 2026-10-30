import AppKit
import SwiftUI

enum CreatureGallery {
    @MainActor
    static func runIfRequested() -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-creature-gallery"), CommandLine.arguments.indices.contains(index + 1) else { return false }
        let hues = [0.58, 0.93, 0.38]
        let moods: [AgentActivity.Mood] = [.idle, .reading, .working, .needsYou, .sleeping]
        let sheet = VStack(alignment: .leading, spacing: 30) {
            ForEach([CreatureDose.light, .full], id: \.self) { dose in
                VStack(alignment: .leading, spacing: 14) {
                    Text(dose == .light ? "Light" : "Full").font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    HStack(alignment: .center, spacing: 34) {
                        notch(hues, dose)
                        HStack(spacing: 12) {
                            ForEach(Array(hues.enumerated()), id: \.offset) { i, hue in
                                CreatureView(look: look(hue), size: 64, pose: .peek, limbs: 0, motion: CreatureMotion(), dose: dose, shine: i == 1 ? 0.1 : -2)
                            }
                        }
                        CreatureView(look: look(hues[1]), size: DragStage.heldSize, pose: .dangle, motion: CreatureMotion(time: 0.2, swing: 0.25, flail: 0.5), dose: dose)
                            .rotationEffect(.radians(0.3), anchor: CreatureView.gripAnchor)
                            .overlay(alignment: .top) {
                                Image(systemName: "cursorarrow").font(.system(size: 18)).foregroundStyle(.white)
                                    .offset(x: 6, y: CreatureView.frame(DragStage.heldSize).height * CreatureView.gripAnchor.y - 22)
                            }
                        perched(hues, dose)
                    }
                    HStack(spacing: 16) {
                        ForEach(Array(moods.enumerated()), id: \.offset) { _, mood in
                            CreatureView(look: look(hues[0]), mood: mood, size: Perch.size, pose: .perch, motion: CreatureMotion(time: 0.25), dose: dose)
                        }
                    }
                    .padding(.leading, 300)
                }
            }
        }
        .padding(28)
        .background(Color(white: 0.28))
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { exit(1) }
        try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        print("wrote \(CommandLine.arguments[index + 1])")
        exit(0)
    }

    private static func look(_ hue: Double) -> Agent.Look { Agent.Look(hue: hue, accessory: "none") }

    private static func notch(_ hues: [Double], _ dose: CreatureDose) -> some View {
        HStack(spacing: 3) {
            ForEach(hues, id: \.self) { hue in
                CreatureView(look: look(hue), size: 20, pose: .peek, limbs: 0, motion: CreatureMotion(), dose: dose)
                    .frame(width: 23, height: 32)
            }
            Color.clear.frame(width: 70)
            HStack(spacing: 3) {
                Capsule().fill(NotchStyle.accent).frame(width: 9, height: 11)
                Capsule().fill(NotchStyle.accent).frame(width: 9, height: 11)
            }
            .shadow(color: NotchStyle.accent.opacity(0.75), radius: 3)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).fill(.black))
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
    }

    private static func perched(_ hues: [Double], _ dose: CreatureDose) -> some View {
        let frame = CreatureView.frame(Perch.size)
        let edge = frame.height * CreatureView.seatAnchor.y
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.14)).frame(width: 220, height: 70).offset(y: edge)
            HStack(spacing: 14) {
                ForEach(hues.prefix(2), id: \.self) { CreatureView(look: look($0), size: Perch.size, pose: .perch, motion: CreatureMotion(time: 0.25), dose: dose) }
            }
        }
        .frame(width: 220, height: edge + 70, alignment: .top)
    }
}
