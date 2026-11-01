import SwiftUI

struct OnboardingView: View {
    static let width: CGFloat = 480
    @ObservedObject var flow: Onboarding

    var body: some View {
        Group {
            switch flow.step {
            case .ask: AskStep(flow: flow)
            case .model: ModelStep(flow: flow)
            case .sees: SeesStep(flow: flow)
            case .access: AccessStep(flow: flow)
            case .making: MakingStep(flow: flow)
            case .job: JobStep(flow: flow)
            case .drag: DragStep(flow: flow)
            case .closing, .done: ClosingStep(flow: flow)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 38)
        .padding(.bottom, 22)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geo in
            Color.clear.onChange(of: geo.size, initial: true) { _, size in DispatchQueue.main.async { flow.fit(size) } }
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }
}

private struct Face: View {
    var look = Agent.Look.pearl
    var size: CGFloat = 46

    var body: some View {
        let frame = CreatureView.frame(size)
        CreatureView(look: look, mood: .idle, size: size, pose: .peek, limbs: 0)
            .frame(width: frame.width, height: frame.height)
            .accessibilityHidden(true)
    }
}

private struct Heading: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 8) {
            Text(verbatim: title)
                .font(.system(size: 22, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(verbatim: detail)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct Dots: View {
    let at: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<6, id: \.self) { index in
                Circle().fill(index == at ? Color.primary.opacity(0.7) : Color.primary.opacity(0.15)).frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

// The dots sit on the window's center, whatever the buttons beside them measure.
private struct Footer<Leading: View, Trailing: View>: View {
    let at: Int
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ZStack {
            HStack {
                leading
                Spacer()
                trailing
            }
            Dots(at: at)
        }
    }
}

private struct Primary: View {
    let title: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { Text(verbatim: title).frame(minWidth: 72) }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(disabled)
    }
}

private struct Quiet: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Text(verbatim: title) }
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
    }
}

private struct Panel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

private struct Line: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Color.accentColor).frame(width: 20)
            Text(verbatim: text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
    }
}

private struct Problem: View {
    let line: String

    var body: some View {
        Label { Text(verbatim: line) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
            .font(.system(size: 12))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct WordsField: View {
    let prompt: String
    @Binding var text: String
    let submit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField(prompt, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .lineLimit(2...4)
            .focused($focused)
            .padding(12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(focused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08)))
            .onSubmit(submit)
            .onAppear {
                focused = true
                // macOS selects a field's text when it takes focus, and the next key would erase the person's words. The window can become key late.
                for delay in [0.05, 0.4, 1.2] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { (NSApp.keyWindow?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil) }
                }
            }
    }
}

// MARK: The person's words

private struct AskStep: View {
    @ObservedObject var flow: Onboarding

    private var empty: Bool { flow.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 18) {
            Face()
            Heading(title: "What do you want help with?",
                    detail: "I'm Bean. I live in your Mac's notch, and I put small helpers called agents to work in your apps.")
            VStack(alignment: .leading, spacing: 10) {
                WordsField(prompt: "Say it in your own words", text: Binding(get: { flow.draft }, set: { flow.draft = $0 }), submit: flow.answer)
                Text(verbatim: "For example: write down what's decided in my meetings and send me a recap.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Footer(at: 0) {
                if empty { Quiet(title: "Not sure yet", action: flow.notSure) }
            } trailing: {
                Primary(title: "Continue", disabled: empty, action: flow.answer)
            }
        }
    }
}

// MARK: The model

private struct ModelStep: View {
    @ObservedObject var flow: Onboarding
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 18) {
            Face()
            Heading(title: "Where should my AI run?")
            Panel {
                row(selected: false, title: "On this Mac", detail: "Not available yet.").opacity(0.5)
                Divider().padding(.leading, 38)
                row(selected: true, title: "In the cloud", detail: "Muse Spark, by Meta")
            }
            VStack(alignment: .leading, spacing: 8) {
                if flow.keyFound {
                    Text(verbatim: "A Muse Spark key is already on this Mac.").font(.system(size: 13))
                } else {
                    HStack(spacing: 8) {
                        SecureField("Paste your Muse Spark key", text: $flow.key)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .focused($focused)
                            .onSubmit(flow.check)
                        if let url = AIProvider.meta.keyURL {
                            Link(destination: url) { Text(verbatim: "Get a key") }.font(.system(size: 13))
                        }
                    }
                }
                if let problem = flow.keyProblem { Problem(line: problem) }
                Text(verbatim: "A key is your access to Muse Spark, from Meta's website. Muse Spark gets what you write and what your agents read. Your key stays in this Mac's Keychain.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Footer(at: 1) {
                EmptyView()
            } trailing: {
                if flow.keyPassed {
                    Label { Text(verbatim: "It works") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        .font(.system(size: 13, weight: .medium))
                } else if flow.checking {
                    ProgressView().controlSize(.small).frame(minWidth: 72)
                } else {
                    Primary(title: "Check", disabled: !flow.keyFound && flow.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: flow.check)
                }
            }
        }
        .onAppear {
            focused = true
            flow.lookForKey()
        }
    }

    private func row(selected: Bool, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .font(.system(size: 15))
            Text(verbatim: title).font(.system(size: 13.5, weight: .medium))
            Text(verbatim: detail).font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
    }
}

// MARK: What Bean sees

private struct SeesStep: View {
    @ObservedObject var flow: Onboarding

