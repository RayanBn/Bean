import ApplicationServices

enum AX {
    static func value(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func string(_ name: String, of element: AXUIElement) -> String? {
        let raw = value(name, of: element)
        return raw as? String ?? (raw as? URL)?.absoluteString
    }

    static func element(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let raw = value(name, of: element), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    static func children(of element: AXUIElement) -> [AXUIElement] {
        value(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
    }

    static func pid(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }
}
