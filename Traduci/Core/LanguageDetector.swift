import Foundation
import NaturalLanguage

enum TextLanguage {
    /// Italian: translate it.
    case italian
    /// Clearly another language (English, French, German, Spanish): multilingual menus and notices
    /// print these beside the Italian, and they must not be "translated" as if they were Italian.
    case foreign
    /// Too short or too mixed to tell: treated as Italian.
    case unknown
}

/// Tells Italian from the languages printed beside it, on-device. Not thread-safe: use from one queue.
final class LanguageDetector {
    private static let candidates: [NLLanguage] = [.italian, .english, .french, .german, .spanish]
    private let recognizer = NLLanguageRecognizer()
    private var cache: [String: TextLanguage] = [:]

    func language(of text: String) -> TextLanguage {
        if let known = cache[text] { return known }
        let result = detect(text)
        if cache.count > 4_000 { cache.removeAll(keepingCapacity: true) }
        cache[text] = result
        return result
    }

    /// The recognizer's top guesses with their probabilities, for tuning ("it": 0.62, "en": 0.3).
    func hypotheses(for text: String) -> [String: Double] {
        recognizer.reset()
        recognizer.languageConstraints = Self.candidates
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: 3).reduce(into: [:]) { result, pair in
            result[pair.key.rawValue] = (pair.value * 1_000).rounded() / 1_000
        }
    }

    private func detect(_ text: String) -> TextLanguage {
        guard text.filter(\.isLetter).count >= 4 else { return .unknown }
        recognizer.reset()
        recognizer.languageConstraints = Self.candidates
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first else { return .unknown }
        if language == .italian { return confidence >= 0.5 ? .italian : .unknown }
        return confidence >= 0.75 ? .foreign : .unknown // only drop text we're sure isn't Italian
    }
}
