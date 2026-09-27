import Foundation
import NaturalLanguage

enum TextLanguage {
    /// Italian: translate it.
    case italian
    /// Clearly English, French or German: multilingual menus and notices print these beside the
    /// Italian, and they must not be "translated" as if they were Italian.
    case foreign
    /// Too short or too mixed to tell: treated as Italian.
    case unknown
}

/// Tells Italian from the languages printed beside it, on-device. Not thread-safe: use from one queue.
final class LanguageDetector {
    private static let candidates: [NLLanguage] = [.italian, .english, .french, .german, .spanish]
    /// Spanish is a candidate only so that Italian reading a little Spanish ("Carne cruda": 69 %
    /// Spanish) isn't pushed toward English. Italian menus don't print Spanish beside the Italian.
    private static let foreign: [NLLanguage] = [.english, .french, .german]
    private let recognizer = NLLanguageRecognizer()
    private var cache: [String: TextLanguage] = [:]

    func language(of text: String) -> TextLanguage {
        if let known = cache[text] { return known }
        let result = detect(text)
        if cache.count > 4_000 { cache.removeAll(keepingCapacity: true) }
        cache[text] = result
        return result
    }

    /// Every candidate's probability, for tuning ("it": 0.62, "en": 0.3, …).
    func hypotheses(for text: String) -> [String: Double] {
        guesses(text).reduce(into: [:]) { result, pair in
            result[pair.key.rawValue] = (pair.value * 1_000).rounded() / 1_000
        }
    }

    private func guesses(_ text: String) -> [NLLanguage: Double] {
        recognizer.reset()
        recognizer.languageConstraints = Self.candidates
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: Self.candidates.count)
    }

    private func detect(_ text: String) -> TextLanguage {
        guard text.filter(\.isLetter).count >= 4 else { return .unknown }
        let guesses = guesses(text)
        let italian = guesses[.italian] ?? 0
        if italian >= 0.5 { return .italian }
        // Menu English is often misspelled or cut short ("Nodles with trufle", "Parmesan aubergines"
        // reads 38 % French, 27 % German): count the three together.
        let foreign = Self.foreign.reduce(0) { $0 + (guesses[$1] ?? 0) }
        return foreign >= 0.6 && italian < 0.3 ? .foreign : .unknown
    }
}
