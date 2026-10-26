import ApplicationServices
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments[1])!
let app = AXUIElementCreateApplication(pid)
func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
}
guard let extras = value(app, kAXExtrasMenuBarAttribute), let item = (value(extras as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement])?.first else {
    print("no status item for pid \(pid)"); exit(1)
}
if CommandLine.arguments.dropFirst(2).first != "peek" {
    AXUIElementPerformAction(item, kAXPressAction as CFString)
    usleep(700_000)
}
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
let popover = list.compactMap { w -> CGRect? in
    guard (w[kCGWindowOwnerPID as String] as? Int32) == pid, let d = w[kCGWindowBounds as String] as? NSDictionary,
          let r = CGRect(dictionaryRepresentation: d), r.width < 500, r.height > 60, r.minY < 60 else { return nil }
    return r
}.first
if let r = popover { print(Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)) } else { print("closed") }
