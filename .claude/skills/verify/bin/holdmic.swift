import AVFoundation

let engine = AVAudioEngine()
engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: engine.inputNode.outputFormat(forBus: 0)) { _, _ in }
try engine.start()
Thread.sleep(forTimeInterval: Double(CommandLine.arguments[1]) ?? 60)
