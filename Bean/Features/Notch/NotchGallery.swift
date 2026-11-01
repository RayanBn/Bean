import AppKit
import SwiftUI

// Renders every notch surface at real size, with the real height measure, off screen and with no input.
enum NotchGallery {
    private static let notch = CGSize(width: 185, height: 32)
    private static let long = "This agent keeps a very long sentence here on purpose, to see how the notch caps it and truncates it cleanly instead of cutting it at the bottom of the panel, whatever the language turns out to be."

    private static func look(_ hue: Double) -> Agent.Look { Agent.Look(hue: hue, accessory: "none") }

    private static func card(_ title: String, saw: String?, _ choices: [NotchCard.Choice], replies: Bool = false, other: Bool = false, agent: UUID? = UUID()) -> NotchCard {
        NotchCard(id: UUID(), source: agent.map { .need(agent: $0, need: UUID()) } ?? .offer(UUID()), name: "Noor", look: look(0.02), title: title, saw: saw, choices: choices, replies: replies, offersOther: other)
    }

    private static func cases() -> [(String, NotchSurface)] {
        let yes = [NotchCard.Choice(title: "Yes", answer: "Yes"), .init(title: "Not now", answer: "Not now")]
        let longChoices = [NotchCard.Choice(title: long, answer: "a", detail: long), .init(title: "Keep both invoices for now", answer: "b", detail: "Nothing is deleted."), .init(title: "Third way", answer: "c"), .init(title: "Fourth way", answer: "d"), .init(title: "Fifth way", answer: "e")]
        let id = UUID()
        let many = (1...8).map { NotchReport.Item(text: "\($0). \(long)", undo: {}) }
        return [
            ("list", .list),
            ("list empty", .list),
            ("compose", .compose),
            ("making", .making(long)),
            ("ready short", .ready(RosterItem(id: id, name: "Noor", look: look(0.02), mood: .idle, line: "You get a short list of what changed in this document, each time it changes."))),
            ("ready long", .ready(RosterItem(id: id, name: "A very long agent name that keeps going and going", look: look(0.3), mood: .idle, line: long))),
            ("card", .card(card("Keep your session moving, and only call you for decisions?", saw: "You came back to Refactor billing 3 times this hour.", yes, agent: nil), more: 0)),
            ("card long", .card(card(long, saw: long, yes), more: 2)),
            ("card three answers", .card(card("Listen to this call?", saw: "A call started in this window.", [.init(title: "Yes", answer: "y"), .init(title: "Not now", answer: "n"), .init(title: "Never here", answer: "x")]), more: 0)),
            ("card long answers", .card(card("Which invoice should stay?", saw: "One invoice appears twice in October.", longChoices), more: 0)),
            ("card other", .card(card("Which invoice should stay?", saw: "One invoice appears twice in October.", [.init(title: "The first", answer: "a"), .init(title: "The second", answer: "b"), .init(title: "Both", answer: "c")], other: true), more: 0)),
            ("card reply", .card(card("Which client is this invoice for?", saw: "The name is cut off in the window.", [], replies: true), more: 0)),
            ("line done", .line(NotchReport(line: "3 tickets filed from the meeting", link: URL(string: "https://example.com"), tone: .done))),
            ("line working", .line(NotchReport(line: String(format: "%@ is on %@. Nothing has changed yet.", "Noor", "Q4 plan.txt"), items: [.init(text: "Noor", undo: {})], tone: .working))),
            ("line plain", .line(NotchReport(line: "I see no document about Lisbon in this window."))),
            ("line long", .line(NotchReport(line: long, link: URL(string: "https://example.com"), items: [.init(text: long, undo: {})]))),
            ("return", .line(NotchReport(line: String(format: "While you were away: %@.", String(format: "%d done", 2) + ", " + "1 question"), isReturn: true))),
            ("report", .report(NotchReport(line: "3 tickets filed from the meeting", link: URL(string: "https://example.com"), items: [.init(text: "Filed LIN-41: fix the export", undo: {}), .init(text: "Filed LIN-42: new pricing page")]))),
            ("report reopen", .report(NotchReport(line: "The session finished", items: [.init(text: "Fixed the export")], actions: [.init(title: "Reopen in the app", run: {}), .init(title: "Reopen in a terminal", run: {})]))),
            ("line reopen", .line(NotchReport(line: "The session finished", actions: [.init(title: "Reopen", run: {})]))),
            ("report long", .report(NotchReport(line: long, link: URL(string: "https://example.com"), items: many))),
        ]
    }

    private static func roster(_ name: String) -> [RosterItem] {
        guard name != "list empty" else { return [] }
        return [RosterItem(id: UUID(), name: "Ellis", look: look(0.9), mood: .needsYou, line: "Waiting for your answer", place: "Safari", app: nil),
                RosterItem(id: UUID(), name: "A very long agent name that keeps going", look: look(0.3), mood: .working, line: long, place: "TextEdit", app: nil),
                RosterItem(id: UUID(), name: "Ava", look: look(0.58), mood: .idle, line: "Drag me onto an app")]
    }

    @MainActor
    private static func cell(_ name: String, _ surface: NotchSurface) -> some View {
        let model = NotchModel()
        model.notchSize = notch
        model.bean = CrewMember(id: Agent.beanID, name: "Bean", look: .pearl, mood: .idle)
        model.crew = [CrewMember(id: UUID(), name: "Ava", look: look(0.58), mood: .idle)]
        model.roster = roster(name)
        model.surface = surface
        let height = NotchController.height(of: surface, like: model)
        model.contentHeight = height
        model.shape = .init(width: NotchController.panelWidth(surface), height: notch.height + height, radius: 18, flare: 6)
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(name): \(Int(height))").font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
            NotchView(model: model, onTap: {}, onCrew: { _, _ in }, onPlus: {})
                .frame(width: 470, height: notch.height + height + 6)
        }
    }

    @MainActor
    static func runIfRequested() -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-notch-surfaces"), CommandLine.arguments.indices.contains(index + 1) else { return false }
        let all = cases()
        let columns = stride(from: 0, to: all.count, by: 6).map { Array(all[$0..<min($0 + 6, all.count)]) }
        let sheet = HStack(alignment: .top, spacing: 20) {
            ForEach(columns.indices, id: \.self) { c in
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(columns[c], id: \.0) { item in cell(item.0, item.1) }
                }
            }
        }
        .padding(20)
        .background(Color(red: 0.36, green: 0.4, blue: 0.5))
        let host = NSHostingView(rootView: sheet)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -9000, y: 0))
        window.orderBack(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            exit(0)
        }
        return true
    }
}
