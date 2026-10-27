import CoreAudio
import Foundation

enum AudioObjects {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    static func list(_ selector: AudioObjectPropertySelector, of object: AudioObjectID = system) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    static func value<T>(_ selector: AudioObjectPropertySelector, of object: AudioObjectID, as _: T.Type) -> T? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr ? value.pointee : nil
    }

    static func string(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    @discardableResult
    static func listen(_ selector: AudioObjectPropertySelector, of object: AudioObjectID = system, queue: DispatchQueue = .main, _ handler: @escaping () -> Void) -> Bool {
        var address = address(selector)
        return AudioObjectAddPropertyListenerBlock(object, &address, queue) { _, _ in handler() } == noErr
    }
}
