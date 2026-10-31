import AppKit
import SwiftUI

@MainActor
final class WindowGuess: ObservableObject {
    private static let threshold = 0.85
    private static let question = "Which open window is this goal about?"
    private static let limit = 12
    private static let log = JSONLog(name: "guess")
    private static let noteStart = "\n\n[The user means their window number "
    private struct Entry: Encodable { var at = Date(); let words: Int; let pick: Int?; let confidence: Double; let ms: Int; let lit: Int? }

    @Published private(set) var lit: OpenWindow?
    private var asked = ""
    private var previous: Int?
    private var waiting: (goal: String, words: Int, options: [OpenWindow])?
    private var asking = false
    private var round = 0
    private let glow = WindowGlow()

    static func visible(_ said: String) -> String {
        said.components(separatedBy: noteStart).first ?? said
    }

    func typed(_ text: String, windows: [OpenWindow]) {
        guard BeanSettings.shared.effectiveDecidesOnThisMac, !BeanSettings.shared.effectivePaused, StrandsServer.isAvailable else { return clear() }
        let words = text.split(whereSeparator: \.isWhitespace)
        let complete = text.last?.isWhitespace == true ? words[...] : words.dropLast()
        guard complete.count >= 2 else { return clear() }
        let goal = complete.joined(separator: " ")
        guard goal != asked else { return }
        if !goal.hasPrefix(asked) { clear() }
        asked = goal
        waiting = (goal, complete.count, Array(windows.prefix(Self.limit)))
        askNext()
    }

    private func askNext() {
        guard !asking, let next = waiting else { return }
        waiting = nil
        asking = true
        let current = round
        Task { [weak self] in
            let started = Date()
            let answer = await Self.choose(next.goal, among: next.options)
            guard let self else { return }
            self.asking = false
            if let answer, current == self.round {
                self.heard(answer, among: next.options, words: next.words, ms: Int(Date().timeIntervalSince(started) * 1000))
            }
            self.askNext()
        }
    }

    func confirm(_ text: String) -> String {
        defer { clear() }
        guard let lit else { return text }
        return "\(text)\(Self.noteStart)\(lit.number), in \(lit.app).]"
    }

    func clear() {
        waiting = nil
        round += 1
        asked = ""
        previous = nil
        light(nil)
    }

    private func heard(_ answer: (pick: Int?, confidence: Double), among options: [OpenWindow], words: Int, ms: Int) {
        let pick = answer.confidence >= Self.threshold ? answer.pick : nil
        let window = pick.map { options[$0].number }
        if let window, window == previous {
            light(options.first { $0.number == window })
        } else if let window, let lit, lit.number != window {
            light(nil)
        }
        previous = window
        Self.log.append(Entry(words: words, pick: window, confidence: answer.confidence, ms: ms, lit: lit?.number))
    }

    private func light(_ window: OpenWindow?) {
        guard window != lit else { return }
        lit = window
        glow.show(window)
    }

    private static func choose(_ goal: String, among windows: [OpenWindow]) async -> (pick: Int?, confidence: Double)? {
        guard !windows.isEmpty, let endpoint = await StrandsServer.shared.ready() else { return nil }
        var criteria = ["none": "None of these windows"]
        for (index, window) in windows.enumerated() { criteria["w\(index)"] = "\(window.app), \(window.title ?? "No title")" }
        let body: [String: Any] = ["state": goal, "questions": ["q": ["type": "choice", "instructions": question, "criteria": criteria]]]
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/systemone"))
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let answers = json["answers"] as? [String: Any], let answer = answers["q"] as? [String: Any],
              let choice = answer["choice"] as? String, let confidence = answer["confidence"] as? Double else { return nil }
        return (Int(choice.dropFirst()), confidence)
    }
}

private final class WindowGlow {
    private let panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 4)
            .shadow(color: .accentColor, radius: 8)
            .padding(8))
        return panel
    }()

    func show(_ window: OpenWindow?) {
        guard let window, let found = ForeignWindow.lookup(window.number) else { return panel.orderOut(nil) }
        panel.setFrame(found.appKitFrame.insetBy(dx: -12, dy: -12), display: true)
        panel.order(.above, relativeTo: window.number)
    }
}

struct WindowGuessChip: View {
    let window: OpenWindow

    var body: some View {
        HStack(spacing: 8) {
            TargetIcon(target: AgentTarget(kind: .window, name: window.title ?? window.app, app: window.app, title: window.title))
            Text(window.title ?? window.app).font(.callout.weight(.medium)).lineLimit(1)
            Text(AgentStrings.shown("Return tells Bean you mean this window.")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 14).padding(.top, 8)
        .accessibilityIdentifier("page-window-guess")
    }
}
