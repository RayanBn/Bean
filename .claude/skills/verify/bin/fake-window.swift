import AppKit

let args = CommandLine.arguments
let text = (try? String(contentsOfFile: args[1], encoding: .utf8)) ?? ""
let frame = args.count > 5 ? NSRect(x: Double(args[2])!, y: Double(args[3])!, width: Double(args[4])!, height: Double(args[5])!) : NSRect(x: 200, y: 200, width: 820, height: 320)
let seconds = args.count > 6 ? Double(args[6])! : 60
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let primary = NSScreen.screens[0].frame.height
let window = NSWindow(contentRect: NSRect(x: frame.minX, y: primary - frame.maxY, width: frame.width, height: frame.height), styleMask: [.titled], backing: .buffered, defer: false)
window.title = (args[1] as NSString).lastPathComponent
window.level = .floating
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
let view = NSTextView(frame: window.contentView!.bounds)
view.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
view.backgroundColor = .white
view.textColor = .black
view.textContainerInset = NSSize(width: 12, height: 12)
view.string = text
window.contentView!.addSubview(view)
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
print("fake-window pid=\(getpid()) id=\(window.windowNumber)")
fflush(stdout)
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
app.run()
