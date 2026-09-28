import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// One thing to read on a page, in reading order: a section heading, a dish, or plain text.
struct MenuEntry: Equatable {
    enum Kind: Equatable {
        case heading, item, text
    }

    var kind: Kind
    /// The dish name, heading or sentence as printed, without list marker or price.
    var title: String
    /// Description, ingredients, allergens: one string per run of lines in the same type.
    var details: [String]
    /// Tidied for reading: "€18", "€13.00", "€5 / €15", "€1.50 each".
    var price: String?
    /// Already English (or French or German): shown as printed, never translated.
    var isForeign: Bool
    /// The title's lines on the image, and all of the entry's lines (normalized, origin top-left).
    var titleBox: CGRect
    var box: CGRect
    var lineCount: Int

    /// Everything to translate, title first.
    var sources: [String] { isForeign ? [] : [title] + details }
}

/// Reads a page of OCR lines the way a diner does: which lines are one dish, which are its
/// description, which price goes with it, what's a section heading, which lines are the menu's
/// own English, and in what order the columns go. Pure geometry and text, so it's testable.
enum MenuReader {
    static func entries(from lines: [OCRLine], aspect: CGFloat = 16.0 / 9.0,
                        language: (String) -> TextLanguage = { _ in .unknown }) -> [MenuEntry] {
        var rows = lines.compactMap { line -> Row? in
            let text = TextNormalizer.collapseWhitespace(line.text)
            guard !text.isEmpty, line.box.width > 0, line.box.height > 0 else { return nil }
            return Row(text: text, box: line.box, corners: line.corners)
        }
        level(rows, aspect: aspect)
        rows = joinPieces(rows, aspect: aspect, language: language)

        var prices: [Row] = []
        var texts: [Row] = []
        for row in rows {
            if Price.isWholeLine(row.text) {
                prices.append(row)
                continue
            }
            let (text, price) = Price.split(row.text)
            row.text = text
            row.ownPrice = price
            row.language = language(text)
            if TextNormalizer.isWorthTranslating(text) { texts.append(row) }
        }
        texts.sort { ($0.top, $0.left) < ($1.top, $1.left) }
        let italianHeights = texts.filter { $0.language != .foreign }.map(\.height).sorted()
        let medianHeight = italianHeights.isEmpty ? 0.01 : italianHeights[italianHeights.count / 2]

        let groups = group(texts)
        attach(prices, to: groups)
        return order(groups).compactMap { entry(from: $0, medianHeight: medianHeight) }
    }

    // MARK: - Rows

    /// A printed line (or pieces of one, glued back together).
    final class Row {
        var text: String
        var raw: String // before the price came off: its width covers the price too
        var box: CGRect // on the image, for drawing
        let corners: [CGPoint]
        var language: TextLanguage = .unknown
        var ownPrice: String?
        // Where the line sits once the page is turned level, and how tall its type really is.
        var left: CGFloat
        var right: CGFloat
        var centerY: CGFloat
        var height: CGFloat

        init(text: String, box: CGRect, corners: [CGPoint]) {
            self.text = text
            raw = text
            self.box = box
            self.corners = corners
            left = box.minX
            right = box.maxX
            centerY = box.midY
            height = box.height
        }

        var top: CGFloat { centerY - height / 2 }
        var bottom: CGFloat { centerY + height / 2 }
        var centerX: CGFloat { (left + right) / 2 }
        var width: CGFloat { right - left }
    }

