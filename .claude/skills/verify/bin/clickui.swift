import AppKit
import ApplicationServices
let args = CommandLine.arguments
let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).first!
app.activate()
Thread.sleep(forTimeInterval: 0.4)
let ax = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
func str(_ e: AXUIElement, _ a: String) -> String? { attr(e, a) as? String }
func label(_ e: AXUIElement) -> String? {
  for a in ["AXTitle", "AXDescription"] { if let s = str(e, a), !s.isEmpty { return s } }
  for c in (attr(e, "AXChildren") as? [AXUIElement] ?? []).prefix(4) where str(c, "AXRole") == "AXStaticText" { if let s = str(c, "AXValue"), !s.isEmpty { return s } }
  return nil }
var target: AXUIElement?
for _ in 0..<20 {
  guard let w = attr(ax, "AXFocusedWindow") else { Thread.sleep(forTimeInterval: 0.25); continue }
  var q = [w as! AXUIElement], n = 0
  while !q.isEmpty, n < 8000 { let e = q.removeFirst(); n += 1
    if ["AXLink", "AXButton", "AXMenuItem", "AXCheckBox"].contains(str(e, "AXRole") ?? ""), label(e) == args[2] { target = e; break }
    q += attr(e, "AXChildren") as? [AXUIElement] ?? [] }
  if target != nil { break }
  Thread.sleep(forTimeInterval: 0.25)
}
guard let target else { print("not found: \(args[2])"); exit(1) }
var window: CFTypeRef?
if AXUIElementCopyAttributeValue(target, "AXWindow" as CFString, &window) == .success, let window { AXUIElementPerformAction(window as! AXUIElement, "AXRaise" as CFString) }
app.activate()
AXUIElementPerformAction(target, "AXScrollToVisible" as CFString)
Thread.sleep(forTimeInterval: 0.4)
var p = CGPoint.zero, s = CGSize.zero
AXValueGetValue(attr(target, "AXPosition") as! AXValue, .cgPoint, &p); AXValueGetValue(attr(target, "AXSize") as! AXValue, .cgSize, &s)
let c = CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
var hit: AXUIElement?
AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(c.x), Float(c.y), &hit)
var hitPid: pid_t = 0
if let hit { AXUIElementGetPid(hit, &hitPid) }
guard hitPid == app.processIdentifier else { print("covered: \(args[2]) is under pid \(hitPid)"); exit(1) }
for t in [CGEventType.leftMouseDown, .leftMouseUp] { CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: c, mouseButton: .left)!.post(tap: .cghidEventTap); usleep(40000) }
print("clicked \(args[2]) at \(Int(c.x)) \(Int(c.y))")
