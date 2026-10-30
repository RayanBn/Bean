import Foundation
import CoreGraphics

if ProcessInfo.processInfo.environment["BEAN_INPUT_OK"] != "1" {
    print("refused: real input needs the notch lock, go through bean")
    exit(3)
}
let p = CGPoint(x: Double(CommandLine.arguments[1])!, y: Double(CommandLine.arguments[2])!)
let back = CGEvent(source: nil)!.location
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap)
usleep(80_000)
for t in [CGEventType.leftMouseDown, .leftMouseUp] {
    CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap)
}
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: back, mouseButton: .left)!.post(tap: .cghidEventTap)
