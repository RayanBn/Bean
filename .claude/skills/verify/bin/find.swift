import ApplicationServices
import Foundation

let pid = Int32(CommandLine.arguments[1])!
let wanted = CommandLine.arguments[2]
func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
}
func search(_ element: AXUIElement) -> AXUIElement? {
    if value(element, kAXIdentifierAttribute) as? String == wanted { return element }
    for child in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let found = search(child) { return found }
    }
    return nil
}
guard let element = search(AXUIElementCreateApplication(pid)),
      let p = value(element, kAXPositionAttribute), let s = value(element, kAXSizeAttribute) else { print("none"); exit(1) }
var origin = CGPoint.zero, size = CGSize.zero
AXValueGetValue(p as! AXValue, .cgPoint, &origin)
AXValueGetValue(s as! AXValue, .cgSize, &size)
print(Int(origin.x.rounded()), Int(origin.y.rounded()), Int(size.width.rounded()), Int(size.height.rounded()))
