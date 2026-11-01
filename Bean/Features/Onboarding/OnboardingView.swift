import SwiftUI

struct OnboardingView: View {
    static let width: CGFloat = 480
    @ObservedObject var flow: Onboarding

    private var compact: Bool { [.making, .drag, .result].contains(flow.step) }

    var body: some View {
        Group {
            switch flow.step {
            case .ask: AskStep(flow: flow)
            case .brain: BrainStep(flow: flow)
            case .sees: SeesStep(flow: flow)
            case .access: AccessStep(flow: flow)
            case .making: MakingStep(flow: flow)
            case .drag: DragStep(flow: flow)
            case .result: ResultStep(flow: flow)
            case .closing, .done: ClosingStep(flow: flow)
            }
        }
        .padding(.horizontal, compact ? 22 : 32)
        .padding(.top, compact ? 34 : 38)
        .padding(.bottom, 22)
        .frame(width: compact ? 360 : Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geo in
            Color.clear.onChange(of: geo.size, initial: true) { _, size in DispatchQueue.main.async { flow.fit(size) } }
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }
}

private struct Pearl: View {
    var size: CGFloat = 46

    var body: some View {
        let frame = CreatureView.frame(size)
        CreatureView(look: .pearl, mood: .idle, size: size, pose: .peek, limbs: 0)
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
                    .font(.system(size: 13))
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
            ForEach(0..<4, id: \.self) { index in
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

private struct Problem: View {
    let line: String

    var body: some View {
        Label { Text(verbatim: line) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
            .font(.system(size: 12))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: 1

private struct AskStep: View {
    @ObservedObject var flow: Onboarding
    @FocusState private var focused: Bool

    private var starters: [String] {
        ["Stay on top of what people ask me",
         "Get me ready before my meetings",
         "Keep track of what I promised",
         "Take small repeating tasks off my plate"]
    }

    var body: some View {
        VStack(spacing: 18) {
            Pearl()
            Heading(title: "What do you want me to take care of?",
                    detail: "I'm Bean. I run work for you on this Mac, with small helpers called agents.")
            VStack(spacing: 10) {
                TextField("One sentence is enough", text: $flow.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(2...4)
                    .focused($focused)
                    .padding(12)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(focused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08)))
                    .onSubmit(flow.answer)
                Flow(spacing: 6) {
                    ForEach(starters, id: \.self) { starter in
                        Button {
                            flow.draft = starter
                            focused = true
                        } label: {
                            Text(verbatim: starter).font(.system(size: 12.5)).padding(.vertical, 5).padding(.horizontal, 10)
                                .background(Color.primary.opacity(0.07), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Footer(at: 0) {
                Quiet(title: "Not sure yet", action: flow.notSure)
            } trailing: {
                Primary(title: "Continue", disabled: flow.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: flow.answer)
            }
        }
        .onAppear { focused = true }
    }
}

// MARK: 2

private struct BrainStep: View {
    @ObservedObject var flow: Onboarding
    @FocusState private var focused: Bool

    private var title: String {
        flow.saved.sentence == nil
            ? "I need a brain. Where should it run?"
            : "To work on that, I need a brain. Where should it run?"
    }

    var body: some View {
        VStack(spacing: 18) {
            Pearl()
            Heading(title: title)
            Panel {
                row(selected: false, title: "On this Mac", detail: "Not available yet.").opacity(0.5)
                Divider().padding(.leading, 38)
                row(selected: true, title: "In the cloud", detail: nil)
                HStack(spacing: 8) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accentColor)
                    Text(verbatim: "Muse Spark, by Meta").font(.system(size: 13))
                    Spacer()
                }
                .padding(.leading, 38).padding(.trailing, 12).padding(.bottom, 12)
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
                Text(verbatim: "It receives what you write, the window an agent is on, and app and window names after a private check on this Mac. The key stays in your Keychain.")
                    .font(.system(size: 11.5))
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

    private func row(selected: Bool, title: String, detail: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .font(.system(size: 15))
            Text(verbatim: title).font(.system(size: 13.5, weight: .medium))
            if let detail { Text(verbatim: detail).font(.system(size: 13)).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(12)
    }
}

// MARK: 3

private struct InstallLine: View {
    @ObservedObject private var installer = StrandsInstaller.shared

    var body: some View {
        switch installer.stage {
        case .idle:
            EmptyView()
        case .running(let done):
            HStack(spacing: 8) {
                ProgressView(value: done).progressViewStyle(.linear).controlSize(.small).frame(width: 70)
                Text(verbatim: "Installing the check, about 6 GB. You can carry on.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .ready:
            Label { Text(verbatim: "The check is on.") } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        case .failed(let line):
            HStack(spacing: 8) {
                Problem(line: line)
                Button { installer.start() } label: { Text(verbatim: "Try again") }.controlSize(.small)
            }
        case .unsupported:
            Text(verbatim: "This Mac cannot run the check, so window names stay here.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}

private struct SeesStep: View {
    @ObservedObject var flow: Onboarding

    var body: some View {
        VStack(spacing: 16) {
            Pearl()
            Heading(title: "Here is what I see")
            Panel {
                line("eye", "What I notice",
                     "Which apps and windows you use and for how long, when a call starts, and what changes in a service you connect. This log stays on this Mac.")
                Divider().padding(.leading, 44)
                line("doc.text.magnifyingglass", "What I read",
                     "Nothing inside a window, until an agent is on it or you say yes.")
                Divider().padding(.leading, 44)
                VStack(alignment: .leading, spacing: 6) {
                    line("cloud", "What leaves this Mac",
                         "Window names, only after a private check by Strands, a model that runs here.")
                    InstallLine().padding(.leading, 44).padding(.trailing, 12).padding(.bottom, 10)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "Closed already: messages, banks, passwords and health apps. I keep no window names for them.")
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                OffLimitsEditor(items: flow.offLimits, prompt: "Close something else: an app, a site or a word")
                Text(verbatim: "To pause me at any time, right-click the notch.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Footer(at: 2) {
                EmptyView()
            } trailing: {
                Primary(title: "Continue", action: flow.told)
            }
        }
    }

    private func line(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Color.accentColor).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.system(size: 13, weight: .semibold))
                Text(verbatim: detail).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }
}

// MARK: 4

private struct AccessStep: View {
    @ObservedObject var flow: Onboarding

    var body: some View {
        VStack(spacing: 16) {
            Pearl()
            if flow.accessOn {
                Heading(title: "It works.",
                        detail: flow.accessProof.map { "I can see: \($0)" })
            } else {
                Heading(title: "macOS needs one switch from you")
                Panel {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: WindowAccess.paneName).font(.system(size: 13.5, weight: .semibold))
                        Text(verbatim: "It covers every app at once, so macOS lists all an app could do with it, like reading mail or watching the keyboard. I use it to read the window an agent is on and to see window names.")
                            .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: "You can turn it off at any time.")
                            .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
                if flow.accessAsked {
                    VStack(spacing: 6) {
                        Text(verbatim: "In System Settings, turn on Bean in the list. I carry on by myself.")
                            .font(.system(size: 13)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        Button { flow.openPane() } label: { Text(verbatim: "Open System Settings again") }
                            .buttonStyle(.link).font(.system(size: 12))
                    }
                }
            }
            Footer(at: 3) {
                if !flow.accessOn {
                    Quiet(title: "Not now", action: flow.leaveAccess)
                }
            } trailing: {
                if flow.accessOn {
                    Primary(title: "Continue", action: flow.leaveAccess)
                } else if !flow.accessAsked {
                    Primary(title: "Open System Settings", action: flow.askAccess)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }
}

// MARK: 5

private struct MakingStep: View {
    @ObservedObject var flow: Onboarding

    var body: some View {
        VStack(spacing: 14) {
            if let problem = flow.makeProblem {
                Problem(line: problem)
                Primary(title: "Try again", action: flow.make)
            } else {
                ProgressView().controlSize(.regular)
                Text(verbatim: "Making your first agent.").font(.system(size: 14, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

private struct DragStep: View {
    @ObservedObject var flow: Onboarding
    @State private var correcting = false

    var body: some View {
        let name = flow.agent?.name ?? ""
        VStack(alignment: .leading, spacing: 12) {
            if flow.holding {
                Text(verbatim: "Let go on the window.").font(.system(size: 16, weight: .semibold))
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(Color.accentColor)
                    Text(verbatim: flow.returned
                         ? "It came back. Hold \(name) and let go over a window."
                         : flow.openWindows
                         ? "Drag \(name) from the notch onto the window that holds this."
                         : "Open what you'd like it to work on, then drag \(name) there.")
                        .font(.system(size: 16, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: "That window becomes its work. Any window will do.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let job = flow.job {
                    Divider()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(name)'s job").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Text(verbatim: job).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                    if correcting {
                        TextField("Say what it should do", text: $flow.correction)
                            .textFieldStyle(.roundedBorder).onSubmit(flow.correct)
                    } else {
                        Quiet(title: "Not right? Tell me.") { correcting = true }
                    }
                }
                if flow.missed >= 2 {
                    Button { flow.placeForMe() } label: { Text(verbatim: "I can't drag it. Put it there for me.") }
                        .controlSize(.regular)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: 6

private struct ResultStep: View {
    @ObservedObject var flow: Onboarding

    var body: some View {
        let name = flow.agent?.name ?? ""
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let agent = flow.agent {
                    let frame = CreatureView.frame(26)
                    CreatureView(look: agent.look, mood: flow.working ? .working : .idle, size: 26, pose: .peek, limbs: 0)
                        .frame(width: frame.width, height: frame.height)
                }
                Text(verbatim: flow.agent?.attachment?.windowTitle ?? flow.agent?.attachment?.appName ?? "")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            if !flow.accessOn {
                Text(verbatim: "To read this window I need the switch: \(WindowAccess.paneName). Once it is on, I carry on by myself.")
                    .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                Button { flow.openPane() } label: { Text(verbatim: "Open System Settings") }
            } else if let found = flow.found {
                if !flow.unreadable { Text(verbatim: "I read this window.").font(.system(size: 16, weight: .semibold)) }
                ScrollView {
                    Text(verbatim: found).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: flow.unreadable ? "You can drag \(name) onto another window." : "I changed nothing.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                TextField("No, do this instead", text: $flow.reply).textFieldStyle(.roundedBorder).onSubmit(flow.tell)
                if flow.working { ProgressView().controlSize(.small) }
            } else if let problem = flow.problem {
                Problem(line: problem)
                Button { flow.lookAgain() } label: { Text(verbatim: "Try again") }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: "\(name) is reading this window.").font(.system(size: 14, weight: .medium))
                }
            }
            if flow.askedInNotch {
                Text(verbatim: "\(name) has a question for you, in the notch.").font(.system(size: 12.5)).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Primary(title: "Continue", disabled: flow.found == nil && flow.accessOn && flow.problem == nil, action: flow.finishResult)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: 7

private struct ClosingStep: View {
    @ObservedObject var flow: Onboarding
    @ObservedObject private var installer = StrandsInstaller.shared

    var body: some View {
        VStack(spacing: 16) {
            Pearl()
            Heading(title: "I'll take it from here.")
            Panel {
                line("checkmark.circle", "I act on my own, and tell you in the notch. You can undo it.")
                Divider().padding(.leading, 44)
                line("questionmark.circle", "I ask only when I'd read something new, reach someone else, or do what can't be undone.")
                Divider().padding(.leading, 44)
                line("eye", "I watch which apps and windows you use, on this Mac. I read nothing inside them until you say yes.")
                Divider().padding(.leading, 44)
                line("plus.circle", "To make another agent, click + in the notch. I can also offer to place one.")
            }
            if case .running = installer.stage {
                Text(verbatim: "The private check is still installing and turns on by itself. Until then, window names stay on this Mac.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Primary(title: "Done", action: flow.finish)
            }
        }
    }

    private func line(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Color.accentColor).frame(width: 20)
            Text(verbatim: text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
    }
}
