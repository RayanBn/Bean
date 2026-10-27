import AVFoundation

let args = CommandLine.arguments
let script = try String(contentsOfFile: args[1], encoding: .utf8)
let out = URL(fileURLWithPath: args[2])
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
var tracks: [String: [Float]] = ["me": [], "them": []]
let gap = [Float](repeating: 0, count: 48000 * 6 / 10)

for (index, line) in script.split(separator: "\n").enumerated() {
    let parts = line.split(separator: "|", maxSplits: 2).map { String($0) }
    guard parts.count == 3 else { continue }
    let (who, voice, text) = (parts[0], parts[1], parts[2])
    let aiff = out.appendingPathComponent("line-\(index).aiff")
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-v", voice, "-o", aiff.path, text]
    try say.run()
    say.waitUntilExit()
    let file = try AVAudioFile(forReading: aiff)
    let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: source)
    let converter = AVAudioConverter(from: file.processingFormat, to: format)!
    let target = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(file.length) * 48000 / file.processingFormat.sampleRate) + 64)!
    var fed = false
    converter.convert(to: target, error: nil) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true; status.pointee = .haveData; return source
    }
    let samples = Array(UnsafeBufferPointer(start: target.floatChannelData![0], count: Int(target.frameLength)))
    let speaker = who == "me" ? "me" : "them"
    let other = speaker == "me" ? "them" : "me"
    tracks[speaker]! += samples + gap
    tracks[other]! += [Float](repeating: 0, count: samples.count) + gap
    try? FileManager.default.removeItem(at: aiff)
}

for (name, samples) in tracks {
    let file = try AVAudioFile(forWriting: out.appendingPathComponent("\(name).caf"), settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = buffer.frameCapacity
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buffer)
}
print("fake call: \(Double(tracks["me"]!.count) / 48000) s, me.caf and them.caf in \(out.path)")