    /// Turns the page level: a photo is rarely square to the menu, and a slanted line's box is
    /// taller than its type, which throws off every size and row comparison.
    static func level(_ rows: [Row], aspect: CGFloat) {
        func slant(_ row: Row) -> CGFloat {
            let c = row.corners
            return atan2((c[1].y - c[0].y) * aspect, c[1].x - c[0].x)
        }
        // Vision reports some lines as level boxes whatever their slant: only slanted readings of
        // long lines say how the page is turned.
        let measured = rows.filter { $0.corners.count == 4 && abs(slant($0)) > 0.0001 }
        var long = measured.filter { $0.box.width > 0.25 }
        if long.isEmpty { long = measured.filter { $0.box.width > 0.1 } }
        let angles = long.map(slant).sorted()
        let theta = angles.isEmpty ? 0 : angles[angles.count / 2]
        let cosine = cos(-theta), sine = sin(-theta)

        for row in rows where row.corners.count == 4 {
            let c = row.corners
            // In units of the image width both ways, so rotation keeps its shape.
            let turned = c.map { point -> CGPoint in
                let x = point.x - 0.5, y = (point.y - 0.5) * aspect
                return CGPoint(x: x * cosine - y * sine + 0.5, y: (x * sine + y * cosine) / aspect + 0.5)
            }
            func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
                hypot(a.x - b.x, (a.y - b.y) * aspect)
            }
            var height = (distance(c[0], c[3]) + distance(c[1], c[2])) / 2 / aspect
            if abs(slant(row)) <= 0.0001, abs(theta) > 0.005 {
                // A level box around slanted text: take the slant back out of its height.
                height = max(height - row.box.width * abs(tan(theta)) / aspect, height * 0.4)
            }
            row.left = turned.map(\.x).min() ?? row.left
            row.right = turned.map(\.x).max() ?? row.right
            row.centerY = turned.map(\.y).reduce(0, +) / 4
            row.height = height
        }
    }

    /// Vision sometimes splits one printed line (a wide gap, a change of font): glue side-by-side
    /// pieces back together, left to right. Two columns in two languages stay apart.
    static func joinPieces(_ rows: [Row], aspect: CGFloat, language: (String) -> TextLanguage) -> [Row] {
        var joined: [Row] = []
        for row in rows.sorted(by: { $0.left < $1.left }) {
            if let match = joined.first(where: { sameLine($0, row, aspect: aspect) && compatible(language($0.text), language(row.text)) }) {
                match.text += " " + row.text
                match.raw = match.text
                match.box = match.box.union(row.box)
                match.right = max(match.right, row.right)
                let top = min(match.top, row.top), bottom = max(match.bottom, row.bottom)
                match.centerY = (top + bottom) / 2
                match.height = max(match.height, row.height)
            } else {
                joined.append(row)
            }
        }
        return joined
    }

    /// `right` carries on `left`'s printed line after at most about a word's gap.
    static func sameLine(_ left: Row, _ right: Row, aspect: CGFloat) -> Bool {
        let small = min(left.height, right.height), large = max(left.height, right.height)
        guard small > 0, large <= small * 1.4 else { return false }
        guard min(left.bottom, right.bottom) - max(left.top, right.top) >= small * 0.6 else { return false }
        let wordGap = small * aspect // x is in widths, y in heights
        let gap = right.left - left.right
        return gap > -wordGap && gap < wordGap * 1.2
    }

    static func compatible(_ a: TextLanguage, _ b: TextLanguage) -> Bool {
        a == b || a == .unknown || b == .unknown
    }

    // MARK: - Grouping

    /// Lines that make one dish, heading or paragraph, plus the menu's own English lines for it.
    final class Group {
        var rows: [Row]
        var foreign: [Row] = []
        var price: String?
        /// Already in another language, with nothing Italian above it: a name, or an English notice.
        let isForeign: Bool
        /// The last line taken in any language: the next line must sit right under it.
        var last: Row

        init(_ row: Row, isForeign: Bool = false) {
            rows = [row]
            last = row
            self.isForeign = isForeign
            price = row.ownPrice
        }

        var top: CGFloat { rows.map(\.top).min() ?? 0 }
        var bottom: CGFloat { (rows + foreign).map(\.bottom).max() ?? 0 }
        var left: CGFloat { rows.map(\.left).min() ?? 0 }
        var right: CGFloat { rows.map(\.right).max() ?? 0 }
    }

    static func group(_ rows: [Row]) -> [Group] {
        var groups: [Group] = []
        for row in rows {
            var best: Group?
            var bestGap = CGFloat.greatestFiniteMagnitude
            for group in groups {
                let last = group.last
                let gap = row.top - last.bottom
                let small = min(last.height, row.height)
                let reach: CGFloat = TextNormalizer.endsOpen(last.text) ? 1.6 : 1.0 // "…di vitello," carries on
                guard gap > -0.5 * small, gap < reach * small, aligned(last, row), gap < bestGap else { continue }
                best = group
                bestGap = gap
            }
            if row.language == .foreign {
                if let best, best.isForeign || best.last === best.rows.last || !best.foreign.isEmpty {
                    if best.isForeign { best.rows.append(row) } else { best.foreign.append(row) }
                    best.last = row
                } else {
                    groups.append(Group(row, isForeign: true))
                }
                continue
            }
            if let best, !best.isForeign, best.last === best.rows.last, continues(best, with: row) {
                best.rows.append(row)
                best.last = row
                if best.price == nil { best.price = row.ownPrice }
            } else {
                groups.append(Group(row))
            }
        }
        return groups
    }

    /// Left, centre or right edges line up: one paragraph, one dish, one centred block.
    static func aligned(_ a: Row, _ b: Row) -> Bool {
        let h = max(a.height, b.height)
        return abs(a.left - b.left) < 3 * h || abs(a.centerX - b.centerX) < 2 * h || abs(a.right - b.right) < 2 * h
    }

    /// Does `row` belong to the dish (or paragraph) above it?
    static func continues(_ group: Group, with row: Row) -> Bool {
        guard let last = group.rows.last else { return false }
        if TextNormalizer.startsListItem(row.text) { return false }
        if group.price != nil, row.ownPrice != nil { return false } // two prices, two dishes
        if group.rows.count == 1, isSection(last.text) || (TextNormalizer.isAllCaps(last.text) && !TextNormalizer.isAllCaps(row.text)) {
            return false // a heading doesn't swallow the first dish under it
        }
        if TextNormalizer.endsOpen(last.text) { return true }
        let ratio = sizeRatio(last, row)
        if ratio > sameSize.upperBound { return false } // bigger type: the next dish's name
        if TextNormalizer.isAllCaps(last.text), TextNormalizer.isAllCaps(row.text),
           max(row.height, last.height) > 1.2 * min(row.height, last.height) {
            return false
        }
        let flows = TextNormalizer.readsAsContinuation(last.text, row.text)
        if group.price != nil, ratio >= sameSize.lowerBound, !flows {
            return false // a priced dish is complete: the next line in the same type is the next dish
        }
        return ratio < sameSize.lowerBound || flows
    }

    /// Type sizes this close are the same type.
    static let sameSize: ClosedRange<CGFloat> = 0.85...1.2

    /// How big `b`'s type is next to `a`'s. Heights alone are noisy (ascenders, descenders, short
    /// words), so lines of some length also compare their average character width.
    static func sizeRatio(_ a: Row, _ b: Row) -> CGFloat {
        let heights = b.height / max(a.height, 0.000_001)
        let lengthA = CGFloat(a.raw.count), lengthB = CGFloat(b.raw.count)
        guard lengthA >= 6, lengthB >= 6, TextNormalizer.isAllCaps(a.raw) == TextNormalizer.isAllCaps(b.raw) else {
            return heights
        }
        let advance = (b.width / lengthB) / max(a.width / lengthA, 0.000_001)
        return (heights * advance).squareRoot()
    }

    // MARK: - Prices

    /// Price lines go with the dish on the same printed row (a price column), or else with the dish
    /// right above them (centred menus print the price on the line under the dish).
    static func attach(_ prices: [Row], to groups: [Group]) {
        for price in prices.sorted(by: { $0.top < $1.top }) {
            var target: Group?
            var best = CGFloat.greatestFiniteMagnitude
            for group in groups where !group.isForeign {
                for row in group.rows + group.foreign where row.right <= price.left + 0.01 {
                    let overlap = min(row.bottom, price.bottom) - max(row.top, price.top)
                    guard overlap >= 0.5 * min(row.height, price.height) else { continue }
                    let distance = abs(row.centerY - price.centerY)
                    if distance < best {
                        target = group
                        best = distance
                    }
                }
            }
            if target == nil {
                for group in groups where !group.isForeign {
                    let gap = price.top - group.bottom
                    guard gap >= -0.5 * price.height, gap < 1.6 * price.height,
                          price.centerX >= group.left - 0.02, price.centerX <= group.right + 0.02,
                          gap < best else { continue }
                    target = group
                    best = gap
                }
            }
            if let target, target.price == nil { target.price = price.text }
        }
    }

    // MARK: - Reading order

    /// Columns left to right, top to bottom in each; anything spanning columns (a title, a footer)
    /// is read where it sits and splits the page into bands.
    static func order(_ groups: [Group]) -> [Group] {
        var columns: [(left: CGFloat, right: CGFloat)] = []
        for group in groups.filter({ $0.right - $0.left < 0.55 }).sorted(by: { $0.left < $1.left }) {
            if let last = columns.last, group.left <= last.right + 0.02 {
                columns[columns.count - 1].right = max(last.right, group.right)
            } else {
                columns.append((group.left, group.right))
            }
        }
        let byTop = groups.sorted { $0.top < $1.top }
        guard columns.count > 1 else { return byTop }

        func column(_ group: Group) -> Int? {
            let overlaps = columns.map { min(group.right, $0.right) - max(group.left, $0.left) }
            if overlaps.filter({ $0 > 0.02 }).count > 1 { return nil } // spans columns
            return overlaps.indices.max { overlaps[$0] < overlaps[$1] }
        }
        var result: [Group] = []
        var band: [(column: Int, group: Group)] = []
        func flush() {
            result += band.sorted { ($0.column, $0.group.top) < ($1.column, $1.group.top) }.map(\.group)
            band = []
        }
        for group in byTop {
            if let index = column(group) {
                band.append((index, group))
            } else {
                flush()
                result.append(group)
            }
        }
        flush()
        return result
    }

    // MARK: - Entries

    static func entry(from group: Group, medianHeight: CGFloat) -> MenuEntry? {
        let (titleRows, chunks) = splitTitle(group.rows)
        var title = TextNormalizer.removingListMarker(join(titleRows.map(\.text)))
        var details = chunks.map { join($0.map(\.text)) }
        if details.isEmpty, let colon = title.firstIndex(of: ":") {
            // "CROSTONE: pecorino senese, noci…": a name, then what's in it.
            let name = title[..<colon].trimmingCharacters(in: .whitespaces)
            let rest = title[title.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if (2...40).contains(name.count), name.split(separator: " ").count <= 4, TextNormalizer.isWorthTranslating(rest) {
                title = name
                details = [rest]
            }
        }
        guard title.filter(\.isLetter).count >= (group.price == nil ? 4 : 2) else { return nil } // stray glyphs
        let kind: MenuEntry.Kind
        if group.price != nil, !group.isForeign {
            kind = .item
        } else if group.rows.count == 1, details.isEmpty, looksLikeHeading(group.rows[0], title: title, medianHeight: medianHeight) {
            kind = .heading
        } else {
            kind = .text
        }
        let titleBox = titleRows.map(\.box).reduce(CGRect.null) { $0.union($1) }
        let box = group.rows.map(\.box).reduce(CGRect.null) { $0.union($1) }
        return MenuEntry(kind: kind, title: title, details: details,
                         price: group.isForeign ? nil : group.price.map(Price.tidy),
                         isForeign: group.isForeign, titleBox: titleBox, box: box, lineCount: group.rows.count)
    }

    /// The name (first line, plus lines that carry it on in the same type) and the rest in runs:
    /// a run ends at a price or where the type changes (description, then allergens).
    static func splitTitle(_ rows: [Row]) -> (title: [Row], chunks: [[Row]]) {
        guard let first = rows.first else { return ([], []) }
        var title = [first]
        for row in rows.dropFirst() {
            guard let previous = title.last, previous.ownPrice == nil else { break }
            if !TextNormalizer.endsOpen(previous.text) {
                let reference = title.max { $0.raw.count < $1.raw.count } ?? previous // longest line shows the type best
                // A name wraps on in the same type; a line with a comma under a name is what's in it
                // ("Quaglia arrosto" / "polenta, silene 15").
                guard TextNormalizer.readsAsContinuation(previous.text, row.text),
                      sameSize.contains(sizeRatio(reference, row)),
                      !row.text.contains(",") else { break }
            }
            title.append(row)
        }
        var chunks: [[Row]] = []
        for row in rows.dropFirst(title.count) {
            if let previous = chunks.last?.last, previous.ownPrice == nil,
               sameSize.contains(sizeRatio(previous, row)), !TextNormalizer.startsListItem(row.text) {
                chunks[chunks.count - 1].append(row)
            } else {
                chunks.append([row])
            }
        }
        return (title, chunks)
    }

    static func join(_ parts: [String]) -> String {
        parts.reduce("") { text, part in
            if text.isEmpty { return part }
            if text.hasSuffix("-"), part.first?.isLowercase == true {
                return String(text.dropLast()) + part // "costrui-" + "to" → "costruito"
            }
            return text + " " + part
        }
    }

    static func looksLikeHeading(_ row: Row, title: String, medianHeight: CGFloat) -> Bool {
        let words = title.split(separator: " ").count
        if words > 6 { return false }
        if isSection(title) { return true }
        if TextNormalizer.isAllCaps(title), words <= 4 { return true }
        return row.height >= 1.4 * medianHeight && words <= 3
    }

    /// "ANTIPASTI", "Primi piatti *", "SECONDI PIATTI / MAIN COURSES": the courses of a menu.
    static func isSection(_ text: String) -> Bool {
        let key = TextNormalizer.words(text).joined(separator: " ")
        let beforeSlash = text.split(separator: "/").first.map { TextNormalizer.words(String($0)).joined(separator: " ") } ?? key
        return sections.contains(key) || sections.contains(beforeSlash)
    }

    static let sections: Set<String> = [
        "antipasti", "antipasto", "primi", "primi piatti", "primo", "secondi", "secondi piatti", "secondo",
        "contorni", "contorno", "dolci", "dolce", "dessert", "desserts", "frutta", "formaggi", "insalate",
        "insalatone", "zuppe", "minestre", "pizze", "pizza", "le pizze", "pasta", "risotti", "carne", "pesce",
        "crudi", "fritti", "bevande", "bibite", "vini", "vino", "birre", "caffetteria", "caffè", "aperitivi",
        "digestivi", "amari", "menu", "menù", "specialità", "piatti del giorno", "alla brace", "griglia",
        "taglieri", "bruschette", "focacce", "schiacciate", "panini", "piadine", "gelati", "sorbetti",
        "vini rossi", "vini bianchi", "bollicine", "cocktail", "analcolici", "colazione", "pranzo", "cena",
        "degustazione", "menu degustazione", "bambini", "carta dei vini",
    ]
}

