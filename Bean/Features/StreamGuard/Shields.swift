import AppKit
import AVFoundation
import ScreenCaptureKit

struct ShieldSpot: Equatable {
    let rect: CGRect
    let window: CGWindowID
    let windowFrame: CGRect
}

final class Shields {
    private final class Shield {
        let panel: NSPanel
        var spot: ShieldSpot
        var filled = false
        init(panel: NSPanel, spot: ShieldSpot) { self.panel = panel; self.spot = spot }
    }

    private var shields: [String: Shield] = [:]
    private var raised = false

    var count: Int { shields.count }
    private(set) var refilled = 0

    func prepare(_ spots: [String: ShieldSpot]) async {
        let stale = await MainActor.run { () -> [String: ShieldSpot] in
            for key in Array(shields.keys) where spots[key] == nil { shields.removeValue(forKey: key)?.panel.orderOut(nil) }
            var stale: [String: ShieldSpot] = [:]
            for (key, spot) in spots {
                if let shield = shields[key], shield.spot == spot, shield.filled { continue }
                let shield = shields[key] ?? Shield(panel: Self.panel(), spot: spot)
                shield.spot = spot
                shields[key] = shield
                Self.place(shield.panel, rect: spot.rect)
                stale[key] = spot
            }
            layout()
            refilled = stale.count
            return stale
        }
        guard !stale.isEmpty else { return }
        let images = await Self.snapshots(of: stale)
        await MainActor.run {
            for (key, image) in images {
                guard let shield = shields[key], shield.spot == stale[key], let buffer = Self.sampleBuffer(image) else { continue }
                Self.layer(of: shield.panel)?.sampleBufferRenderer.enqueue(buffer)
                shield.filled = true
            }
        }
    }

    func drop(_ keys: [String]) {
        for key in keys { shields.removeValue(forKey: key)?.panel.orderOut(nil) }
    }

    func raise() {
        raised = true
        layout()
    }

    func lower() {
        raised = false
        shields.values.forEach { $0.panel.orderOut(nil) }
    }

    func move(window: CGWindowID, by delta: CGPoint) {
        for shield in shields.values where shield.spot.window == window {
            let spot = shield.spot
            shield.spot = ShieldSpot(rect: spot.rect.offsetBy(dx: delta.x, dy: delta.y), window: spot.window, windowFrame: spot.windowFrame.offsetBy(dx: delta.x, dy: delta.y))
            Self.place(shield.panel, rect: shield.spot.rect)
        }
    }

    func layout() {
        guard raised else { return }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let own = getpid()
        let windows: [(id: CGWindowID, frame: CGRect)] = list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) != own, let layer = info[kCGWindowLayer as String] as? Int, (0...3).contains(layer),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.1, let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return (id, frame)
        }
        for shield in shields.values {
            let center = CGPoint(x: shield.spot.rect.midX, y: shield.spot.rect.midY)
            guard let index = windows.firstIndex(where: { $0.id == shield.spot.window }) else { shield.panel.orderOut(nil); continue }
            let covered = windows[..<index].contains { $0.frame.contains(center) }
            if covered { shield.panel.orderOut(nil) } else if !shield.panel.isVisible { shield.panel.orderFrontRegardless() }
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

    private static func layer(of panel: NSPanel) -> AVSampleBufferDisplayLayer? {
        panel.contentView?.layer?.sublayers?.compactMap { $0 as? AVSampleBufferDisplayLayer }.first
    }

    private static func place(_ panel: NSPanel, rect: CGRect) {
        let primary = NSScreen.screens.first?.frame.height ?? 0
        panel.setFrame(NSRect(x: rect.minX, y: primary - rect.maxY, width: rect.width, height: rect.height), display: false)
        guard let layers = panel.contentView?.layer?.sublayers, layers.count == 2 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layers[0].frame = CGRect(x: 0, y: (rect.height - 14) / 2, width: rect.width, height: 14)
        layers[0].isHidden = rect.width < 90
        layers[1].frame = CGRect(origin: .zero, size: rect.size)
        CATransaction.commit()
    }

    private static func snapshots(of spots: [String: ShieldSpot]) async -> [String: CGImage] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [:] }
        var result: [String: CGImage] = [:]
        for (window, group) in Dictionary(grouping: spots, by: { $0.value.window }) {
            guard let scWindow = content.windows.first(where: { $0.windowID == window }), let frame = group.first?.value.windowFrame else { continue }
            let config = SCStreamConfiguration()
            config.width = Int(frame.width * 2)
            config.height = Int(frame.height * 2)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: scWindow), configuration: config) else { continue }
            let factor = CGFloat(image.width) / frame.width
            for (key, spot) in group {
                let local = spot.rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
                let pixels = CGRect(x: local.minX * factor, y: local.minY * factor, width: local.width * factor, height: local.height * factor).integral
                if let crop = image.cropping(to: pixels) { result[key] = crop }
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
