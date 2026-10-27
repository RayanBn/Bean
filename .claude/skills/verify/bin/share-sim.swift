import AppKit
import ScreenCaptureKit
import Vision

let args = CommandLine.arguments
let area = CGRect(x: Double(args[1])!, y: Double(args[2])!, width: Double(args[3])!, height: Double(args[4])!)
let seconds = Double(args[5])!
let out = args[6]
let allowed = Set(args.dropFirst(7).compactMap { pid_t($0) })
func stamp() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }

final class Viewer: NSObject, SCStreamOutput {
    var first: Date?
    var last: CVPixelBuffer?
    var firstPixels: CVPixelBuffer?
    var frames = 0
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixels = buffer.imageBuffer else { return }
        if first == nil { firstPixels = pixels; first = Date(); print("\(stamp()) viewer first frame"); fflush(stdout) }
        frames += 1
        last = pixels
    }
}
let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
let display = content.displays.first { CGDisplayBounds($0.displayID).intersects(area) }!
let bounds = CGDisplayBounds(display.displayID)
let config = SCStreamConfiguration()
config.sourceRect = area.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
config.width = Int(area.width * 2)
config.height = Int(area.height * 2)
config.showsCursor = false
config.pixelFormat = kCVPixelFormatType_32BGRA
config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
let viewer = Viewer()
let others = content.applications.filter { !allowed.contains($0.processID) }
let stream = SCStream(filter: SCContentFilter(display: display, excludingApplications: others, exceptingWindows: []), configuration: config, delegate: nil)
try stream.addStreamOutput(viewer, type: .screen, sampleHandlerQueue: .global())
print("\(stamp()) share-sim start: display capture cropped to \(area), every other app excluded, only pids \(allowed.sorted()) so nothing else on screen is captured")
fflush(stdout)
try await stream.startCapture()
try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
try await stream.stopCapture()
print("\(stamp()) share-sim stop after \(viewer.frames) frames")
guard let pixels = viewer.last, let firstPixels = viewer.firstPixels else { exit(1) }
func read(_ pixels: CVPixelBuffer, _ label: String) throws -> CGImage {
    let image = CIContext().createCGImage(CIImage(cvPixelBuffer: pixels), from: CIImage(cvPixelBuffer: pixels).extent)!
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    print("what the viewer can read in the \(label) frame:")
    for line in request.results ?? [] { print("  " + (line.topCandidates(1).first?.string ?? "")) }
    return image
}
_ = try read(firstPixels, "first")
let image = try read(pixels, "last")
let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: out))
print("saved \(out)")
