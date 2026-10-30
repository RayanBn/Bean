import AppKit

final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: fixture-window.swift <title> <text-file>"); exit(64) }
let title = args[1], file = URL(fileURLWithPath: args[2])

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = OffscreenWindow(contentRect: NSRect(x: -6000, y: -6000, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
window.title = title
let scroll = NSTextView.scrollableTextView()
let text = scroll.documentView as! NSTextView
text.isEditable = false
window.contentView = scroll
window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
window.orderBack(nil)

var last = ""
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
    let now = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    guard now != last else { return }
    last = now
    text.string = now
    if let first = now.split(separator: "\n").first, first.hasPrefix("title: ") { window.title = String(first.dropFirst(7)) }
}.fire()
print("fixture pid=\(ProcessInfo.processInfo.processIdentifier) window=\(window.windowNumber)")
fflush(stdout)
app.run()
