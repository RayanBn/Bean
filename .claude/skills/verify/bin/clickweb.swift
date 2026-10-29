import AppKit
import ApplicationServices
let args = CommandLine.arguments
let bundle = args[1], wanted = args[2]
let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first!
app.activate()
Thread.sleep(forTimeInterval: 0.4)
let js = """
(function(){var w=\(String(data: try! JSONSerialization.data(withJSONObject: [wanted], options: .fragmentsAllowed), encoding: .utf8)!)[0];
var byHref=w.indexOf('href=')===0, h=w.slice(5);
var els=[].slice.call(document.querySelectorAll('a,button,[role=button]')).filter(function(e){return e.offsetParent!==null && (byHref ? (e.getAttribute('href')===h) : (e.innerText||'').trim()===w)});
if(!els.length) return 'none'; var e=els[0]; e.scrollIntoView({block:'center',behavior:'instant'});
var r=e.getBoundingClientRect(); return (r.left+r.width/2)+','+(r.top+r.height/2)+','+els.length;})()
"""
let oneLine = js.replacingOccurrences(of: "\n", with: " ")
let quoted = "\"" + oneLine.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
let marker = ProcessInfo.processInfo.environment["CLICK_WEB_TAB"] ?? ""
let script = marker.isEmpty
  ? "tell application id \"\(bundle)\" to tell front window to tell active tab to execute javascript \(quoted)"
  : "tell application id \"\(bundle)\"\nrepeat with w in windows\nif URL of active tab of w contains \"\(marker)\" then return (execute active tab of w javascript \(quoted))\nend repeat\nreturn \"none\"\nend tell"
var error: NSDictionary?
var result = ""
for _ in 0..<24 {
  result = (NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue ?? "error").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
  if result != "none", result != "error" { break }
  Thread.sleep(forTimeInterval: 0.5)
}
guard result != "none", result != "error" else { print("not found: \(wanted) (\(error?["NSAppleScriptErrorMessage"] ?? result))"); exit(1) }
let parts = result.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).split(separator: ",").compactMap { Double($0) }
guard parts.count == 3 else { print("unexpected result for \(wanted): [\(result)]"); exit(1) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
var q = [attr(ax, "AXFocusedWindow") as! AXUIElement], web: AXUIElement?
while !q.isEmpty { let e = q.removeFirst(); if (attr(e, "AXRole") as? String) == "AXWebArea" { web = e; break }; q += attr(e, "AXChildren") as? [AXUIElement] ?? [] }
guard let web else { print("no web area"); exit(1) }
var o = CGPoint.zero
AXValueGetValue(attr(web, "AXPosition") as! AXValue, .cgPoint, &o)
let c = CGPoint(x: o.x + parts[0], y: o.y + parts[1])
var hit: AXUIElement?
AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(c.x), Float(c.y), &hit)
var pid: pid_t = 0
if let hit { AXUIElementGetPid(hit, &pid) }
guard pid == app.processIdentifier else { print("covered: \(wanted) is under pid \(pid)"); exit(1) }
if ProcessInfo.processInfo.environment["CLICK_DRY_RUN"] != nil { print("would click \(wanted) at \(Int(c.x)) \(Int(c.y)) (\(Int(parts[2])) matches)"); exit(0) }
for t in [CGEventType.leftMouseDown, .leftMouseUp] { CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: c, mouseButton: .left)!.post(tap: .cghidEventTap); usleep(40000) }
print("clicked \(wanted) at \(Int(c.x)) \(Int(c.y))")
