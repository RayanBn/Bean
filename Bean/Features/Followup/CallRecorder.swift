import AVFoundation
import CoreAudio

enum Channel: String, Codable {
    case me, them
}

@available(macOS 14.2, *)
final class CallRecorder {
    var onBuffer: ((Channel, AVAudioPCMBuffer) -> Void)?
    var onProblem: ((String) -> Void)?
    private(set) var stats: [Channel: (frames: Int, loud: Int)] = [.me: (0, 0), .them: (0, 0)]

    private let queue = DispatchQueue(label: "bean.call.audio")
    private let ioQueue = DispatchQueue(label: "bean.call.tap", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var lastTapBuffer = Date()
    private var watchdog: DispatchSourceTimer?
    private var micFile: DispatchSourceTimer?
    private var micObserver: NSObjectProtocol?
    private var rebuilds = 0
    private var running = false

    static var systemAudioAllowed: Bool? {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
        guard let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW), let symbol = dlsym(tcc, "TCCAccessPreflight") else { return nil }
        switch unsafeBitCast(symbol, to: Preflight.self)("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    func start() throws {
        running = true
        try startTap()
        try startMic()
        AudioObjects.listen(kAudioHardwarePropertyDefaultOutputDevice, queue: queue) { [weak self] in
            guard let self, running else { return }
            rebuildTap(reason: "output device changed")
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, running, Date().timeIntervalSince(lastTapBuffer) > 5 else { return }
            rebuildTap(reason: "no system audio for 5 s")
        }
        timer.resume()
        watchdog = timer
    }

    func stop() {
        queue.sync {
            running = false
            watchdog?.cancel()
            micFile?.cancel()
            stopTap()
        }
        micObserver.map(NotificationCenter.default.removeObserver)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func startTap() throws {
        let own = AudioObjects.processObject(pid: getpid())
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: own.map { [$0] } ?? [])
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tapID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { throw RecorderError.tap("create tap") }
        tap = tapID
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Bean Call",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregateID) == noErr else { throw RecorderError.tap("create aggregate") }
        aggregate = aggregateID
        guard var stream = AudioObjects.value(kAudioTapPropertyFormat, of: tapID, as: AudioStreamBasicDescription.self),
              let format = AVAudioFormat(streamDescription: &stream) else { throw RecorderError.tap("read tap format") }
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, ioQueue) { [weak self] _, input, _, _, _ in
            guard let self, let view = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                  let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: view.frameLength) else { return }
            copy.frameLength = view.frameLength
            for channel in 0..<Int(format.channelCount) {
                copy.floatChannelData?[channel].update(from: view.floatChannelData![channel], count: Int(view.frameLength))
            }
            queue.async { self.deliver(.them, copy) }
        }
        guard status == noErr, let proc else { throw RecorderError.tap("create IO proc") }
        ioProc = proc
        lastTapBuffer = Date()
        guard AudioDeviceStart(aggregateID, proc) == noErr else { throw RecorderError.tap("start") }
    }

    private func stopTap() {
        if let ioProc {
            AudioDeviceStop(aggregate, ioProc)
            AudioDeviceDestroyIOProcID(aggregate, ioProc)
        }
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        ioProc = nil
        aggregate = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }

    private func rebuildTap(reason: String) {
        stopTap()
        rebuilds += 1
        guard rebuilds <= 10 else {
            onProblem?("system audio stopped (\(reason)), gave up after 10 rebuilds")
            return
        }
        do { try startTap() } catch { onProblem?("system audio rebuild failed: \(error.localizedDescription)") }
        onProblem?("rebuilt system audio: \(reason)")
    }

    private func startMic() throws {
        if let path = ProcessInfo.processInfo.environment["BEAN_MIC_FILE"] {
            try playMicFile(URL(fileURLWithPath: path))
            return
        }
        micObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, running else { return }
            do {
                try startEngine()
                onProblem?("restarted the microphone: input format changed")
            } catch {
                onProblem?("microphone restart failed: \(error.localizedDescription)")
            }
        }
        try startEngine()
    }

    private func startEngine() throws {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.mic }
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.queue.async { self?.deliver(.me, buffer) }
        }
        try engine.start()
    }

    private func playMicFile(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.1)
        timer.setEventHandler { [weak self] in
            guard let self, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return }
            if (try? file.read(into: buffer, frameCount: chunk)) == nil || buffer.frameLength == 0 {
                micFile?.cancel()
                return
            }
            deliver(.me, buffer)
        }
        timer.resume()
        micFile = timer
    }

    private func deliver(_ channel: Channel, _ buffer: AVAudioPCMBuffer) {
        guard running, let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        var loud = 0
        for i in stride(from: 0, to: count, by: 16) where abs(samples[i]) > 0.003 { loud += 16 }
        if channel == .them { lastTapBuffer = Date() }
        let current = stats[channel] ?? (0, 0)
        stats[channel] = (current.frames + count, current.loud + loud)
        onBuffer?(channel, buffer)
    }

    enum RecorderError: LocalizedError {
        case tap(String), mic
        var errorDescription: String? {
            switch self {
            case let .tap(step): return "system audio: \(step) failed"
            case .mic: return "no microphone input"
            }
        }
    }
}
