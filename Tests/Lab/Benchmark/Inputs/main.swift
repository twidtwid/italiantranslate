// What the app sends the translator for each benchmark line. Usage: inputs DIR/sources.json > DIR/inputs.json
import Foundation
let rows = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
var out: [String: String] = [:]
for row in rows {
    let text = row["text"] as! String
    out[text] = TextNormalizer.translationInput(text)
}
FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]))
