import AppKit
import CoreAudio
import CoreMediaIO

@available(macOS 14.2, *)
final class CallWatcher {
    struct Call {
        let startedAt: Date
        let pid: pid_t
        let app: String?
    }

    var onStart: ((Call) -> Void)?
    var onEnd: ((Call) -> Void)?
    private(set) var current: Call?

    private let environment = ProcessInfo.processInfo.environment
    private lazy var startDelay = environment["BEAN_CALL_START_SECONDS"].flatMap(Double.init) ?? 3
    private lazy var endDelay = environment["BEAN_CALL_END_SECONDS"].flatMap(Double.init) ?? 8
    private var watched: Set<AudioObjectID> = []
    private var pending: DispatchWorkItem?
    private var cameraCheck: Timer?
    private var watchedInput = AudioObjectID(kAudioObjectUnknown)

    func start() {
        AudioObjects.listen(kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.refresh() }
        AudioObjects.listen(kAudioHardwarePropertyDefaultInputDevice) { [weak self] in self?.watchInput() }
        cameraCheck = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.evaluate() }
        watchInput()
        refresh()
    }

    private func watchInput() {
        guard let device = AudioObjects.value(kAudioHardwarePropertyDefaultInputDevice, of: AudioObjects.system, as: AudioObjectID.self),
              device != watchedInput else { return }
        watchedInput = device
        AudioObjects.listen(kAudioDevicePropertyDeviceIsRunningSomewhere, of: device) { [weak self] in self?.refresh() }
        refresh()
    }

    private func refresh() {
        let processes = Set(AudioObjects.list(kAudioHardwarePropertyProcessObjectList))
        watched.formIntersection(processes)
        for process in processes.subtracting(watched) {
            watched.insert(process)
            AudioObjects.listen(kAudioProcessPropertyIsRunningInput, of: process) { [weak self] in self?.evaluate() }
        }
        evaluate()
    }

    private func evaluate() {
        let wantsCall = holder() != nil
        guard wantsCall != (current != nil) else {
            pending?.cancel()
            pending = nil
            return
        }
        guard pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pending = nil
            if let holder = holder(), current == nil {
                let call = Call(startedAt: Date(), pid: holder.pid, app: holder.app)
                current = call
                onStart?(call)
            } else if holder() == nil, let call = current {
                current = nil
                onEnd?(call)
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (wantsCall ? startDelay : endDelay), execute: work)
    }

    private func holder() -> (pid: pid_t, app: String?)? {
        let own = getpid(), ownBundle = Bundle.main.bundleIdentifier
        for process in AudioObjects.list(kAudioHardwarePropertyProcessObjectList) {
            guard let pid = AudioObjects.value(kAudioProcessPropertyPID, of: process, as: pid_t.self), pid != own,
                  AudioObjects.value(kAudioProcessPropertyIsRunningInput, of: process, as: UInt32.self) == 1 else { continue }
            let bundle = AudioObjects.string(kAudioProcessPropertyBundleID, of: process)
            if bundle == ownBundle { continue }
            return (pid, NSRunningApplication(processIdentifier: pid)?.localizedName ?? bundle)
        }
        if Self.cameraInUse(), let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != own {
            return (front.processIdentifier, front.localizedName)
        }
        return nil
    }

    static func parents(of pid: pid_t) -> [pid_t] {
        var chain: [pid_t] = [], current = pid
        for _ in 0..<8 {
            chain.append(current)
            var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
            var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_eproc.e_ppid > 1 else { break }
            current = info.kp_eproc.e_ppid
        }
        return chain
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
            var running = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var value: UInt32 = 0, valueUsed: UInt32 = 0
            return CMIOObjectGetPropertyData(device, &running, 0, nil, UInt32(MemoryLayout<UInt32>.size), &valueUsed, &value) == noErr && value != 0
        }
    }
}
