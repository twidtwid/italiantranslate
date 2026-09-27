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
    /// Groups OCR lines into translation units. Pieces of one printed line are glued back together;
    /// lines merge only when they read as one sentence in the same language (paragraphs, two-line
    /// signs). Everything else (menu items, labels, prices) stays one line per block, so each
    /// translation lands on the text it belongs to. Other languages are dropped: multilingual menus
    /// and notices print English, French or German beside the Italian, and it needs no translating.
    /// - Parameter aspect: upright frame height ÷ width, to compare horizontal and vertical distances.
    static func blocks(from lines: [OCRLine], aspect: CGFloat = 16.0 / 9.0,
                       language: (String) -> TextLanguage = { _ in .unknown }) -> [TextBlock] {
        let cleaned = lines
            .map { OCRLine(text: TextNormalizer.collapseWhitespace($0.text), box: $0.box) }
            .filter { !$0.text.isEmpty && $0.box.width > 0 && $0.box.height > 0 }
        let rows = joinRows(cleaned, aspect: aspect, language: language)
            .sorted { ($0.box.minY, $0.box.minX) < ($1.box.minY, $1.box.minX) }

        var groups: [[OCRLine]] = []
        for row in rows {
            var best: Int?
            var bestGap = CGFloat.greatestFiniteMagnitude
            for index in groups.indices {
                guard let last = groups[index].last, continues(last, row),
                      compatible(language(last.text), language(row.text)) else { continue }
                let gap = row.box.minY - last.box.maxY
                if gap < bestGap {
                    best = index
                    bestGap = gap
                }
            }
            if let best {
                groups[best].append(row)
            } else {
                groups.append([row])
            }
        }
        return groups.compactMap { block(from: $0, language: language) }
    }

    /// Vision sometimes splits one printed line in two (a wide gap, a change of font). Glue
    /// side-by-side pieces of the same line back together, left to right. Two columns in two
    /// languages (Italian | English) stay apart.
    static func joinRows(_ lines: [OCRLine], aspect: CGFloat, language: (String) -> TextLanguage) -> [OCRLine] {
        var rows: [OCRLine] = []
        for line in lines.sorted(by: { $0.box.minX < $1.box.minX }) {
            let match = rows.firstIndex { sameRow($0, line, aspect: aspect) && compatible(language($0.text), language(line.text)) }
            if let match {
                rows[match] = OCRLine(text: rows[match].text + " " + line.text, box: rows[match].box.union(line.box))
            } else {
                rows.append(line)
            }
        }
        return rows
    }

    /// `right` continues `left` on the same printed line, after at most about a word's gap.
    static func sameRow(_ left: OCRLine, _ right: OCRLine, aspect: CGFloat) -> Bool {
        let a = left.box, b = right.box
        let small = min(a.height, b.height), large = max(a.height, b.height)
        guard small > 0, large <= small * 1.4 else { return false }
        guard min(a.maxY, b.maxY) - max(a.minY, b.minY) >= small * 0.6 else { return false }
        let lineHeightInWidths = small * aspect // x is normalized to width, y to height
        let gap = b.minX - a.maxX
        return gap > -lineHeightInWidths && gap < lineHeightInWidths * 1.2
    }

    static func compatible(_ a: TextLanguage, _ b: TextLanguage) -> Bool {
        a == b || a == .unknown || b == .unknown
    }

    /// `next` sits right under `line`, in the same column, at the same size, and reads as its continuation.
    static func continues(_ line: OCRLine, _ next: OCRLine) -> Bool {
        let a = line.box, b = next.box
        let small = min(a.height, b.height), large = max(a.height, b.height)
        // All-caps lines have no ascenders or descenders, so their heights compare font sizes
        // directly: a big heading and the smaller subtitle under it stay separate.
        let bothCaps = TextNormalizer.isAllCaps(line.text) && TextNormalizer.isAllCaps(next.text)
        guard small > 0, large <= small * (bothCaps ? 1.2 : 1.6) else { return false }
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

    private static func block(from lines: [OCRLine], language: (String) -> TextLanguage) -> TextBlock? {
        guard var text = lines.first?.text, var box = lines.first?.box else { return nil }
        for line in lines.dropFirst() {
            text = join(text, line.text)
            box = box.union(line.box)
        }
        guard TextNormalizer.isWorthTranslating(text), language(text) != .foreign else { return nil }
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
        guard text.filter({ $0.isLetter }).count >= 4, isAllCaps(text) else { return text }
        let lower = text.lowercased()
        guard let first = lower.firstIndex(where: { $0.isLetter }) else { return lower }
        return String(lower[..<first]) + lower[first].uppercased() + lower[lower.index(after: first)...]
    }

    /// True when the translation adds nothing (names, brands, "Tiramisù" → "Tiramisu").
    static func isEffectivelySame(_ a: String, _ b: String) -> Bool {
        folded(a) == folded(b)
    }

    static func isAllCaps(_ text: String) -> Bool {
        let letters = text.filter { $0.isLetter }
        return letters.count >= 2 && letters.filter { $0.isUppercase }.count * 5 >= letters.count * 4
    }

    /// "• …", "- …", "1. …", "2) …": always the start of a new item, whatever the line above says.
    static func startsListItem(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        if "•·▪●○◦‣⁃-–—*".contains(first) { return true }
        let digits = text.prefix { $0.isNumber }
        guard (1...2).contains(digits.count) else { return false }
        let marker = text.dropFirst(digits.count).first
        return marker == "." || marker == ")"
    }

    /// How alike two OCR readings are, 0...1 (Dice overlap of letter pairs), ignoring case,
    /// accents, spaces and punctuation. "Usclta di sicurezza" vs "Uscita di sicurezza" ≈ 0.88.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(folded(a)), y = Array(folded(b))
        guard x.count > 1, y.count > 1 else { return x == y ? 1 : 0 }
        var pairs: [String: Int] = [:]
        for index in 0..<(x.count - 1) {
            pairs[String([x[index], x[index + 1]]), default: 0] += 1
        }
        var shared = 0
        for index in 0..<(y.count - 1) {
            let pair = String([y[index], y[index + 1]])
            if let count = pairs[pair], count > 0 {
                pairs[pair] = count - 1
                shared += 1
            }
        }
        return Double(2 * shared) / Double(x.count + y.count - 2)
    }

    static func readsAsContinuation(_ line: String, _ next: String) -> Bool {
        guard let lastCharacter = line.last,
              let firstLetter = next.first(where: { $0.isLetter }) else { return false }
        if startsListItem(next) { return false }
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
