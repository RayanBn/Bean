import Foundation

enum ConnectorsProbe {
    static func runIfRequested() -> Bool {
        if let index = CommandLine.arguments.firstIndex(of: "--probe-connectors-remote"), CommandLine.arguments.indices.contains(index + 2),
           let url = URL(string: CommandLine.arguments[index + 2]) {
            signInRemote(name: CommandLine.arguments[index + 1], url: url)
            return true
        }
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-connectors") else { return false }
        let wanted = CommandLine.arguments.indices.contains(index + 1) ? CommandLine.arguments[index + 1] : "rea"
        Task {
            let local = ConnectorDiscovery.local()
            print("--- local servers (\(local.count))")
            local.forEach { print($0.summary) }

            print("\n--- registry: linear")
            await ConnectorDiscovery.registry("linear").forEach { print($0.summary) }

            guard let server = local.first(where: { $0.name == wanted && $0.command != nil }) else {
                print("\nno local stdio server named \(wanted)")
                exit(1)
            }
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bean-probe-connectors.json")
            let connectors = Connectors(store: ConnectorStore(file: scratch), reconnect: false)
            let started = Date()
            do {
                try await connectors.attach(Connection(name: server.name, command: server.command, args: server.args, cwd: server.cwd), interactive: false)
            } catch {
                print("\n\(wanted) failed: \(error.localizedDescription)")
                exit(1)
            }
            let exposure = await connectors.exposure(server: server.name)
            let counts = Dictionary(grouping: exposure, by: \.kind).mapValues(\.count)
            print(String(format: "\n--- %@: %d tools in %.1f s, read %d, act %d, hidden %d", server.name, exposure.count, Date().timeIntervalSince(started),
                         counts[.read] ?? 0, counts[.act] ?? 0, counts[.hidden] ?? 0))
            print("hidden: " + exposure.filter { $0.kind == .hidden }.map(\.tool).joined(separator: ", "))

            let trigger = Trigger(at: Date(), kind: .appChanged, app: "Xcode", bundleId: nil, windowTitle: "Bean.app binary", idleSeconds: 0, errorLine: nil, errorSeconds: nil, terminalTail: nil)
            let tools = await connectors.tools(for: trigger)
            print("\n--- brain tools exposed (\(tools.count))")
            for tool in tools {
                let schema = (tool.schema["function"] as? [String: Any])?["parameters"] as? [String: Any]
                let properties = (schema?["properties"] as? [String: Any])?.keys.sorted() ?? []
                print("\(tool.effect.rawValue)\t\(tool.name)(\(properties.joined(separator: ", ")))")
            }
            let schemas = tools.compactMap { try? JSONSerialization.data(withJSONObject: $0.schema, options: [.sortedKeys]) }.map { String(decoding: $0, as: UTF8.self) }
            let leftovers = ["$ref", "$defs", "$schema", "anyOf", "oneOf", "allOf"].filter { key in schemas.contains { $0.contains("\"\(key)\"") } }
            print("\nschema keys left after sanitizing: \(leftovers.isEmpty ? "none" : leftovers.joined(separator: ", "))")
            for (tool, schema) in zip(tools, schemas) where tool.name.hasPrefix(Connectors.clean(server.name) + "__") {
                print("\(tool.name): \(schema.prefix(700))")
            }
            exit(0)
        }
        return true
    }

    private static func signInRemote(name: String, url: URL) {
        Task {
            let connectors = Connectors(store: ConnectorStore(file: JSONLog.directory.appendingPathComponent("connectors.json")), reconnect: false)
            do {
                let tools = try await connectors.attach(Connection(name: name, url: url, redirectPort: LoopbackAuthorization.freePort()))
                let exposure = await connectors.exposure(server: name)
                let counts = Dictionary(grouping: exposure, by: \.kind).mapValues(\.count)
                print("--- \(name): \(exposure.count) tools, read \(counts[.read] ?? 0), act \(counts[.act] ?? 0), hidden \(counts[.hidden] ?? 0)")
                tools.forEach { print("\($0.effect.rawValue)\t\($0.name)") }
                exit(0)
            } catch {
                print("\(name) failed: \(error.localizedDescription)")
                exit(1)
            }
        }
    }
}
