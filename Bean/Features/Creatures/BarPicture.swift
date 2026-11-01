import AppKit
import ScreenCaptureKit

// A picture of the window alone, without what covers it and without Bean's own panels. Accessibility says what a bar holds, and this says what it shows, where the two disagree.
struct BarPicture {
    struct Glyph {
        let centerY: CGFloat
        let extent: CGFloat
        let ink: NSColor
    }

    private let pixels: [UInt8]
    private let width: Int
    private let height: Int
    private let scale: CGFloat

    static func capture(_ window: ForeignWindow) async -> BarPicture? {
        guard SpaceWindows.picturesWork, OffLimits.match("\(window.appName) \(window.title ?? "")") == nil,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let found = content.windows.first(where: { Int($0.windowID) == window.barWindow ?? window.number }) else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(found.frame.width * 2)
        configuration.height = Int(found.frame.height * 2)
        guard let shot = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: found), configuration: configuration) else { return nil }
        return BarPicture(shot)
    }

    private init?(_ image: CGImage) {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        pixels = data
        width = w
        height = h
        scale = 2
    }

    private func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
    }

    private func range(_ rect: CGRect) -> (x: Range<Int>, y: Range<Int>)? {
        guard !rect.isNull, !rect.isEmpty else { return nil }
        let x0 = max(0, Int(rect.minX * scale)), x1 = min(width, Int(rect.maxX * scale))
        let y0 = max(0, Int(rect.minY * scale)), y1 = min(height, Int(rect.maxY * scale))
        return x0 < x1 && y0 < y1 ? (x0..<x1, y0..<y1) : nil
    }

    // The rect is in points from the window's top left. Empty means one flat tone, or a gentle gradient.
    func isEmpty(_ rect: CGRect) -> Bool {
        guard let area = range(rect) else { return false }
        var low = (255, 255, 255), high = (0, 0, 0)
        for y in area.y {
            for x in area.x {
                let p = pixel(x, y)
                low = (min(low.0, p.0), min(low.1, p.1), min(low.2, p.2))
                high = (max(high.0, p.0), max(high.1, p.1), max(high.2, p.2))
            }
        }
        return max(high.0 - low.0, high.1 - low.1, high.2 - low.2) < 36
    }

    // The icon in a button. A label below it is a separate band of rows, so the first solid band is the icon.
    func glyph(in rect: CGRect) -> Glyph? {
        guard let area = range(rect.insetBy(dx: 3, dy: 3)) else { return nil }
        var edge: [(Int, Int, Int)] = []
        for x in area.x { edge.append(pixel(x, area.y.lowerBound)); edge.append(pixel(x, area.y.upperBound - 1)) }
        for y in area.y { edge.append(pixel(area.x.lowerBound, y)); edge.append(pixel(area.x.upperBound - 1, y)) }
        let middle = edge.count / 2
        let back = (edge.map(\.0).sorted()[middle], edge.map(\.1).sorted()[middle], edge.map(\.2).sorted()[middle])
        func distance(_ p: (Int, Int, Int)) -> Int { abs(p.0 - back.0) + abs(p.1 - back.1) + abs(p.2 - back.2) }
        var marked = [Int](repeating: 0, count: area.y.count), strongest = 0, left = area.x.upperBound, right = area.x.lowerBound
        for y in area.y {
            for x in area.x {
                let d = distance(pixel(x, y))
                if d > 75 {
                    marked[y - area.y.lowerBound] += 1
                    left = min(left, x)
                    right = max(right, x)
                }
                strongest = max(strongest, d)
            }
        }
        var bands: [Range<Int>] = [], start: Int?
        for (i, count) in marked.enumerated() {
            if count > 0, start == nil { start = i }
            if count == 0, let begun = start { bands.append(begun..<i); start = nil }
        }
        if let begun = start { bands.append(begun..<marked.count) }
        guard let band = bands.first(where: { CGFloat($0.count) / scale >= 8 }) ?? bands.max(by: { $0.count < $1.count }) else { return nil }
        var sum = (0, 0, 0), count = 0
        for i in band {
            for x in area.x {
                let p = pixel(x, area.y.lowerBound + i)
                if distance(p) * 10 >= strongest * 7 { sum = (sum.0 + p.0, sum.1 + p.1, sum.2 + p.2); count += 1 }
            }
        }
        guard count > 0 else { return nil }
        // An icon can be dim for being disabled. The agent keeps enough contrast to be seen.
        let shade = { (r: Int, g: Int, b: Int) in Double(r + g + b) / 765 }
        let tone = shade(sum.0 / count, sum.1 / count, sum.2 / count), behind = shade(back.0, back.1, back.2)
        let lift = CGFloat(abs(tone - behind) >= 0.4 ? 0 : (behind < 0.5 ? behind + 0.4 : behind - 0.4) - tone)
        func channel(_ total: Int) -> CGFloat { min(max(CGFloat(total) / CGFloat(count) / 255 + lift, 0), 1) }
        let top = CGFloat(area.y.lowerBound + band.lowerBound) / scale, tall = CGFloat(band.count) / scale
        return Glyph(centerY: top + tall / 2, extent: max(tall, CGFloat(right - left + 1) / scale),
                     ink: NSColor(srgbRed: channel(sum.0), green: channel(sum.1), blue: channel(sum.2), alpha: 1))
    }
}
