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
    /// While reading, the phone has moved on to other text: most of the locked captions are gone
    /// from a fresh look at the camera. A frame with barely any text (a glance away, motion blur)
    /// proves nothing, so it never unlocks on its own.
    static func sceneChanged(from captions: [Caption], to blocks: [TextBlock]) -> Bool {
        guard !captions.isEmpty, blocks.count >= 2 else { return false }
        let found = captions.filter { caption in
            blocks.contains { TextNormalizer.similarity($0.text, caption.source) >= 0.75 }
        }.count
        return Double(found) < Double(captions.count) * 0.4
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
