// Plain executable tests for the camera-free logic in Traduci/Core.
// CI builds them with: swiftc Traduci/Core/*.swift Tests/CoreTests/main.swift
import CoreGraphics
import Foundation

var failures = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !condition() {
        failures += 1
        print("FAIL line \(line): \(message)")
    }
}

func approx(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }

func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat = 0.02) -> OCRLine {
    OCRLine(text: text, box: CGRect(x: x, y: y, width: width, height: height))
}

func texts(_ lines: [OCRLine]) -> [String] {
    TextBlockBuilder.blocks(from: lines).map(\.text)
}

// MARK: Aspect-fill mapping (1080×1920 portrait frame on a 402×874 pt screen)

do {
    let mapper = AspectFillMapper(imageSize: CGSize(width: 1080, height: 1920), viewSize: CGSize(width: 402, height: 874))
    let whole = mapper.viewRect(for: CGRect(x: 0, y: 0, width: 1, height: 1))
    expect(approx(whole.minY, 0) && approx(whole.height, 874), "fills the height: \(whole)")
    expect(approx(whole.midX, 201), "centred horizontally: \(whole)")
    let visible = mapper.visibleRect
    let expectedMinX = (1 - 402.0 / (1080.0 * 874.0 / 1920.0)) / 2
    expect(approx(visible.minX, expectedMinX) && approx(visible.maxX, 1 - expectedMinX), "crops left/right evenly: \(visible)")
    expect(approx(visible.minY, 0) && approx(visible.height, 1), "keeps every row: \(visible)")
    let empty = AspectFillMapper(imageSize: CGSize(width: 1080, height: 1920), viewSize: .zero)
    expect(empty.visibleRect == CGRect(x: 0, y: 0, width: 1, height: 1), "before layout, everything counts as visible")
}

// MARK: Line grouping

do {
    let result = texts([
        line("La chiesa fu costruita", 0.1, 0.100, 0.6),
        line("nel dodicesimo secolo.", 0.1, 0.125, 0.55),
        line("Spaghetti alla carbonara", 0.1, 0.300, 0.6),
        line("Penne all'arrabbiata", 0.1, 0.325, 0.5),
    ])
    expect(result == ["La chiesa fu costruita nel dodicesimo secolo.", "Spaghetti alla carbonara", "Penne all'arrabbiata"],
           "paragraph merges, menu items stay separate: \(result)")
}

do {
    let result = texts([line("Il museo fu costrui-", 0.1, 0.1, 0.6), line("to nel 1300", 0.1, 0.125, 0.4)])
    expect(result == ["Il museo fu costruito nel 1300"], "hyphenated word rejoins: \(result)")
}

do {
    let result = texts([line("USCITA", 0.3, 0.40, 0.4, 0.05), line("DI SICUREZZA", 0.2, 0.46, 0.6, 0.05)])
    expect(result == ["USCITA DI SICUREZZA"], "two-line sign joined by a preposition: \(result)")
}

do {
    let result = texts([line("Visita guidata della", 0.1, 0.1, 0.5), line("Galleria degli Uffizi", 0.1, 0.125, 0.5)])
    expect(result == ["Visita guidata della Galleria degli Uffizi"], "line ending in an article continues: \(result)")
}

do {
    let result = texts([line("ANTIPASTI", 0.1, 0.1, 0.4, 0.04), line("BRUSCHETTA AL POMODORO", 0.1, 0.15, 0.6, 0.04)])
    expect(result == ["ANTIPASTI", "BRUSCHETTA AL POMODORO"], "all-caps menu lines stay separate: \(result)")
}

do {
    let blocks = TextBlockBuilder.blocks(from: [
        line("Primi piatti e", 0.05, 0.200, 0.35),
        line("Secondi piatti e", 0.55, 0.200, 0.35),
        line("contorni misti", 0.05, 0.225, 0.30),
        line("dolci della casa", 0.55, 0.225, 0.30),
    ])
    expect(Set(blocks.map(\.text)) == ["Primi piatti e contorni misti", "Secondi piatti e dolci della casa"],
           "columns don't bleed into each other: \(blocks.map(\.text))")
    expect(blocks.allSatisfy { $0.lineCount == 2 }, "each column block has two lines")
}

do {
    expect(texts([line("Benvenuti a", 0.1, 0.1, 0.4), line("firenze", 0.1, 0.3, 0.4)]).count == 2, "distant lines stay separate")
    expect(texts([line("Grande", 0.1, 0.1, 0.4, 0.08), line("piccolo", 0.1, 0.19, 0.2, 0.02)]).count == 2, "different sizes stay separate")
    expect(texts([line("12,50 €", 0.7, 0.3, 0.2)]).isEmpty, "a bare price isn't worth translating")
    expect(texts([line("  Vietato   fumare ", 0.1, 0.1, 0.5)]) == ["Vietato fumare"], "whitespace collapsed")
}

// MARK: Text helpers

