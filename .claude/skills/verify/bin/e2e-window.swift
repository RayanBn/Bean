import AppKit

final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

let args = CommandLine.arguments
guard args.count >= 5 else { print("usage: e2e-window <title> <text-file> <live-file> <changes-file> [revert]"); exit(64) }
let reverts = args.count > 5
let (title, live, changes) = (args[1], args[3], args[4])
let start = (try? String(contentsOfFile: args[2], encoding: .utf8)) ?? ""

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = OffscreenWindow(contentRect: NSRect(x: -6000, y: -6000, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
window.title = title
let scroll = NSTextView.scrollableTextView()
let text = scroll.documentView as! NSTextView
text.isEditable = true
text.string = start
window.contentView = scroll
window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
window.orderBack(nil)

var last = start
try? start.write(toFile: live, atomically: true, encoding: .utf8)
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    let now = text.string
    guard now != last else { return }
    if reverts, now != start { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { text.string = start } }
    last = now
    try? now.write(toFile: live, atomically: true, encoding: .utf8)
    if let handle = FileHandle(forWritingAtPath: changes) {
        handle.seekToEndOfFile()
        handle.write(Data("\(Date().timeIntervalSince1970)\n".utf8))
        try? handle.close()
    } else {
        try? "\(Date().timeIntervalSince1970)\n".write(toFile: changes, atomically: true, encoding: .utf8)
    }
}
print("ready")
fflush(stdout)
app.run()
