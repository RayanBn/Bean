import ApplicationServices
import Foundation
let pid = Int32(CommandLine.arguments[1])!, text = CommandLine.arguments[2]
func value(_ e: AXUIElement, _ n: String) -> CFTypeRef? { var r: CFTypeRef?; return AXUIElementCopyAttributeValue(e, n as CFString, &r) == .success ? r : nil }
func all(_ e: AXUIElement, _ out: inout [AXUIElement]) { out.append(e); for c in value(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] { all(c, &out) } }
var list: [AXUIElement] = []
all(AXUIElementCreateApplication(pid), &list)
for m in list where value(m, kAXRoleAttribute) as? String == kAXMenuRole && value(m, kAXParentAttribute).map({ value($0 as! AXUIElement, kAXRoleAttribute) as? String }) != .some(kAXMenuBarItemRole) { print("cancel menu", AXUIElementPerformAction(m, kAXCancelAction as CFString).rawValue) }
usleep(400_000)
list = []; all(AXUIElementCreateApplication(pid), &list)
guard let field = list.first(where: { value($0, kAXRoleAttribute) as? String == kAXTextFieldRole }) else { print("no field"); exit(1) }
print("set", AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString).rawValue, value(field, kAXValueAttribute) as? String ?? "nil")
usleep(600_000)
list = []; all(AXUIElementCreateApplication(pid), &list)
guard let send = list.first(where: { value($0, kAXRoleAttribute) as? String == kAXButtonRole && ((value($0, kAXDescriptionAttribute) as? String) == "Send" || (value($0, kAXTitleAttribute) as? String) == "Send") }) else { print("no send"); exit(1) }
print("press", AXUIElementPerformAction(send, kAXPressAction as CFString).rawValue)
