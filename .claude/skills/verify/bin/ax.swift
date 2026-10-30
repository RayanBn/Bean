import AppKit
import ApplicationServices

let args = CommandLine.arguments
guard args.count >= 3, let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).first else { print("usage: ax.swift <bundle-id> get|set x y w h|full 0|1|front|close"); exit(64) }
let el = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? { var r: CFTypeRef?; return AXUIElementCopyAttributeValue(e, n as CFString, &r) == .success ? r : nil }
let windows = (attr(el, kAXWindowsAttribute) as? [AXUIElement]) ?? []
guard let w = (attr(el, kAXMainWindowAttribute) as! AXUIElement?) ?? windows.first else { print("no window"); exit(1) }
func frame(_ w: AXUIElement) -> CGRect {
    var o = CGPoint.zero, s = CGSize.zero
    if let p = attr(w, kAXPositionAttribute) { AXValueGetValue(p as! AXValue, .cgPoint, &o) }
    if let z = attr(w, kAXSizeAttribute) { AXValueGetValue(z as! AXValue, .cgSize, &s) }
    return CGRect(origin: o, size: s)
}
switch args[2] {
case "get":
    let f = frame(w)
    print(Int(f.minX), Int(f.minY), Int(f.width), Int(f.height), (attr(w, "AXFullScreen") as? Bool) == true ? 1 : 0)
case "set":
    var o = CGPoint(x: Double(args[3])!, y: Double(args[4])!), s = CGSize(width: Double(args[5])!, height: Double(args[6])!)
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &o)!)
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!)
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &o)!)
    let f = frame(w); print(Int(f.minX), Int(f.minY), Int(f.width), Int(f.height))
case "full":
    let r = AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString, (args[3] == "1" ? kCFBooleanTrue : kCFBooleanFalse)!)
    print("full", args[3], r.rawValue)
case "close":
    if let button = attr(w, kAXCloseButtonAttribute) { AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) }
    print("closed")
case "front":
    AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    app.activate()
    print("front")
default: print("?")
}
