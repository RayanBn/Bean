import Foundation

typealias JSONArgs = [String: Any]

struct ToolOutput {
    var text: String
    var ok = true
    var image: Data? = nil
    var addsTools: [BrainTool] = []
}

struct BrainTool {
    enum Effect: String, Codable { case read, act }

    let name: String
    let description: String
    let parameters: [String: Any]
    var required: [String]? = nil
    let effect: Effect
    let run: (JSONArgs) async -> ToolOutput
    var stepTitles: ((JSONArgs) -> [String])? = nil
    var runSteps: ((JSONArgs, @escaping (Int, Bool) -> Void) async -> ToolOutput)? = nil
    var showsArguments = false
    var waitsForResult = false

    static let messageKey = "notch_message"
    static let buttonKey = "notch_button"

    var schema: [String: Any] {
        var properties = parameters
        var required = required ?? Array(parameters.keys)
        if effect == .act {
            properties[Self.messageKey] = ["type": "string", "description": "The conclusion for the notch, shown above the button. At most 140 characters."]
            properties[Self.buttonKey] = ["type": "string", "description": "The button label, one to three words."]
            required += [Self.messageKey, Self.buttonKey]
        }
        return ["type": "function", "function": [
            "name": name, "description": description,
            "parameters": ["type": "object", "properties": properties, "required": required],
        ]]
    }
}

protocol ToolSource: AnyObject {
    func tools(context: String, folder: String?) async -> [BrainTool]
    func catalog() async -> String?
    func tool(named name: String) async -> BrainTool?
}

extension ToolSource {
    func catalog() async -> String? { nil }
    func tool(named name: String) async -> BrainTool? { nil }
}

final class Tools {
    static let shared = Tools()

    private var sources: [ToolSource] = []

    func add(_ source: ToolSource) {
        sources.append(source)
    }

    func catalog() async -> String {
        var lines: [String] = []
        for source in sources { if let text = await source.catalog() { lines.append(text) } }
        return lines.joined(separator: "\n")
    }

    func tool(named name: String) async -> BrainTool? {
        for source in sources { if let tool = await source.tool(named: name) { return tool } }
        return nil
    }

    func all(context: String, folder: String?) async -> [BrainTool] {
        var tools: [BrainTool] = []
        for source in sources { tools += await source.tools(context: context, folder: folder) }
        var seen = Set<String>()
        return tools.filter { seen.insert($0.name).inserted }
    }
}

extension JSONArgs {
    func string(_ key: String) -> String? {
        (self[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    var withoutNotch: JSONArgs { filter { $0.key != BrainTool.messageKey && $0.key != BrainTool.buttonKey } }

    var shown: String {
        withoutNotch.sorted { $0.key < $1.key }.compactMap { key, value in
            let text = (value as? String) ?? (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])).map { String(decoding: $0, as: UTF8.self) }
            return text.map { "\(key): \($0.prefix(80))" }
        }.joined(separator: " · ")
    }

    var json: String {
        (try? JSONSerialization.data(withJSONObject: self, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