/// Prices as menus print them: "€ 12", "12,00 €", "EURO 8", "13,00", "€ 5 / € 15", "€ 1.50 cadauna",
/// and "fragole 13" at the end of a description.
enum Price {
    private static let currency = #"(?:€|eur(?:o|os)?\.?)"#
    private static let number = #"\d{1,3}(?:[.,]\d{1,2})?"#
    private static let qualifier = #"(?:\s*(?:cad(?:auna|\.)?|l'uno|a persona|p\.\s?p\.?|al kg|all'etto|l'etto|/\s*[a-z]+\.?))?"#

    private static let wholeLine = try! NSRegularExpression(
        pattern: #"^\s*(?:\#(currency)|c(?=\s?\d))?\s*\#(number)\s*\#(currency)?\#(qualifier)(?:\s*/\s*\#(currency)?\s*\#(number)\s*\#(currency)?)?\s*$"#,
        options: [.caseInsensitive]
    )
    private static let trailing = try! NSRegularExpression(
        pattern: #"^(.*?[^\s.·…_])\s*(?:[.·…_]{2,}\s*)?(\#(currency)\s*\#(number)\#(qualifier)|\d{1,3}[.,]\d{2}\s*\#(currency)?\#(qualifier)|\d{1,3}\s*\#(currency)\#(qualifier)|(?<=[a-zà-ÿ)"”'’])\s\d{1,3})\s*$"#,
        options: [.caseInsensitive]
    )

