import ApplicationServices
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: BeanSettings
    let localGateAvailable: Bool
    let hasSparkKey: Bool
    let shellLog: URL
    @State private var shellInstalled = ShellHooks.isInstalled()
    @State private var accessibility = AXIsProcessTrusted()
    @State private var screenRecording = CGPreflightScreenCaptureAccess()
    @State private var shellError: String?

    var body: some View {
        Form {
            Section("When to step in") {
                Picker("Gate model", selection: $settings.gateProvider) {
                    Text("Cloud: Muse Spark").tag(BeanSettings.GateProvider.cloud)
                    Text("On this Mac: Llama 3.2 3B").tag(BeanSettings.GateProvider.local)
                }
                Text(settings.gateProvider == .cloud
                     ? "The gate sends a short text description of what happened (app, window title, error line). Never a screenshot."
                     : localGateAvailable ? "Nothing leaves the Mac until the gate says yes." : "Needs llama-server and the model in ~/Models/llama32. Bean falls back to no decision without them.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.gateProvider == .cloud {
                    slider("Threshold", value: $settings.cloudThreshold, in: 0.3...0.9, step: 0.05, format: "%.2f")
                } else {
                    slider("Threshold", value: $settings.localThreshold, in: 0.3...0.9, step: 0.05, format: "%.2f")
                }
                slider("Stuck on an error after", value: $settings.stuckSeconds, in: 30...600, step: 30, format: "%.0f s")
                slider("Away after", value: $settings.idleSeconds, in: 60...1800, step: 60, format: "%.0f s")
                Toggle("Stay quiet during calls (microphone or camera in use)", isOn: $settings.quietInMeetings)
            }

            Section("Thinking") {
                Picker("Model", selection: $settings.brainModel) {
                    ForEach(["muse-spark-1.3", "muse-spark-1.2", "muse-spark-1.1"], id: \.self) { Text($0).tag($0) }
                }
                Picker("Reasoning", selection: $settings.brainEffort) {
                    ForEach(["minimal", "low", "medium", "high"], id: \.self) { Text($0).tag($0) }
                }
                status("Meta Model API key", hasSparkKey, ok: "Found", missing: "Missing")
            }

            Section("What Bean can see") {
                HStack {
                    status("Terminal commands and exit codes", shellInstalled, ok: "On, in new terminals", missing: "Off")
                    Spacer()
                    Button(shellInstalled ? "Turn off" : "Turn on", action: toggleShell)
                }
                if let shellError { Text(shellError).font(.caption).foregroundStyle(.red) }
                Toggle("Active browser tab (URL and title only, never mail)", isOn: $settings.readBrowser)
            }

            Section("macOS permissions") {
                HStack {
                    status("Accessibility", accessibility, ok: "Allowed", missing: "Needed to read windows and type for you")
                    Spacer()
                    if !accessibility { Button("Open") { open("Privacy_Accessibility") } }
                }
                HStack {
                    status("Screen Recording", screenRecording, ok: "Allowed", missing: "Needed to look at your screen")
                    Spacer()
                    if !screenRecording { Button("Open") { open("Privacy_ScreenCapture") } }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            accessibility = AXIsProcessTrusted()
            screenRecording = CGPreflightScreenCaptureAccess()
            shellInstalled = ShellHooks.isInstalled()
        }
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double, format: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step)
                Text(String(format: format, value.wrappedValue)).monospacedDigit().frame(width: 52, alignment: .trailing)
            }
        }
    }

    private func status(_ title: String, _ ok: Bool, ok okText: String, missing: String) -> some View {
        LabeledContent(title) {
            Label(ok ? okText : missing, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? .green : .orange)
        }
    }

    private func toggleShell() {
        do {
            if shellInstalled { try ShellHooks.uninstall() } else { try ShellHooks.install(logTo: shellLog) }
            UserDefaults.standard.set(false, forKey: ShellHooks.declinedKey)
            shellError = nil
        } catch {
            shellError = error.localizedDescription
        }
        shellInstalled = ShellHooks.isInstalled()
    }

    private func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}
