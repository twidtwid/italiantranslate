import Foundation
import Translation
// Apple Translation on every benchmark line, as the app sends it: without and with the dish glossary.
// Usage: apple DIR (needs the Italian pack on the Mac). Writes DIR/candidates/apple{,-glossary}.json.
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: dir.appendingPathComponent("candidates"), withIntermediateDirectories: true)
let rows = try! JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("sources.json"))) as! [[String: Any]]
let session = TranslationSession(installedSource: Locale.Language(identifier: "it"), target: Locale.Language(identifier: "en"))
for glossary in [false, true] {
    var out: [String: String] = [:]
    var times: [Double] = []
    for row in rows {
        let text = row["text"] as! String
        let started = Date()
        if glossary, case .known(let english) = Glossary.prepare(text) {
            out[text] = english
        } else {
            var input = TextNormalizer.translationInput(text)
            if glossary, case .translate(let rewritten) = Glossary.prepare(text) { input = rewritten }
            out[text] = (try? await session.translate(input).targetText) ?? "(failed)"
        }
        times.append(Date().timeIntervalSince(started) * 1000)
    }
    times.sort()
    let name = glossary ? "apple-glossary" : "apple"
    let summary: [String: Any] = ["name": name, "repo": "Apple Translation (macOS 26)", "median_ms": Int(times[times.count / 2]), "p90_ms": Int(times[times.count * 9 / 10])]
    let data = try! JSONSerialization.data(withJSONObject: ["summary": summary, "translations": out], options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: dir.appendingPathComponent("candidates/\(name).json"))
    print(summary)
}
