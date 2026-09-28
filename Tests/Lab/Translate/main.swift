import Foundation
import Translation

// Real English for the menu lab, from Apple's on-device translator on the Mac (macOS 26): every
// source the app would translate, read from the lab's results, the way the app sends it. Each
// dish name is also translated with its description after it, to see what context changes.
// Needs the Italian language pack on the Mac (System Settings → General → Language & Region →
// Translation Languages). Usage: translate LAB_OUT_DIR
// Writes LAB_OUT_DIR/translations.md and LAB_OUT_DIR/english.json (Italian → English, for the
// Simulator's demo mode).

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    print("usage: translate LAB_OUT_DIR")
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])
let italian = Locale.Language(identifier: "it"), english = Locale.Language(identifier: "en")
let status = await LanguageAvailability().status(from: italian, to: english)
guard status == .installed else {
    print("Italian → English isn't installed on this Mac (\(status)): no translations.")
    exit(0)
}
let session = TranslationSession(installedSource: italian, target: english)

struct Dish {
    let title: String
    let details: [String]
}

var dishes: [String: [Dish]] = [:] // by frame
let files = ((try? FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension == "json" && $0.lastPathComponent != "english.json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
for file in files {
    guard let json = try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
          let entries = json["entries"] as? [[String: Any]] else { continue }
    dishes[file.deletingPathExtension().lastPathComponent] = entries.compactMap { entry in
        guard entry["foreign"] as? Bool != true, let title = entry["title"] as? String else { return nil }
        return Dish(title: title, details: entry["details"] as? [String] ?? [])
    }
}

var cache: [String: String] = [:]
var sources: Set<String> = [] // what the app itself sends: the english.json for demo mode
var milliseconds: [Double] = []
@MainActor func translate(_ text: String) async -> String {
    if let known = cache[text] { return known }
    let started = Date()
    let result = (try? await session.translate(TextNormalizer.translationInput(text)).targetText) ?? "(failed)"
    milliseconds.append(Date().timeIntervalSince(started) * 1000)
    cache[text] = result
    return result
}

var report = "# Menu lab: English\n\nApple's on-device translator, as the app sends each line. \"With its description\": the name translated with what follows it, to show what context changes.\n"
var changedByContext = 0, withDescription = 0
for frame in dishes.keys.sorted() {
    report += "\n## \(frame)\n\n| Italian | English | With its description |\n|---|---|---|\n"
    for dish in dishes[frame] ?? [] {
        let alone = await translate(dish.title)
        sources.insert(dish.title)
        var inContext = ""
        if !dish.details.isEmpty {
            let whole = await translate(dish.title + ": " + dish.details.joined(separator: "; "))
            inContext = whole
            withDescription += 1
            let lead = whole.split(separator: ":", maxSplits: 1).first.map(String.init) ?? whole
            if !TextNormalizer.isEffectivelySame(lead, alone) { changedByContext += 1 }
        }
        report += "| \(dish.title) | \(alone) | \(inContext) |\n"
        for detail in dish.details {
            sources.insert(detail)
            report += "| ↳ \(detail) | \(await translate(detail)) | |\n"
        }
    }
}
let sorted = milliseconds.sorted()
let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
let summary = "\(cache.count) lines, median \(Int(median)) ms each. Context changed the name of \(changedByContext) of \(withDescription) dishes with a description."
report = report.replacingOccurrences(of: "context changes.\n", with: "context changes.\n\n\(summary)\n", options: [], range: report.range(of: "context changes.\n"))
try report.write(to: output.appendingPathComponent("translations.md"), atomically: true, encoding: .utf8)
let canned = cache.filter { sources.contains($0.key) }
try JSONSerialization.data(withJSONObject: canned, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("english.json"))
print(summary)
