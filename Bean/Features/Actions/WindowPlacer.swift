import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ data: CFData) -> Unmanaged<AXUIElement>?

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> Unmanaged<CFArray>?

struct SpaceInfo: Codable, Equatable {
    let id: Int
    let display: String
    let fullScreen: Bool
}

enum WindowPlacer {
    static let fullScreenWait: TimeInterval = 6
    static let remoteElementScan: UInt64 = 2000

    static func spaces() -> [SpaceInfo] {
        let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?.takeRetainedValue() as? [[String: Any]] ?? []
        return displays.flatMap { display in
            (display["Spaces"] as? [[String: Any]] ?? []).compactMap { space -> SpaceInfo? in
                guard let id = (space["ManagedSpaceID"] as? NSNumber)?.intValue else { return nil }
                return SpaceInfo(id: id, display: display["Display Identifier"] as? String ?? "", fullScreen: (space["type"] as? NSNumber)?.intValue == 4)
            }
        }
    }

    static func find(pid: pid_t, title: String?) -> CGWindowID? {
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
        let match = windows.first { window in
            guard let title else { return true }
            return (window[kCGWindowName as String] as? String)?.localizedCaseInsensitiveContains(title) ?? false
        }
        return (match?[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) }
    }

    static func space(of window: CGWindowID) -> Int? {
        WindowServer.spaces(of: [window])[window]
    }

    /// kAXWindows only lists the current Space. The focused and main windows are not filtered by Space, and other windows are found by their remote token, as AltTab and yabai do.
    static func element(for window: CGWindowID, pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let main = [kAXFocusedWindowAttribute, kAXMainWindowAttribute].compactMap { Accessibility.attribute($0, of: app).map { $0 as! AXUIElement } }
        for candidate in main + (Accessibility.attribute(kAXWindowsAttribute, of: app) as? [AXUIElement] ?? []) where WindowServer.windowId(of: candidate) == window {
            return candidate
        }
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: pid, toByteOffset: 0, as: Int32.self)
            bytes.storeBytes(of: Int32(0), toByteOffset: 4, as: Int32.self)
            bytes.storeBytes(of: Int32(0x636f_636f), toByteOffset: 8, as: Int32.self)
        }
        for id in 0 ..< remoteElementScan {
            token.withUnsafeMutableBytes { $0.storeBytes(of: id, toByteOffset: 12, as: UInt64.self) }
            guard let element = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            if Accessibility.attribute(kAXRoleAttribute, of: element) as? String == kAXWindowRole, WindowServer.windowId(of: element) == window {
                return element
            }
        }
        return nil
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = Accessibility.attribute(kAXPositionAttribute, of: element), let size = Accessibility.attribute(kAXSizeAttribute, of: element) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    static func isFullScreen(_ element: AXUIElement) -> Bool {
        Accessibility.attribute("AXFullScreen", of: element) as? Bool ?? false
    }

    /// Size, position, then size again: macOS clamps a size to the display the window is on before the move (Rectangle does the same).
    @discardableResult
    static func setFrame(_ element: AXUIElement, pid: pid_t, to frame: CGRect) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        let enhanced = Accessibility.attribute("AXEnhancedUserInterface", of: app) as? Bool ?? false
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer { if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }
        var size = frame.size, origin = frame.origin
        let sizeValue = AXValueCreate(.cgSize, &size)!, originValue = AXValueCreate(.cgPoint, &origin)!
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        let moved = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, originValue)
        let sized = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        return moved == .success && sized == .success
    }

    /// A second full-screen request sent during the previous animation is ignored, so this waits until the window has its own Space.
    static func enterFullScreen(_ element: AXUIElement, window: CGWindowID) async -> Bool {
        let before = space(of: window)
        for attempt in 0 ..< 2 {
            AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, kCFBooleanTrue)
            let deadline = Date().addingTimeInterval(fullScreenWait)
            while Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
                if let now = space(of: window), now != before, spaces().first(where: { $0.id == now })?.fullScreen == true {
                    try? await Task.sleep(for: .milliseconds(attempt == 0 ? 900 : 1200))
                    return true
                }
            }
        }
        return false
    }

    static func exitFullScreen(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, kCFBooleanFalse)
    }

    /// Works with SIP on from macOS 26.4 (the bridged SkyLight operation yabai 7.1.25 uses). Checked by reading the Space back.
    static func move(_ window: CGWindowID, toSpace target: Int) async -> Bool {
        guard space(of: window) != target else { return true }
        guard let operation = SkyLightBridge.moveOperation(windows: [window], space: UInt64(target)) else { return false }
        SkyLightBridge.perform(operation)
        for _ in 0 ..< 40 {
            if space(of: window) == target { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }
}

private enum SkyLightBridge {
    private static let send = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")
    private static let loaded: Bool = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW) != nil

    static func moveOperation(windows: [CGWindowID], space: UInt64) -> AnyObject? {
        guard loaded, let send, let type = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation") else { return nil }
        typealias Alloc = @convention(c) (AnyClass, Selector) -> AnyObject?
        typealias Initialize = @convention(c) (AnyObject, Selector, NSArray, UInt64) -> AnyObject?
        let initializer = NSSelectorFromString("initWithWindows:spaceID:")
        guard (type as? NSObject.Type)?.instancesRespond(to: initializer) == true,
              let allocated = unsafeBitCast(send, to: Alloc.self)(type, NSSelectorFromString("alloc")) else { return nil }
        return unsafeBitCast(send, to: Initialize.self)(allocated, initializer, windows.map { NSNumber(value: $0) } as NSArray, space)
    }

    static func perform(_ operation: AnyObject) {
        guard let send else { return }
        typealias Perform = @convention(c) (AnyObject, Selector) -> AnyObject?
        _ = unsafeBitCast(send, to: Perform.self)(operation, NSSelectorFromString("performWithWMBridgeDelegate"))
    }
}
