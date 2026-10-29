import AppKit
import ApplicationServices
let app = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[1]).first!
let ax = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
Thread.sleep(forTimeInterval: 1)
func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
func str(_ e: AXUIElement, _ a: String) -> String? { attr(e, a) as? String ?? (attr(e, a) as? URL)?.absoluteString }
func label(_ e: AXUIElement) -> String? {
  for a in ["AXTitle", "AXDescription"] { if let s = str(e, a), !s.isEmpty { return s } }
  for c in (attr(e, "AXChildren") as? [AXUIElement] ?? []).prefix(4) where str(c, "AXRole") == "AXStaticText" { if let s = str(c, "AXValue"), !s.isEmpty { return s } }
  return nil }
let pattern = CommandLine.arguments[2]
guard let window = attr(ax, "AXFocusedWindow") else { print("no window"); exit(1) }
var q = [window as! AXUIElement], n = 0
while !q.isEmpty, n < 20000 { let e = q.removeFirst(); n += 1
  let r = str(e, "AXRole") ?? ""
  if ["AXLink", "AXButton", "AXTab", "AXRadioButton"].contains(r) {
    let l = label(e) ?? "", u = str(e, "AXURL") ?? ""
    if l.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil || u.range(of: pattern, options: .regularExpression) != nil { print(r, "|", l, "|", u) } }
  q += attr(e, "AXChildren") as? [AXUIElement] ?? [] }
