import AVFoundation
import Speech

protocol ChannelTranscriber: AnyObject {
    func append(_ buffer: AVAudioPCMBuffer)
    func finish() async -> [Utterance]
}

enum Transcribers {
    static func make(_ kind: BeanSettings.Transcriber, channel: Channel, locale: Locale) async throws -> ChannelTranscriber {
        switch kind {
        case .metaVoice:
            guard let key = APIKeyStore.current(for: .meta).key else { throw ModelClient.SparkError.noKey }
            return MetaVoiceTranscriber(channel: channel, key: key)
        case .apple:
            guard #available(macOS 26, *) else { throw TranscriberError.needsMacOS26 }
            return try await AppleTranscriber(channel: channel, locale: locale)
        }
    }

    static func callLocale() async -> Locale {
        if let forced = ProcessInfo.processInfo.environment["BEAN_CALL_LOCALE"] { return Locale(identifier: forced) }
        if #available(macOS 26, *) {
            for identifier in Locale.preferredLanguages {
                if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) { return locale }
            }
        }
        return Locale(identifier: "en_US")
    }

    enum TranscriberError: LocalizedError {
        case needsMacOS26, noFormat
        var errorDescription: String? {
            switch self {
            case .needsMacOS26: return "transcription on this Mac needs macOS 26, pick Meta Muse Voice in Settings"
            case .noFormat: return "no audio format for the transcriber"
            }
        }
    }
}

final class AudioResampler {
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?

    init(to target: AVAudioFormat) {
        self.target = target
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == target { return buffer }
        if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: target) }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}

@available(macOS 26, *)
final class AppleTranscriber: ChannelTranscriber {
    private let channel: Channel
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let resampler: AudioResampler
    private let results: Task<[Utterance], Never>

    init(channel: Channel, locale: Locale) async throws {
        self.channel = channel
        transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await install.downloadAndInstall() }
        analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw Transcribers.TranscriberError.noFormat }
        resampler = AudioResampler(to: format)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        let transcriber = transcriber
        results = Task {
            var lines: [Utterance] = []
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    lines.append(Utterance(channel: channel, start: result.range.start.seconds, text: text))
                }
            } catch {}
            return lines
        }
        try await analyzer.start(inputSequence: stream)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = resampler.convert(buffer) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async -> [Utterance] {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        return await results.value
    }
}

final class MetaVoiceTranscriber: ChannelTranscriber {
    private static let endpoint = URL(string: "wss://api.meta.ai/v1/asr/realtime")!
    private static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!

    private let channel: Channel
    private let socket: URLSessionWebSocketTask
    private let resampler = AudioResampler(to: MetaVoiceTranscriber.format)
    private let lock = NSLock()
    private var lines: [Utterance] = []
    private var speaker: String?
    private var closed = false
    private var reader: Task<Void, Never>?

    init(channel: Channel, key: String) {
        self.channel = channel
        socket = URLSession.shared.webSocketTask(with: Self.endpoint)
        socket.resume()
        let mode = channel == .them ? "DIARIZATION" : "ENDPOINTING"
        let hello = #"{"authorization":{"accessToken":"Bearer \#(key)"},"audioEncoding":"PCM_24KHZ","model":"muse-voice-transcribe-1.0","mode":"\#(mode)"}"#
        socket.send(.string(hello)) { _ in }
        reader = Task { [weak self] in await self?.read() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = resampler.convert(buffer), let samples = converted.int16ChannelData?[0] else { return }
        socket.send(.data(Data(bytes: samples, count: Int(converted.frameLength) * 2))) { _ in }
    }

    func finish() async -> [Utterance] {
        try? await socket.send(.string(#"{"type":"endStream"}"#))
        for _ in 0..<80 where !lock.withLock({ closed }) { try? await Task.sleep(nanoseconds: 100_000_000) }
        socket.cancel(with: .normalClosure, reason: nil)
        reader?.cancel()
        return lock.withLock { lines }
    }

    private func read() async {
        while let message = try? await socket.receive() {
            guard case let .string(text) = message,
                  let event = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "speaker": lock.withLock { speaker = event["label"] as? String }
            case "speechComplete":
                let transcript = (event["transcript"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let endMs = event["audioProcessedMs"] as? Double ?? 0
                let words = Double(transcript.split(separator: " ").count)
                guard !transcript.isEmpty else { continue }
                lock.withLock {
                    lines.append(Utterance(channel: channel, speaker: channel == .them ? speaker : nil, start: max(0, endMs / 1000 - words * 0.4), text: transcript))
                }
            default: break
            }
        }
        lock.withLock { closed = true }
    }
}
