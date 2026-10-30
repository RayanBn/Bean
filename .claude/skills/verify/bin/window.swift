import ApplicationServices
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
func area(_ w: [String: Any]) -> Double {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (b["Width"] ?? 0) * (b["Height"] ?? 0)
}
var ids = [CGDirectDisplayID](repeating: 0, count: 8)
var count: UInt32 = 0
CGGetActiveDisplayList(8, &ids, &count)
let displays = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
func visible(_ w: [String: Any]) -> Bool {
    guard let d = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: d) else { return false }
    return displays.contains { $0.intersects(r) }
}
let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && visible($0) }
let notch = mine.filter { ($0[kCGWindowLayer as String] as? Int) == 25 }
guard let w = (notch.isEmpty ? mine : notch).min(by: { area($0) < area($1) }),
      let b = w[kCGWindowBounds as String] as? [String: Double] else { exit(1) }

func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
}
func island(_ element: AXUIElement) -> AXUIElement? {
    if value(element, kAXIdentifierAttribute) as? String == "bean-island" { return element }
    for child in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let found = island(child) { return found }
    }
    return nil
}
if let element = island(AXUIElementCreateApplication(pid)),
   let p = value(element, kAXPositionAttribute), let s = value(element, kAXSizeAttribute) {
    var origin = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &origin)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    print(Int(origin.x.rounded()), Int(origin.y.rounded()), Int(size.width.rounded()), Int(size.height.rounded()), w[kCGWindowLayer as String]!)
} else {
    print(Int(b["X"]!), Int(b["Y"]!), Int(b["Width"]!), Int(b["Height"]!), w[kCGWindowLayer as String]!)
}
