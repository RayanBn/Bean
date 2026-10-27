import CoreGraphics
import Foundation

struct Locator: Codable, Equatable {
    var bundleId: String?
    var window: String?
    var role: String?
    var title: String?
    var label: String?
    var identifier: String?
    var domId: String?
    var url: String?
    var urlPattern: String?
    var ancestors: [String]?
    var index: Int?

    var summary: String {
        [role, title.map { "\"\($0)\"" }, label.map { "label \"\($0)\"" }, identifier.map { "#\($0)" }, domId.map { "dom #\($0)" }, url, urlPattern.map { "url ~ \($0)" }, index.map { "nth \($0)" }]
            .compactMap { $0 }.joined(separator: " ")
    }
}

struct Frame: Codable, Equatable {
    var x: Double, y: Double, width: Double, height: Double
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct Check: Codable, Equatable {
    enum Kind: String, Codable { case urlMatches, present, absent, textAppears, titleContains, shellExit, all, any }

    var kind: Kind
    var value: String?
    var target: Locator?
    var exit: Int32?
    var checks: [Check]?
}

struct Step: Codable, Equatable {
    enum Kind: String, Codable { case open, press, setValue, typeText, keys, menu, script, shell, terminal, window, wait, each }

    var intent: String
    var kind: Kind
    var target: Locator?
    var text: String?
    var url: String?
    var path: String?
    var bundleId: String?
    var menu: [String]?
    var cwd: String?
    var frame: Frame?
    var fullScreen: Bool?
    var space: Int?
    var check: Check?
    var seconds: Double?
    var post: Check?
    var irreversible: Bool?
    var excluding: [String]?
    var steps: [Step]?

    enum CodingKeys: String, CodingKey {
        case intent, kind = "do", target, text, url, path, bundleId, menu, cwd, frame, fullScreen, space, check, seconds, post, irreversible, excluding, steps
    }

    var app: String? { bundleId ?? target?.bundleId }

    func filled(_ params: [String: String]) -> Step {
        guard !params.isEmpty, let data = try? JSONEncoder().encode(self), var json = String(data: data, encoding: .utf8) else { return self }
        for (name, value) in params {
            let escaped = String(data: (try? JSONEncoder().encode(value)) ?? Data(), encoding: .utf8)?.dropFirst().dropLast() ?? ""
            json = json.replacingOccurrences(of: "{\(name)}", with: escaped)
        }
        return (try? JSONDecoder().decode(Step.self, from: Data(json.utf8))) ?? self
    }

    static let schema: [String: Any] = {
        var schema = flatSchema
        var properties = schema["properties"] as! [String: Any]
        properties["excluding"] = ["type": "array", "items": ["type": "string"], "description": "each: labels already done, to skip."]
        properties["steps"] = ["type": "array", "items": flatSchema, "description": "each: the steps to run for every matching element, with {item} for its label."]
        schema["properties"] = properties
        return schema
    }()

    static let flatSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "intent": ["type": "string", "description": "What this step does, in a few words."],
            "do": ["type": "string", "enum": Kind.allNames, "description": "open: a URL, a document (path) or an app (bundleId). press, setValue, typeText: a UI element (target). keys: a shortcut like cmd+shift+t (text) sent to bundleId. menu: menu bar path. script: AppleScript told to one app (bundleId, text), with verbs from its dictionary. shell: hidden command (text). terminal: visible command (text). window: place a window on any Space (target with bundleId and window title, then frame, fullScreen and/or space). wait: until check passes. each: for every element matching target (in document order, skipping excluding), run steps with {item} replaced by its label; at most 20."],
            "target": Locator.schema,
            "text": ["type": "string"],
            "url": ["type": "string"],
            "path": ["type": "string"],
            "bundleId": ["type": "string"],
            "menu": ["type": "array", "items": ["type": "string"]],
            "cwd": ["type": "string"],
            "frame": ["type": "object", "properties": ["x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"]]],
            "fullScreen": ["type": "boolean"],
            "space": ["type": "integer", "description": "Move the window to this Space id (window steps)."],
            "check": Check.schema,
            "seconds": ["type": "number"],
            "post": Check.schema,
            "irreversible": ["type": "boolean", "description": "True when the step sends, deletes, buys or publishes something."],
        ],
        "required": ["intent", "do"],
    ]
}

extension Step.Kind {
    static let allNames = ["open", "press", "setValue", "typeText", "keys", "menu", "script", "shell", "terminal", "window", "wait", "each"]
}

extension Locator {
    static let schema: [String: Any] = [
        "type": "object",
        "description": "A UI element, as read_ui lists it. Give only the fields you need to find it once.",
        "properties": [
            "bundleId": ["type": "string"], "window": ["type": "string", "description": "Part of the window title."],
            "role": ["type": "string"], "title": ["type": "string"], "label": ["type": "string"],
            "identifier": ["type": "string"], "domId": ["type": "string"], "url": ["type": "string", "description": "Part of the link's URL."],
            "urlPattern": ["type": "string", "description": "A regular expression the link's URL must match."],
            "ancestors": ["type": "array", "items": ["type": "string"], "description": "Roles of the element's ancestors from the window down, like read_ui shows them, when needed to tell matches apart."],
            "index": ["type": "integer", "description": "Which match, from 0, when several elements match."],
        ],
    ]
}

extension Check {
    static let schema: [String: Any] = [
        "type": "object",
        "description": "How Bean knows the step worked. urlMatches (value: regex), present / absent (target), textAppears / titleContains (value), shellExit (value: command, exit).",
        "properties": [
            "kind": ["type": "string", "enum": ["urlMatches", "present", "absent", "textAppears", "titleContains", "shellExit"]],
            "value": ["type": "string"], "target": Locator.schema, "exit": ["type": "integer"],
        ],
        "required": ["kind"],
    ]
}
