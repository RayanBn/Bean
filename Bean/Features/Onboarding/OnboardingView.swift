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
        [say("Stay on top of what people ask me", "Suivre ce qu'on me demande"),
         say("Get me ready before my meetings", "Me préparer avant mes réunions"),
         say("Keep track of what I promised", "Garder la trace de ce que j'ai promis"),
         say("Take small repeating tasks off my plate", "Me décharger des petites tâches répétitives")]
    }

    var body: some View {
        VStack(spacing: 18) {
            Pearl()
            Heading(title: say("What do you want me to take care of?", "De quoi voulez-vous que je m'occupe ?"),
                    detail: say("I'm Bean. I run work for you on this Mac, with small helpers called agents.", "Je suis Bean. Je fais avancer votre travail sur ce Mac, avec de petits assistants : les agents."))
            VStack(spacing: 10) {
                TextField(say("One sentence is enough", "Une phrase suffit"), text: $flow.draft, axis: .vertical)
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
            HStack {
                Quiet(title: say("Not sure yet", "Je ne sais pas encore"), action: flow.notSure)
                Spacer()
                Dots(at: 0)
                Spacer()
                Primary(title: say("Continue", "Continuer"), disabled: flow.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: flow.answer)
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
            ? say("I need a brain. Where should it run?", "Il me faut un cerveau. Où doit-il tourner ?")
            : say("To work on that, I need a brain. Where should it run?", "Pour m'en occuper, il me faut un cerveau. Où doit-il tourner ?")
    }

    var body: some View {
        VStack(spacing: 18) {
            Pearl()
            Heading(title: title)
            Panel {
                row(selected: false, title: say("On this Mac", "Sur ce Mac"), detail: say("Not available yet.", "Pas encore disponible.")).opacity(0.5)
                Divider().padding(.leading, 38)
                row(selected: true, title: say("In the cloud", "Dans le cloud"), detail: nil)
                HStack(spacing: 8) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accentColor)
                    Text(verbatim: say("Muse Spark, by Meta", "Muse Spark, de Meta")).font(.system(size: 13))
                    Spacer()
                }
                .padding(.leading, 38).padding(.trailing, 12).padding(.bottom, 12)
            }
            VStack(alignment: .leading, spacing: 8) {
                if flow.keyFound {
                    Text(verbatim: say("A Muse Spark key is already on this Mac.", "Une clé Muse Spark est déjà sur ce Mac.")).font(.system(size: 13))
                } else {
                    HStack(spacing: 8) {
                        SecureField(say("Paste your Muse Spark key", "Collez votre clé Muse Spark"), text: $flow.key)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .focused($focused)
                            .onSubmit(flow.check)
                        if let url = AIProvider.meta.keyURL {
                            Link(destination: url) { Text(verbatim: say("Get a key", "Obtenir une clé")) }.font(.system(size: 13))
                        }
                    }
                }
                if let problem = flow.keyProblem { Problem(line: problem) }
                Text(verbatim: say("It receives what you write, the window an agent is on, and app and window names after a private check on this Mac. The key stays in your Keychain.",
                                   "Il reçoit ce que vous écrivez, la fenêtre où se trouve un agent, et les noms d'apps et de fenêtres après un contrôle privé sur ce Mac. La clé reste dans votre trousseau."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Color.clear.frame(width: 72, height: 1)
                Spacer()
                Dots(at: 1)
                Spacer()
                if flow.keyPassed {
                    Label { Text(verbatim: say("It works", "Ça marche")) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        .font(.system(size: 13, weight: .medium))
                } else if flow.checking {
                    ProgressView().controlSize(.small).frame(minWidth: 72)
                } else {
                    Primary(title: say("Check", "Vérifier"), disabled: !flow.keyFound && flow.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: flow.check)
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
                Text(verbatim: say("Installing the check, about 6 GB. You can carry on.", "Installation du contrôle, environ 6 Go. Vous pouvez continuer."))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .ready:
            Label { Text(verbatim: say("The check is on.", "Le contrôle est actif.")) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        case .failed(let line):
            HStack(spacing: 8) {
                Problem(line: line)
                Button { installer.start() } label: { Text(verbatim: say("Try again", "Réessayer")) }.controlSize(.small)
            }
        case .unsupported:
            Text(verbatim: say("This Mac cannot run the check, so window names stay here.", "Ce Mac ne peut pas faire ce contrôle : les noms de fenêtres restent ici."))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}

private struct SeesStep: View {
    @ObservedObject var flow: Onboarding

    var body: some View {
        VStack(spacing: 16) {
            Pearl()
            Heading(title: say("Here is what I see", "Voici ce que je vois"))
            Panel {
                line("eye", say("What I notice", "Ce que je remarque"),
                     say("Which apps and windows you use and for how long, when a call starts, and what changes in a service you connect. This log stays on this Mac.",
                         "Les apps et fenêtres que vous utilisez et combien de temps, le début d'un appel, et ce qui change dans un service connecté. Ce journal reste sur ce Mac."))
                Divider().padding(.leading, 44)
                line("doc.text.magnifyingglass", say("What I read", "Ce que je lis"),
                     say("Nothing inside a window, until an agent is on it or you say yes.", "Rien dans une fenêtre, tant qu'aucun agent n'y est et que vous n'avez pas dit oui."))
                Divider().padding(.leading, 44)
                VStack(alignment: .leading, spacing: 6) {
                    line("cloud", say("What leaves this Mac", "Ce qui quitte ce Mac"),
                         say("Window names, only after a private check by Strands, a model that runs here.", "Les noms de fenêtres, seulement après un contrôle privé par Strands, un modèle qui tourne ici."))
                    InstallLine().padding(.leading, 44).padding(.trailing, 12).padding(.bottom, 10)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: say("Closed already: messages, banks, passwords and health apps. I keep no window names for them.",
                                   "Déjà fermés : messageries, banques, mots de passe et apps de santé. Je ne garde aucun nom de fenêtre pour eux."))
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                OffLimitsEditor(items: flow.offLimits, prompt: say("Close something else: an app, a site or a word", "Fermer autre chose : une app, un site ou un mot"))
                Text(verbatim: say("To pause me at any time, right-click the notch.", "Pour me mettre en pause à tout moment, faites un clic droit sur l'encoche."))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Color.clear.frame(width: 72, height: 1)
                Spacer()
                Dots(at: 2)
                Spacer()
                Primary(title: say("Continue", "Continuer"), action: flow.told)
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
                Heading(title: say("It works.", "Ça marche."),
                        detail: flow.accessProof.map { say("I can see: \($0)", "Je vois : \($0)") })
            } else {
                Heading(title: say("macOS needs one switch from you", "macOS a besoin d'un réglage de votre part"))
                Panel {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: WindowAccess.paneName).font(.system(size: 13.5, weight: .semibold))
                        Text(verbatim: say("It covers every app at once, so macOS lists all an app could do with it, like reading mail or watching the keyboard. I use it to read the window an agent is on and to see window names.",
                                           "Il vaut pour toutes les apps à la fois, alors macOS liste tout ce qu'une app pourrait en faire, comme lire le courrier ou surveiller le clavier. Je m'en sers pour lire la fenêtre où se trouve un agent et voir les noms de fenêtres."))
                            .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: say("You can turn it off at any time.", "Vous pouvez le couper à tout moment."))
                            .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
                if flow.accessAsked {
                    VStack(spacing: 6) {
                        Text(verbatim: say("In System Settings, turn on Bean in the list. I carry on by myself.", "Dans Réglages Système, activez Bean dans la liste. Je continue tout seul."))
                            .font(.system(size: 13)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        Button { flow.openPane() } label: { Text(verbatim: say("Open System Settings again", "Rouvrir Réglages Système")) }
                            .buttonStyle(.link).font(.system(size: 12))
                    }
                }
            }
            HStack {
                if flow.accessOn { Color.clear.frame(width: 72, height: 1) } else {
                    Quiet(title: say("Not now", "Pas maintenant"), action: flow.leaveAccess)
                }
                Spacer()
                Dots(at: 3)
                Spacer()
                if flow.accessOn {
                    Primary(title: say("Continue", "Continuer"), action: flow.leaveAccess)
                } else if !flow.accessAsked {
                    Primary(title: say("Open System Settings", "Ouvrir Réglages Système"), action: flow.askAccess)
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
                Primary(title: say("Try again", "Réessayer"), action: flow.make)
            } else {
                ProgressView().controlSize(.regular)
                Text(verbatim: say("Making your first agent.", "Je crée votre premier agent.")).font(.system(size: 14, weight: .medium))
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
                Text(verbatim: say("Let go on the window.", "Lâchez sur la fenêtre.")).font(.system(size: 16, weight: .semibold))
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(Color.accentColor)
                    Text(verbatim: flow.returned
                         ? say("It came back. Hold \(name) and let go over a window.", "Il est revenu. Maintenez \(name) et lâchez au-dessus d'une fenêtre.")
                         : flow.openWindows
                         ? say("Drag \(name) from the notch onto the window that holds this.", "Glissez \(name) depuis l'encoche sur la fenêtre où se trouve ce travail.")
                         : say("Open what you'd like it to work on, then drag \(name) there.", "Ouvrez ce sur quoi il doit travailler, puis glissez \(name) dessus."))
                        .font(.system(size: 16, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: say("That window becomes its work. Any window will do.", "Cette fenêtre devient son travail. N'importe laquelle convient."))
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let job = flow.job {
                    Divider()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: say("\(name)'s job", "La mission de \(name)")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Text(verbatim: job).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                    if correcting {
                        TextField(say("Say what it should do", "Dites ce qu'il doit faire"), text: $flow.correction)
                            .textFieldStyle(.roundedBorder).onSubmit(flow.correct)
                    } else {
                        Quiet(title: say("Not right? Tell me.", "Ce n'est pas ça ? Dites-le-moi.")) { correcting = true }
                    }
                }
                if flow.missed >= 2 {
                    Button { flow.placeForMe() } label: { Text(verbatim: say("I can't drag it. Put it there for me.", "Je n'arrive pas à le glisser. Posez-le pour moi.")) }
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
                Text(verbatim: say("To read this window I need the switch: \(WindowAccess.paneName). Once it is on, I carry on by myself.", "Pour lire cette fenêtre, il me faut le réglage : \(WindowAccess.paneName). Dès qu'il est activé, je continue tout seul."))
                    .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                Button { flow.openPane() } label: { Text(verbatim: say("Open System Settings", "Ouvrir Réglages Système")) }
            } else if let found = flow.found {
                Text(verbatim: say("I read this window.", "J'ai lu cette fenêtre.")).font(.system(size: 16, weight: .semibold))
                ScrollView {
                    Text(verbatim: found).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: say("I changed nothing.", "Je n'ai rien changé.")).font(.system(size: 12.5)).foregroundStyle(.secondary)
                TextField(say("No, do this instead", "Non, faites plutôt ceci"), text: $flow.reply).textFieldStyle(.roundedBorder).onSubmit(flow.tell)
                if flow.working { ProgressView().controlSize(.small) }
            } else if let problem = flow.problem {
                Problem(line: problem)
                Button { flow.lookAgain() } label: { Text(verbatim: say("Try again", "Réessayer")) }
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: say("\(name) is reading this window.", "\(name) lit cette fenêtre.")).font(.system(size: 14, weight: .medium))
                }
            }
            if flow.askedInNotch {
                Text(verbatim: say("\(name) has a question for you, in the notch.", "\(name) a une question pour vous, dans l'encoche.")).font(.system(size: 12.5)).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Primary(title: say("Continue", "Continuer"), disabled: flow.found == nil && flow.accessOn && flow.problem == nil, action: flow.finishResult)
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
            Heading(title: say("I'll take it from here.", "Je prends le relais."))
            Panel {
                line("checkmark.circle", say("I act on my own, and tell you in the notch. You can undo it.", "J'agis seul et je vous le dis dans l'encoche. Vous pouvez annuler."))
                Divider().padding(.leading, 44)
                line("questionmark.circle", say("I ask only when I'd read something new, reach someone else, or do what can't be undone.", "Je demande seulement pour lire quelque chose de nouveau, toucher quelqu'un d'autre, ou faire ce qui ne s'annule pas."))
                Divider().padding(.leading, 44)
                line("eye", say("I watch which apps and windows you use, on this Mac. I read nothing inside them until you say yes.", "Je regarde quelles apps et fenêtres vous utilisez, sur ce Mac. Je ne lis rien dedans sans votre oui."))
                Divider().padding(.leading, 44)
                line("plus.circle", say("To make another agent, click + in the notch. I can also offer to place one.", "Pour créer un autre agent, cliquez sur + dans l'encoche. Je peux aussi proposer d'en placer un."))
            }
            if case .running = installer.stage {
                Text(verbatim: say("The private check is still installing and turns on by itself. Until then, window names stay on this Mac.", "Le contrôle privé s'installe encore et s'activera tout seul. D'ici là, les noms de fenêtres restent sur ce Mac."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Primary(title: say("Done", "Terminé"), action: flow.finish)
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
