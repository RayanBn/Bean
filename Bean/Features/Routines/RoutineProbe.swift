import Foundation

enum RoutineProbe {
    static func runIfRequested() -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--routines-probe"), index + 1 < CommandLine.arguments.count else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let actions = ((try? String(contentsOfFile: CommandLine.arguments[index + 1], encoding: .utf8)) ?? "")
            .split(separator: "\n").compactMap { try? decoder.decode(RecordedAction.self, from: Data($0.utf8)) }
        let started = Date()
        let routines = RoutineMiner.all(actions)
        print("\(actions.count) actions, \(routines.count) routines in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        for routine in routines.prefix(10) {
            print("- \(routine.instances)x on \(routine.days) days\(routine.loops ? ", loop" : "")\(routine.scope.map { ", only \($0)" } ?? ""): \(routine.name)")
            for (step, token) in zip(routine.steps, routine.tokens) {
                print("    \(step.step.intent)  [\(token)]  post: \(step.step.post.map { "\($0.kind.rawValue) \($0.value ?? "")" } ?? "any visible change")")
            }
        }
        return true
    }
}
