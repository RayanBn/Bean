import AppKit
import ApplicationServices
let app = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[1]).first!
let pattern = CommandLine.arguments[2]
app.activate(); Thread.sleep(forTimeInterval: 0.5)
let ax = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
var closed = 0
for w in attr(ax, "AXWindows") as? [AXUIElement] ?? [] {
  let title = attr(w, "AXTitle") as? String ?? ""
  guard title.range(of: pattern, options: .regularExpression) != nil, let close = attr(w, "AXCloseButton") else { continue }
  AXUIElementPerformAction(close as! AXUIElement, "AXPress" as CFString)
  closed += 1
  print("closed window: \(title)")
  Thread.sleep(forTimeInterval: 0.3)
}
print("\(closed) windows closed")
