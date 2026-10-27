import AppKit
import CoreAudio

@available(macOS 14.2, *)
final class CallWatcher {
    struct Call {
        let startedAt: Date
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

    private var watchedInput = AudioObjectID(kAudioObjectUnknown)

    func start() {
        AudioObjects.listen(kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.refresh() }
        AudioObjects.listen(kAudioHardwarePropertyDefaultInputDevice) { [weak self] in self?.watchInput() }
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
        let user = micUser()
        let wantsCall = user != nil
        guard wantsCall != (current != nil) else {
            pending?.cancel()
            pending = nil
            return
        }
        guard pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pending = nil
            if let user = micUser(), current == nil {
                let call = Call(startedAt: Date(), app: user.isEmpty ? nil : user)
                current = call
                onStart?(call)
            } else if micUser() == nil, let call = current {
                current = nil
                onEnd?(call)
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (wantsCall ? startDelay : endDelay), execute: work)
    }

    private func micUser() -> String? {
        let own = getpid()
        for process in AudioObjects.list(kAudioHardwarePropertyProcessObjectList) {
            guard let pid = AudioObjects.value(kAudioProcessPropertyPID, of: process, as: pid_t.self), pid != own,
                  AudioObjects.value(kAudioProcessPropertyIsRunningInput, of: process, as: UInt32.self) == 1 else { continue }
            return Self.name(pid: pid, bundleId: AudioObjects.string(kAudioProcessPropertyBundleID, of: process)) ?? ""
        }
        return nil
    }

    private static func name(pid: pid_t, bundleId: String?) -> String? {
        if let meeting = Presence.current().meetingApp { return meeting }
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName { return name }
        if let bundleId, !bundleId.isEmpty {
            let parent = bundleId.components(separatedBy: ".helper").first ?? bundleId
            return NSRunningApplication.runningApplications(withBundleIdentifier: parent).first?.localizedName ?? parent
        }
        return nil
    }
}
