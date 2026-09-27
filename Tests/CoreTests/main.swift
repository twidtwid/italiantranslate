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

// MARK: TestFlight feedback: dense text

do {
    // Hotel fire notice: bullets were merged into one blob because a line ended in "non".
    let bullets = texts([
        line("• Uscire dalla camera chiudendo la porta, ma non", 0.1, 0.100, 0.7),
        line("• Avvisare immediatamente il personale di servizio", 0.1, 0.125, 0.7),
        line("• Non ostruire le uscite con", 0.1, 0.150, 0.5),
        line("bagagli o altri oggetti.", 0.1, 0.175, 0.4),
        line("1. Mantenere la calma", 0.1, 0.200, 0.4),
        line("2. Uscire dalla camera", 0.1, 0.225, 0.4),
    ])
    expect(bullets == ["• Uscire dalla camera chiudendo la porta, ma non", "• Avvisare immediatamente il personale di servizio",
                       "• Non ostruire le uscite con bagagli o altri oggetti.", "1. Mantenere la calma", "2. Uscire dalla camera"],
           "each bullet is its own block; a bullet's wrapped line still joins it: \(bullets)")

    // Big red heading over a smaller subtitle that starts with "IN": keep them apart.
    let headings = texts([
        line("COSA FARE IN CASO DI INCENDIO", 0.1, 0.30, 0.6, 0.030),
        line("IN CASO DI INCENDIO NELLA VOSTRA CAMERA", 0.1, 0.335, 0.6, 0.022),
    ])
    expect(headings.count == 2, "heading and subtitle stay separate: \(headings)")
    expect(TextNormalizer.startsListItem("10) Chiamare il 112") && !TextNormalizer.startsListItem("1300 anni fa")
           && !TextNormalizer.startsListItem("2,50 €"), "list markers are recognised, numbers aren't")
}

// MARK: Reading similarity

do {
    expect(TextNormalizer.similarity("Uscita di sicurezza", "Usclta di sicurezza") > 0.8, "a one-letter misread is still the same text")
    expect(TextNormalizer.similarity("Uscita", "Ingresso") < 0.3, "different words aren't")
}

// MARK: TestFlight feedback: bilingual menus (screen recordings)

do {
    let detector = LanguageDetector()
    expect(detector.language(of: "Beef Tartare with sautéed mushrooms and parmesan foam") == .english, "English menu line")
    expect(detector.language(of: "Confit salt cod with creamy rice bean purée, tomato & red onion compote") == .english, "English menu line 2")
    expect(detector.language(of: "Tartare di manzo con funghi saltati e spuma di parmigiano") == .italian, "Italian menu line")
    expect(detector.language(of: "Baccalà confit su vellutata di fagioli risina, composta di pomodoro") == .italian, "Italian menu line 2")
    expect(detector.language(of: "€ 29,00") == .unknown, "prices have no language")

    // Italian, then the menu's own English in smaller italics, then the price.
    let menu = TextBlockBuilder.blocks(from: [
        line("Tartare di manzo con funghi saltati e spuma di parmigiano", 0.10, 0.300, 0.80),
        line("Beef Tartare with sautéed mushrooms and parmesan foam", 0.15, 0.325, 0.70, 0.017),
        line("€ 29,00", 0.42, 0.347, 0.16),
        line("Pappardella fatta in casa ripiena di pappa al pomodoro, crema di aglione e", 0.08, 0.400, 0.84),
        line("olio al basilico", 0.40, 0.425, 0.20),
        line("Homemade stuffed pappardelle filled with \"pappa al pomodoro\", served with", 0.10, 0.450, 0.80, 0.017),
        line("aglione garlic cream and basil oil", 0.30, 0.470, 0.40, 0.017),
        line("€ 35,00", 0.42, 0.492, 0.16),
    ], language: detector.language(of:))
    expect(menu.map(\.text) == ["Tartare di manzo con funghi saltati e spuma di parmigiano",
                                "Pappardella fatta in casa ripiena di pappa al pomodoro, crema di aglione e olio al basilico"],
           "only the Italian gets translated; the menu's English is left alone and never glued on: \(menu.map(\.text))")

    // One printed line that Vision split in two is glued back; a price further out is not.
    let split = TextBlockBuilder.blocks(from: [
        line("Baccalà confit su vellutata di fagioli", 0.05, 0.30, 0.50),
        line("risina, composta di pomodoro", 0.57, 0.302, 0.23),
        line("€ 38,00", 0.90, 0.30, 0.08),
    ], language: detector.language(of:))
    expect(split.map(\.text) == ["Baccalà confit su vellutata di fagioli risina, composta di pomodoro"], "split line rejoined: \(split.map(\.text))")

    // Italian and English side by side in two columns stay apart.
    let columns = TextBlockBuilder.blocks(from: [
        line("Tartare di manzo con funghi saltati", 0.05, 0.30, 0.42),
        line("Beef tartare with sautéed mushrooms", 0.49, 0.30, 0.42),
    ], language: detector.language(of:))
    expect(columns.map(\.text) == ["Tartare di manzo con funghi saltati"], "two-language columns stay apart: \(columns.map(\.text))")

}

// MARK: Reading a still: zoom and pan

