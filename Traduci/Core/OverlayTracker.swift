import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A translation overlay pinned to a piece of text on screen.
struct OverlayItem: Identifiable, Equatable {
    let id: UUID
    /// Latest OCR reading of the text; also the translation cache key.
    var source: String
    /// Normalized upright-image rect, origin top-left.
    var box: CGRect
    var lineCount: Int
    /// May belong to an earlier reading of `source` while the new one is being translated.
    var translation: String?
    var translationIsCurrent: Bool
    var lastSeen: TimeInterval
}

/// Keeps overlays stable across OCR frames: matches new text to existing overlays, damps jitter,
/// keeps the previous translation up while a changed reading is retranslated, and briefly holds
/// overlays when OCR misses a line for a frame or two.
struct OverlayTracker {
    private(set) var items: [OverlayItem] = []
    var minimumOverlap: CGFloat = 0.25
    private var lastUpdate: TimeInterval?
    private var frameInterval: TimeInterval = 0.1

    /// - Parameter exact: use this frame's boxes verbatim and drop everything not in it (frozen frames).
    mutating func update(with blocks: [TextBlock], at now: TimeInterval, exact: Bool = false, translations: [String: String]) {
        if let lastUpdate, now > lastUpdate {
            frameInterval = frameInterval * 0.8 + min(now - lastUpdate, 1) * 0.2
        }
        lastUpdate = now

        var matchedItems = Set<Int>(), matchedBlocks = Set<Int>()

        // 1. Same place: best overlap wins.
        var candidates: [(overlap: CGFloat, item: Int, block: Int)] = []
        for (itemIndex, item) in items.enumerated() {
            for (blockIndex, block) in blocks.enumerated() {
                let overlap = item.box.intersectionOverUnion(block.box)
                if overlap >= minimumOverlap {
                    candidates.append((overlap, itemIndex, blockIndex))
                }
            }
        }
        candidates.sort { $0.overlap > $1.overlap }
        for candidate in candidates where !matchedItems.contains(candidate.item) && !matchedBlocks.contains(candidate.block) {
            matchedItems.insert(candidate.item)
            matchedBlocks.insert(candidate.block)
            refresh(candidate.item, with: blocks[candidate.block], at: now, smooth: !exact, translations: translations)
        }

        // 2. Same words, somewhere else: the camera moved faster than overlaps can follow.
        for (blockIndex, block) in blocks.enumerated() where !matchedBlocks.contains(blockIndex) {
            let nearest = items.indices
                .filter { !matchedItems.contains($0) && items[$0].source == block.text }
                .min { items[$0].box.centerDistance(to: block.box) < items[$1].box.centerDistance(to: block.box) }
            guard let itemIndex = nearest else { continue }
            matchedItems.insert(itemIndex)
            matchedBlocks.insert(blockIndex)
            refresh(itemIndex, with: block, at: now, smooth: false, translations: translations)
        }

        // 3. Everything else is new text.
        for (blockIndex, block) in blocks.enumerated() where !matchedBlocks.contains(blockIndex) {
            let translation = translations[block.text]
            items.append(OverlayItem(
                id: UUID(),
                source: block.text,
                box: block.box,
                lineCount: block.lineCount,
                translation: translation,
                translationIsCurrent: translation != nil,
                lastSeen: now
            ))
        }

        if exact {
            items.removeAll { $0.lastSeen != now }
        } else {
            // Ride out a couple of missed OCR frames, whatever the current OCR speed.
            let hold = min(max(frameInterval * 2.5, 0.3), 1)
            items.removeAll { now - $0.lastSeen > hold }
        }
    }

    mutating func apply(translation: String, for source: String) {
        for index in items.indices where items[index].source == source {
            items[index].translation = translation
            items[index].translationIsCurrent = true
        }
    }

    /// Texts visible in the frame at `time`, most central first: the translator's work queue.
    func sourcesByPriority(seenAt time: TimeInterval) -> [String] {
        var queued = Set<String>()
        return items
            .filter { $0.lastSeen == time }
            .sorted { $0.box.distanceFromCenter < $1.box.distanceFromCenter }
            .map(\.source)
            .filter { queued.insert($0).inserted }
    }

    private mutating func refresh(_ index: Int, with block: TextBlock, at now: TimeInterval, smooth: Bool, translations: [String: String]) {
        var item = items[index]
        item.box = smooth ? Self.steady(item.box, toward: block.box) : block.box
        item.lineCount = block.lineCount
        item.lastSeen = now
        if item.source != block.text {
            item.source = block.text
            item.translationIsCurrent = false
        }
        if !item.translationIsCurrent, let translation = translations[block.text] {
            item.translation = translation
            item.translationIsCurrent = true
        }
        items[index] = item
    }

    /// Small OCR jitter is damped so overlays sit still; real camera movement is followed immediately.
    static func steady(_ old: CGRect, toward new: CGRect) -> CGRect {
        let tolerance = max(new.height, 0.005) * 0.4
        guard abs(new.midX - old.midX) < tolerance, abs(new.midY - old.midY) < tolerance else { return new }
        return CGRect(
            x: (old.minX + new.minX) / 2,
            y: (old.minY + new.minY) / 2,
            width: (old.width + new.width) / 2,
            height: (old.height + new.height) / 2
        )
    }
}

extension CGRect {
    func intersectionOverUnion(_ other: CGRect) -> CGFloat {
        let overlap = intersection(other)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return 0 }
        let shared = overlap.width * overlap.height
        let total = width * height + other.width * other.height - shared
        return total > 0 ? shared / total : 0
    }

    func centerDistance(to other: CGRect) -> CGFloat {
        let dx = midX - other.midX, dy = midY - other.midY
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Distance from the middle of a normalized image.
    var distanceFromCenter: CGFloat {
        centerDistance(to: CGRect(x: 0.5, y: 0.5, width: 0, height: 0))
    }
}
