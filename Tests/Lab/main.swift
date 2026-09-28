import CoreGraphics
import Foundation

// The menu lab: runs the app's own OCR and menu reading on camera-like frames of real menus and
// writes what it found (JSON), the frames with the entries drawn on them, and a readable summary.
// Usage: lab FRAMES_DIR OUT_DIR

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: lab FRAMES_DIR OUT_DIR")
    exit(2)
}
let input = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let recognizer = TextRecognizer()
let languages = LanguageDetector()
var summary = "# Menu lab\n\n"
var comparison = "Lines / price lines / ms: the whole frame, then as a capture reads it (whole + 2 bands).\n\n| frame | whole | capture |\n|---|---|---|\n"

/// Price-like lines ("€ 12", "11,00", "EURO 8"): the small print a whole-page shot tends to lose.
func priceCount(_ lines: [OCRLine]) -> Int {
    lines.filter { Price.isWholeLine($0.text) }.count
}

func name(_ language: TextLanguage) -> String {
    switch language {
    case .italian: return "it"
    case .foreign: return "foreign"
    case .unknown: return "?"
    }
}

func name(_ kind: MenuEntry.Kind) -> String {
    switch kind {
    case .heading: return "heading"
    case .item: return "item"
    case .text: return "text"
    }
}

func record(_ lines: [OCRLine]) -> [[String: Any]] {
    lines.map { line in
        [
            "text": line.text,
            "box": numbers(line.box),
            "corners": line.corners.flatMap { [Double($0.x), Double($0.y)] }.map { ($0 * 10_000).rounded() / 10_000 },
            "language": name(languages.language(of: line.text)),
            "hypotheses": languages.hypotheses(for: line.text),
            "confidence": (Double(line.confidence) * 1000).rounded() / 1000,
        ] as [String: Any]
    }
}

func record(_ entries: [MenuEntry]) -> [[String: Any]] {
    entries.map { entry in
        [
            "kind": name(entry.kind),
            "title": entry.title,
            "details": entry.details,
            "price": entry.price.map { $0 as Any } ?? NSNull(),
            "foreign": entry.isForeign,
            "titleBox": numbers(entry.titleBox),
            "box": numbers(entry.box),
        ] as [String: Any]
    }
}

func describe(_ entries: [MenuEntry]) -> String {
    entries.map { entry in
        let kind = entry.isForeign ? "as printed" : name(entry.kind)
        var text = "- `\(kind)` **\(entry.title)**"
        if let price = entry.price { text += " — \(price)" }
        for detail in entry.details { text += "\n  - \(detail)" }
        return text
    }.joined(separator: "\n")
}

for url in frames(in: input) {
    guard let image = loadImage(url) else { continue }
    let frame = url.deletingPathExtension().lastPathComponent
    let aspect = CGFloat(image.height) / CGFloat(image.width)

    var started = Date()
    let whole = recognizer.lines(in: image, orientation: .up, fast: false)
    let wholeMs = Date().timeIntervalSince(started) * 1000
    var row = "| \(frame) | \(whole.count) / \(priceCount(whole)) / \(Int(wholeMs))"
    started = Date()
    let lines = OCRTiles.merge([whole, recognizer.lines(in: image, fast: false, bands: 2)]) // what a capture reads
    row += " | \(lines.count) / \(priceCount(lines)) / \(Int(Date().timeIntervalSince(started) * 1000))"
    comparison += row + " |\n"

    let entries = MenuReader.entries(from: lines, aspect: aspect, language: languages.language(of:))
    let wholeEntries = MenuReader.entries(from: whole, aspect: aspect, language: languages.language(of:))

    try writeJSON([
        "frame": frame,
        "width": image.width,
        "height": image.height,
        "ocrMs": Int(wholeMs),
        "lines": record(whole),
        "bandedLines": record(lines),
        "entries": record(entries),
        "wholeEntries": record(wholeEntries),
    ], to: output.appendingPathComponent("\(frame).json"))

    if let sketch = Sketch(image: image) {
        for line in lines {
            let color: CGColor
            switch languages.language(of: line.text) {
            case .italian: color = Palette.italian
            case .foreign: color = Palette.foreign
            case .unknown: color = Palette.unknown
            }
            sketch.box(line.box, color: color, lineWidth: 1)
        }
        for (index, entry) in entries.enumerated() {
            let color: CGColor
            if entry.isForeign {
                color = Palette.foreign
            } else {
                switch entry.kind {
                case .heading: color = Palette.heading
                case .item: color = Palette.block
                case .text: color = Palette.unknown
                }
            }
            sketch.box(entry.box.insetBy(dx: -0.003, dy: -0.002), color: color, lineWidth: 3)
            sketch.box(entry.titleBox.insetBy(dx: -0.001, dy: -0.001), color: color, lineWidth: 1.5)
            sketch.label("\(index + 1)" + (entry.price.map { " \($0)" } ?? ""), at: entry.box, color: color, size: 18)
        }
        if let annotated = sketch.image() {
            writeJPEG(annotated, to: output.appendingPathComponent("\(frame)-ocr.jpg"))
        }
    }

    summary += "## \(frame)\n\nOCR \(Int(wholeMs)) ms, \(whole.count) lines whole, \(lines.count) as a capture reads it. "
    summary += "\(entries.count) entries (\(entries.filter { $0.price != nil }.count) priced).\n\n"
    summary += describe(entries) + "\n\n"
    print("\(frame): \(lines.count) lines, \(entries.count) entries, \(Int(wholeMs)) ms")
}

try summary.write(to: output.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
try comparison.write(to: output.appendingPathComponent("bands.md"), atomically: true, encoding: .utf8)
