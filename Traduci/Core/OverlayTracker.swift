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
    /// A different OCR reading of the same text, waiting to prove it isn't just noise.
    var candidate: String? = nil
    var candidateFrames = 0
}

/// Keeps overlays calm across OCR frames: matches new text to existing overlays, holds them still
/// through hand shake, ignores flickering misreads, keeps the previous translation up while a
/// changed reading is retranslated, and briefly holds overlays when OCR misses a line.
struct OverlayTracker {
    private(set) var items: [OverlayItem] = []
    var minimumOverlap: CGFloat = 0.25
    /// Upright frame height ÷ width, to weigh horizontal and vertical movement alike.
    var imageAspect: CGFloat = 16.0 / 9.0
    /// Readings at least this alike are the same text, misread; below it the text really changed.
    var sameTextSimilarity = 0.6
    /// Frames in a row a new reading of the same text must survive before it replaces the old one.
    var framesToAdopt = 3
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
        var pairs: [(overlap: CGFloat, item: Int, block: Int)] = []
        for (itemIndex, item) in items.enumerated() {
            for (blockIndex, block) in blocks.enumerated() {
                let overlap = item.box.intersectionOverUnion(block.box)
                if overlap >= minimumOverlap {
                    pairs.append((overlap, itemIndex, blockIndex))
                }
            }
        }
        pairs.sort { $0.overlap > $1.overlap }
        for pair in pairs where !matchedItems.contains(pair.item) && !matchedBlocks.contains(pair.block) {
            matchedItems.insert(pair.item)
            matchedBlocks.insert(pair.block)
            refresh(pair.item, with: blocks[pair.block], at: now, snap: exact, translations: translations)
        }

        // 2. Same words, somewhere else: the camera moved faster than overlaps can follow.
        for (blockIndex, block) in blocks.enumerated() where !matchedBlocks.contains(blockIndex) {
            let nearest = items.indices
                .filter { !matchedItems.contains($0) && Self.sameWords(items[$0], block.text) }
                .min { items[$0].box.centerDistance(to: block.box) < items[$1].box.centerDistance(to: block.box) }
            guard let itemIndex = nearest else { continue }
            matchedItems.insert(itemIndex)
            matchedBlocks.insert(blockIndex)
            refresh(itemIndex, with: block, at: now, snap: true, translations: translations)
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

    private mutating func refresh(_ index: Int, with block: TextBlock, at now: TimeInterval, snap: Bool, translations: [String: String]) {
        var item = items[index]
        item.box = snap ? block.box : settle(item.box, toward: block.box, lines: block.lineCount)
        item.lineCount = block.lineCount
        item.lastSeen = now

        if block.text == item.source || TextNormalizer.isEffectivelySame(block.text, item.source) {
            item.candidate = nil // same words; only case or punctuation wobbled
            item.candidateFrames = 0
        } else if TextNormalizer.similarity(block.text, item.source) < sameTextSimilarity {
            // Different text now sits here: switch at once, and never show the old text's translation on it.
            Self.adopt(block.text, into: &item)
            item.translation = translations[block.text]
        } else if block.text == item.candidate {
            item.candidateFrames += 1
            if item.candidateFrames >= framesToAdopt {
                Self.adopt(block.text, into: &item) // keeps the old translation up until the new one lands
            }
        } else {
            item.candidate = block.text
            item.candidateFrames = 1
        }

        if !item.translationIsCurrent, let translation = translations[item.source] {
            item.translation = translation
            item.translationIsCurrent = true
        }
        items[index] = item
    }

    /// Exact words only (case and punctuation aside): "similar" would confuse neighbouring menu items.
    private static func sameWords(_ item: OverlayItem, _ text: String) -> Bool {
        item.source == text || item.candidate == text || TextNormalizer.isEffectivelySame(item.source, text)
    }

    private static func adopt(_ text: String, into item: inout OverlayItem) {
        item.source = text
        item.translationIsCurrent = false
        item.candidate = nil
        item.candidateFrames = 0
    }

    /// Hand shake and OCR noise nudge boxes by a few points every frame. Overlays hold still until
    /// the text has really moved or changed size, then jump there (the view animates the jump).
    func settle(_ old: CGRect, toward new: CGRect, lines: Int) -> CGRect {
        let lineHeight = new.height / CGFloat(max(lines, 1))
        let moved = abs(new.midY - old.midY) > lineHeight * 0.45
            || abs(new.midX - old.midX) > lineHeight * imageAspect * 0.6
        let resized = abs(new.width - old.width) > old.width * 0.2
            || abs(new.height - old.height) > old.height * 0.2
        return moved || resized ? new : old
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
