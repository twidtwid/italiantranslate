import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Colors for a translation patch, taken from the still itself: the paper around the text and the
/// ink of the text. The English then looks printed on the page instead of stuck on in black bars.
struct InkSampler {
    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double
        var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
    }

    struct Colors: Equatable {
        var paper: RGB
        var ink: RGB
    }

    let width: Int
    let height: Int
    private let rgba: [UInt8] // row-major, top row first, 4 bytes per pixel

    init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    init?(image: CGImage) {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, rgba: bytes)
    }

    /// `box` is normalized, origin top-left.
    func colors(for box: CGRect) -> Colors {
        let x0 = clamp(Int(box.minX * Double(width)), width), x1 = clamp(Int((box.maxX * Double(width)).rounded(.up)), width)
        let y0 = clamp(Int(box.minY * Double(height)), height), y1 = clamp(Int((box.maxY * Double(height)).rounded(.up)), height)
        let pad = max(2, (y1 - y0) / 3)
        let ox0 = clamp(x0 - pad, width), ox1 = clamp(x1 + pad, width)
        let oy0 = clamp(y0 - pad, height), oy1 = clamp(y1 + pad, height)
        let step = max(1, Int(Double((ox1 - ox0) * (oy1 - oy0)) / 2_000).squareRootCeil)

        var ring: [RGB] = [], inside: [RGB] = []
        var y = oy0
        while y < oy1 {
            var x = ox0
            while x < ox1 {
                let offset = (y * width + x) * 4
                let pixel = RGB(red: Double(rgba[offset]) / 255, green: Double(rgba[offset + 1]) / 255, blue: Double(rgba[offset + 2]) / 255)
                if x >= x0, x < x1, y >= y0, y < y1 { inside.append(pixel) } else { ring.append(pixel) }
                x += step
            }
            y += step
        }

        let paper = Self.median(ring.isEmpty ? inside : ring) ?? RGB(red: 0, green: 0, blue: 0)
        // Ink: the pixels inside that differ most from the paper (the strokes of the letters).
        let strokes = inside.sorted { abs($0.luminance - paper.luminance) > abs($1.luminance - paper.luminance) }
            .prefix(max(3, inside.count / 10))
        var ink = Self.mean(Array(strokes)) ?? paper
        if abs(ink.luminance - paper.luminance) < 0.25 { // too faint to read: plain black or white
            ink = paper.luminance > 0.5 ? RGB(red: 0.08, green: 0.08, blue: 0.08) : RGB(red: 0.97, green: 0.97, blue: 0.97)
        }
        return Colors(paper: paper, ink: ink)
    }

    private func clamp(_ value: Int, _ limit: Int) -> Int { min(max(value, 0), limit) }

    private static func median(_ pixels: [RGB]) -> RGB? {
        guard !pixels.isEmpty else { return nil }
        func mid(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        return RGB(red: mid(pixels.map(\.red)), green: mid(pixels.map(\.green)), blue: mid(pixels.map(\.blue)))
    }

    private static func mean(_ pixels: [RGB]) -> RGB? {
        guard !pixels.isEmpty else { return nil }
        let n = Double(pixels.count)
        return RGB(red: pixels.map(\.red).reduce(0, +) / n, green: pixels.map(\.green).reduce(0, +) / n, blue: pixels.map(\.blue).reduce(0, +) / n)
    }
}

private extension Int {
    var squareRootCeil: Int { Int(Double(self).squareRoot().rounded(.up)) }
}
