import CoreGraphics
import Foundation

// The menu lab: runs the app's own OCR and grouping on camera-like frames of real menus and writes
// what it found (JSON), the frames with boxes drawn on them, and a readable summary.
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
var comparison = "Lines / price lines / ms, reading the whole frame vs in 2, 3, 4 bands.\n\n| frame | whole | 2 bands | 3 bands | 4 bands |\n|---|---|---|---|---|\n"

/// Price-like lines ("€ 12", "11,00", "EURO 8"): the small print a whole-page shot tends to lose.
func priceCount(_ lines: [OCRLine]) -> Int {
    lines.filter { line in
        let text = line.text.replacingOccurrences(of: " ", with: "")
        return text.count <= 9 && text.contains(where: \.isNumber) && text.filter(\.isLetter).count <= 4
    }.count
}
var summary = "# Menu lab\n\n"

func name(_ language: TextLanguage) -> String {
    switch language {
    case .italian: return "it"
    case .foreign: return "foreign"
    case .unknown: return "?"
    }
}

for url in frames(in: input) {
    guard let image = loadImage(url) else { continue }
    let frame = url.deletingPathExtension().lastPathComponent
    let aspect = CGFloat(image.height) / CGFloat(image.width)

    var started = Date()
    let lines = recognizer.lines(in: image, orientation: .up, fast: false)
    let accurateMs = Date().timeIntervalSince(started) * 1000
    started = Date()
    let fastLines = recognizer.lines(in: image, orientation: .up, fast: true)
    let fastMs = Date().timeIntervalSince(started) * 1000

    var row = "| \(frame) | \(lines.count) / \(priceCount(lines)) / \(Int(accurateMs))"
    var tiled: [Int: [OCRLine]] = [:]
    for bands in [2, 3, 4] {
        started = Date()
        let banded = recognizer.lines(in: image, fast: false, bands: bands)
        row += " | \(banded.count) / \(priceCount(banded)) / \(Int(Date().timeIntervalSince(started) * 1000))"
        tiled[bands] = banded
    }
    comparison += row + " |\n"
    let fineLines = tiled[3] ?? lines

    let blocks = TextBlockBuilder.blocks(from: lines, aspect: aspect, language: languages.language(of:))

    try writeJSON([
        "frame": frame,
        "width": image.width,
        "height": image.height,
        "ocrMs": Int(accurateMs),
        "fastOcrMs": Int(fastMs),
        "fastLineCount": fastLines.count,
        "bandedLines": fineLines.map { line in
            [
                "text": line.text,
                "box": numbers(line.box),
                "corners": line.corners.flatMap { [Double($0.x), Double($0.y)] }.map { ($0 * 10_000).rounded() / 10_000 },
                "language": name(languages.language(of: line.text)),
                "hypotheses": languages.hypotheses(for: line.text),
            ] as [String: Any]
        },
        "lines": lines.map { line in
            [
                "text": line.text,
                "box": numbers(line.box),
                "corners": line.corners.flatMap { [Double($0.x), Double($0.y)] }.map { ($0 * 10_000).rounded() / 10_000 },
                "language": name(languages.language(of: line.text)),
                "hypotheses": languages.hypotheses(for: line.text),
            ] as [String: Any]
        },
        "blocks": blocks.map { ["text": $0.text, "box": numbers($0.box), "lines": $0.lineCount] },
    ], to: output.appendingPathComponent("\(frame).json"))

    if let sketch = Sketch(image: image) {
        for line in lines {
            let color: CGColor
            switch languages.language(of: line.text) {
            case .italian: color = Palette.italian
            case .foreign: color = Palette.foreign
            case .unknown: color = Palette.unknown
            }
            sketch.box(line.box, color: color, lineWidth: 1.5)
        }
        for (index, block) in blocks.enumerated() {
            sketch.box(block.box.insetBy(dx: -0.003, dy: -0.002), color: Palette.block, lineWidth: 3)
            sketch.label("\(index + 1)", at: block.box, color: Palette.block, size: 20)
        }
        if let annotated = sketch.image() {
            writeJPEG(annotated, to: output.appendingPathComponent("\(frame)-ocr.jpg"))
        }
    }

    summary += "## \(frame)\n\nOCR \(Int(accurateMs)) ms accurate (\(lines.count) lines), \(Int(fastMs)) ms fast (\(fastLines.count) lines). \(blocks.count) blocks.\n\n"
    summary += "Lines:\n\n"
    for line in lines {
        summary += "- `\(name(languages.language(of: line.text)))` \(line.text)  _\(numbers(line.box).map { String(format: "%.3f", $0) }.joined(separator: " "))_\n"
    }
    summary += "\nBlocks:\n\n"
    for (index, block) in blocks.enumerated() {
        summary += "\(index + 1). \(block.text)\n"
    }
    summary += "\n"
    print("\(frame): \(lines.count) lines, \(blocks.count) blocks, \(Int(accurateMs)) ms")
}

try summary.write(to: output.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
try comparison.write(to: output.appendingPathComponent("bands.md"), atomically: true, encoding: .utf8)
