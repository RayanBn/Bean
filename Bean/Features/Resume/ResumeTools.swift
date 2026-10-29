import Foundation

/// Offers the brain one act when the user comes back to a project: put back its windows. The brain decides whether to propose it.
final class ResumeTools: ToolSource {
    private let store: ResumeStore
    private let resumer: Resumer

    init(store: ResumeStore, resumer: Resumer) {
        self.store = store
        self.resumer = resumer
    }

    func tools(for trigger: Trigger) async -> [BrainTool] {
        guard trigger.kind == .projectBack else { return [] }
        return [BrainTool(
            name: "resume_project",
            description: "Put back the windows the user had open in this project, as they were: reopen what is missing with the app's learned recipe, place each window, full screen included.",
            parameters: ["root": ["type": "string", "description": "The project folder, as given in the event."]],
            effect: .act,
            run: { [weak self] args in await self?.restore(args, progress: { _, _ in }) ?? ToolOutput(text: "Bean is quitting", ok: false) },
            stepTitles: { [weak self] args in
                self?.project(args)?.toRestore().map { "\($0.facts.appName): \($0.facts.title)".prefix(48).description } ?? []
            },
            runSteps: { [weak self] args, progress in await self?.restore(args, progress: progress) ?? ToolOutput(text: "Bean is quitting", ok: false) }
        )]
    }

    private func project(_ args: JSONArgs) -> ProjectState? {
        args.string("root").flatMap { store.projects[$0] }
    }

    private func restore(_ args: JSONArgs, progress: @escaping (Int, Bool) -> Void) async -> ToolOutput {
        guard let project = project(args) else { return ToolOutput(text: "No saved project at \(args.string("root") ?? "?")", ok: false) }
        let outcomes = await resumer.restore(project) { _, _, _ in } done: { index, ok in progress(index, ok) }
        let back = outcomes.filter { $0.result != .failed }.count
        let lines = outcomes.map { "\($0.app) \"\($0.title)\": \($0.result.rawValue)\($0.placed ? ", placed" : "")\($0.fullScreen ? ", full screen" : "") in \($0.seconds) s\($0.note.map { ". \($0)" } ?? "")" }
        return ToolOutput(text: "\(back) of \(outcomes.count) windows back.\n" + lines.joined(separator: "\n"), ok: back > 0)
    }
}
