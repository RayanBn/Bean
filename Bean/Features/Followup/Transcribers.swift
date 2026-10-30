import AVFoundation
import Speech

protocol ChannelTranscriber: AnyObject {
    func append(_ buffer: AVAudioPCMBuffer)
    func finish() async -> [Utterance]
}

enum Transcribers {
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
