import AVFoundation

struct HeardCall: Codable {
    let app: String?
    let startedAt: Date
    let endedAt: Date
    let language: String
    let transcript: String
}

struct HearingRecord: Codable {
    let at: Date
    let event: String
    var app: String? = nil
    var detail: String? = nil
    var call: HeardCall? = nil
    var audio: [String: [Int]]? = nil
    var seconds: Double? = nil
}

extension Trigger.Kind {
    static let callEnded: Self = "callEnded"
}

@available(macOS 14.2, *)
final class Hearing {
    static let consentTimeout: TimeInterval = 30
    static let detailsLimit = 12000

    var isRecording: Bool { session != nil }

    private let notch: NotchController
    private let log: JSONLog
    private let settings = BeanSettings.shared
    private let watcher = CallWatcher()
    private var session: Session?

    private final class Session {
        let call: CallWatcher.Call
        let language: String
        let recorder = CallRecorder()
        let me: ChannelTranscriber
        let them: ChannelTranscriber

        init(call: CallWatcher.Call, language: String, me: ChannelTranscriber, them: ChannelTranscriber) {
            self.call = call
            self.language = language
            self.me = me
            self.them = them
        }
    }

    init(notch: NotchController, log: JSONLog) {
        self.notch = notch
        self.log = log
    }

    func start() {
        watcher.onStart = { [weak self] call in self?.callStarted(call) }
        watcher.onEnd = { [weak self] call in self?.callEnded(call) }
        watcher.start()
    }

    private func callStarted(_ call: CallWatcher.Call) {
        log.append(HearingRecord(at: Date(), event: "callStarted", app: call.app))
        guard settings.effectiveCallNotes == .ask, !settings.effectivePaused else { return }
        var answered = false
        let answer = { [weak self] (takeNotes: Bool) in
            guard let self, !answered else { return }
            answered = true
            notch.rest()
            log.append(HearingRecord(at: Date(), event: takeNotes ? "consented" : "declined", app: call.app))
            if takeNotes { Task { @MainActor in await self.record(call) } }
        }
        notch.show(NotchMessage(text: "\(call.app.map { "Call in \($0)." } ?? "A call started.") Take notes so I can handle what follows? Tell the others first.", choices: [
            NotchChoice(label: "Not this call", isPrimary: false) { answer(false) },
            NotchChoice(label: "Take notes", isPrimary: true) { answer(true) },
        ]))
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.consentTimeout) { [weak self] in
            guard !answered, self?.watcher.current?.startedAt == call.startedAt else { return }
            answer(false)
        }
    }

    @MainActor
    private func record(_ call: CallWatcher.Call) async {
        guard watcher.current?.startedAt == call.startedAt, session == nil else { return }
        if ProcessInfo.processInfo.environment["BEAN_MIC_FILE"] == nil, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            log.append(HearingRecord(at: Date(), event: "recordFailed", app: call.app, detail: "microphone not allowed"))
            notch.show(NotchMessage(text: "I can't hear you: allow the microphone for Bean in System Settings.", choices: [
                NotchChoice(label: "OK", isPrimary: true) { [weak self] in self?.notch.rest() },
            ]))
            return
        }
        do {
            let locale = await Transcribers.callLocale()
            let kind = settings.effectiveTranscriber
            let session = Session(
                call: call,
                language: locale.identifier,
                me: try await Transcribers.make(kind, channel: .me, locale: locale),
                them: try await Transcribers.make(kind, channel: .them, locale: locale)
            )
            session.recorder.onBuffer = { [weak session] channel, buffer in
                (channel == .me ? session?.me : session?.them)?.append(buffer)
            }
            session.recorder.onProblem = { [weak self] problem in
                self?.log.append(HearingRecord(at: Date(), event: "audioProblem", app: call.app, detail: problem))
            }
            try session.recorder.start()
            self.session = session
            notch.recording(true)
            log.append(HearingRecord(at: Date(), event: "recording", app: call.app, detail: "\(kind.rawValue) \(locale.identifier), system audio allowed: \(CallRecorder.systemAudioAllowed.map(String.init) ?? "unknown")"))
            if watcher.current == nil { callEnded(call) }
        } catch {
            log.append(HearingRecord(at: Date(), event: "recordFailed", app: call.app, detail: error.localizedDescription))
            notch.show(NotchMessage(text: "I can't take notes: \(error.localizedDescription)", choices: [
                NotchChoice(label: "OK", isPrimary: true) { [weak self] in self?.notch.rest() },
            ]))
        }
    }

    private func callEnded(_ call: CallWatcher.Call) {
        log.append(HearingRecord(at: Date(), event: "callEnded", app: call.app))
        guard let session, session.call.startedAt == call.startedAt else { return }
        self.session = nil
        session.recorder.stop()
        notch.recording(false)
        let endedAt = Date()
        Task { @MainActor in
            let started = Date()
            let audio = session.recorder.stats.reduce(into: [String: [Int]]()) { $0[$1.key.rawValue] = [$1.value.frames, $1.value.loud] }
            async let mine = session.me.finish()
            async let theirs = session.them.finish()
            let transcript = Transcript(app: call.app, startedAt: call.startedAt, endedAt: endedAt, utterances: await mine + theirs)
            let heard = HeardCall(app: call.app, startedAt: call.startedAt, endedAt: endedAt, language: session.language, transcript: transcript.text)
            log.append(HearingRecord(at: Date(), event: "transcribed", app: call.app, call: heard, audio: audio, seconds: Date().timeIntervalSince(started)))
            guard !transcript.isEmpty else { return }
            Events.post(Self.trigger(for: heard))
        }
    }

    static func trigger(for call: HeardCall) -> Trigger {
        let minutes = max(1, Int(call.endedAt.timeIntervalSince(call.startedAt) / 60 + 0.5))
        let header = "A call just ended (\(call.app ?? "unknown app"), \(minutes) min, \(call.language)). The user said yes to taking notes so Bean can handle what follows. Lines tagged me are the user, them are the other participants."
        var transcript = call.transcript
        if transcript.count > detailsLimit { transcript = "…" + transcript.suffix(detailsLimit) }
        return Trigger(at: call.endedAt, kind: .callEnded, app: call.app, bundleId: nil, windowTitle: nil, idleSeconds: IdleClock.seconds(),
                       errorLine: nil, errorSeconds: nil, terminalTail: nil, details: header + "\n" + transcript, notice: "Call ended", gate: .always, source: "followup")
    }
}