do {
    let base = AspectFillMapper(imageSize: CGSize(width: 1080, height: 1920), viewSize: CGSize(width: 402, height: 874))
    var zoomed = base
    zoomed.zoom = 2
    expect(approx(zoomed.displayedSize.height, base.displayedSize.height * 2), "zoom magnifies")
    expect(approx(zoomed.imageFrame.midX, 201) && approx(zoomed.imageFrame.midY, 437), "zoom stays centred")
    let far = zoomed.clamped(CGSize(width: 5_000, height: -5_000))
    expect(approx(far.width, (zoomed.displayedSize.width - 402) / 2) && approx(far.height, -(zoomed.displayedSize.height - 874) / 2),
           "pan stops at the image edge: \(far)")
    zoomed.pan = CGSize(width: 50, height: 0)
    let line = CGRect(x: 0.2, y: 0.5, width: 0.3, height: 0.02)
    expect(approx(zoomed.viewRect(for: line).minX, base.viewRect(for: line).minX * 2 - 201 + 50),
           "captions follow the zoomed, panned still exactly")
    expect(base.clamped(CGSize(width: 30, height: 30)) == CGSize(width: 30, height: 0), "unzoomed: only the cropped axis pans")
}

// MARK: Reading a still: queue and page changes

do {
    let blocks = [
        TextBlock(text: "Angolo", box: CGRect(x: 0.0, y: 0.0, width: 0.2, height: 0.05), lineCount: 1),
        TextBlock(text: "Centro", box: CGRect(x: 0.4, y: 0.45, width: 0.2, height: 0.05), lineCount: 1),
        TextBlock(text: "Centro", box: CGRect(x: 0.4, y: 0.6, width: 0.2, height: 0.05), lineCount: 1),
    ]
    expect(Captions.priority(blocks) == ["Centro", "Angolo"], "centre first, duplicates once")

    let page = [
        TextBlock(text: "Tartare di manzo con funghi saltati", box: CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.02), lineCount: 1),
        TextBlock(text: "Spaghetti della tradizione al pomodoro", box: CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.02), lineCount: 1),
        TextBlock(text: "Tagliolini fatti in casa con bisque", box: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.02), lineCount: 1),
    ]
    let captions = page.map { Caption(block: $0, translation: nil) }
    var glance = page
    glance[0].text = "Tartare di manzo con funghi saltatl" // same page, OCR a hair off
    expect(!Captions.sceneChanged(from: captions, to: glance), "same page, slightly misread: keep reading")
    expect(!Captions.sceneChanged(from: captions, to: [page[0]]), "a glance with barely any text proves nothing")
    let next = [
        TextBlock(text: "Tiramisù della casa", box: CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.02), lineCount: 1),
        TextBlock(text: "Panna cotta ai frutti di bosco", box: CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.02), lineCount: 1),
    ]
    expect(Captions.sceneChanged(from: captions, to: next), "moved on to the desserts: aim again")

    var same = Caption(block: page[0], translation: "Tiramisu")
    same.source = "Tiramisù"
    expect(!same.showsTranslation, "a translation that only drops an accent isn't drawn")
    expect(Caption(block: page[0], translation: "Beef tartare").showsTranslation, "a real translation is")
}

// MARK: Reading a still: paper and ink colours

func image(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    draw(context)
    return context.makeImage()!
}

func near(_ rgb: InkSampler.RGB, _ r: Double, _ g: Double, _ b: Double) -> Bool {
    abs(rgb.red - r) < 0.08 && abs(rgb.green - g) < 0.08 && abs(rgb.blue - b) < 0.08
}

do {
    // Top half red, bottom half blue (Core Graphics draws y-up): proves rows are read top-first.
    let halves = InkSampler(image: image(width: 100, height: 200) { context in
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); context.fill(CGRect(x: 0, y: 100, width: 100, height: 100))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
    })!
    expect(near(halves.colors(for: CGRect(x: 0.3, y: 0.1, width: 0.4, height: 0.1)).paper, 1, 0, 0), "top of the image is on top")
    expect(near(halves.colors(for: CGRect(x: 0.3, y: 0.8, width: 0.4, height: 0.1)).paper, 0, 0, 1), "bottom is at the bottom")

    // Cream paper, dark brown "letters" (vertical strokes) in the middle.
    let menu = InkSampler(image: image(width: 400, height: 400) { context in
        context.setFillColor(red: 0.95, green: 0.91, blue: 0.83, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        context.setFillColor(red: 0.2, green: 0.12, blue: 0.08, alpha: 1)
        for x in stride(from: 100, to: 300, by: 12) { context.fill(CGRect(x: x, y: 190, width: 4, height: 20)) }
    })!
    let printed = menu.colors(for: CGRect(x: 0.25, y: 0.475, width: 0.5, height: 0.05))
    expect(near(printed.paper, 0.95, 0.91, 0.83), "paper is the page colour: \(printed.paper)")
    expect(near(printed.ink, 0.2, 0.12, 0.08), "ink is the print colour: \(printed.ink)")

    // White chalk on a blackboard.
    let board = InkSampler(image: image(width: 400, height: 400) { context in
        context.setFillColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        context.setFillColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)
        for x in stride(from: 100, to: 300, by: 12) { context.fill(CGRect(x: x, y: 190, width: 4, height: 20)) }
    })!
    let chalk = board.colors(for: CGRect(x: 0.25, y: 0.475, width: 0.5, height: 0.05))
    expect(chalk.paper.luminance < 0.15 && chalk.ink.luminance > 0.8, "light ink on a dark page")

    // Barely-there text: fall back to black on light paper, so the English is always legible.
    let faint = InkSampler(image: image(width: 200, height: 200) { context in
        context.setFillColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
    })!.colors(for: CGRect(x: 0.2, y: 0.4, width: 0.6, height: 0.1))
    expect(faint.ink.luminance < 0.2, "no visible ink: black on light paper")
}

if failures == 0 {
    print("All core tests passed")
} else {
    print("\(failures) core test(s) failed")
    exit(1)
}
