import Foundation

typealias JSONArgs = [String: Any]

struct ToolOutput {
    var text: String
    var ok = true
    var image: Data? = nil
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

    var schema: [String: Any] {
        var properties = parameters
        var required = required ?? Array(parameters.keys)
        if effect == .act {
            properties["message"] = ["type": "string", "description": "The conclusion for the notch, shown above the button. At most 140 characters."]
            properties["button"] = ["type": "string", "description": "One to three words."]
            required += ["message", "button"]
        }
        return ["type": "function", "function": [
            "name": name, "description": description,
            "parameters": ["type": "object", "properties": properties, "required": required],
        ]]
    }
}

protocol ToolSource: AnyObject {
    func tools(for trigger: Trigger) async -> [BrainTool]
}

final class Tools {
    static let shared = Tools()

    private var sources: [ToolSource] = []

    func add(_ source: ToolSource) {
        sources.append(source)
    }

    func all(for trigger: Trigger) async -> [BrainTool] {
        var tools: [BrainTool] = []
        for source in sources { tools += await source.tools(for: trigger) }
        var seen = Set<String>()
        return tools.filter { seen.insert($0.name).inserted }
    }
}

extension JSONArgs {
    func string(_ key: String) -> String? {
        (self[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    var json: String {
        (try? JSONSerialization.data(withJSONObject: self, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
