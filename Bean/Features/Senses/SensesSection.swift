import SwiftUI

struct SensesSection: View {
    let rows: [SenseRow]
    let set: (String, Bool) -> Void
    @State private var overrides: [String: Bool] = [:]

    var body: some View {
        if !rows.isEmpty {
            Section("Notices") {
                ForEach(rows) { row in
                    Toggle(isOn: Binding(get: { overrides[row.id] ?? row.on }, set: { overrides[row.id] = $0; set(row.id, $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                            Text(row.sentence).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("sense-\(row.id)")
                }
            }
        }
    }
}
