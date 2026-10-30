import AppKit

final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class Actions: NSObject {
    @objc func pressed(_ sender: NSButton) {
        print("pressed \(sender.title)")
        fflush(stdout)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = OffscreenWindow(contentRect: NSRect(x: -6000, y: -6000, width: 400, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
window.title = "Bean controls fixture"
let actions = Actions()
let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
let field = NSTextField(frame: NSRect(x: 20, y: 190, width: 360, height: 24))
field.placeholderString = "Draft"
let secure = NSSecureTextField(frame: NSRect(x: 20, y: 150, width: 360, height: 24))
secure.placeholderString = "Password"
let locked = NSTextField(labelWithString: "Read only label")
locked.frame = NSRect(x: 20, y: 120, width: 360, height: 20)
content.addSubview(field)
content.addSubview(secure)
content.addSubview(locked)
for (i, title) in ["Save draft", "Send", "Supprimer", "Buy now"].enumerated() {
    let button = NSButton(title: title, target: actions, action: #selector(Actions.pressed))
    button.frame = NSRect(x: 20 + i * 92, y: 70, width: 88, height: 32)
    content.addSubview(button)
}
window.contentView = content
window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
window.orderBack(nil)
print("ready \(ProcessInfo.processInfo.processIdentifier)")
fflush(stdout)
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in print("field=\(field.stringValue)"); fflush(stdout) }
DispatchQueue.main.asyncAfter(deadline: .now() + 45) { exit(0) }
app.run()