    /// The whole line is a price ("€ 12", "EURO 18", "11,00", "C18" for a misread "€18").
    static func isWholeLine(_ text: String) -> Bool {
        guard text.contains(where: \.isNumber) else { return false }
        return wholeLine.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// "Dolce del giorno € 6.00" → ("Dolce del giorno", "€ 6.00"); no price → (text, nil).
    static func split(_ text: String) -> (text: String, price: String?) {
        guard let match = trailing.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let textRange = Range(match.range(at: 1), in: text),
              let priceRange = Range(match.range(at: 2), in: text) else { return (text, nil) }
        let rest = text[textRange].trimmingCharacters(in: CharacterSet(charactersIn: " :-–"))
        guard TextNormalizer.isWorthTranslating(rest) else { return (text, nil) }
        return (rest, text[priceRange].trimmingCharacters(in: .whitespaces))
    }

    /// "EURO   8" → "€8", "13,00 €" → "€13.00", "€ 5 /€ 15" → "€5 / €15", "€ 1.50 cadauna" → "€1.50 each".
    static func tidy(_ price: String) -> String {
        var text = TextNormalizer.collapseWhitespace(price)
        var suffix = ""
        let qualifiers: [(String, String)] = [
            ("cadauna", " each"), ("cad.", " each"), ("cad", " each"), ("l'uno", " each"),
            ("a persona", " per person"), ("p.p.", " per person"), ("p. p.", " per person"),
            ("al kg", " per kg"), ("all'etto", " per 100 g"), ("l'etto", " per 100 g"),
        ]
        for (italian, english) in qualifiers where text.lowercased().hasSuffix(italian) {
            text = String(text.dropLast(italian.count)).trimmingCharacters(in: .whitespaces)
            suffix = english
            break
        }
        let parts = text.split(separator: "/").compactMap { part -> String? in
            let digits = part.drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "," || $0 == "." }
            guard !digits.isEmpty else { return nil }
            var amount = digits.replacingOccurrences(of: ",", with: ".")
            while amount.hasSuffix(".") { amount.removeLast() }
            if let dot = amount.firstIndex(of: "."), amount.distance(from: dot, to: amount.endIndex) == 2 { amount += "0" }
            return "€" + amount
        }
        return parts.isEmpty ? price : parts.joined(separator: " / ") + suffix
    }
}
