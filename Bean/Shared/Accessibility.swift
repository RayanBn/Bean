import ApplicationServices
import Foundation

enum Accessibility {
    static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        guard AXIsProcessTrusted() else { return nil }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func focusedWindow(of pid: pid_t) -> AXUIElement? {
        attribute(kAXFocusedWindowAttribute, of: AXUIElementCreateApplication(pid)).map { $0 as! AXUIElement }
    }

    static func focusedWindowTitle(of pid: pid_t) -> String? {
        focusedWindow(of: pid).flatMap { attribute(kAXTitleAttribute, of: $0) as? String }
    }

    static func focusedWindowFrame(of pid: pid_t) -> CGRect? {
        guard let window = focusedWindow(of: pid),
              let position = attribute(kAXPositionAttribute, of: window),
              let size = attribute(kAXSizeAttribute, of: window) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    static func focusedText(of pid: pid_t, limit: Int = 8000) -> String? {
        guard let element = attribute(kAXFocusedUIElementAttribute, of: AXUIElementCreateApplication(pid)),
              let text = attribute(kAXValueAttribute, of: element as! AXUIElement) as? String else { return nil }
        return String(text.suffix(limit))
    }
}
