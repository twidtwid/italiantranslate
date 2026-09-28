import Foundation

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

    /// What the translator gets. Menus and signs shout in capitals ("CROSTONE", "ANTIPASTO DELLA
    /// CASA"), which translation models handle badly, and squeeze lists together
    /// ("pecorino,noci,miele"): feed them sentence case and spaced punctuation.
    static func translationInput(_ text: String) -> String {
        var result = ""
        var previous: Character = " "
        for character in text {
            if (previous == "," || previous == ";" || previous == ":"), character.isLetter {
                result.append(" ")
            }
            result.append(character)
            previous = character
        }
        let words = result.split(separator: " ", omittingEmptySubsequences: false)
        let lettersCount = result.filter(\.isLetter).count
        let shouting = lettersCount >= 4 && isAllCaps(result)
        var sentenceStart = true
        return words.map { word -> String in
            let letters = word.filter(\.isLetter)
            defer {
                if !letters.isEmpty { sentenceStart = false }
                if word.last.map({ ".:!?".contains($0) }) == true { sentenceStart = true }
            }
            // Whole words in capitals, 4+ letters (short ones are often abbreviations: DOP, IGP).
            guard shouting || (letters.count >= 4 && letters.allSatisfy(\.isUppercase)) else { return String(word) }
            let lower = word.lowercased()
            guard sentenceStart, let first = lower.firstIndex(where: \.isLetter) else { return lower }
            return String(lower[..<first]) + lower[first].uppercased() + lower[lower.index(after: first)...]
        }.joined(separator: " ")
    }

    /// "• Filetto", "-Pere e pecorino", "* Ribollita": the marker off the front.
    static func removingListMarker(_ text: String) -> String {
        let markers = "•·▪●○◦‣⁃-–—*"
        let trimmed = text.drop { markers.contains($0) || $0 == " " }
        return trimmed.isEmpty ? text : String(trimmed)
    }

    /// The line can't stop there: it ends in a comma or a hyphen, or in a word like "e", "di", "con".
    static func endsOpen(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        if last == "," || last == "-" { return true }
        return words(text).last.map { trailingJoiners.contains($0) } ?? false
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

    /// How much of `part` is in `whole`, 0...1: the share of its letter pairs found there (case,
    /// accents, spaces and punctuation ignored). A misread piece of a line is mostly in the line.
    static func containment(_ part: String, in whole: String) -> Double {
        let x = Array(folded(part)), y = Array(folded(whole))
        guard x.count > 1, y.count > 1 else { return 0 }
        var pairs: [String: Int] = [:]
        for index in 0..<(y.count - 1) {
            pairs[String([y[index], y[index + 1]]), default: 0] += 1
        }
        var shared = 0
        for index in 0..<(x.count - 1) {
            let pair = String([x[index], x[index + 1]])
            if let count = pairs[pair], count > 0 {
                pairs[pair] = count - 1
                shared += 1
            }
        }
        return Double(shared) / Double(x.count - 1)
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

    static func words(_ text: String) -> [String] {
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
