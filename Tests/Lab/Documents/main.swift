import CoreGraphics
import Foundation
import Vision

// An experiment for the menu lab: Vision's document reader (macOS 26 / iOS 26), which finds
// paragraphs, lists and tables itself, against the app's own menu reader on the same frames.
// Usage: documents FRAMES_DIR LAB_OUT_DIR   (LAB_OUT_DIR: the lab's results, for comparison)
// Writes LAB_OUT_DIR/documents.md.

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: documents FRAMES_DIR LAB_OUT_DIR")
    exit(2)
}
let output = URL(fileURLWithPath: arguments[2])
var request = RecognizeDocumentsRequest()
request.textRecognitionOptions.recognitionLanguages = [Locale.Language(identifier: "it-IT")]
request.textRecognitionOptions.automaticallyDetectLanguage = false

/// Dishes with a price, as the app's reader found them (the lab's JSON).
func pricedEntries(_ frame: String) -> Int {
    guard let data = try? Data(contentsOf: output.appendingPathComponent("\(frame).json")),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let entries = json["entries"] as? [[String: Any]] else { return 0 }
    return entries.filter { $0["price"] is String }.count
}

var report = "# Menu lab: Vision's document reader\n\n| frame | ms | paragraphs | lists (items) | tables (rows × columns) | rows with a price | the app's priced dishes |\n|---|---|---|---|---|---|---|\n"
var samples = ""
for url in frames(in: URL(fileURLWithPath: arguments[1])) where url.lastPathComponent.contains("-page.") {
    guard let image = loadImage(url) else { continue }
    let frame = url.deletingPathExtension().lastPathComponent
    let started = Date()
    guard let document = try? await request.perform(on: image).first else { continue }
    let ms = Int(Date().timeIntervalSince(started) * 1000)
    let content = document.document
    let tables = content.tables.map { "\($0.rows.count) × \($0.columns.count)" }.joined(separator: ", ")
    let rows = content.tables.flatMap(\.rows)
    let priced = rows.filter { row in row.contains { Price.isWholeLine($0.content.text.transcript) } }.count
    let items = content.lists.map { "\($0.items.count)" }.joined(separator: ", ")
    report += "| \(frame) | \(ms) | \(content.paragraphs.count) | \(content.lists.count) (\(items)) | \(tables.isEmpty ? "none" : tables) | \(priced) | \(pricedEntries(frame)) |\n"

    samples += "\n## \(frame)\n\n"
    for (index, table) in content.tables.enumerated() {
        samples += "Table \(index + 1):\n\n"
        for row in table.rows.prefix(12) {
            samples += "- " + row.map { $0.content.text.transcript.replacingOccurrences(of: "\n", with: " / ") }.joined(separator: " ‖ ") + "\n"
        }
        samples += "\n"
    }
    samples += "Paragraphs:\n\n" + content.paragraphs.prefix(12).map { "- " + $0.transcript.replacingOccurrences(of: "\n", with: " / ") }.joined(separator: "\n") + "\n"
    print("\(frame): \(ms) ms, \(content.paragraphs.count) paragraphs, tables \(tables.isEmpty ? "none" : tables)")
}
try (report + samples).write(to: output.appendingPathComponent("documents.md"), atomically: true, encoding: .utf8)
