import ApplicationServices
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var settings: BeanSettings
    @ObservedObject var notch: NotchModel
    let openAgents: () -> Void
    let close: () -> Void

    @State private var keySource = APIKeyStore.current(for: BeanSettings.shared.provider).source
    @State private var editingKey = false
    @State private var keyDraft = ""
    @State private var keyError: String?
    @State private var accessibility = AXIsProcessTrusted()
    @AppStorage("menuBarSettingsOpen") private var settingsOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            card {
                row("sparkles", "Provider") {
                    Picker("", selection: $settings.provider) {
                        ForEach(AIProvider.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
                if settings.provider == .openAICompatible {
                    row("link", "Base URL") { field("http://localhost:11434/v1", $settings.customBaseURL) }
                }
                row("cpu", "Model") { modelControl }
                if settings.provider.acceptsReasoningEffort {
                    row("brain", "Reasoning") {
                        Picker("", selection: $settings.brainEffort) {
                            ForEach(["minimal", "low", "medium", "high"], id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                    }
                }
                row("key", "API key") {
                    HStack(spacing: 6) {
                        pill(keyLabel, ok: keySource != .missing, neutral: keySource == .missing && settings.provider.keyIsOptional)
                        Button(keySource == .missing ? "Add" : "Change") { editingKey.toggle() }
                            .buttonStyle(.link).font(.system(size: 11))
                    }
                }
                if editingKey || (keySource == .missing && !settings.provider.keyIsOptional) { keyField }
            }
            settingsGroup
            if !accessibility { permissions }
            footer
        }
        .padding(12)
        .frame(width: 320)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in refresh() }
        .onAppear(perform: refresh)
        .onChange(of: settings.provider) {
            editingKey = false
            keyDraft = ""
            keyError = nil
            refresh()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: MenuBarController.glyph(paused: settings.paused))
                .renderingMode(.template)
                .foregroundStyle(settings.paused ? Color.secondary : Color.primary)
                .scaleEffect(1.3)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("Bean").font(.system(size: 13, weight: .semibold))
                Text(settings.paused ? "Paused" : "Running").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Running", isOn: Binding(get: { !settings.paused }, set: { settings.paused = !$0 }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .help(settings.paused ? "Resume" : "Pause")
        }
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SecureField("Paste your \(settings.provider.displayName) key", text: $keyDraft)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .onSubmit(saveKey)
                Button("Save", action: saveKey).controlSize(.small)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                if let url = settings.provider.keyURL { Link("Get a key", destination: url) }
                Spacer()
                if keySource == .keychain { Button("Remove", role: .destructive, action: removeKey).buttonStyle(.link) }
            }
            .font(.system(size: 11))
            if let keyError { Text(keyError).font(.system(size: 11)).foregroundStyle(.red) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var settingsGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { settingsOpen.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text("Off limits").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(settingsOpen ? 90 : 0))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .accessibilityLabel("Off limits")
            if settingsOpen {
                card {
                    row("hand.raised", "Off limits") {
                        Text(settings.offLimits.isEmpty ? "None" : "\(settings.offLimits.count)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    OffLimitsEditor(items: $settings.offLimits)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var permissions: some View {
        card {
            if !accessibility {
                permissionRow("Accessibility", "To read the window you drop an agent on", pane: "Privacy_Accessibility")
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().padding(.bottom, 4)
            menuButton("Open Agents", action: openAgents)
            menuButton("About Bean") {
                close()
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(nil)
            }
            menuButton("Quit Bean", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func row(_ symbol: String, _ title: String, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
            Text(title).font(.system(size: 12))
            Spacer(minLength: 8)
            trailing()
        }
        .frame(minHeight: 28)
        .padding(.horizontal, 10)
    }

    private func permissionRow(_ title: String, _ why: String, pane: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                Text(why).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    private func menuButton(_ title: String, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                if let shortcut { Text(shortcut).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 4).frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var modelControl: some View {
        if settings.provider == .meta {
            Picker("", selection: $settings.model) {
                ForEach(Array(Set(["muse-spark-1.3", "muse-spark-1.2", "muse-spark-1.1", settings.model])).sorted().reversed(), id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
        } else {
            field(settings.provider.defaultModel.isEmpty ? "model name" : settings.provider.defaultModel, $settings.model)
        }
    }

    private func field(_ placeholder: String, _ text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.roundedBorder).controlSize(.small)
            .multilineTextAlignment(.trailing)
            .frame(width: 170)
    }

    private func pill(_ text: String, ok: Bool, neutral: Bool = false) -> some View {
        let color: Color = neutral ? .secondary : ok ? .green : .orange
        return Text(neutral ? "Optional" : text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private var keyLabel: String {
        switch keySource {
        case .environment: return "Set by environment"
        case .repoEnvFile: return "Set by environment"
        case .keychain: return "Keychain"
        case .missing: return "Missing"
        }
    }

    private func refresh() {
        keySource = APIKeyStore.current(for: settings.provider).source
        accessibility = AXIsProcessTrusted()
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
