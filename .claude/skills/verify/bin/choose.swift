import ApplicationServices
import Foundation

let pid = Int32(CommandLine.arguments[1])!, current = CommandLine.arguments[2], target = CommandLine.arguments[3]
func value(_ e: AXUIElement, _ n: String) -> CFTypeRef? { var r: CFTypeRef?; return AXUIElementCopyAttributeValue(e, n as CFString, &r) == .success ? r : nil }
func find(_ e: AXUIElement, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
    if match(e) { return e }
    for c in value(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] { if let f = find(c, match) { return f } }
    return nil
}
let app = AXUIElementCreateApplication(pid)
guard let popup = find(app, { value($0, kAXRoleAttribute) as? String == kAXPopUpButtonRole && value($0, kAXValueAttribute) as? String == current }) else { print("no popup showing \(current)"); exit(1) }
AXUIElementPerformAction(popup, kAXPressAction as CFString)
usleep(400_000)
guard let item = find(app, { value($0, kAXRoleAttribute) as? String == kAXMenuItemRole && value($0, kAXTitleAttribute) as? String == target }) else { print("no menu item \(target)"); exit(1) }
AXUIElementPerformAction(item, kAXPressAction as CFString)
print("chose \(target)")
