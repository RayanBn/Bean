import ApplicationServices
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General", bean = "Bean", ai = "AI", connectors = "Connectors", offLimits = "Off Limits", permissions = "Permissions", sees = "What Bean Sees"
    var id: String { rawValue }
}

struct SettingsPage: View {
    let tab: SettingsTab
    var agents: [Agent] = []
    let feed: PageFeed
    let actions: PageActions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { actions.closeSettings() } label: { Label(AgentStrings.shown("Back"), systemImage: "chevron.left") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("page-settings-back")
                Spacer()
                Picker(AgentStrings.shown("Section"), selection: Binding(get: { tab }, set: { actions.setSettingsTab($0) })) {
                    ForEach(SettingsTab.allCases) { Text(AgentStrings.shown($0.rawValue)).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("page-settings-tabs")
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            switch tab {
            case .general: GeneralSettings(agents: agents, feed: feed, actions: actions)
            case .bean:
                if let bean = agents.first(where: \.isBean) {
                    AgentInspector(agent: bean, mission: feed.missions[bean.id], targets: feed.targets[bean.id] ?? [], connectors: feed.connectors[bean.id] ?? [], allAbilities: feed.abilities[bean.id] ?? [], actions: actions)
                }
            case .ai: AISettings()
            case .connectors: ConnectorsPage(entries: feed.catalogue, agents: agents, actions: actions)
            case .offLimits: OffLimitsSettings()
            case .permissions: PermissionSettings(notificationsOff: feed.notificationsOff, actions: actions)
            case .sees:
                WhatBeanSeesView(sees: feed.sees, decisions: feed.gate)
                    .onAppear { actions.watchSees(true) }
                    .onDisappear { actions.watchSees(false) }
            }
        }
        .accessibilityIdentifier("page-settings")
    }
}

private struct GeneralSettings: View {
    let agents: [Agent]
    let feed: PageFeed
    let actions: PageActions
    @State private var language = UserProfile.current.language ?? ""

    private static let languages = ["English", "French", "Spanish", "German", "Italian", "Portuguese"]

