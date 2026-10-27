import AppKit

struct Vision {
    static let schema: [String: Any] = [
        "type": "object",
        "properties": ["found": ["type": "boolean"], "x": ["type": "number"], "y": ["type": "number"]],
        "required": ["found", "x", "y"],
        "additionalProperties": false,
    ]

    let client: ModelClient

    func locate(_ step: Step, _ jpeg: Data) async -> CGPoint? {
        guard let image = NSBitmapImageRep(data: jpeg), let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else { return nil }
        let prompt = """
        Find the UI element for this step on the screenshot (\(image.pixelsWide)×\(image.pixelsHigh) pixels). Step: \(step.intent).\(step.target.map { " Element: \($0.summary)." } ?? "")
        Answer in JSON: found, and x, y of the element's center in screenshot pixels from the top left.
        """
        let messages: [[String: Any]] = [["role": "user", "content": [["type": "text", "text": prompt], ModelClient.image(jpeg)]]]
        guard let reply = try? await client.json(messages: messages, schema: Self.schema, effort: "low"), let text = reply.text,
              let answer = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], answer["found"] as? Bool == true,
              let x = answer["x"] as? Double, let y = answer["y"] as? Double else { return nil }
        let scale = screen.frame.width / CGFloat(image.pixelsWide)
        return CGPoint(x: x * scale, y: y * scale)
    }
}
