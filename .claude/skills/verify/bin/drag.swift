import CoreGraphics
import Foundation

let a = CommandLine.arguments.dropFirst().compactMap(Double.init)
let from = CGPoint(x: a[0], y: a[1]), to = CGPoint(x: a[2], y: a[3])
let seconds = a.count > 4 ? a[4] : 1.2
let back = CGEvent(source: nil)!.location
func post(_ type: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap)
}
post(.mouseMoved, from)
usleep(120_000)
post(.leftMouseDown, from)
usleep(150_000)
let steps = Int(seconds * 60)
for i in 1...steps {
    let t = Double(i) / Double(steps)
    let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    let wobble = sin(t * .pi * 3) * 40 * (1 - t)
    post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * e + wobble, y: from.y + (to.y - from.y) * e))
    usleep(16_000)
}
usleep(500_000)
post(.leftMouseUp, to)
usleep(900_000)
post(.mouseMoved, back)