    var body: some View {
        Form {
            Section {
                Toggle(AgentStrings.shown("Pause All Agents"), isOn: Binding(get: { feed.allPaused }, set: { $0 ? actions.pauseAll() : actions.resume() }))
                    .accessibilityIdentifier("page-pause-all")
            } footer: {
                Text(AgentStrings.shown("While paused, agents read nothing and make no model calls."))
            }
            Section(AgentStrings.shown("Language")) {
                Picker(AgentStrings.shown("Bean writes in"), selection: $language) {
                    Text(AgentStrings.shown("Same as my messages")).tag("")
                    ForEach(Set(Self.languages + [language]).filter { !$0.isEmpty }.sorted(), id: \.self) { Text(AgentStrings.shown($0)).tag($0) }
                }
                .onChange(of: language) { _, chosen in actions.setLanguage(chosen.isEmpty ? nil : chosen) }
                .accessibilityIdentifier("settings-language")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AISettings: View {
    @ObservedObject private var settings = BeanSettings.shared
    @State private var keySource = APIKeyStore.current(for: BeanSettings.shared.provider).source
    @State private var editingKey = false
    @State private var keyDraft = ""
    @State private var keyError: String?

    var body: some View {
        Form {
            Section(AgentStrings.shown("Model")) {
                Picker(AgentStrings.shown("Provider"), selection: $settings.provider) {
                    ForEach(AIProvider.allCases) { Text($0.displayName).tag($0) }
                }
                .accessibilityIdentifier("settings-provider")
                if settings.provider == .openAICompatible {
                    TextField(AgentStrings.shown("Address"), text: $settings.customBaseURL, prompt: Text(verbatim: "http://localhost:11434/v1"))
                }
                if settings.provider == .meta {
                    Picker(AgentStrings.shown("Model"), selection: $settings.model) {
                        ForEach(Array(Set(["muse-spark-1.3", "muse-spark-1.2", "muse-spark-1.1", settings.model])).sorted().reversed(), id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    TextField(AgentStrings.shown("Model"), text: $settings.model, prompt: Text(verbatim: settings.provider.defaultModel.isEmpty ? "model name" : settings.provider.defaultModel))
                }
                if settings.provider.acceptsReasoningEffort {
                    Picker(AgentStrings.shown("Reasoning"), selection: $settings.brainEffort) {
                        ForEach(["minimal", "low", "medium", "high"], id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .accessibilityIdentifier("settings-reasoning")
                }
            }
            Section(AgentStrings.shown("API key")) {
                LabeledContent(AgentStrings.shown("Key")) {
                    HStack(spacing: 8) {
                        Text(keyLabel).foregroundStyle(keySource == .missing && !settings.provider.keyIsOptional ? Color.orange : .secondary)
                        Button(keySource == .missing ? "Add…" : "Change…") { editingKey.toggle() }
                            .accessibilityIdentifier("settings-key")
                    }
                }
                if editingKey || (keySource == .missing && !settings.provider.keyIsOptional) {
                    SecureField("Paste your \(settings.provider.displayName) key", text: $keyDraft)
                        .onSubmit(saveKey)
                    HStack {
                        if let url = settings.provider.keyURL { Link(AgentStrings.shown("Get a key"), destination: url) }
                        Spacer()
                        if keySource == .keychain { Button(AgentStrings.shown("Remove"), role: .destructive, action: removeKey) }
                        Button(AgentStrings.shown("Save"), action: saveKey).disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if let keyError { Text(keyError).foregroundStyle(.red) }
            }
            Section {
                Picker(AgentStrings.shown("Write calls down"), selection: $settings.transcriber) {
                    ForEach(BeanSettings.Transcriber.allCases) { Text($0.displayName).tag($0) }
                }
            } footer: {
                Text(settings.transcriber == .apple
                     ? "The sound stays on this Mac. Bean tries your two first languages and keeps the better one."
                     : "The audio and transcript of each call you allow go to Meta. It handles 25 languages and tells speakers apart. This Mac takes over if it fails.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if StrandsServer.isAvailable {
                    Picker(AgentStrings.shown("Decisions"), selection: $settings.decidesOnThisMac) {
                        Text(AgentStrings.shown("Local first")).tag(true)
                        Text(AgentStrings.shown("Cloud")).tag(false)
                    }
                } else {
                    StrandsInstallRow()
                }
            } footer: {
                Text(AgentStrings.shown("Local first runs third-party code (Strands) on this Mac, and asks Muse Spark only when it matters. Without it, no window name leaves this Mac, unless you turn off the check below."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(AgentStrings.shown("Check window titles on this Mac first"), isOn: $settings.filtersWhatBeanSees)
                    .accessibilityIdentifier("settings-local-filter")
            } footer: {
                Text(AgentStrings.shown(settings.filtersWhatBeanSees ? "Bean checks each window title on this Mac first, and holds back what looks private or not like work. If the check cannot run, nothing is sent." : "The titles of your windows go to the model without being checked on your Mac first. Off Limits still applies."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onChange(of: settings.provider) {
            editingKey = false
            keyDraft = ""
            keyError = nil
            refresh()
        }
    }

    private var keyLabel: String {
        if keySource == .missing && settings.provider.keyIsOptional { return "Optional" }
        switch keySource {
        case .environment, .repoEnvFile: return "Set by environment"
        case .keychain: return "In your Keychain"
        case .missing: return "Missing"
        }
    }

    private func refresh() {
        keySource = APIKeyStore.current(for: settings.provider).source
    }

    private func saveKey() {
        do {
            try APIKeyStore.save(keyDraft, for: settings.provider)
            keyDraft = ""
            keyError = nil
            editingKey = false
            refresh()
            Task { keyError = await ModelClient().checkKey() }
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func removeKey() {
        APIKeyStore.delete(for: settings.provider)
        refresh()
    }
}

private struct StrandsInstallRow: View {
    @ObservedObject private var installer = StrandsInstaller.shared

    var body: some View {
        LabeledContent(AgentStrings.shown("Private check")) {
            switch installer.stage {
            case .running(let done):
                ProgressView(value: done).frame(width: 120)
            case .unsupported:
                Text(AgentStrings.shown("Needs an Apple silicon Mac")).foregroundStyle(.secondary)
            case .failed(let line):
                HStack {
                    Text(line).foregroundStyle(.orange)
                    Button(AgentStrings.shown("Try Again")) { installer.start() }
                }
            default:
                Button(AgentStrings.shown("Install")) { installer.start() }.disabled(!installer.isWanted)
            }
        }
    }
}

private struct OffLimitsSettings: View {
    @ObservedObject private var settings = BeanSettings.shared

    var body: some View {
        Form {
            Section {
                OffLimitsEditor(items: $settings.offLimits)
            } header: {
                Text(AgentStrings.shown("Off limits"))
            } footer: {
                Text(AgentStrings.shown("Agents never read or touch an app, site or word on this list.")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionSettings: View {
    let notificationsOff: Bool
    let actions: PageActions
    @State private var accessibility = WindowAccess.isOn

    var body: some View {
        Form {
            Section {
                row(WindowAccess.paneName, "To read the window an agent is on and see window names, and to act in that window.", allowed: accessibility, pane: "Privacy_Accessibility")
                row("Automation", "To drive the apps you put an agent on. macOS asks for each app.", allowed: nil, pane: "Privacy_Automation")
                LabeledContent {
                    Button(AgentStrings.shown("Open Settings…"), action: actions.openNotificationSettings)
                } label: {
                    Text(AgentStrings.shown("Notifications"))
                    Text(notificationsOff ? "Off. Bean cannot tell you when an agent needs you." : "To tell you when an agent needs you.")
                }
            } footer: {
                Text(AgentStrings.shown("Bean asks only for what it uses.")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in accessibility = WindowAccess.isOn }
    }

    private func row(_ title: String, _ why: String, allowed: Bool?, pane: String) -> some View {
        LabeledContent {
            if allowed == true {
                Label(AgentStrings.shown("Allowed"), systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
            } else {
                Button(AgentStrings.shown("Open Settings…")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
                }
            }
        } label: {
            Text(title)
            Text(why)
        }
    }
}
