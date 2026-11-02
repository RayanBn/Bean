import Foundation

// The words for tool results as they really came back in the Arc trial of Nov 1. No model, no window.
enum StepsProbe {
    private static let asleep = "The tab's text cannot be read now: the browser has probably put it to sleep, and waking it would change what the person sees. The tab's title and address still come from app_windows."

    private static let calls: [(name: String, args: JSONArgs, output: ToolOutput)] = [
        ("app_windows", [:], ToolOutput(text: (["Window: Model API"] + ["Tab 1.27 | Google Agenda - Semaine du 31 mai 2026 | https://calendar.google.com/calendar/u/0/r?pli=1", "Tab 1.33 | coffeebean.app/rooms/313e67fe | https://coffeebean.app/rooms/313e67fe", "Tab 1.8 | coffeebean.app/rooms/f8551c7b | https://coffeebean.app/rooms/18f0ba06", "Tab 1.2 | Instagram | https://instagram.com", "Tab 1.3 | Secret | off limits"]).joined(separator: "\n"))),
        ("tab_read", ["window": 1, "tab": 27], ToolOutput(text: "Google Agenda - Semaine du 31 mai 2026 https://calendar.google.com/calendar/u/0/r?pli=1\n\(asleep)", ok: false)),
        ("tab_read", ["window": 1, "tab": 33], ToolOutput(text: "coffeebean.app/rooms/313e67fe https://coffeebean.app/rooms/313e67fe\n\(asleep)", ok: false)),
        ("tab_read", ["window": 1, "tab": 8], ToolOutput(text: "coffeebean.app/rooms/f8551c7b https://coffeebean.app/rooms/18f0ba06\n\(asleep)", ok: false)),
        ("window_read", [:], ToolOutput(text: "Model API: pricing and limits.")),
        ("linear__list_issues", ["team": "x"], ToolOutput(text: "3 issues")),
        ("linear__get_issue", ["id": "x"], ToolOutput(text: "denied", ok: false)),
        ("terminal", ["command": "ls"], ToolOutput(text: "[Exit code 0.]")),
        ("use_services", [:], ToolOutput(text: "You now have them.")),
        ("some_new_tool", [:], ToolOutput(text: "ok")),
    ]

    static func runIfRequested() -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-steps") else { return false }
        var words = StepWords(app: "Arc", window: "Model API", scope: "RayanBn/Bean")
        let run = UUID()
        var steps = [AgentStep(run: run, kind: .began, words: "Seeing what your job needs")]
        for call in calls {
            print("running: \(words.running(call.name, call.args) ?? "(nothing new)")")
            switch words.ended(call.name, call.args, call.output) {
            case .hidden: print("  hidden")
            case .inJournal: print("  in the journal")
            case .step(let kind, let line, let family, let object, let reason, let detail):
                print("  \(kind.rawValue): \(line)")
                steps.append(AgentStep(run: run, kind: kind, words: line, family: family, object: object, reason: reason, detail: detail))
            }
        }
        let shown = StepRun.all(steps: steps, journal: [], live: nil)
        for row in shown.first?.rows ?? [] { if case .steps(let list) = row { print("row: \(StepRun.label(list))") } }
        print("folded: \(shown.first?.summary ?? "")")
        if CommandLine.arguments.indices.contains(index + 1) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let file = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            for step in steps + [AgentStep(run: run, kind: .ended, words: "")] { if let line = try? encoder.encode(step) { JSONLines.append(line, to: file) } }
        }
        return true
    }
}
