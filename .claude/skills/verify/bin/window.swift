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
guard let w = list.filter({ ($0[kCGWindowOwnerPID as String] as? Int32) == pid && visible($0) }).min(by: { area($0) < area($1) }),
      let b = w[kCGWindowBounds as String] as? [String: Double] else { exit(1) }
print(Int(b["X"]!), Int(b["Y"]!), Int(b["Width"]!), Int(b["Height"]!), w[kCGWindowLayer as String]!)
