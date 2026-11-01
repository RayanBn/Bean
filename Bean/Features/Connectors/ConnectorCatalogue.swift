import Foundation
import MCP

struct CatalogueService: Decodable, Identifiable, Equatable {
    struct Auth: Decodable, Equatable {
        let kind: String
        var clientIDVariable: String? = nil
        var secretVariable: String? = nil
    }

    struct CommandLineTool: Decodable, Equatable {
        let name: String
        let signedIn: String
    }

    let id: String
    let name: String
    let summary: String
    let audience: String
    let mcp: URL
    let auth: Auth
    var cli: CommandLineTool? = nil

    var registeredAuthentication: OAuthConfiguration.TokenEndpointAuthentication? {
        guard auth.kind == "registered", let idName = auth.clientIDVariable, let secretName = auth.secretVariable,
              let id = APIKeyStore.named(idName), let secret = APIKeyStore.named(secretName) else { return nil }
        return .clientSecretPost(clientID: id, clientSecret: secret)
    }

    var isReady: Bool { auth.kind != "registered" || registeredAuthentication != nil }
}

enum Catalogue {
    static let services: [CatalogueService] = {
        guard let url = Bundle.main.url(forResource: "catalogue", withExtension: "json"), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CatalogueService].self, from: data)) ?? []
    }()

    static func service(url: URL?) -> CatalogueService? {
        services.first { $0.mcp == url }
    }

    static func service(matching text: String) -> CatalogueService? {
        let word = text.lowercased().trimmingCharacters(in: .whitespaces)
        return services.first { $0.id == word || $0.name.lowercased() == word }
    }

    static var forModel: String {
        services.map { "- \($0.id): \($0.name), \($0.summary)" }.joined(separator: "\n")
    }
}

struct ConnectorEntry: Identifiable, Equatable {
    enum Status: Equatable { case available, connecting, connected, failed(String) }
    let id: String
    let name: String
    let summary: String
    let audience: String
    var status: Status
    var usedBy: [UUID]
}

@MainActor
final class ConnectorCatalogue: ObservableObject {
    enum AddError: LocalizedError {
        case notSecure, notOneClick
        var errorDescription: String? {
            switch self {
            case .notSecure: "That address must start with https."
            case .notOneClick: "This server cannot connect in one click: it does not let a new app register itself."
            }
        }
    }

    @Published private(set) var entries: [ConnectorEntry] = []
    var onConnected: ((ConnectorEntry) -> Void)?
    private let connectors: Connectors
    private let store: AgentStore
    private var extras: [String: (name: String, summary: String, url: URL)] = [:]

    init(connectors: Connectors, store: AgentStore) {
        self.connectors = connectors
        self.store = store
        entries = Catalogue.services.map { ConnectorEntry(id: $0.id, name: $0.name, summary: $0.summary, audience: $0.audience, status: .available, usedBy: []) }
        Task { await refresh() }
    }

    func refresh() async {
        let state = await connectors.state()
        for connection in state.saved where Catalogue.service(url: connection.url) == nil && extras[connection.name] == nil {
            if let url = connection.url { extras[connection.name] = (connection.name, url.host ?? "", url) }
        }
        var list = entries.filter { entry in entry.id != "" }
        for (id, extra) in extras where !list.contains(where: { $0.id == id }) {
            list.append(ConnectorEntry(id: id, name: extra.name, summary: extra.summary, audience: "everyone", status: .available, usedBy: []))
        }
        for index in list.indices {
            let id = list[index].id
            if state.live.contains(id) {
                list[index].status = .connected
            } else if let failure = state.failures[id], list[index].status != .connecting {
                list[index].status = .failed(Self.plain(failure, name: list[index].name))
            } else if list[index].status == .connected {
                list[index].status = .available
            }
            let name = list[index].name
            list[index].usedBy = store.agents.filter { agent in AgentFolder(agent, in: store).connectors.contains { $0.name == name } }.map(\.id)
        }
        entries = list
    }

    func connect(_ id: String) {
        guard let url = Catalogue.services.first(where: { $0.id == id })?.mcp ?? extras[id]?.url else { return }
        if let service = Catalogue.services.first(where: { $0.id == id }), !service.isReady {
            return set(id, .failed("\(service.name) is not set up in this copy of Bean: its app credentials are missing."))
        }
        set(id, .connecting)
        Task {
            do {
                try await connectors.add(Connection(name: id, url: url, redirectPort: LoopbackAuthorization.freePort()))
                set(id, .connected)
                await refresh()
                if let entry = entries.first(where: { $0.id == id }) { onConnected?(entry) }
            } catch {
                set(id, .failed(Self.plain(error.localizedDescription, name: entries.first { $0.id == id }?.name ?? id)))
            }
        }
    }

    func disconnect(_ id: String) {
        Task {
            await connectors.remove(id)
            set(id, .available)
            await refresh()
        }
    }

    func search(_ query: String) async -> [ConnectorEntry] {
        let known = Set(Catalogue.services.map(\.mcp))
        return await ConnectorDiscovery.oneClick(query).filter { !known.contains($0.remotes[0]) }.map { server in
            let id = Connectors.clean(server.name.lowercased())
            extras[id] = (server.title, server.description, server.remotes[0])
            return ConnectorEntry(id: id, name: server.title, summary: server.description, audience: "everyone", status: .available, usedBy: [])
        }
    }

    func addCustom(url text: String) async throws -> ConnectorEntry {
        guard let url = URL(string: text), url.scheme == "https", let host = url.host else { throw AddError.notSecure }
        guard await ConnectorDiscovery.connectsInOneClick(url) else { throw AddError.notOneClick }
        let id = Connectors.clean(host.lowercased())
        extras[id] = (host, "Added by you.", url)
        let entry = ConnectorEntry(id: id, name: host, summary: "Added by you.", audience: "everyone", status: .available, usedBy: [])
        if !entries.contains(where: { $0.id == id }) { entries.append(entry) }
        return entry
    }

    private func set(_ id: String, _ status: ConnectorEntry.Status) {
        if let index = entries.firstIndex(where: { $0.id == id }) { entries[index].status = status }
    }

    private static func plain(_ failure: String, name: String) -> String {
        let lower = failure.lowercased()
        if lower.contains("sign in") { return "\(name) asks you to sign in again." }
        if lower.contains("did not finish in time") || lower.contains("did not answer") { return "The sign-in for \(name) did not finish in time." }
        return "\(name) could not connect: \(failure.prefix(160))"
    }
}
