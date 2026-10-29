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
  if ["AXTextField", "AXStaticText"].contains(str(e, "AXRole") ?? ""), let p = attr(e, "AXParent"), str(p as! AXUIElement, "AXRole") == "AXCell" { return str(e, "AXValue") }
  return nil }
var target: AXUIElement?
for _ in 0..<48 {
  guard let w = attr(ax, "AXFocusedWindow") else { Thread.sleep(forTimeInterval: 0.25); continue }
  var q = [w as! AXUIElement], n = 0
  while !q.isEmpty, n < 8000 { let e = q.removeFirst(); n += 1
    if ["AXLink", "AXButton", "AXMenuItem", "AXCheckBox", "AXTextField", "AXStaticText"].contains(str(e, "AXRole") ?? ""), label(e) == args[2] { target = e; break }
    q += attr(e, "AXChildren") as? [AXUIElement] ?? [] }
  if target != nil { break }
  Thread.sleep(forTimeInterval: 0.25)
}
guard let target else { print("not found: \(args[2])"); exit(1) }
var window: CFTypeRef?
if AXUIElementCopyAttributeValue(target, "AXWindow" as CFString, &window) == .success, let window { AXUIElementPerformAction(window as! AXUIElement, "AXRaise" as CFString) }
app.activate()
AXUIElementPerformAction(target, "AXScrollToVisible" as CFString)
func center() -> CGPoint {
  var p = CGPoint.zero, s = CGSize.zero
  AXValueGetValue(attr(target, "AXPosition") as! AXValue, .cgPoint, &p); AXValueGetValue(attr(target, "AXSize") as! AXValue, .cgSize, &s)
  return CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
}
var c = center()
for _ in 0..<20 { Thread.sleep(forTimeInterval: 0.15); let next = center(); if next == c { break }; c = next }
var hit: AXUIElement?
AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(c.x), Float(c.y), &hit)
var hitPid: pid_t = 0
if let hit { AXUIElementGetPid(hit, &hitPid) }
guard hitPid == app.processIdentifier else { print("covered: \(args[2]) is under pid \(hitPid)"); exit(1) }
func lands(_ point: CGPoint) -> Bool {
  var hit: AXUIElement?
  AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
  guard let hit else { return false }
  var under: AXUIElement? = hit
  for _ in 0..<6 { guard let e = under else { break }; if CFEqual(e, target) || label(e) == args[2] { return true }; under = attr(e, "AXParent").map { $0 as! AXUIElement } }
  var above: AXUIElement? = target
  for _ in 0..<4 { guard let e = above else { break }; if CFEqual(e, hit) { return true }; above = attr(e, "AXParent").map { $0 as! AXUIElement } }
  return false
}
if !lands(c) {
  let found = stride(from: 60.0, through: 1000.0, by: 6.0).map { CGPoint(x: c.x, y: $0) }.first(where: lands)
  guard let found else { print("moved: \(args[2]) is not under its AX frame and was not found in its column"); exit(1) }
  print("the AX frame of \(args[2]) was stale: found it at y \(Int(found.y)) instead of \(Int(c.y))")
  c = found
}
if ProcessInfo.processInfo.environment["CLICK_DRY_RUN"] != nil { print("would click \(args[2]) at \(Int(c.x)) \(Int(c.y))"); exit(0) }
for t in [CGEventType.leftMouseDown, .leftMouseUp] { CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: c, mouseButton: .left)!.post(tap: .cghidEventTap); usleep(40000) }
print("clicked \(args[2]) at \(Int(c.x)) \(Int(c.y))")
