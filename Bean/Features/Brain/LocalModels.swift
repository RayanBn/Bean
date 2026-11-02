import Foundation
import SwiftUI

enum LocalModels {
    struct Server: Equatable {
        let name: String
        let address: String
        let models: [String]
    }

    struct Choice: Hashable, Identifiable {
        let serverName: String
        let address: String
        let model: String
        var id: String { address + " " + model }
    }

    private static let known = [("Ollama", 11434), ("LM Studio", 1234), ("llama.cpp", 8080), ("Jan", 1337)]

    static func address(from typed: String) -> String? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.host != nil else { return nil }
        return url.path.isEmpty ? text + "/v1" : text
    }

    static func find(other: String) async -> [Server] {
        var places = known.map { (name: $0.0, address: "http://localhost:\($0.1)/v1") }
        if let address = address(from: other), !places.contains(where: { $0.address == address }) {
            places.append((name: URL(string: address)?.host ?? address, address: address))
        }
        return await withTaskGroup(of: (Int, Server?).self) { group in
            for (index, place) in places.enumerated() {
                group.addTask { (index, await server(name: place.name, address: place.address)) }
            }
            var found: [(Int, Server)] = []
            for await (index, server) in group { if let server { found.append((index, server)) } }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func server(name: String, address: String) async -> Server? {
        guard let url = URL(string: address)?.appendingPathComponent("models") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        struct Listing: Decodable {
            struct Model: Decodable { let id: String }
            let object: String?
            let data: [Model]?
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let listing = try? JSONDecoder().decode(Listing.self, from: data), listing.data != nil || listing.object == "list" else { return nil }
        return Server(name: name, address: address, models: (listing.data ?? []).map(\.id).filter(canChat).sorted())
    }

    private static func canChat(_ model: String) -> Bool {
        let name = model.lowercased()
        return !name.contains("embed") && !name.contains("rerank")
    }

    static func nothingFound(in servers: [Server]) -> String? {
        guard servers.allSatisfy(\.models.isEmpty) else { return nil }
        guard let server = servers.first else { return "No local model server is running. Start Ollama or LM Studio's server, then look again." }
        return "\(server.name) is running with no chat model. Install one there, then look again."
    }

    // MARK: What a model cannot do

    static func cannotCallTools(_ model: String) -> String { "\(model) cannot call tools, and Bean's agents need them. Pick another model." }
    static func cannotWriteJSON(_ model: String) -> String { "\(model) cannot answer in JSON, and Bean's agents need it. Pick another model." }

    private static func refusalKey(_ model: String) -> String { "localRefusal.\(model)" }
    static func refusal(of model: String) -> String? { BeanDefaults.shared.string(forKey: refusalKey(model)) }
    static func setRefusal(_ line: String?, of model: String) { BeanDefaults.shared.set(line, forKey: refusalKey(model)) }

    static func line(code: Int, body: String, model: String) -> String {
        let said = serverWords(body)
        let lower = said.lowercased()
        if lower.contains("tool") { return cannotCallTools(model) }
        if lower.contains("response_format") || lower.contains("json") || lower.contains("schema") { return cannotWriteJSON(model) }
        if code == 404 { return "\(model) is not on the local server anymore. Pick another model in Settings." }
        return said.isEmpty ? "The model on this Mac returned an error (\(code))." : "The model on this Mac said: \(said.prefix(200))"
    }

    private static func serverWords(_ body: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else { return body }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        return object["error"] as? String ?? object["message"] as? String ?? body
    }

    static func withoutThinking(_ text: String?) -> String? {
        guard var text else { return nil }
        while let open = text.range(of: "<think>"), let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func jsonObject(in text: String?) -> String? {
        guard let text, let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else { return nil }
        let body = String(text[open...close])
        return (try? JSONSerialization.jsonObject(with: Data(body.utf8))) is [String: Any] ? body : nil
    }
}

// Finds local servers, checks the model set by BEAN_BRAIN_MODEL and makes one call of each kind.
enum LocalModelProbe {
    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--probe-local-model") else { return false }
        Task {
            let settings = BeanSettings.shared
            let servers = await LocalModels.find(other: settings.localOtherAddress)
            for server in servers { print("server \(server.name) \(server.address): \(server.models)") }
            print("nothing found: \(LocalModels.nothingFound(in: servers) ?? "-")")
            let client = ModelClient()
            guard !client.model.isEmpty else { exit(0) }
            print("\(client.label) at \(settings.effectiveBaseURL?.absoluteString ?? "-") ready \(client.isReady)")
            print("check: \(await client.checkKey() ?? "passed")")
            let tool: [String: Any] = ["type": "function", "function": ["name": "finish", "description": "Finish.", "parameters": ["type": "object", "properties": ["summary": ["type": "string"]]]]]
            do { print("chat: \(try await client.chat([["role": "user", "content": "Finish now."]], tools: [tool]).toolCalls.map(\.name))") } catch { print("chat failed: \(error.localizedDescription)") }
            let schema: [String: Any] = ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]]
            do { print("json: \(try await client.json(system: "Name a colour.", text: "Now.", schema: schema, effort: "low").text ?? "-")") } catch { print("json failed: \(error.localizedDescription)") }
            print("problem: \(ModelClient.problem ?? "-")")
            let rows = CostLedger.lines.filter { $0.run == ProcessInfo.processInfo.environment["BEAN_RUN_ID"] }
            print("ledger: \(rows.count) lines, $\(rows.reduce(0) { $0 + $1.usd })")
            exit(0)
        }
        return true
    }
}

