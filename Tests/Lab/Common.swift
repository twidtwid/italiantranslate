import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Shared by the lab tools: loading frames, writing results, and drawing boxes on frames.

func loadImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.8) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    CGImageDestinationFinalize(destination)
}

func writeJSON(_ value: Any, to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
}

/// A normalized, top-left-origin rect as [x, y, width, height] rounded to 4 places.
func numbers(_ rect: CGRect) -> [Double] {
    [rect.minX, rect.minY, rect.width, rect.height].map { (Double($0) * 10_000).rounded() / 10_000 }
}

func frames(in directory: URL) -> [URL] {
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return files.filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// The frame, faded, with boxes and labels drawn over it. Boxes are normalized with the origin
/// at the top left, like the app's.
final class Sketch {
    let context: CGContext
    let width: CGFloat
    let height: CGFloat

    init?(image: CGImage) {
        width = CGFloat(image.width)
        height = CGFloat(image.height)
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        self.context = context
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.35))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func pixels(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * width, y: (1 - rect.maxY) * height, width: rect.width * width, height: rect.height * height)
    }

    func box(_ rect: CGRect, color: CGColor, lineWidth: CGFloat = 2, fill: CGColor? = nil) {
        let area = pixels(rect)
        if let fill {
            context.setFillColor(fill)
            context.fill(area)
        }
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth)
        context.stroke(area)
    }

    /// Text just above the top-left corner of `rect` (inside it when there's no room above).
    func label(_ text: String, at rect: CGRect, color: CGColor, size: CGFloat = 22) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let area = pixels(rect)
        let bounds = CTLineGetImageBounds(line, context)
        var origin = CGPoint(x: area.minX, y: area.maxY + 3)
        if origin.y + size > height { origin.y = area.maxY - size }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
        context.fill(CGRect(x: origin.x - 2, y: origin.y - 3, width: bounds.width + 6, height: size + 2))
        context.textPosition = origin
        CTLineDraw(line, context)
    }

    func image() -> CGImage? { context.makeImage() }
}

enum Palette {
    static let italian = CGColor(red: 0.1, green: 0.6, blue: 0.2, alpha: 1)
    static let foreign = CGColor(red: 0.15, green: 0.35, blue: 0.95, alpha: 1)
    static let unknown = CGColor(gray: 0.45, alpha: 1)
    static let block = CGColor(red: 0.95, green: 0.45, blue: 0.05, alpha: 1)
    static let heading = CGColor(red: 0.75, green: 0.1, blue: 0.6, alpha: 1)
    static let price = CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1)
    static let table = CGColor(red: 0.0, green: 0.55, blue: 0.6, alpha: 1)
}
