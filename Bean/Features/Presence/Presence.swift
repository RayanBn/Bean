import AppKit
import CoreAudio
import CoreMediaIO

struct PresenceState: Codable, Equatable {
    let micInUse: Bool
    let cameraInUse: Bool
    let meetingApp: String?
    let inMeeting: Bool
}

enum Presence {
    private static let meetingApps: Set<String> = ["us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.FaceTime", "com.cisco.webexmeetingsapp"]
    private static let meetingHosts: Set<String> = ["meet.google.com", "teams.microsoft.com", "teams.live.com", "app.zoom.us"]

    static func current() -> PresenceState {
        let mic = micInUse(), camera = cameraInUse(), app = frontmostMeeting()
        return PresenceState(micInUse: mic, cameraInUse: camera, meetingApp: app, inMeeting: mic || camera || app != nil)
    }

    private static func frontmostMeeting() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundleId = app.bundleIdentifier else { return nil }
        if meetingApps.contains(bundleId) { return bundleId }
        guard let page = BrowserReader.current(bundleId: bundleId, pid: app.processIdentifier), meetingHosts.contains(page.host) else { return nil }
        if page.host == "meet.google.com", page.url.path.range(of: #"^/[a-z]{3}-[a-z]{4}-[a-z]{3}"#, options: .regularExpression) == nil { return nil }
        return page.host
    }

    private static func micInUse() -> Bool {
        if #available(macOS 14.2, *) {
            let own = getpid()
            return audioObjects(kAudioHardwarePropertyProcessObjectList).contains { process in
                audioValue(kAudioProcessPropertyPID, of: process, as: pid_t.self) != own && audioValue(kAudioProcessPropertyIsRunningInput, of: process, as: UInt32.self) == 1
            }
        }
        return audioObjects(kAudioHardwarePropertyDevices).contains { device in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
                && audioValue(kAudioDevicePropertyDeviceIsRunningSomewhere, of: device, as: UInt32.self) == 1
        }
    }

    private static func audioObjects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private static func audioValue<T>(_ selector: AudioObjectPropertySelector, of object: AudioObjectID, as _: T.Type) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr ? value.pointee : nil
    }

    private static func cameraInUse() -> Bool {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == noErr else { return false }
        return devices.contains { device in
            var running = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            var value: UInt32 = 0, valueUsed: UInt32 = 0
            return CMIOObjectGetPropertyData(device, &running, 0, nil, UInt32(MemoryLayout<UInt32>.size), &valueUsed, &value) == noErr && value != 0
        }
    }
}
