import ApplicationServices
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments[1])!, text = CommandLine.arguments[2]
func value(_ e: AXUIElement, _ n: String) -> CFTypeRef? { var r: CFTypeRef?; return AXUIElementCopyAttributeValue(e, n as CFString, &r) == .success ? r : nil }
func find(_ e: AXUIElement) -> AXUIElement? {
    if value(e, kAXRoleAttribute) as? String == kAXTextFieldRole { return e }
    for c in value(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] { if let f = find(c) { return f } }
    return nil
}
guard let field = find(AXUIElementCreateApplication(pid)) else { print("no text field"); exit(1) }
var o = CGPoint.zero, s = CGSize.zero
AXValueGetValue(value(field, kAXPositionAttribute) as! AXValue, .cgPoint, &o)
AXValueGetValue(value(field, kAXSizeAttribute) as! AXValue, .cgSize, &s)
let p = CGPoint(x: o.x + s.width / 2, y: o.y + s.height / 2)
for t in [CGEventType.leftMouseDown, .leftMouseUp] { CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap) }
usleep(300_000)
let units = Array(text.utf16)
for start in stride(from: 0, to: units.count, by: 16) {
    let chunk = Array(units[start..<min(start + 16, units.count)])
    for k in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: k)
        e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
        e?.post(tap: .cghidEventTap)
    }
    usleep(20_000)
}
print("typed into the field at \(Int(p.x)),\(Int(p.y))")
