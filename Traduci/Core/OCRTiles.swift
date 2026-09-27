import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

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

    /// Every line once. Where two readings of overlapping bands cover the same spot, the longer one
    /// wins: a line cut by a band's edge reads shorter than the whole line in the next band.
    static func merge(_ readings: [[OCRLine]]) -> [OCRLine] {
        var kept: [OCRLine] = []
        for reading in readings {
            for line in reading {
                if let index = kept.firstIndex(where: { sameSpot($0, line) }) {
                    if line.text.count > kept[index].text.count { kept[index] = line }
                } else {
                    kept.append(line)
                }
            }
        }
        return kept
    }

    private static func sameSpot(_ a: OCRLine, _ b: OCRLine) -> Bool {
        let overlap = a.box.intersection(b.box)
        guard !overlap.isNull else { return false }
        let smaller = min(a.box.width * a.box.height, b.box.width * b.box.height)
        return smaller > 0 && overlap.width * overlap.height >= 0.5 * smaller
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
            corners: corners.map(point)
        )
    }
}
