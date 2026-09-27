import Foundation
import NaturalLanguage

enum TextLanguage {
    case italian, english, unknown
}

/// Tells Italian from English, on-device. Bilingual menus print English right under the Italian;
/// that English is left alone: never "translated" again, never glued onto the Italian above it.
/// Not thread-safe: use from one queue.
final class LanguageDetector {
    private let recognizer = NLLanguageRecognizer()
    private var cache: [String: TextLanguage] = [:]

    func language(of text: String) -> TextLanguage {
        if let known = cache[text] { return known }
        let result = detect(text)
        if cache.count > 4_000 { cache.removeAll(keepingCapacity: true) }
        cache[text] = result
        return result
    }

    private func detect(_ text: String) -> TextLanguage {
        guard text.filter(\.isLetter).count >= 4 else { return .unknown }
        recognizer.reset()
        recognizer.languageConstraints = [.italian, .english]
        recognizer.processString(text)
        let odds = recognizer.languageHypotheses(withMaximum: 2)
        if odds[.english, default: 0] >= 0.75 { return .english }
        if odds[.italian, default: 0] >= 0.75 { return .italian }
        return .unknown
    }
}
