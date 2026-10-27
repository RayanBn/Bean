import AppKit
import ApplicationServices

struct ClickMap {
    struct Item {
        let frame: CGRect
        let locator: ElementLocator
    }

    let pid: pid_t
    let window: String
    let items: [Item]

    static func build(_ app: NSRunningApplication, nodeLimit: Int = 4000) -> ClickMap? {
        guard let bundle = app.bundleIdentifier else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.25)
        guard let window = AX.element(kAXFocusedWindowAttribute, of: root) else { return nil }
        var items: [Item] = [], queue: [(AXUIElement, [String], String?)] = [(window, [], nil)], seen = 0
        while !queue.isEmpty, seen < nodeLimit {
            let (element, ancestors, url) = queue.removeFirst()
            seen += 1
            let role = AX.string(kAXRoleAttribute, of: element) ?? "?"
            let pageURL = role == "AXWebArea" ? AX.string("AXURL", of: element) ?? url : url
            if ActionRecorder.actionable.contains(role), let frame = ActionRecorder.frame(of: element), frame.width > 0, frame.height > 0 {
                let path = ancestors.reversed().prefix { $0 != "AXWebArea" && $0 != "AXWindow" }
                items.append(Item(frame: frame, locator: ElementLocator(
                    bundleId: bundle, role: role, identifier: ActionRecorder.nonEmpty(AX.string(kAXIdentifierAttribute, of: element)),
                    domId: ActionRecorder.nonEmpty(AX.string("AXDOMIdentifier", of: element)), label: ActionRecorder.label(of: element),
                    path: Array(path.prefix(4)), url: pageURL, href: ActionRecorder.nonEmpty(AX.string(kAXURLAttribute, of: element)))))
            }
            queue += AX.children(of: element).map { ($0, ancestors + [role], pageURL) }
        }
        return ClickMap(pid: app.processIdentifier, window: AX.string(kAXTitleAttribute, of: window) ?? "", items: items)
    }

    func locator(at point: CGPoint) -> ElementLocator? {
        items.filter { $0.frame.contains(point) }.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?.locator
    }
}
