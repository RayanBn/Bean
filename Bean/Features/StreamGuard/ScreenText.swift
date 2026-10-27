import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision

struct VisibleWindow {
    let id: CGWindowID
    let pid: pid_t
    let app: String
    let title: String
    let frame: CGRect
}

struct TextPiece {
    let window: VisibleWindow
    let text: String
    let rect: (NSRange) -> CGRect?
}

enum ScreenText {
    static let nodeLimit = 4000
    static let timeLimit: TimeInterval = 0.3
    static let ocrBelowCharacters = 40
    private static let textRoles: Set<String> = [kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole, kAXCellRole, "AXHeading", "AXLink"]
    private static let skippedRoles: Set<String> = [kAXMenuBarRole, kAXScrollBarRole, kAXImageRole, kAXMenuRole]

    static func visibleWindows(limit: Int = 8) -> [VisibleWindow] {
        let own = getpid()
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info -> VisibleWindow? in
            guard let layer = info[kCGWindowLayer as String] as? Int, (0...3).contains(layer), (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width > 60, frame.height > 40 else { return nil }
            return VisibleWindow(id: id, pid: pid, app: info[kCGWindowOwnerName as String] as? String ?? "?", title: info[kCGWindowName as String] as? String ?? "", frame: frame)
        }.prefix(limit).map { $0 }
    }

    static func accessibilityText(in window: VisibleWindow) -> (pieces: [TextPiece], secure: [CGRect]) {
        guard let element = axWindow(for: window) else { return ([], []) }
        var pieces: [TextPiece] = []
        var secure: [CGRect] = []
        walk(element) { node, role in
            if role == "AXSecureTextField", let frame = frame(of: node) { secure.append(frame) }
            guard textRoles.contains(role) else { return role != kAXTextAreaRole }
            guard let value = Accessibility.attribute(kAXValueAttribute, of: node) as? String ?? Accessibility.attribute(kAXTitleAttribute, of: node) as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return role != kAXTextAreaRole }
            var offset = 0
            var text = value
            if let visible = Accessibility.attribute("AXVisibleCharacterRange", of: node), CFGetTypeID(visible) == AXValueGetTypeID() {
                var range = CFRange()
                AXValueGetValue(visible as! AXValue, .cfRange, &range)
                let ns = value as NSString
                if range.location >= 0, range.location + range.length <= ns.length, range.length > 0 {
                    offset = range.location
                    text = ns.substring(with: NSRange(location: range.location, length: range.length))
                }
            }
            let whole = frame(of: node)
            pieces.append(TextPiece(window: window, text: text) { local in
                var range = CFRange(location: local.location + offset, length: local.length)
                guard let parameter = AXValueCreate(.cfRange, &range) else { return whole }
                var out: AnyObject?
                guard AXUIElementCopyParameterizedAttributeValue(node, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &out) == .success,
                      let value = out, CFGetTypeID(value) == AXValueGetTypeID() else { return whole }
                var rect = CGRect.zero
                AXValueGetValue(value as! AXValue, .cgRect, &rect)
                return rect.width > 0 && rect.height > 0 ? rect : whole
            })
            return role != kAXTextAreaRole
        }
        return (pieces, secure)
    }

    static func ocrPieces(in window: VisibleWindow, content: SCShareableContent) async -> [TextPiece] {
        guard let scWindow = content.windows.first(where: { $0.windowID == window.id }) else { return [] }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2)
        config.height = Int(window.frame.height * 2)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: scWindow), configuration: config) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string
            func global(_ box: CGRect) -> CGRect {
                CGRect(x: window.frame.minX + box.minX * window.frame.width, y: window.frame.minY + (1 - box.maxY) * window.frame.height,
                       width: box.width * window.frame.width, height: box.height * window.frame.height)
            }
            let line = global(observation.boundingBox)
            return TextPiece(window: window, text: text) { local in
                guard let range = Range(local, in: text), let box = try? candidate.boundingBox(for: range)?.boundingBox else { return line }
                return global(box)
            }
        }
    }

    private static func axWindow(for window: VisibleWindow) -> AXUIElement? {
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let windows = Accessibility.attribute(kAXWindowsAttribute, of: app) as? [AXUIElement] ?? []
        return windows.first { WindowServer.windowId(of: $0) == window.id }
    }

    private static func walk(_ root: AXUIElement, _ visit: (AXUIElement, String) -> Bool) {
        let started = Date()
        var queue = [root], visited = 0
        while !queue.isEmpty, visited < nodeLimit, Date().timeIntervalSince(started) < timeLimit {
            let node = queue.removeFirst()
            AXUIElementSetMessagingTimeout(node, 0.05)
            visited += 1
            let role = Accessibility.attribute(kAXRoleAttribute, of: node) as? String ?? ""
            if skippedRoles.contains(role) { continue }
            if visit(node, role) { queue += Accessibility.attribute(kAXChildrenAttribute, of: node) as? [AXUIElement] ?? [] }
        }
    }

    private static func frame(of node: AXUIElement) -> CGRect? {
        guard let position = Accessibility.attribute(kAXPositionAttribute, of: node), let size = Accessibility.attribute(kAXSizeAttribute, of: node) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }
}