    var body: some View {
        VStack(spacing: 16) {
            Face()
            Heading(title: "What I see on your Mac")
            Panel {
                Line(icon: "eye", text: "Which apps you use, for how long, and when a call starts.")
                Divider().padding(.leading, 44)
                Line(icon: "doc.text.magnifyingglass", text: "I read inside an app only once you put an agent on it or say yes.")
                Divider().padding(.leading, 44)
                VStack(alignment: .leading, spacing: 8) {
                    Line(icon: "lock", text: "Messages, banks, passwords and health apps stay closed.")
                    OffLimitsEditor(items: flow.offLimits, prompt: "Close another app, site or word").padding(.leading, 34).padding(.trailing, 2)
                }
            }
            Text(verbatim: "This stays on your Mac. App and window names reach Muse Spark only after a check here.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Footer(at: 2) {
                EmptyView()
            } trailing: {
                Primary(title: "Continue", action: flow.told)
            }
        }
    }
}

// MARK: The one macOS setting

private struct AccessStep: View {
    @ObservedObject var flow: Onboarding

    var body: some View {
        VStack(spacing: 16) {
            Face()
            Heading(title: "Turn on one macOS setting", detail: "So I can see your apps, and an agent can work in the one you choose.")
            Panel {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: WindowAccess.paneName).font(.system(size: 13.5, weight: .semibold))
                    Text(verbatim: "macOS warns that it covers every app. You can turn it off at any time.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            if flow.accessAsked {
                Text(verbatim: "In System Settings, turn on Bean in the list. I'll notice by myself.")
                    .font(.system(size: 13, weight: .medium)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            Footer(at: 3) {
                Quiet(title: "Not now", action: flow.make)
            } trailing: {
                if flow.accessAsked {
                    Button { flow.openPane() } label: { Text(verbatim: "Open Again") }.controlSize(.large)
                } else {
                    Primary(title: "Open Settings", action: flow.askAccess)
                }
            }
        }
    }
}

// MARK: The agent

private struct QuestionStep: View {
    @ObservedObject var flow: Onboarding
    let question: String

    var body: some View {
        VStack(spacing: 18) {
            Face()
            Heading(title: question, detail: "Say it in a few words, and I'll write the agent.")
            WordsField(prompt: "Say it in your own words", text: $flow.answerDraft, submit: flow.answerQuestion)
            Footer(at: 4) {
                EmptyView()
            } trailing: {
                Primary(title: "Continue", disabled: flow.answerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: flow.answerQuestion)
            }
        }
    }
}

private struct MakingStep: View {
    @ObservedObject var flow: Onboarding

    var body: some View {
        if let question = flow.question {
            QuestionStep(flow: flow, question: question.text)
        } else {
            VStack(spacing: 14) {
                if let problem = flow.makeProblem {
                    Problem(line: problem)
                    Primary(title: "Try Again", action: flow.make)
                } else {
                    ProgressView().controlSize(.regular)
                    Text(verbatim: "Making your first agent.").font(.system(size: 14, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}

private struct JobStep: View {
    @ObservedObject var flow: Onboarding

    var body: some View {
        if let question = flow.question {
            QuestionStep(flow: flow, question: question.text)
        } else {
            job
        }
    }

    private var job: some View {
        let name = flow.agent?.name ?? ""
        return VStack(spacing: 18) {
            Face(look: flow.agent?.look ?? .pearl)
            Heading(title: "This is \(name), your first agent", detail: "Here is \(name)'s job. Change it if it's not what you meant.")
            WordsField(prompt: "What should \(name) do?", text: $flow.jobDraft, submit: flow.confirmJob)
            if let problem = flow.makeProblem { Problem(line: problem) }
            Footer(at: 4) {
                EmptyView()
            } trailing: {
                if flow.rewriting {
                    ProgressView().controlSize(.small).frame(minWidth: 72)
                } else {
                    Primary(title: "Continue", disabled: flow.jobDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: flow.confirmJob)
                }
            }
        }
    }
}

private struct DragStep: View {
    @ObservedObject var flow: Onboarding

    var body: some View {
        let name = flow.agent?.name ?? ""
        VStack(spacing: 18) {
            Image(systemName: "arrow.up").font(.system(size: 30, weight: .semibold)).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            if flow.returned {
                Heading(title: "\(name) came back", detail: "Hold \(name) in the notch, and let go over an app.")
            } else if flow.openWindows {
                Heading(title: "Now drag \(name) onto an app",
                        detail: "\(name) is in the notch, at the top of your screen. Hold it, and let go over the app you want help in.")
            } else {
                Heading(title: "Open the app you want help in", detail: "Then drag \(name) from the notch onto it.")
            }
            Text(verbatim: "\(name) can then read everything in that app.").font(.system(size: 12.5)).foregroundStyle(.secondary)
            if flow.missed >= 2 {
                Button { flow.placeForMe() } label: { Text(verbatim: "I can't drag it. Put it there for me.") }.controlSize(.regular)
            }
            Footer(at: 5) {
                EmptyView()
            } trailing: {
                EmptyView()
            }
        }
    }
}

// MARK: The end

private struct ClosingStep: View {
    @ObservedObject var flow: Onboarding
    @ObservedObject private var installer = StrandsInstaller.shared

    var body: some View {
        let name = flow.agent?.name ?? ""
        let app = flow.agent?.attachment?.appName ?? ""
        VStack(spacing: 16) {
            Face(look: flow.agent?.look ?? .pearl)
            Heading(title: "\(name) is on \(app)", detail: "\(name) works in the background and speaks up only with something useful.")
            if !flow.accessOn {
                VStack(spacing: 6) {
                    Text(verbatim: "\(name) can't read \(app) until you turn on \(WindowAccess.paneName) in System Settings.")
                        .font(.system(size: 13)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Button { flow.openPane() } label: { Text(verbatim: "Open System Settings") }
                }
            }
            Panel {
                Line(icon: "questionmark.bubble", text: "When something needs you, I ask in the notch.")
                Divider().padding(.leading, 44)
                Line(icon: "plus.circle", text: "To add an agent, click + in the notch. To pause me, right-click it.")
            }
            setup
            HStack {
                Spacer()
                Primary(title: "Done", action: flow.finish)
            }
        }
    }

    @ViewBuilder private var setup: some View {
        switch installer.stage {
        case .running:
            Text(verbatim: "I'm still finishing my setup. You don't have to wait.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        case .failed(let line):
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Problem(line: line)
                    Button { installer.start() } label: { Text(verbatim: "Try Again") }.controlSize(.small)
                }
                Text(verbatim: "Until it finishes, I make no offers from what I notice, and no app or window name leaves this Mac.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        case .unsupported:
            Text(verbatim: "This Mac can't finish my setup, so I make no offers from what I notice, and no app or window name leaves it.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }
}
