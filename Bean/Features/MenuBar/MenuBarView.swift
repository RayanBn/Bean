import ApplicationServices
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var settings: BeanSettings
    @ObservedObject var notch: NotchModel
    let localGateAvailable: Bool
    let shellLog: URL
    let openInspector: () -> Void
    let close: () -> Void

    @State private var keySource = APIKeyStore.current(for: BeanSettings.shared.provider).source
    @State private var editingKey = false
    @State private var keyDraft = ""
    @State private var keyError: String?
    @State private var shellOn = ShellHooks.isInstalled()
    @State private var shellError: String?
    @State private var accessibility = AXIsProcessTrusted()
    @State private var screenRecording = CGPreflightScreenCaptureAccess()
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
                row("shield.lefthalf.filled", "Gate") {
                    Picker("", selection: $settings.gateProvider) {
                        Text("Cloud").tag(BeanSettings.GateProvider.cloud)
                        Text("On this Mac").tag(BeanSettings.GateProvider.local)
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small).fixedSize()
                }
                if settings.gateProvider == .local && !localGateAvailable {
                    hint("Needs llama-server and the model in ~/Models/llama32.")
                }
            }
            settingsGroup
            if !accessibility || !screenRecording { permissions }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(nsImage: MenuBarController.glyph(paused: settings.paused))
                    .renderingMode(.template)
                    .foregroundStyle(settings.paused ? Color.secondary : Color.primary)
                    .scaleEffect(1.3)
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Bean").font(.system(size: 13, weight: .semibold))
                    Text(settings.paused ? "Paused" : "Watching").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Watching", isOn: Binding(get: { !settings.paused }, set: { settings.paused = !$0 }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .help(settings.paused ? "Resume" : "Pause")
            }
            Text("Stayed quiet \(notch.quietCount) \(notch.quietCount == 1 ? "time" : "times") today, stepped in \(notch.steppedInToday)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .contentTransition(.numericText())
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
                    Text("SETTINGS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(settingsOpen ? 90 : 0))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .accessibilityLabel("Settings")
            if settingsOpen {
                card {
                    row("exclamationmark.bubble", "Stuck on an error after") { minutes($settings.stuckSeconds, [60, 120, 180, 300, 600]) }
                    row("moon.zzz", "Away after") { minutes($settings.idleSeconds, [60, 120, 300, 600, 1800]) }
                    row("phone", "Quiet during calls") { toggle($settings.quietInMeetings) }
                    row("terminal", "Terminal commands") { toggle(Binding(get: { shellOn }, set: setShell)) }
                    if let shellError { hint(shellError) }
                    row("safari", "Browser tab") { toggle($settings.readBrowser) }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var permissions: some View {
        card {
            if !accessibility {
                permissionRow("Accessibility", "To read windows and type for you", pane: "Privacy_Accessibility")
            }
            if !screenRecording {
                permissionRow("Screen Recording", "To look at your screen when it helps", pane: "Privacy_ScreenCapture")
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().padding(.bottom, 4)
            menuButton("What Bean sees…", shortcut: "⌘I") {
                close()
                openInspector()
            }
            .keyboardShortcut("i")
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

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.bottom, 4)
    }

    private func toggle(_ value: Binding<Bool>) -> some View {
        Toggle("", isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.mini)
    }

    private func minutes(_ value: Binding<Double>, _ options: [Double]) -> some View {
        Picker("", selection: value) {
            ForEach(Array(Set(options + [value.wrappedValue])).sorted(), id: \.self) { seconds in
                Text(seconds < 60 ? "\(Int(seconds)) s" : "\(Int(seconds / 60)) min").tag(seconds)
            }
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
    }

    private var keyLabel: String {
        switch keySource {
        case .environment: return "Environment"
        case .repoEnvFile: return "Repo .env"
        case .keychain: return "Keychain"
        case .missing: return "Missing"
        }
    }

    private func refresh() {
        keySource = APIKeyStore.current(for: settings.provider).source
        shellOn = ShellHooks.isInstalled()
        accessibility = AXIsProcessTrusted()
        screenRecording = CGPreflightScreenCaptureAccess()
    }

    private func saveKey() {
        do {
            try APIKeyStore.save(keyDraft, for: settings.provider)
            keyDraft = ""
            keyError = nil
            editingKey = false
            refresh()
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func removeKey() {
        APIKeyStore.delete(for: settings.provider)
        refresh()
    }

    private func setShell(_ on: Bool) {
        do {
            if on { try ShellHooks.install(logTo: shellLog) } else { try ShellHooks.uninstall() }
            UserDefaults.standard.set(false, forKey: ShellHooks.declinedKey)
            shellError = nil
        } catch {
            shellError = error.localizedDescription
        }
        shellOn = ShellHooks.isInstalled()
    }
}