@MainActor
final class LocalModelFinder: ObservableObject {
    @Published private(set) var servers: [LocalModels.Server]?
    @Published private(set) var looking = false
    @Published private(set) var checking = false
    @Published private(set) var checkLine: String?
    @Published private(set) var passed = false

    var choices: [LocalModels.Choice] {
        (servers ?? []).flatMap { server in server.models.map { LocalModels.Choice(serverName: server.name, address: server.address, model: $0) } }
    }

    func look() {
        Task { await lookNow() }
    }

    func lookNow() async {
        guard !looking else { return }
        looking = true
        servers = await LocalModels.find(other: BeanSettings.shared.localOtherAddress)
        looking = false
    }

    func check() {
        checkLine = nil
        passed = false
        checking = true
        Task {
            let problem = await ModelClient().checkKey()
            checking = false
            checkLine = problem
            passed = problem == nil
        }
    }
}

struct LocalModelRows: View {
    @ObservedObject var finder: LocalModelFinder
    @ObservedObject private var settings = BeanSettings.shared
    var checksOnPick = true

    private var selected: LocalModels.Choice? {
        guard !settings.model.isEmpty else { return nil }
        return LocalModels.Choice(serverName: finder.choices.first { $0.address == settings.localAddress }?.serverName ?? "not found", address: settings.localAddress, model: settings.model)
    }

    private var entries: [LocalModels.Choice] {
        if let selected, !finder.choices.contains(selected) { return finder.choices + [selected] }
        return finder.choices
    }

    var body: some View {
        Picker("Model", selection: Binding<LocalModels.Choice?>(get: { selected }, set: { pick($0) })) {
            Text(verbatim: "Choose a model").tag(LocalModels.Choice?.none)
            ForEach(entries) { choice in
                Text(verbatim: "\(choice.model) (\(choice.serverName))").tag(LocalModels.Choice?.some(choice))
            }
        }
        .accessibilityIdentifier("settings-local-model")
        HStack(spacing: 8) {
            TextField("Other address", text: $settings.localOtherAddress, prompt: Text(verbatim: "http://localhost:8000/v1"))
                .onSubmit { finder.look() }
                .accessibilityIdentifier("settings-local-address")
            Button("Look Again") { finder.look() }
                .disabled(finder.looking)
                .accessibilityIdentifier("settings-local-look")
        }
        if let line = statusLine {
            Text(verbatim: line.text).font(.system(size: 12)).foregroundStyle(line.isProblem ? Color.orange : .secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusLine: (text: String, isProblem: Bool)? {
        if finder.looking { return ("Looking for local models…", false) }
        if finder.checking { return ("Trying \(settings.model). The first answer can take a while.", false) }
        if checksOnPick, let line = finder.checkLine ?? (settings.model.isEmpty ? nil : LocalModels.refusal(of: settings.model)) { return (line, true) }
        if let servers = finder.servers, let line = LocalModels.nothingFound(in: servers) { return (line, true) }
        if finder.passed { return ("\(settings.model) can run Bean's agents. Calls stay on this server and cost nothing.", false) }
        return nil
    }

    private func pick(_ choice: LocalModels.Choice?) {
        guard let choice else {
            settings.model = ""
            return
        }
        settings.localAddress = choice.address
        settings.model = choice.model
        if checksOnPick { finder.check() }
    }
}
