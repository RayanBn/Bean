import SwiftUI

struct ConnectorsPage: View {
    let entries: [ConnectorEntry]
    let agents: [Agent]
    let actions: PageActions
    @State private var query = ""
    @State private var results: [ConnectorEntry] = []
    @State private var searching = false
    @State private var address = ""
    @State private var addError: String?

    private var everyone: [ConnectorEntry] { entries.filter { $0.audience != "developers" } }
    private var developers: [ConnectorEntry] { entries.filter { $0.audience == "developers" } }
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        List {
            if !trimmed.isEmpty {
                Section("Find more") {
                    if searching {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Searching").foregroundStyle(.secondary)
                        }
                    } else if results.isEmpty {
                        Text("Nothing that connects in one click matches \u{201C}\(trimmed)\u{201D}.").foregroundStyle(.secondary)
                    }
                    ForEach(results) { row($0) }
                }
            }
            if !everyone.isEmpty {
                Section("For everyone") { ForEach(everyone) { row($0) } }
            }
            if !developers.isEmpty {
                Section("For developers") { ForEach(developers) { row($0) } }
            }
            Section {
                HStack {
                    TextField("Server address", text: $address, prompt: Text(verbatim: "https://example.com/mcp"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                        .accessibilityIdentifier("page-connector-address")
                    Button("Add", action: add).disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let addError { Text(addError).font(.callout).foregroundStyle(.orange) }
            } header: {
                Text("Add by address")
            } footer: {
                Text("Agents get a connector's tools. Anything irreversible stays off until you allow it.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
        .searchable(text: $query, placement: .toolbar, prompt: "Find more")
        .task { await actions.refreshConnectors() }
        .task(id: trimmed) {
            guard !trimmed.isEmpty else { results = []; return }
            searching = true
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            results = await actions.searchConnectors(trimmed)
            searching = false
        }
    }

    private func row(_ entry: ConnectorEntry) -> some View {
        ConnectorRow(entry: entry, users: agents.filter { entry.usedBy.contains($0.id) }, actions: actions)
    }

    private func add() {
        let url = address.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        addError = nil
        Task {
            do {
                _ = try await actions.addConnector(url)
                address = ""
            } catch {
                addError = error.localizedDescription
            }
        }
    }
}

private struct ConnectorRow: View {
    let entry: ConnectorEntry
    let users: [Agent]
    let actions: PageActions

    private var monogramHue: Double {
        Double(entry.id.unicodeScalars.reduce(5381) { ($0 * 33 + Int($1.value)) % 360 }) / 360
    }

    @ViewBuilder private var icon: some View {
        if NSImage(named: logoName) != nil {
            Image(logoName)
                .resizable()
                .scaledToFit()
                .frame(width: entry.id == "dropbox" ? 30 : 20, height: entry.id == "dropbox" ? 30 : 20)
                .frame(width: 30, height: 30)
        } else {
            Text(String(entry.name.prefix(1)).uppercased())
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color(hue: monogramHue, saturation: 0.42, brightness: 0.68), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private var logoName: String { "connector-\(entry.id)" }

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                Text(entry.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if case .failed(let reason) = entry.status {
                    Text(reason).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if !users.isEmpty {
                HStack(spacing: -3) {
                    ForEach(users.prefix(3)) { PageDrop(look: $0.look, mood: .idle, size: 13) }
                }
                .help(AgentStrings.shown("Used by %@", users.map(\.name).joined(separator: ", ")))
            }
            control.fixedSize()
        }
        .padding(.vertical, 3)
        .contextMenu {
            if entry.status == .connected { Button("Disconnect") { actions.disconnectService(entry.id) } }
        }
        .accessibilityIdentifier("page-connector-\(entry.id)")
    }

    @ViewBuilder private var control: some View {
        switch entry.status {
        case .available:
            Button("Connect") { actions.connectService(entry.id) }.accessibilityIdentifier("page-connect-\(entry.id)")
        case .connecting:
            ProgressView().controlSize(.small)
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.secondary)
        case .failed:
            Button("Retry") { actions.connectService(entry.id) }.accessibilityIdentifier("page-connect-\(entry.id)")
        }
    }
}
