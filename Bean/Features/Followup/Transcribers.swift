import AVFoundation
import Speech

protocol ChannelTranscriber: AnyObject {
    func append(_ buffer: AVAudioPCMBuffer)
    func finish() async -> [Utterance]
}

enum Transcribers {
    @available(macOS 26, *)
    static func make(_ channel: Channel) async throws -> ChannelTranscriber {
        let onThisMac = try await LanguageRace(channel: channel, locales: await callLocales())
        guard BeanSettings.shared.effectiveTranscriber == .metaVoice, let key = metaKey else { return onThisMac }
        return WithBackup(MetaVoiceTranscriber(channel: channel, key: key), backup: onThisMac)
    }

    static var metaKey: String? {
        BeanSettings.shared.effectiveProvider == .meta ? APIKeyStore.current(for: .meta).key : nil
    }

    static var sendsSoundToMeta: Bool { BeanSettings.shared.effectiveTranscriber == .metaVoice && metaKey != nil }

    @available(macOS 26, *)
    static func callLocales() async -> [Locale] {
        if let forced = ProcessInfo.processInfo.environment["BEAN_CALL_LOCALE"] { return [Locale(identifier: forced)] }
        var locales: [Locale] = []
        for identifier in Locale.preferredLanguages {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)),
                  !locales.contains(where: { $0.language.languageCode == locale.language.languageCode }) else { continue }
            locales.append(locale)
        }
        return locales.isEmpty ? [Locale(identifier: "en_US")] : Array(locales.prefix(2))
    }

    enum TranscriberError: LocalizedError {
        case needsMacOS26, noFormat
        var errorDescription: String? {
            switch self {
            case .needsMacOS26: return "transcription on this Mac needs macOS 26"
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

final class WithBackup: ChannelTranscriber {
    private let primary: ChannelTranscriber
    private let backup: ChannelTranscriber

    init(_ primary: ChannelTranscriber, backup: ChannelTranscriber) {
        self.primary = primary
        self.backup = backup
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        primary.append(buffer)
        backup.append(buffer)
    }

    func finish() async -> [Utterance] {
        async let first = primary.finish()
        async let second = backup.finish()
        let lines = await first
        let fallback = await second
        return lines.isEmpty ? fallback : lines
    }
}

@available(macOS 26, *)
final class LanguageRace: ChannelTranscriber {
    private let runners: [AppleTranscriber]

    init(channel: Channel, locales: [Locale]) async throws {
        var runners: [AppleTranscriber] = []
        for locale in locales { runners.append(try await AppleTranscriber(channel: channel, locale: locale)) }
        self.runners = runners
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        runners.forEach { $0.append(buffer) }
    }

    func finish() async -> [Utterance] {
        var best: (lines: [Utterance], confidence: Double) = ([], -1)
        for runner in runners {
            let lines = await runner.finish()
            if runner.confidence > best.confidence, !lines.isEmpty { best = (lines, runner.confidence) }
        }
        return best.lines
    }
}

@available(macOS 26, *)
final class AppleTranscriber: ChannelTranscriber {
    private let channel: Channel
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let resampler: AudioResampler
    private let results: Task<(lines: [Utterance], confidence: Double), Never>
    private(set) var confidence = 0.0

    init(channel: Channel, locale: Locale) async throws {
        self.channel = channel
        transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await install.downloadAndInstall() }
        analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw Transcribers.TranscriberError.noFormat }
        resampler = AudioResampler(to: format)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        let transcriber = transcriber
        results = Task {
            var lines: [Utterance] = []
            var total = 0.0, weight = 0.0
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    lines.append(Utterance(channel: channel, start: result.range.start.seconds, text: text))
                    for run in result.text.runs {
                        guard let value = run.transcriptionConfidence else { continue }
                        let size = Double(result.text[run.range].characters.count)
                        total += value * size
                        weight += size
                    }
                }
            } catch {}
            return (lines, weight > 0 ? total / weight : 0)
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
        let done = await results.value
        confidence = done.confidence
        return done.lines
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
        let hello: [String: Any] = ["authorization": ["accessToken": "Bearer \(key)"], "audioEncoding": "PCM_24KHZ", "model": "muse-voice-transcribe-1.0", "mode": channel == .them ? "DIARIZATION" : "ENDPOINTING"]
        if let data = try? JSONSerialization.data(withJSONObject: hello), let text = String(data: data, encoding: .utf8) { socket.send(.string(text)) { _ in } }
        reader = Task { [weak self] in await self?.read() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = resampler.convert(buffer), let samples = converted.int16ChannelData?[0] else { return }
        socket.send(.data(Data(bytes: samples, count: Int(converted.frameLength) * 2))) { _ in }
    }

    func finish() async -> [Utterance] {
        try? await socket.send(.string(#"{"type":"endStream"}"#))
        for _ in 0..<80 where !lock.withLock({ closed }) { try? await Task.sleep(for: .milliseconds(100)) }
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
