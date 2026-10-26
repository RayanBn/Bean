import ApplicationServices
import CoreGraphics

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int32

@_silgen_name("CGSGetActiveSpace")
func CGSGetActiveSpace(_ connection: Int32) -> Int

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ connection: Int32, _ mask: Int32, _ windows: CFArray) -> Unmanaged<CFArray>?

enum WindowServer {
    static func windowId(of element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
    }

    static var activeSpace: Int { CGSGetActiveSpace(CGSMainConnectionID()) }

    static func spaces(of windows: [CGWindowID]) -> [CGWindowID: Int] {
        var result: [CGWindowID: Int] = [:]
        let connection = CGSMainConnectionID()
        for window in windows {
            let spaces = CGSCopySpacesForWindows(connection, 0x7, [window] as CFArray)?.takeRetainedValue() as? [Int]
            if let space = spaces?.first { result[window] = space }
        }
        return result
    }
}
