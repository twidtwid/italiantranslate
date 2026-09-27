import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// One line of text from OCR. `box` is normalized (0...1) in the upright image, origin top-left.
struct OCRLine: Equatable {
    var text: String
    var box: CGRect
}

/// One or more lines that are translated as a unit and drawn as one overlay.
struct TextBlock: Equatable {
    var text: String
    var box: CGRect
    var lineCount: Int
}

enum TextBlockBuilder {
    /// Merges lines only when they read as one sentence (paragraphs, two-line signs).
    /// Everything else — menu items, labels, prices — stays one line per block so each
    /// translation lands on top of the text it belongs to.
    static func blocks(from lines: [OCRLine]) -> [TextBlock] {
        let lines = lines
            .map { OCRLine(text: TextNormalizer.collapseWhitespace($0.text), box: $0.box) }
            .filter { !$0.text.isEmpty && $0.box.width > 0 && $0.box.height > 0 }
            .sorted { ($0.box.minY, $0.box.minX) < ($1.box.minY, $1.box.minX) }

        var groups: [[OCRLine]] = []
        for line in lines {
            var best: Int?
            var bestGap = CGFloat.greatestFiniteMagnitude
            for index in groups.indices {
                guard let last = groups[index].last, continues(last, line) else { continue }
                let gap = line.box.minY - last.box.maxY
                if gap < bestGap {
                    best = index
                    bestGap = gap
                }
            }
            if let best {
                groups[best].append(line)
            } else {
                groups.append([line])
            }
        }
        return groups.compactMap(block(from:))
    }

    /// `next` sits right under `line`, in the same column, at the same size, and reads as its continuation.
    static func continues(_ line: OCRLine, _ next: OCRLine) -> Bool {
        let a = line.box, b = next.box
        let small = min(a.height, b.height), large = max(a.height, b.height)
        guard small > 0, large <= small * 1.6 else { return false }
        let gap = b.minY - a.maxY
        guard gap > -0.5 * small, gap < small else { return false }
        let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let aligned = abs(a.minX - b.minX) < 1.5 * small || overlap > 0.5 * min(a.width, b.width)
        return aligned && TextNormalizer.readsAsContinuation(line.text, next.text)
    }

    static func join(_ text: String, _ next: String) -> String {
        if text.hasSuffix("-"), next.first?.isLowercase == true {
            return String(text.dropLast()) + next // "costrui-" + "to" → "costruito"
        }
        return text + " " + next
    }

    private static func block(from lines: [OCRLine]) -> TextBlock? {
        guard var text = lines.first?.text, var box = lines.first?.box else { return nil }
        for line in lines.dropFirst() {
            text = join(text, line.text)
            box = box.union(line.box)
        }
        guard TextNormalizer.isWorthTranslating(text) else { return nil }
        return TextBlock(text: text, box: box, lineCount: lines.count)
    }
}

enum TextNormalizer {
    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Real words, not just prices, phone numbers or stray glyphs.
    static func isWorthTranslating(_ text: String) -> Bool {
        let visible = text.filter { !$0.isWhitespace }
        let letters = visible.filter { $0.isLetter }
        return letters.count >= 2 && letters.count * 2 >= visible.count
    }

    /// Signs are often ALL CAPS, which translation models handle badly. Feed them sentence case.
    static func translationInput(_ text: String) -> String {
        let letters = text.filter { $0.isLetter }
        guard letters.count >= 4 else { return text }
        let uppercase = letters.filter { $0.isUppercase }.count
        guard uppercase * 5 >= letters.count * 4 else { return text }
        let lower = text.lowercased()
        guard let first = lower.firstIndex(where: { $0.isLetter }) else { return lower }
        return String(lower[..<first]) + lower[first].uppercased() + lower[lower.index(after: first)...]
    }

    /// True when the translation adds nothing (names, brands, "Tiramisù" → "Tiramisu").
    static func isEffectivelySame(_ a: String, _ b: String) -> Bool {
        folded(a) == folded(b)
    }

    static func readsAsContinuation(_ line: String, _ next: String) -> Bool {
        guard let lastCharacter = line.last,
              let firstLetter = next.first(where: { $0.isLetter }) else { return false }
        if lastCharacter == "-" || lastCharacter == "," { return true }
        if firstLetter.isLowercase { return true }
        if let last = words(line).last, trailingJoiners.contains(last) { return true }
        if let first = words(next).first, leadingJoiners.contains(first) { return true }
        return false
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    /// Italian prepositions and conjunctions: a line starting with one continues the line above
    /// ("USCITA" / "DI SICUREZZA").
    private static let leadingJoiners: Set<String> = [
        "a", "ad", "al", "allo", "alla", "ai", "agli", "alle", "all",
        "che", "col", "coi", "con", "da", "dal", "dallo", "dalla", "dai", "dagli", "dalle", "dall",
        "del", "dello", "della", "dei", "degli", "delle", "dell", "di", "e", "ed", "fra", "in",
        "nel", "nello", "nella", "nei", "negli", "nelle", "nell", "o", "od", "per",
        "su", "sul", "sullo", "sulla", "sui", "sugli", "sulle", "sull", "tra",
    ]

    /// …and a line ending in one of these (or an article) runs on to the next ("costruita dalla" / "famiglia Medici").
    private static let trailingJoiners: Set<String> = leadingJoiners.union([
        "il", "lo", "la", "i", "gli", "le", "un", "uno", "una", "non",
    ])
}
