import AppKit
import AVFoundation
import ScreenCaptureKit

final class Shields {
    private var panels: [String: NSPanel] = [:]
    private var raised = false

    var count: Int { panels.count }

    func prepare(_ rects: [String: CGRect]) async {
        let keys = Array(rects.keys)
        let snapshots = await Self.snapshots(of: keys.map { rects[$0]! })
        await MainActor.run {
            for key in Array(panels.keys) where rects[key] == nil { panels.removeValue(forKey: key)?.orderOut(nil) }
            for (index, key) in keys.enumerated() {
                let panel = panels[key] ?? Self.panel()
                panels[key] = panel
                Self.fill(panel, rect: rects[key]!, snapshot: snapshots[index])
                if raised { panel.orderFrontRegardless() }
            }
        }
    }

    func drop(_ keys: [String]) {
        for key in keys { panels.removeValue(forKey: key)?.orderOut(nil) }
    }

    func raise() {
        raised = true
        panels.values.forEach { $0.orderFrontRegardless() }
    }

    func lower() {
        raised = false
        panels.values.forEach { $0.orderOut(nil) }
    }

    func move(by delta: CGPoint, keys: [String]) {
        for key in keys {
            guard let panel = panels[key] else { continue }
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX + delta.x, y: panel.frame.minY - delta.y))
        }
    }

    private static func panel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = true
        panel.backgroundColor = NSColor(white: 0.13, alpha: 1)
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView()
        view.wantsLayer = true
        let chip = CATextLayer()
        chip.string = "hidden by Bean"
        chip.fontSize = 11
        chip.foregroundColor = NSColor(white: 0.6, alpha: 1).cgColor
        chip.alignmentMode = .center
        chip.contentsScale = 2
        let screen = AVSampleBufferDisplayLayer()
        screen.preventsCapture = true
        screen.videoGravity = .resize
        view.layer?.addSublayer(chip)
        view.layer?.addSublayer(screen)
        panel.contentView = view
        return panel
    }

    private static func fill(_ panel: NSPanel, rect: CGRect, snapshot: CGImage?) {
        let primary = NSScreen.screens.first?.frame.height ?? 0
        panel.setFrame(NSRect(x: rect.minX, y: primary - rect.maxY, width: rect.width, height: rect.height), display: false)
        guard let layers = panel.contentView?.layer?.sublayers, layers.count == 2, let screen = layers[1] as? AVSampleBufferDisplayLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = CGRect(origin: .zero, size: rect.size)
        layers[0].frame = CGRect(x: 0, y: (rect.height - 14) / 2, width: rect.width, height: 14)
        layers[0].isHidden = rect.width < 90
        screen.frame = bounds
        CATransaction.commit()
        if let snapshot, let buffer = sampleBuffer(snapshot) {
            screen.sampleBufferRenderer.flush()
            screen.sampleBufferRenderer.enqueue(buffer)
        }
    }

    private static func snapshots(of rects: [CGRect]) async -> [CGImage?] {
        var result = [CGImage?](repeating: nil, count: rects.count)
        guard !rects.isEmpty, let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return result }
        let own = content.windows.filter { $0.owningApplication?.processID == getpid() }
        for display in content.displays {
            let bounds = CGDisplayBounds(display.displayID)
            let inside = rects.indices.filter { bounds.intersects(rects[$0]) }
            guard !inside.isEmpty else { continue }
            let config = SCStreamConfiguration()
            let scale = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID }?.backingScaleFactor ?? 2
            config.width = Int(bounds.width * scale)
            config.height = Int(bounds.height * scale)
            config.showsCursor = false
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: own), configuration: config) else { continue }
            let factor = CGFloat(image.width) / bounds.width
            for index in inside {
                let local = rects[index].offsetBy(dx: -bounds.minX, dy: -bounds.minY)
                let pixels = CGRect(x: local.minX * factor, y: local.minY * factor, width: local.width * factor, height: local.height * factor).integral
                result[index] = image.cropping(to: pixels)
            }
        }
        return result
    }

    private static func sampleBuffer(_ image: CGImage) -> CMSampleBuffer? {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
        guard let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &buffer)
        if let attachments = buffer.flatMap({ CMSampleBufferGetSampleAttachmentsArray($0, createIfNecessary: true) }) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return buffer
    }
}
