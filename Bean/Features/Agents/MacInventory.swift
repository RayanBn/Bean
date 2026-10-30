import AppKit

struct MacInventory {
    let installed: [String]
    let running: [String]
    let localConnectors: [LocalServer]
    let connected: [String]

    static func scan() -> MacInventory {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", home.appendingPathComponent("Applications").path]
        let installed = folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
        }
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName)
        return MacInventory(installed: Array(Set(installed)).sorted(), running: Array(Set(running)).sorted(),
                            localConnectors: ConnectorDiscovery.local(), connected: ConnectorStore().connections.map(\.name))
    }

    var summary: String {
        let local = Array(Set(localConnectors.map(\.name))).sorted()
        return """
        Running apps: \(running.joined(separator: ", "))
        Installed apps: \(installed.joined(separator: ", "))
        Connectors already connected in Bean: \(connected.isEmpty ? "none" : connected.joined(separator: ", "))
        MCP servers configured in the user's other tools: \(local.isEmpty ? "none" : local.joined(separator: ", "))
        """
    }

    func resolve(_ names: [String]) async -> [AgentConnector] {
        var resolved: [AgentConnector] = []
        for name in names {
            let key = name.lowercased()
            if let saved = connected.first(where: { $0.lowercased() == key }) {
                resolved.append(AgentConnector(name: saved, status: .connected, source: "Bean"))
            } else if let local = localConnectors.first(where: { $0.name.lowercased() == key }) {
                resolved.append(AgentConnector(name: local.name, status: .toConnect, source: local.source, url: local.url))
            } else if let remote = await ConnectorDiscovery.registry(name).first(where: { $0.official && Self.namespace(of: $0).contains(key) }) {
                resolved.append(AgentConnector(name: name, status: .toConnect, source: "registry \(remote.name)", url: remote.remotes.first))
            } else {
                resolved.append(AgentConnector(name: name, status: .toConnect))
            }
        }
        return resolved
    }

    private static func namespace(of server: RegistryServer) -> [String] {
        server.name.split(separator: "/").first.map { $0.lowercased().split(separator: ".").map(String.init) } ?? []
    }
}
