import AppKit
import Foundation
import MCP
import Network

struct Connection: Codable, Equatable {
    let name: String
    var url: URL? = nil
    var command: String? = nil
    var args: [String] = []
    var cwd: String? = nil
    var redirectPort: Int? = nil

    var summary: String {
        url.map { "remote \($0.absoluteString)" } ?? "stdio " + ([command ?? "?"] + args).joined(separator: " ")
    }
}

final class ConnectorStore {
    let file: URL
    private(set) var connections: [Connection]

    init(file: URL = JSONLog.directory.appendingPathComponent("connectors.json")) {
        self.file = file
        connections = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Connection].self, from: $0) } ?? []
    }

    func save(_ connection: Connection) {
        connections.removeAll { $0.name == connection.name }
        connections.append(connection)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(connections).write(to: file, options: .atomic)
    }

    static func authorizer(for connection: Connection, interactive: Bool) -> OAuthAuthorizer {
        let tokens = FileTokens(account: connection.name)
        let port = connection.redirectPort ?? LoopbackAuthorization.freePort()
        let configuration = OAuthConfiguration(
            grantType: .authorizationCode,
            authentication: .none(clientID: tokens.load()?.clientID ?? ""),
            authorizationRedirectURI: URL(string: "http://127.0.0.1:\(port)/callback")!,
            clientName: "Bean",
            authorizationDelegate: LoopbackAuthorization(port: UInt16(port), interactive: interactive)
        )
        return OAuthAuthorizer(configuration: configuration, tokenStorage: tokens)
    }
}

final class FileTokens: TokenStorage, @unchecked Sendable {
    private static let lock = NSLock()
    let account: String
    let file: URL

    init(account: String, file: URL = JSONLog.directory.appendingPathComponent("connector-tokens.json")) {
        self.account = account
        self.file = file
    }

    func save(_ token: OAuthAccessToken) {
        update { $0[account] = token }
    }

    func load() -> OAuthAccessToken? {
        Self.lock.withLock { read()[account] }
    }

    func clear() {
        update { $0[account] = nil }
    }

    private func read() -> [String: OAuthAccessToken] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: OAuthAccessToken].self, from: $0) } ?? [:]
    }

    private func update(_ change: (inout [String: OAuthAccessToken]) -> Void) {
        Self.lock.withLock {
            var tokens = read()
            change(&tokens)
            guard let data = try? JSONEncoder().encode(tokens) else { return }
            let folder = file.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let temp = folder.appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString)")
            let descriptor = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard descriptor >= 0 else { return }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            let written = (try? handle.write(contentsOf: data)) != nil
            try? handle.close()
            if !written || rename(temp.path, file.path) != 0 { try? FileManager.default.removeItem(at: temp) }
        }
    }
}

struct LoopbackAuthorization: OAuthAuthorizationDelegate {
    let port: UInt16
    let interactive: Bool
    var timeout: TimeInterval = 300

    enum Failure: LocalizedError {
        case listener(String), timedOut, needsSignIn
        var errorDescription: String? {
            switch self {
            case .needsSignIn: return "the server asks to sign in again; propose connect"
            case .listener(let reason): return "could not listen on 127.0.0.1 for the sign-in: \(reason)"
            case .timedOut: return "the sign-in did not finish in time"
            }
        }
    }

    static func freePort() -> Int { Int.random(in: 49152...65535) }

    func presentAuthorizationURL(_ url: URL) async throws -> URL {
        guard interactive else { throw Failure.needsSignIn }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw Failure.listener("bad port \(port)") }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "bean.oauth.loopback")
        let port = port
        let timeout = timeout

        return try await withCheckedThrowingContinuation { continuation in
            let once = Once(listener: listener, continuation: continuation)
            let finish = once.finish
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                case .failed(let error): finish(.failure(Failure.listener(error.localizedDescription)))
                default: break
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                    let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                    let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    let isCallback = target.hasPrefix("/callback")
                    let body = isCallback ? "<html><body style=\"font-family:-apple-system\">Bean is connected. You can close this tab.</body></html>" : ""
                    let response = "HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    if isCallback, let redirect = URL(string: "http://127.0.0.1:\(port)\(target)") { finish(.success(redirect)) }
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(Failure.timedOut)) }
        }
    }

    private final class Once: @unchecked Sendable {
        private let listener: NWListener
        private var continuation: CheckedContinuation<URL, Error>?

        init(listener: NWListener, continuation: CheckedContinuation<URL, Error>) {
            self.listener = listener
            self.continuation = continuation
        }

        func finish(_ result: Result<URL, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            listener.cancel()
            continuation.resume(with: result)
        }
    }
}
