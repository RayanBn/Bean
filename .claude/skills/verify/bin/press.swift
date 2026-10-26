import ApplicationServices
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments[1])!
let label = CommandLine.arguments[2]

func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
}

func find(_ element: AXUIElement) -> AXUIElement? {
    if value(element, kAXRoleAttribute) as? String == kAXButtonRole,
       [kAXTitleAttribute, kAXDescriptionAttribute].contains(where: { value(element, $0) as? String == label }) {
        return element
    }
    for child in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let found = find(child) { return found }
    }
    return nil
}

guard let button = find(AXUIElementCreateApplication(pid)) else {
    print("no button \"\(label)\" in pid \(pid)")
    exit(1)
}
var origin = CGPoint.zero, size = CGSize.zero
AXValueGetValue(value(button, kAXPositionAttribute) as! AXValue, .cgPoint, &origin)
AXValueGetValue(value(button, kAXSizeAttribute) as! AXValue, .cgSize, &size)
let point = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
let back = CGEvent(source: nil)!.location
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)!.post(tap: .cghidEventTap)
usleep(80_000)
for type in [CGEventType.leftMouseDown, .leftMouseUp] {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!.post(tap: .cghidEventTap)
}
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: back, mouseButton: .left)!.post(tap: .cghidEventTap)
print("pressed \"\(label)\" at \(Int(point.x)),\(Int(point.y))")