do {
    expect(TextNormalizer.translationInput("USCITA DI SICUREZZA") == "Uscita di sicurezza", "ALL CAPS becomes sentence case")
    expect(TextNormalizer.translationInput("«VIETATO FUMARE»") == "«Vietato fumare»", "leading punctuation kept")
    expect(TextNormalizer.translationInput("Uscita di sicurezza") == "Uscita di sicurezza", "mixed case untouched")
    expect(TextNormalizer.translationInput("IVA") == "IVA", "short acronyms untouched")
    expect(TextNormalizer.isEffectivelySame("Tiramisù", "Tiramisu"), "accents and case ignored")
    expect(!TextNormalizer.isEffectivelySame("Uscita", "Exit"), "different words differ")
    expect(TextNormalizer.isWorthTranslating("Coperto 2,50€"), "words with a price are kept")
    expect(!TextNormalizer.isWorthTranslating("Tel. 055 123456"), "phone numbers are skipped")
}

// MARK: Overlay tracking

do {
    var tracker = OverlayTracker()
    let exit = TextBlock(text: "Uscita", box: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.05), lineCount: 1)
    tracker.update(with: [exit], at: 1.0, translations: [:])
    let id = tracker.items.first?.id
    expect(tracker.items.count == 1 && tracker.items[0].translation == nil, "new text is tracked untranslated")
    expect(tracker.sourcesByPriority(seenAt: 1.0) == ["Uscita"], "and queued for translation")

    tracker.apply(translation: "Exit", for: "Uscita")
    expect(tracker.items[0].translation == "Exit" && tracker.items[0].translationIsCurrent, "translation lands")

    var jittered = exit
    jittered.box.origin.x += 0.004
    tracker.update(with: [jittered], at: 1.1, translations: ["Uscita": "Exit"])
    expect(tracker.items.count == 1 && tracker.items[0].id == id, "jittered text keeps its overlay")
    expect(approx(tracker.items[0].box.minX, 0.402), "jitter is damped: \(tracker.items[0].box)")

    var moved = exit
    moved.box.origin.y += 0.03
    tracker.update(with: [moved], at: 1.15, translations: ["Uscita": "Exit"])
    expect(tracker.items[0].id == id && tracker.items[0].box == moved.box, "real movement is followed immediately")

    var misread = moved
    misread.text = "Uscita."
    tracker.update(with: [misread], at: 1.2, translations: ["Uscita": "Exit"])
    expect(tracker.items[0].translation == "Exit" && !tracker.items[0].translationIsCurrent,
           "old translation stays up while the new reading is translated")
    expect(tracker.sourcesByPriority(seenAt: 1.2) == ["Uscita."], "new reading is queued")

    tracker.update(with: [], at: 1.3, translations: [:])
    expect(tracker.items.count == 1, "a one-frame OCR dropout is held")
    expect(tracker.sourcesByPriority(seenAt: 1.3).isEmpty, "held overlays aren't re-queued")
    tracker.update(with: [], at: 2.0, translations: [:])
    expect(tracker.items.isEmpty, "gone text expires")
}

do {
    var tracker = OverlayTracker()
    let sign = TextBlock(text: "Vietato fumare", box: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.04), lineCount: 1)
    tracker.update(with: [sign], at: 1.0, translations: ["Vietato fumare": "No smoking"])
    let id = tracker.items.first?.id
    var panned = sign
    panned.box.origin.y += 0.3
    tracker.update(with: [panned], at: 1.1, translations: ["Vietato fumare": "No smoking"])
    expect(tracker.items.count == 1 && tracker.items[0].id == id && tracker.items[0].box == panned.box,
           "fast pan: same words follow the text instead of leaving a ghost behind")

    let other = TextBlock(text: "Ingresso", box: CGRect(x: 0.2, y: 0.8, width: 0.3, height: 0.04), lineCount: 1)
    tracker.update(with: [panned, other], at: 1.2, translations: [:])
    expect(tracker.items.count == 2 && Set(tracker.items.map(\.source)) == ["Vietato fumare", "Ingresso"],
           "unrelated text gets its own overlay")
}

do {
    var tracker = OverlayTracker()
    tracker.update(with: [
        TextBlock(text: "Angolo", box: CGRect(x: 0.0, y: 0.0, width: 0.2, height: 0.05), lineCount: 1),
        TextBlock(text: "Centro", box: CGRect(x: 0.4, y: 0.45, width: 0.2, height: 0.05), lineCount: 1),
        TextBlock(text: "Centro", box: CGRect(x: 0.4, y: 0.6, width: 0.2, height: 0.05), lineCount: 1),
    ], at: 5, translations: ["Angolo": "Corner"])
    expect(tracker.sourcesByPriority(seenAt: 5) == ["Centro", "Angolo"], "centre first, duplicates once")
    expect(tracker.items.first { $0.source == "Angolo" }?.translation == "Corner", "cached translations show immediately")
}

do {
    var tracker = OverlayTracker()
    let bread = TextBlock(text: "Pane", box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05), lineCount: 1)
    let wine = TextBlock(text: "Vino", box: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.05), lineCount: 1)
    tracker.update(with: [bread, wine], at: 1, translations: [:])
    var nudged = bread
    nudged.box.origin.x += 0.004
    tracker.update(with: [nudged], at: 1.05, exact: true, translations: [:])
    expect(tracker.items.count == 1 && tracker.items[0].box == nudged.box, "a frozen frame shows exactly what it contains")
}

if failures == 0 {
    print("All core tests passed")
} else {
    print("\(failures) core test(s) failed")
    exit(1)
}
