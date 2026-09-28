import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// One line of text from OCR. `box` is normalized (0...1) in the upright image, origin top-left.
struct OCRLine: Equatable {
    var text: String
    var box: CGRect
    /// The line's own corners (top left, top right, bottom right, bottom left), same coordinates as
    /// `box`, when OCR reports them: a slanted line's box is taller than its text.
    var corners: [CGPoint] = []
    /// How sure OCR is of the reading, 0...1. Blur costs confidence.
    var confidence: Float = 1
}

/// Reading a capture in overlapping bands, then putting the lines back together. Vision reads at a
/// fixed working resolution, so each band is a closer look than the whole frame.
enum OCRTiles {
    /// `count` full-width bands, top to bottom, overlapping enough that every printed line sits
    /// wholly inside at least one of them.
    static func bands(_ count: Int, overlap: CGFloat = 0.06) -> [CGRect] {
        guard count > 1 else { return [CGRect(x: 0, y: 0, width: 1, height: 1)] }
        let step = 1 / CGFloat(count)
        return (0..<count).map { index in
            let top = max(0, CGFloat(index) * step - overlap / 2)
            let bottom = min(1, CGFloat(index + 1) * step + overlap / 2)
            return CGRect(x: 0, y: top, width: 1, height: bottom - top)
        }
    }

    /// Every line once. Where two readings cover the same spot, the longer one wins: a line cut
    /// short reads shorter. The same text keeps its first box, so a paragraph's lines keep one
    /// geometry. Two different readings of the same length ("alutine. cesce", "glutine, pesce"):
    /// the surer one, else the later, which is a band's closer look.
    static func merge(_ readings: [[OCRLine]]) -> [OCRLine] {
        var kept: [OCRLine] = []
        for reading in readings {
            for line in reading {
                if let index = kept.firstIndex(where: { sameSpot($0, line) }) {
                    if better(line, than: kept[index]) { kept[index] = line }
                } else {
                    kept.append(line)
                }
            }
        }
        return kept
    }

    private static func better(_ line: OCRLine, than other: OCRLine) -> Bool {
        if line.text.count != other.text.count { return line.text.count > other.text.count }
        if line.text == other.text { return false }
        if line.confidence != other.confidence { return line.confidence > other.confidence }
        return true
    }

    /// Two readings of one printed line: they cover the same spot and say much the same. (On a
    /// slanted page the boxes of neighbouring lines overlap too, so the words have to agree.)
    private static func sameSpot(_ a: OCRLine, _ b: OCRLine) -> Bool {
        let overlap = a.box.intersection(b.box)
        guard !overlap.isNull else { return false }
        let smaller = min(a.box.width * a.box.height, b.box.width * b.box.height)
        guard smaller > 0, overlap.width * overlap.height >= 0.5 * smaller else { return false }
        if a.text.contains(b.text) || b.text.contains(a.text) || TextNormalizer.similarity(a.text, b.text) >= 0.75 {
            return true
        }
        // A misread piece of the line ("La rempo elicoidalo che solo a spirato vorso"): on the same
        // line, not the one above or below, and mostly made of the whole line's letters.
        let (piece, whole) = a.text.count <= b.text.count ? (a, b) : (b, a)
        guard piece.text.filter(\.isLetter).count >= 8 else { return false }
        let drift = abs(middle(of: piece, at: piece.box.midX) - middle(of: whole, at: piece.box.midX))
        return drift < 0.5 * max(textHeight(piece), textHeight(whole))
            && TextNormalizer.containment(piece.text, in: whole.text) >= 0.7
    }

    /// Where the middle of a line is at `x`: along its slant when OCR gave its corners.
    private static func middle(of line: OCRLine, at x: CGFloat) -> CGFloat {
        guard line.corners.count == 4 else { return line.box.midY }
        let c = line.corners
        let left = CGPoint(x: (c[0].x + c[3].x) / 2, y: (c[0].y + c[3].y) / 2)
        let right = CGPoint(x: (c[1].x + c[2].x) / 2, y: (c[1].y + c[2].y) / 2)
        guard right.x - left.x > 0.0001 else { return (left.y + right.y) / 2 }
        let t = min(max((x - left.x) / (right.x - left.x), 0), 1)
        return left.y + t * (right.y - left.y)
    }

    /// The type's height, not the box's: a slanted line's box is taller than its letters.
    private static func textHeight(_ line: OCRLine) -> CGFloat {
        guard line.corners.count == 4 else { return line.box.height }
        let c = line.corners
        return max((c[3].y - c[0].y + c[2].y - c[1].y) / 2, 0)
    }

    /// Lines that run into an inner edge of `region` (one band of an image) were read from half
    /// their letters, and come out as nonsense; the neighbouring band, which overlaps this one,
    /// holds them whole. The image's own edges cut nothing.
    static func droppingCut(_ lines: [OCRLine], in region: CGRect) -> [OCRLine] {
        let innerTop = region.minY > 0.001, innerBottom = region.maxY < 0.999
        return lines.filter { line in
            let margin = 0.25 * line.box.height
            if innerTop, line.box.minY - region.minY < margin { return false }
            if innerBottom, region.maxY - line.box.maxY < margin { return false }
            return true
        }
    }
}

extension OCRLine {
    /// From coordinates normalized to `region` of an image to coordinates of the whole image.
    func mapped(from region: CGRect) -> OCRLine {
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: region.minX + p.x * region.width, y: region.minY + p.y * region.height)
        }
        return OCRLine(
            text: text,
            box: CGRect(x: region.minX + box.minX * region.width, y: region.minY + box.minY * region.height,
                        width: box.width * region.width, height: box.height * region.height),
            corners: corners.map(point),
            confidence: confidence
        )
    }
}
