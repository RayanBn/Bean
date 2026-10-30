import AVFoundation

@available(macOS 14.2, *)
final class CallSense {
    static let id = "hear calls"
    static let detects = "A call in an app: the microphone in use by it, or the camera with it in front."
    static let permissions = ["Microphone", "System Audio Recording"]

    enum Event {
        case started(CallWatcher.Call)
        case recording(CallWatcher.Call, language: String)
        case ended(CallWatcher.Call)
        case heard(CallWatcher.Call, endedAt: Date, transcript: String)
        case failed(CallWatcher.Call, String, settingsPane: String?)
    }

    private struct Record: Codable {
        let at: Date
        let event: String
        var app: String? = nil
        var detail: String? = nil
        var audio: [String: [Int]]? = nil
        var seconds: Double? = nil
    }

    private final class Session {
        let call: CallWatcher.Call
        let recorder = CallRecorder()
        let me: ChannelTranscriber
        let them: ChannelTranscriber

        init(call: CallWatcher.Call, me: ChannelTranscriber, them: ChannelTranscriber) {
            self.call = call
            self.me = me
            self.them = them
        }
    }

    var onEvent: ((Event) -> Void)?
    private let log = JSONLog(name: "hearing")
    private var session: Session?
    private(set) var current: CallWatcher.Call?

    func started(_ call: CallWatcher.Call) {
        current = call
        log.append(Record(at: Date(), event: "callStarted", app: call.app))
        onEvent?(.started(call))
    }

    @MainActor
    func record(_ call: CallWatcher.Call) async {
        guard current?.startedAt == call.startedAt, session == nil else { return }
        func fail(_ text: String, pane: String?) {
            log.append(Record(at: Date(), event: "recordFailed", app: call.app, detail: text))
            onEvent?(.failed(call, text, settingsPane: pane))
        }
        if ProcessInfo.processInfo.environment["BEAN_MIC_FILE"] == nil, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            return fail("I cannot hear this call: allow the microphone for Bean in System Settings.", pane: "Privacy_Microphone")
        }
        guard #available(macOS 26, *) else { return fail("Listening to calls needs macOS 26 or later.", pane: nil) }
        do {
            let languages = await Transcribers.callLocales().map(\.identifier).joined(separator: ", ")
            let session = Session(call: call, me: try await Transcribers.make(.me), them: try await Transcribers.make(.them))
            session.recorder.onBuffer = { [weak session] channel, buffer in
                (channel == .me ? session?.me : session?.them)?.append(buffer)
            }
            session.recorder.onProblem = { [weak self] text in
                self?.log.append(Record(at: Date(), event: "audioProblem", app: call.app, detail: text))
            }
            try session.recorder.start()
            self.session = session
            log.append(Record(at: Date(), event: "recording", app: call.app, detail: "\(BeanSettings.shared.effectiveTranscriber.rawValue), \(languages), system audio allowed: \(CallRecorder.systemAudioAllowed.map(String.init) ?? "unknown")"))
            onEvent?(.recording(call, language: languages))
            if current == nil { ended(call) }
        } catch {
            fail("I cannot listen to this call: \(error.localizedDescription)", pane: nil)
        }
    }

    func ended() {
        guard let call = current else { return }
        current = nil
        ended(call)
    }

    private func ended(_ call: CallWatcher.Call) {
        log.append(Record(at: Date(), event: "callEnded", app: call.app))
        onEvent?(.ended(call))
        guard let session, session.call.startedAt == call.startedAt else { return }
        self.session = nil
        session.recorder.stop()
        let endedAt = Date()
        Task { @MainActor in
            let started = Date()
            let audio = session.recorder.stats.reduce(into: [String: [Int]]()) { $0[$1.key.rawValue] = [$1.value.frames, $1.value.loud] }
            async let mine = session.me.finish()
            async let theirs = session.them.finish()
            let transcript = Transcript(app: call.app, startedAt: call.startedAt, endedAt: endedAt, utterances: await mine + theirs)
            log.append(Record(at: Date(), event: "transcribed", app: call.app, detail: "\(transcript.utterances.count) lines", audio: audio, seconds: Date().timeIntervalSince(started)))
            onEvent?(.heard(call, endedAt: endedAt, transcript: transcript.text))
        }
    }

    func simulate(pid: pid_t, app: String, seconds: Double) {
        started(CallWatcher.Call(startedAt: Date(), pid: pid, app: app))
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.ended() }
    }
}
