import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
guard let w = list.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }),
      let b = w[kCGWindowBounds as String] as? [String: Double] else { exit(1) }
print(Int(b["X"]!), Int(b["Y"]!), Int(b["Width"]!), Int(b["Height"]!), w[kCGWindowLayer as String]!)
