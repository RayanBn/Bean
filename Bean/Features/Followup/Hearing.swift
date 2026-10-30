import AVFoundation

struct HearingRecord: Codable {
    let at: Date
    let event: String
    var agent: String? = nil
    var app: String? = nil
    var detail: String? = nil
    var audio: [String: [Int]]? = nil
    var seconds: Double? = nil
}

@available(macOS 14.2, *)
final class CallHearing {
    static let ability = "hear calls"
    static let detailsLimit = 12000

    private final class Session {
        let call: CallWatcher.Call
        let agent: UUID
        let language: String
        let recorder = CallRecorder()
        let me: ChannelTranscriber
        let them: ChannelTranscriber

        init(call: CallWatcher.Call, agent: UUID, language: String, me: ChannelTranscriber, them: ChannelTranscriber) {
            self.call = call
            self.agent = agent
            self.language = language
            self.me = me
            self.them = them
        }
    }

    private let store: AgentStore
    private let worker: AgentWorker
    private let log = JSONLog(name: "hearing")
    private let watcher = CallWatcher()
    private var session: Session?
    private var waiting: UUID?
    private var fakeCall: CallWatcher.Call?

    init(store: AgentStore, worker: AgentWorker) {
        self.store = store
        self.worker = worker
    }

    func start() {
        watcher.onStart = { [weak self] call in self?.callStarted(call) }
        watcher.onEnd = { [weak self] call in self?.callEnded(call) }
        worker.onCallConsent = { [weak self] id, allowed in self?.answered(id, allowed: allowed) }
        watcher.start()
    }

    private var current: CallWatcher.Call? { watcher.current ?? fakeCall }

    private func callStarted(_ call: CallWatcher.Call) {
        log.append(HearingRecord(at: Date(), event: "callStarted", app: call.app))
        guard !BeanSettings.shared.effectivePaused, let agent = agent(for: call) else { return }
        let folder = AgentFolder(agent, in: store)
        if let ability = folder.abilities.first(where: { $0.id == Self.ability }) {
            if ability.allowed {
                Task { @MainActor in await record(call, agent: agent) }
            } else {
                log.append(HearingRecord(at: Date(), event: "notListening", agent: agent.name, app: call.app, detail: "turned off"))
            }
            return
        }
        waiting = agent.id
        log.append(HearingRecord(at: Date(), event: "askedConsent", agent: agent.name, app: call.app))
        worker.askCallConsent(agent, app: call.app ?? agent.attachment?.appName ?? "this app")
    }

    private func answered(_ id: UUID, allowed: Bool) {
        guard waiting == id || session == nil, let agent = store.agents.first(where: { $0.id == id }) else { return }
        waiting = nil
        log.append(HearingRecord(at: Date(), event: allowed ? "consented" : "declined", agent: agent.name))
        if allowed, let call = current { Task { @MainActor in await record(call, agent: agent) } }
    }

    private func agent(for call: CallWatcher.Call) -> Agent? {
        let chain = Set(CallWatcher.parents(of: call.pid))
        let candidates = store.agents.filter { agent in
            guard let attachment = agent.attachment, chain.contains(attachment.pid) else { return false }
            return OffLimits.match("\(attachment.appName) \(attachment.bundleId) \(attachment.windowTitle ?? "")") == nil
        }
        return candidates.first { AgentFolder($0, in: store).abilities.first { $0.id == Self.ability }?.allowed == true } ?? candidates.first
    }

    @MainActor
    private func record(_ call: CallWatcher.Call, agent: Agent) async {
        guard current?.startedAt == call.startedAt, session == nil else { return }
        let app = call.app ?? "this app"
        func problem(_ text: String, pane: String?) {
            log.append(HearingRecord(at: Date(), event: "recordFailed", agent: agent.name, app: call.app, detail: text))
            worker.raise(AgentNeed(kind: .stuck, question: text, settingsPane: pane), agent: agent)
        }
        if ProcessInfo.processInfo.environment["BEAN_MIC_FILE"] == nil, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            return problem("I cannot hear this call: allow the microphone for Bean in System Settings.", pane: "Privacy_Microphone")
        }
        guard #available(macOS 26, *) else { return problem("Listening to calls needs macOS 26 or later.", pane: nil) }
        do {
            let locale = await Transcribers.callLocale()
            let session = Session(call: call, agent: agent.id, language: locale.identifier,
                                  me: try await AppleTranscriber(channel: .me, locale: locale),
                                  them: try await AppleTranscriber(channel: .them, locale: locale))
            session.recorder.onBuffer = { [weak session] channel, buffer in
                (channel == .me ? session?.me : session?.them)?.append(buffer)
            }
            session.recorder.onProblem = { [weak self] text in
                self?.log.append(HearingRecord(at: Date(), event: "audioProblem", agent: agent.name, app: call.app, detail: text))
            }
            try session.recorder.start()
            self.session = session
            worker.setListening(agent, app: app, true)
            log.append(HearingRecord(at: Date(), event: "recording", agent: agent.name, app: call.app, detail: "on this Mac, \(locale.identifier), system audio allowed: \(CallRecorder.systemAudioAllowed.map(String.init) ?? "unknown")"))
            if current == nil { callEnded(call) }
        } catch {
            problem("I cannot listen to this call: \(error.localizedDescription)", pane: nil)
        }
    }

    private func callEnded(_ call: CallWatcher.Call) {
        log.append(HearingRecord(at: Date(), event: "callEnded", app: call.app))
        if let waiting, let agent = store.agents.first(where: { $0.id == waiting }) {
            self.waiting = nil
            worker.dropCallConsent(agent)
        }
        guard let session, session.call.startedAt == call.startedAt, let agent = store.agents.first(where: { $0.id == session.agent }) else { return }
        self.session = nil
        session.recorder.stop()
        let app = call.app ?? "this app"
        worker.setListening(agent, app: app, false)
        let endedAt = Date()
        Task { @MainActor in
            let started = Date()
            let audio = session.recorder.stats.reduce(into: [String: [Int]]()) { $0[$1.key.rawValue] = [$1.value.frames, $1.value.loud] }
            async let mine = session.me.finish()
            async let theirs = session.them.finish()
            let transcript = Transcript(app: call.app, startedAt: call.startedAt, endedAt: endedAt, utterances: await mine + theirs)
            log.append(HearingRecord(at: Date(), event: "transcribed", agent: agent.name, app: call.app, detail: "\(transcript.utterances.count) lines, \(session.language)", audio: audio, seconds: Date().timeIntervalSince(started)))
            await worker.callEnded(agent, app: app, startedAt: call.startedAt, endedAt: endedAt, transcript: transcript.text, audioNote: audio)
        }
    }

    func simulate(pid: pid_t, app: String, seconds: Double) {
        let call = CallWatcher.Call(startedAt: Date(), pid: pid, app: app)
        fakeCall = call
        callStarted(call)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.fakeCall = nil
            self?.callEnded(call)
        }
    }
}
