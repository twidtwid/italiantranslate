import CoreGraphics
import Foundation
import Vision

// Runs Vision's document reader (iOS 26 / macOS 26) on the lab frames, to compare its paragraphs,
// tables and lists with the app's own grouping. Usage: lab-documents FRAMES_DIR OUT_DIR

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: lab-documents FRAMES_DIR OUT_DIR")
    exit(2)
}
let input = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

/// Vision's normalized rects have the origin at the bottom left; the app's at the top left.
func topLeft(_ rect: NormalizedRect) -> CGRect {
    let box = rect.cgRect
    return CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
}

func box(of text: DocumentObservation.Container.Text) -> CGRect {
    text.lines.map { topLeft($0.boundingBox) }.reduce(CGRect.null) { $0.union($1) }
}

var summary = "# Document reader\n\n"
for url in frames(in: input) {
    guard let image = loadImage(url) else { continue }
    let frame = url.deletingPathExtension().lastPathComponent
    var request = RecognizeDocumentsRequest()
    request.textRecognitionOptions.recognitionLanguages = [Locale.Language(identifier: "it-IT")]
    request.textRecognitionOptions.automaticallyDetectLanguage = false
    request.textRecognitionOptions.useLanguageCorrection = true
    request.textRecognitionOptions.minimumTextHeightFraction = 1.0 / 64.0

    let started = Date()
    let observations = try await request.perform(on: image, orientation: .up)
    let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
    guard let document = observations.first?.document else {
        summary += "## \(frame)\n\nNo document (\(milliseconds) ms).\n\n"
        continue
    }

    let paragraphs = document.paragraphs
    let tables = document.tables
    let lists = document.lists
    try writeJSON([
        "frame": frame,
        "ms": milliseconds,
        "title": document.title?.transcript ?? "",
        "paragraphs": paragraphs.map { paragraph in
            [
                "text": paragraph.transcript,
                "box": numbers(box(of: paragraph)),
                "lines": paragraph.lines.map { line in
                    ["text": line.topCandidates(1).first?.string ?? "", "box": numbers(topLeft(line.boundingBox))]
                },
            ] as [String: Any]
        },
        "tables": tables.map { table in
            table.rows.map { row in
                row.map { cell in
                    [
                        "text": cell.content.text.transcript,
                        "row": [cell.rowRange.lowerBound, cell.rowRange.upperBound],
                        "column": [cell.columnRange.lowerBound, cell.columnRange.upperBound],
                        "box": numbers(box(of: cell.content.text)),
                    ] as [String: Any]
                }
            }
        },
        "lists": lists.map { list in
            list.items.map { ["marker": $0.markerString, "text": $0.itemString] }
        },
    ], to: output.appendingPathComponent("\(frame)-documents.json"))

    if let sketch = Sketch(image: image) {
        for (index, paragraph) in paragraphs.enumerated() {
            let rect = box(of: paragraph)
            guard !rect.isNull else { continue }
            sketch.box(rect.insetBy(dx: -0.003, dy: -0.002), color: Palette.block, lineWidth: 3)
            sketch.label("P\(index + 1)", at: rect, color: Palette.block, size: 18)
        }
        for table in tables {
            for row in table.rows {
                for cell in row {
                    let rect = box(of: cell.content.text)
                    guard !rect.isNull else { continue }
                    sketch.box(rect, color: Palette.table, lineWidth: 2)
                }
            }
        }
        if let annotated = sketch.image() {
            writeJPEG(annotated, to: output.appendingPathComponent("\(frame)-documents.jpg"))
        }
    }

    summary += "## \(frame)\n\n\(milliseconds) ms. Title: \(document.title?.transcript ?? "none"). "
    summary += "\(paragraphs.count) paragraphs, \(tables.count) tables, \(lists.count) lists.\n\n"
    for (index, paragraph) in paragraphs.enumerated() {
        summary += "P\(index + 1). \(paragraph.transcript.replacingOccurrences(of: "\n", with: " ⏎ "))\n"
    }
    for (number, table) in tables.enumerated() {
        summary += "\nTable \(number + 1):\n\n"
        for row in table.rows {
            summary += "| " + row.map { $0.content.text.transcript.replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") + " |\n"
        }
    }
    for (number, list) in lists.enumerated() {
        summary += "\nList \(number + 1):\n\n"
        for item in list.items {
            summary += "- [\(item.markerString)] \(item.itemString.replacingOccurrences(of: "\n", with: " "))\n"
        }
    }
    summary += "\n"
    print("\(frame): \(paragraphs.count) paragraphs, \(tables.count) tables, \(lists.count) lists, \(milliseconds) ms")
}

try summary.write(to: output.appendingPathComponent("documents.md"), atomically: true, encoding: .utf8)
