import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// One entry of a captured page (a heading, a dish, a paragraph) with its English as it arrives.
struct Caption: Identifiable, Equatable {
    /// Position in reading order: stable for the life of a capture.
    let id: Int
    let entry: MenuEntry
    /// English for each of the entry's sources (title, details), as the translator delivers them.
    var english: [String: String] = [:]
    /// The page's paper and ink around the title, when sampled from the still.
    var colors: InkSampler.Colors?

    /// The English title; nil while it's being translated. Text already in English is its own.
    var title: String? { entry.isForeign ? entry.title : english[entry.title] }

    /// The English of each detail line, nil where it's still coming.
    var details: [String?] { entry.details.map { english[$0] } }

    var isTranslated: Bool { entry.sources.allSatisfy { english[$0] != nil } }

    /// Worth painting over the Italian: translated, and not just the Italian again (names, brands,
    /// "Tiramisù" → "Tiramisu").
    var paintsTitle: Bool {
        guard !entry.isForeign, let title else { return false }
        return !TextNormalizer.isEffectivelySame(entry.title, title)
    }

    /// The Italian is worth showing under the English: it says something the English doesn't. A
    /// name to order by or a sign to match, yes; a paragraph of a plaque is on the picture already.
    var showsItalian: Bool {
        if entry.kind == .text, entry.title.split(separator: " ").count > 8 { return false }
        guard !entry.isForeign, let title else { return !entry.isForeign }
        return !TextNormalizer.isEffectivelySame(entry.title, title)
    }
}

enum Captions {
    /// What to translate first. While aiming: the middle of the view, where people point. On a
    /// capture: the order the list reads in, every title before any description, so the list fills
    /// from the top in one pass.
    static func priority(_ entries: [MenuEntry], centralFirst: Bool) -> [String] {
        let ordered = centralFirst ? entries.sorted { $0.box.distanceFromCenter < $1.box.distanceFromCenter } : entries
        var queued = Set<String>()
        let titles = ordered.filter { !$0.isForeign }.map(\.title)
        let details = ordered.filter { !$0.isForeign }.flatMap(\.details)
        return (titles + details).filter { queued.insert($0).inserted }
    }

    /// Two looks in a row show the same text in about the same place: the view is steady enough to
    /// capture, whatever the motion sensors think. `aspect` is frame height ÷ width.
    static func sameView(_ previous: [MenuEntry], _ current: [MenuEntry], aspect: CGFloat = 16.0 / 9.0) -> Bool {
        guard !previous.isEmpty, !current.isEmpty else { return false }
        var shifts: [CGFloat] = [] // how far each matched entry moved, in its own line heights
        for entry in current {
            var best: MenuEntry?
            var bestSimilarity = 0.8 // must be at least this alike to count as the same text
            for candidate in previous {
                let similarity = TextNormalizer.similarity(candidate.title, entry.title)
                if similarity >= bestSimilarity {
                    best = candidate
                    bestSimilarity = similarity
                }
            }
            guard let match = best else { continue }
            let lineHeight = max(entry.box.height / CGFloat(max(entry.lineCount, 1)), 0.001)
            let dx = (match.box.midX - entry.box.midX) / aspect, dy = match.box.midY - entry.box.midY
            shifts.append((dx * dx + dy * dy).squareRoot() / lineHeight)
        }
        guard shifts.count * 5 >= current.count * 3 else { return false } // most of the text is the same
        return shifts.sorted()[shifts.count / 2] < 0.6
    }

    /// The whole page as plain text, for sharing: English with the Italian name and the price.
    static func plainText(_ captions: [Caption]) -> String {
        captions.map { caption -> String in
            let entry = caption.entry
            var lines: [String] = []
            let english = caption.title ?? entry.title
            switch entry.kind {
            case .heading:
                lines.append(english.uppercased())
            case .item, .text:
                lines.append(english + (entry.price.map { " — \($0)" } ?? ""))
                lines += caption.details.enumerated().map { $0.element ?? entry.details[$0.offset] }
                if caption.showsItalian, caption.title != nil { lines.append("(\(entry.title))") }
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

extension CGRect {
    /// Distance of the middle of a normalized rect from the middle of the image.
    var distanceFromCenter: CGFloat {
        let dx = midX - 0.5, dy = midY - 0.5
        return (dx * dx + dy * dy).squareRoot()
    }
}
