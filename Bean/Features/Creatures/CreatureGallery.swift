import AppKit
import SwiftUI

enum CreatureGallery {
    @MainActor
    static func runIfRequested() -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-creature-gallery"), CommandLine.arguments.indices.contains(index + 1) else { return false }
        let out = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        let moods: [AgentActivity.Mood] = [.idle, .reading, .working, .needsYou, .sleeping]
        let sheet = VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(Agent.Look.accessories.enumerated()), id: \.offset) { i, accessory in
                let look = Agent.Look(hue: Double(i) / Double(Agent.Look.accessories.count), accessory: accessory)
                HStack(alignment: .bottom, spacing: 18) {
                    Text(accessory).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white).frame(width: 60, alignment: .leading)
                    ForEach(Array(moods.enumerated()), id: \.offset) { _, mood in
                        CreatureView(look: look, mood: mood, size: Perch.size, pose: .perch, motion: CreatureMotion(time: 0.3))
                            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.4)).frame(height: 1).offset(y: CreatureView.frame(Perch.size).height * CreatureView.seatAnchor.y) }
                    }
                    CreatureView(look: look, size: DragStage.heldSize, pose: .dangle, motion: CreatureMotion(time: 0.2, swing: 0.3, flail: 0.6))
                        .rotationEffect(.radians(0.35), anchor: CreatureView.gripAnchor)
                    ZStack {
                        Capsule().fill(.black).frame(width: 34, height: 32)
                        CreatureView(look: look, size: 21, pose: .peek, limbs: 0)
                    }
                    .frame(width: 40, height: 32)
                    .clipped()
                }
            }
        }
        .padding(20)
        .background(Color(white: 0.32))
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 3
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { exit(1) }
        try? data.write(to: out)
        print("wrote \(out.path)")
        exit(0)
    }
}
