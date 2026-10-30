import ApplicationServices
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case ai = "AI", offLimits = "Off Limits", permissions = "Permissions", sees = "What Bean Sees"
    var id: String { rawValue }
}

struct SettingsPage: View {
    let tab: SettingsTab
    let feed: PageFeed
    let actions: PageActions

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: Binding(get: { tab }, set: { actions.setSettingsTab($0) })) {
                ForEach(SettingsTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .padding(.vertical, 10)
            .accessibilityIdentifier("page-settings-tabs")
            Divider()
            switch tab {
            case .ai: AISettings()
            case .offLimits: OffLimitsSettings()
            case .permissions: PermissionSettings(notificationsOff: feed.notificationsOff, actions: actions)
            case .sees:
                WhatBeanSeesView(sees: feed.sees, decisions: feed.gate)
                    .onAppear { actions.watchSees(true) }
                    .onDisappear { actions.watchSees(false) }
            }
        }
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
            Section("Model") {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(AIProvider.allCases) { Text($0.displayName).tag($0) }
                }
                .accessibilityIdentifier("settings-provider")
                if settings.provider == .openAICompatible {
                    TextField("Address", text: $settings.customBaseURL, prompt: Text(verbatim: "http://localhost:11434/v1"))
                }
                if settings.provider == .meta {
                    Picker("Model", selection: $settings.model) {
                        ForEach(Array(Set(["muse-spark-1.3", "muse-spark-1.2", "muse-spark-1.1", settings.model])).sorted().reversed(), id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    TextField("Model", text: $settings.model, prompt: Text(verbatim: settings.provider.defaultModel.isEmpty ? "model name" : settings.provider.defaultModel))
                }
                if settings.provider.acceptsReasoningEffort {
                    Picker("Reasoning", selection: $settings.brainEffort) {
                        ForEach(["minimal", "low", "medium", "high"], id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .accessibilityIdentifier("settings-reasoning")
                }
            }
            Section("API key") {
                LabeledContent("Key") {
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
                        if let url = settings.provider.keyURL { Link("Get a key", destination: url) }
                        Spacer()
                        if keySource == .keychain { Button("Remove", role: .destructive, action: removeKey) }
                        Button("Save", action: saveKey).disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if let keyError { Text(keyError).foregroundStyle(.red) }
            }
            Section {
                Picker("Write calls down", selection: $settings.transcriber) {
                    ForEach(BeanSettings.Transcriber.allCases) { Text($0.displayName).tag($0) }
                }
            } footer: {
                Text(settings.transcriber == .apple
                     ? "The sound stays on this Mac. Bean tries your two first languages and keeps the better one."
                     : "The sound of each call you allow goes to Meta. It handles 25 languages and tells speakers apart. This Mac takes over if it fails.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if StrandsServer.isAvailable {
                Section {
                    Picker("Decisions", selection: $settings.decidesOnThisMac) {
                        Text("Local first").tag(true)
                        Text("Cloud").tag(false)
                    }
                } footer: {
                    Text("Local first runs third-party code (Strands) on this Mac, and asks Muse Spark only when it matters.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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

private struct OffLimitsSettings: View {
    @ObservedObject private var settings = BeanSettings.shared

    var body: some View {
        Form {
            Section {
                OffLimitsEditor(items: $settings.offLimits)
            } header: {
                Text("Off limits")
            } footer: {
                Text("Agents never read or touch an app, site or word on this list.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionSettings: View {
    let notificationsOff: Bool
    let actions: PageActions
    @State private var accessibility = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section {
                row("Accessibility", "To read the window an agent is on, and to act in it.", allowed: accessibility, pane: "Privacy_Accessibility")
                row("Automation", "To drive the apps you put an agent on. macOS asks for each app.", allowed: nil, pane: "Privacy_Automation")
                LabeledContent {
                    Button("Open Settings…", action: actions.openNotificationSettings)
                } label: {
                    Text("Notifications")
                    Text(notificationsOff ? "Off. Bean cannot tell you when an agent needs you." : "To tell you when an agent needs you.")
                }
            } footer: {
                Text("Bean asks only for what it uses.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in accessibility = AXIsProcessTrusted() }
    }

    private func row(_ title: String, _ why: String, allowed: Bool?, pane: String) -> some View {
        LabeledContent {
            if allowed == true {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
            } else {
                Button("Open Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
                }
            }
        } label: {
            Text(title)
            Text(why)
        }
    }
}
