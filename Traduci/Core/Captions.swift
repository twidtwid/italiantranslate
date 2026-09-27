import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// One translated line or paragraph on a locked still.
struct Caption: Identifiable, Equatable {
    let id: UUID
    var source: String
    /// Normalized upright-image rect, origin top-left.
    var box: CGRect
    var lineCount: Int
    var translation: String?
    /// The page's paper and ink around this text, when sampled from the still.
    var colors: InkSampler.Colors?

    init(block: TextBlock, translation: String?, colors: InkSampler.Colors? = nil) {
        id = UUID()
        source = block.text
        box = block.box
        lineCount = block.lineCount
        self.translation = translation
        self.colors = colors
    }

    /// Worth drawing: translated, and not just the Italian again (names, "Tiramisù" → "Tiramisu").
    var showsTranslation: Bool {
        guard let translation else { return false }
        return !TextNormalizer.isEffectivelySame(source, translation)
    }
}

enum Captions {
    /// Columns left to right, then top to bottom within each: the order people read a menu or a
    /// notice in. Columns are found from the gutters no ordinary line crosses; a heading wide
    /// enough to span columns joins the column nearest its middle.
    static func readingOrder(_ captions: [Caption]) -> [Caption] {
        var columns: [(minX: CGFloat, maxX: CGFloat)] = []
        for box in captions.map(\.box).filter({ $0.width < 0.6 }).sorted(by: { $0.minX < $1.minX }) {
            if let last = columns.last, box.minX <= last.maxX + 0.02 {
                columns[columns.count - 1].maxX = max(last.maxX, box.maxX)
            } else {
                columns.append((box.minX, box.maxX))
            }
        }
        func column(_ caption: Caption) -> Int {
            let x = caption.box.midX
            return columns.indices.min { distance(x, columns[$0]) < distance(x, columns[$1]) } ?? 0
        }
        func distance(_ x: CGFloat, _ column: (minX: CGFloat, maxX: CGFloat)) -> CGFloat {
            x < column.minX ? column.minX - x : (x > column.maxX ? x - column.maxX : 0)
        }
        return captions.sorted { (column($0), $0.box.minY) < (column($1), $1.box.minY) }
    }

    /// Two looks in a row show the same text in about the same place: the view is steady enough to
    /// read, whatever the motion sensors think. `aspect` is frame height ÷ width.
    static func sameView(_ previous: [TextBlock], _ current: [TextBlock], aspect: CGFloat = 16.0 / 9.0) -> Bool {
        guard !previous.isEmpty, !current.isEmpty else { return false }
        var shifts: [CGFloat] = [] // how far each matched block moved, in its own line heights
        for block in current {
            var best: TextBlock?
            var bestSimilarity = 0.8 // must be at least this alike to count as the same text
            for candidate in previous {
                let similarity = TextNormalizer.similarity(candidate.text, block.text)
                if similarity >= bestSimilarity {
                    best = candidate
                    bestSimilarity = similarity
                }
            }
            guard let match = best else { continue }
            let lineHeight = max(block.box.height / CGFloat(max(block.lineCount, 1)), 0.001)
            let dx = (match.box.midX - block.box.midX) / aspect, dy = match.box.midY - block.box.midY
            shifts.append((dx * dx + dy * dy).squareRoot() / lineHeight)
        }
        guard shifts.count * 5 >= current.count * 3 else { return false } // most of the text is the same
        return shifts.sorted()[shifts.count / 2] < 0.6
    }

    /// Distinct texts, most central first: the translator's work queue.
    static func priority(_ blocks: [TextBlock]) -> [String] {
        var queued = Set<String>()
        return blocks
            .sorted { $0.box.distanceFromCenter < $1.box.distanceFromCenter }
            .map(\.text)
            .filter { queued.insert($0).inserted }
    }
}

extension CGRect {
    /// Distance of the middle of a normalized rect from the middle of the image.
    var distanceFromCenter: CGFloat {
        let dx = midX - 0.5, dy = midY - 0.5
        return (dx * dx + dy * dy).squareRoot()
    }
}
