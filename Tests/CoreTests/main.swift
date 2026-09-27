// Plain executable tests for the camera-free logic in Traduci/Core.
// CI builds them with: swiftc Traduci/Core/*.swift Tests/CoreTests/main.swift, and runs them from the
// repository root (the menu fixtures are real OCR output from the lab: Tests/Lab).
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

let detector = LanguageDetector()

func read(_ lines: [OCRLine], language: Bool = true) -> [MenuEntry] {
    MenuReader.entries(from: lines, language: language ? detector.language(of:) : { _ in .unknown })
}

func titles(_ lines: [OCRLine]) -> [String] {
    read(lines, language: false).map(\.title)
}

/// A frame the lab read: the lines exactly as Vision returned them.
func fixture(_ name: String) -> [MenuEntry] {
    let url = URL(fileURLWithPath: "Tests/CoreTests/Fixtures/\(name).json")
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let width = json["width"] as? Double, let height = json["height"] as? Double,
          let lines = json["lines"] as? [[String: Any]] else {
        failures += 1
        print("FAIL: can't read fixture \(name) (run from the repository root)")
        return []
    }
    let ocr = lines.compactMap { item -> OCRLine? in
        guard let text = item["text"] as? String, let box = item["box"] as? [Double], box.count == 4 else { return nil }
        let corners = (item["corners"] as? [Double]) ?? []
        return OCRLine(
            text: text,
            box: CGRect(x: box[0], y: box[1], width: box[2], height: box[3]),
            corners: stride(from: 0, to: corners.count - 1, by: 2).map { CGPoint(x: corners[$0], y: corners[$0 + 1]) }
        )
    }
    return MenuReader.entries(from: ocr, aspect: height / width, language: detector.language(of:))
}

func entry(_ entries: [MenuEntry], _ title: String) -> MenuEntry? {
    entries.first { $0.title == title }
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
    let box = CGRect(x: 0.2, y: 0.5, width: 0.3, height: 0.02)
    expect(approx(zoomed.viewRect(for: box).minX, base.viewRect(for: box).minX * 2 - 201 + 50),
           "captions follow the zoomed, panned still exactly")
    expect(base.clamped(CGSize(width: 30, height: 30)) == CGSize(width: 30, height: 0), "unzoomed: only the cropped axis pans")

    // A still shown above the reading panel: wider than tall, so it fills the width and pans up and down.
    let above = AspectFillMapper(imageSize: CGSize(width: 1080, height: 1920), viewSize: CGSize(width: 402, height: 400))
    expect(approx(above.displayedSize.width, 402), "fills the width above the panel")
    let centred = above.centering(CGRect(x: 0.1, y: 0.6, width: 0.3, height: 0.02))
    expect(approx(above.clamped(centred).height, centred.height) && centred.height < 0, "a line low on the page scrolls up into view")
}

// MARK: Text helpers

do {
    expect(TextNormalizer.translationInput("USCITA DI SICUREZZA") == "Uscita di sicurezza", "ALL CAPS becomes sentence case")
    expect(TextNormalizer.translationInput("«VIETATO FUMARE»") == "«Vietato fumare»", "leading punctuation kept")
    expect(TextNormalizer.translationInput("Uscita di sicurezza") == "Uscita di sicurezza", "mixed case untouched")
    expect(TextNormalizer.translationInput("IVA") == "IVA", "short acronyms untouched")
    expect(TextNormalizer.translationInput("CROSTONE") == "Crostone", "a shouted dish name")
    expect(TextNormalizer.translationInput("pecorino senese,noci,miele al tartufo") == "pecorino senese, noci, miele al tartufo",
           "squeezed lists get their spaces back")
    expect(TextNormalizer.translationInput("Mozzarella di bufala D.O.P. con acciughe") == "Mozzarella di bufala D.O.P. con acciughe",
           "abbreviations untouched")
    expect(TextNormalizer.isEffectivelySame("Tiramisù", "Tiramisu"), "accents and case ignored")
    expect(!TextNormalizer.isEffectivelySame("Uscita", "Exit"), "different words differ")
    expect(TextNormalizer.isWorthTranslating("Coperto 2,50€"), "words with a price are kept")
    expect(!TextNormalizer.isWorthTranslating("Tel. 055 123456"), "phone numbers are skipped")
    expect(TextNormalizer.removingListMarker("• Filetto di manzo") == "Filetto di manzo", "bullet off")
    expect(TextNormalizer.removingListMarker("-Pere e pecorino") == "Pere e pecorino", "dash off")
    expect(TextNormalizer.endsOpen("Manzo in crosta di riso e") && TextNormalizer.endsOpen("ragout bianco di vitello,")
           && !TextNormalizer.endsOpen("Ribollita"), "lines that can't end there")
    expect(TextNormalizer.startsListItem("10) Chiamare il 112") && !TextNormalizer.startsListItem("1300 anni fa")
           && !TextNormalizer.startsListItem("2,50 €"), "list markers are recognised, numbers aren't")
    expect(TextNormalizer.similarity("Uscita di sicurezza", "Usclta di sicurezza") > 0.8, "a one-letter misread is still the same text")
    expect(TextNormalizer.similarity("Uscita", "Ingresso") < 0.3, "different words aren't")
}

// MARK: Prices

do {
    for price in ["€ 12", "EURO 18", "EURO   8", "11,00", "13,00 €", "€ 1.50 cadauna", "€ 5 /€ 15", "C18", "€34"] {
        expect(Price.isWholeLine(price), "\(price) is a price")
    }
    for text in ["Ribollita", "per 2 persone", "Tel. 055 123456", "1300 anni fa", "PRIMI PIATTI"] {
        expect(!Price.isWholeLine(text), "\(text) isn't a price")
    }
    expect(Price.split("Dolce del giorno € 6.00") == ("Dolce del giorno", "€ 6.00"), "a price at the end comes off")
    expect(Price.split("limoncello, aglio orsino, fragole 13") == ("limoncello, aglio orsino, fragole", "13"),
           "a bare number after the ingredients is the price")
    expect(Price.split("Spaghetti alle vongole ........ 14,00") == ("Spaghetti alle vongole", "14,00"), "dot leaders")
    expect(Price.split("per 2 persone").price == nil, "a number inside the text isn't a price")
    expect(Price.split("Tagliata di manzo 30 mesi").price == nil, "nor is one followed by a word")
    expect(Price.tidy("EURO   8") == "€8", "EURO 8")
    expect(Price.tidy("13,00 €") == "€13.00", "13,00 €")
    expect(Price.tidy("€ 5 /€ 15") == "€5 / €15", "glass and bottle")
    expect(Price.tidy("€ 1.50 cadauna") == "€1.50 each", "each")
    expect(Price.tidy("9,5") == "€9.50", "one decimal")
}

// MARK: Menu reading: plain text and signs keep working

do {
    let result = titles([
        line("La chiesa fu costruita", 0.1, 0.100, 0.6),
        line("nel dodicesimo secolo.", 0.1, 0.125, 0.55),
        line("Spaghetti alla carbonara", 0.1, 0.300, 0.6),
        line("Penne all'arrabbiata", 0.1, 0.325, 0.5),
    ])
    expect(result == ["La chiesa fu costruita nel dodicesimo secolo.", "Spaghetti alla carbonara", "Penne all'arrabbiata"],
           "paragraph merges, dishes stay separate: \(result)")
    expect(titles([line("Il museo fu costrui-", 0.1, 0.1, 0.6), line("to nel 1300", 0.1, 0.125, 0.4)]) == ["Il museo fu costruito nel 1300"],
           "hyphenated word rejoins")
    expect(titles([line("USCITA", 0.3, 0.40, 0.4, 0.05), line("DI SICUREZZA", 0.2, 0.46, 0.6, 0.05)]) == ["USCITA DI SICUREZZA"],
           "two-line sign joined by a preposition")
    expect(titles([line("Visita guidata della", 0.1, 0.1, 0.5), line("Galleria degli Uffizi", 0.1, 0.125, 0.5)])
           == ["Visita guidata della Galleria degli Uffizi"], "a line ending in an article continues")
    expect(titles([line("ANTIPASTI", 0.1, 0.1, 0.4, 0.04), line("BRUSCHETTA AL POMODORO", 0.1, 0.15, 0.6, 0.04)]).count == 2,
           "a heading doesn't swallow the dish under it")
    expect(titles([line("Benvenuti a", 0.1, 0.1, 0.4), line("firenze", 0.1, 0.3, 0.4)]).count == 2, "distant lines stay separate")
    expect(read([line("12,50 €", 0.7, 0.3, 0.2)]).isEmpty, "a price on its own is nothing to read")
    expect(titles([line("  Vietato   fumare ", 0.1, 0.1, 0.5)]) == ["Vietato fumare"], "whitespace collapsed")

    let columns = read([
        line("Primi piatti e", 0.05, 0.200, 0.35),
        line("Secondi piatti e", 0.55, 0.200, 0.35),
        line("contorni misti", 0.05, 0.225, 0.30),
        line("dolci della casa", 0.55, 0.225, 0.30),
    ], language: false)
    expect(columns.map(\.title) == ["Primi piatti e contorni misti", "Secondi piatti e dolci della casa"],
           "columns don't bleed into each other, and read left then right: \(columns.map(\.title))")

    // Hotel fire notice: bullets, a bullet's wrapped line, numbered steps, heading over subtitle.
    let notice = titles([
        line("• Uscire dalla camera chiudendo la porta, ma non", 0.1, 0.100, 0.7),
        line("• Avvisare immediatamente il personale di servizio", 0.1, 0.125, 0.7),
        line("• Non ostruire le uscite con", 0.1, 0.150, 0.5),
        line("bagagli o altri oggetti.", 0.1, 0.175, 0.4),
        line("1. Mantenere la calma", 0.1, 0.200, 0.4),
        line("2. Uscire dalla camera", 0.1, 0.225, 0.4),
    ])
    expect(notice == ["Uscire dalla camera chiudendo la porta, ma non", "Avvisare immediatamente il personale di servizio",
                      "Non ostruire le uscite con bagagli o altri oggetti.", "1. Mantenere la calma", "2. Uscire dalla camera"],
           "each bullet on its own; a bullet's wrapped line joins it: \(notice)")
    expect(titles([
        line("COSA FARE IN CASO DI INCENDIO", 0.1, 0.30, 0.6, 0.030),
        line("IN CASO DI INCENDIO NELLA VOSTRA CAMERA", 0.1, 0.335, 0.6, 0.022),
    ]).count == 2, "heading and subtitle stay separate")
}

// MARK: Menu reading: dishes, prices, descriptions

do {
    // Prices at a tab stop far to the right, headings in capitals, "NAME: ingredients".
    let menu = read([
        line("PRIMI PIATTI *", 0.1, 0.10, 0.2, 0.018),
        line("-Pappardelle al cinghiale", 0.1, 0.13, 0.3, 0.018),
        line("EURO 13", 0.7, 0.13, 0.08, 0.016),
        line("-CROSTONE:pecorino senese,noci,miele al tartufo", 0.1, 0.16, 0.5, 0.018),
        line("EURO 9", 0.7, 0.16, 0.07, 0.016),
    ])
    expect(menu.map(\.kind) == [.heading, .item, .item], "heading, then two dishes: \(menu.map(\.kind))")
    expect(entry(menu, "Pappardelle al cinghiale")?.price == "€13", "the price on the dish's row")
    expect(entry(menu, "CROSTONE")?.details == ["pecorino senese,noci,miele al tartufo"] && entry(menu, "CROSTONE")?.price == "€9",
           "a name, what's in it, its price: \(menu.map(\.title))")

    // Centred menu: the price on the line under the dish.
    let centred = read([
        line("Flan di Montebore con crema di spinaci", 0.30, 0.300, 0.40, 0.016),
        line("€ 8.00", 0.47, 0.318, 0.06, 0.012),
        line("Mammoli di patate bicolori con fonduta di gorgonzola", 0.25, 0.360, 0.50, 0.016),
        line("e granella di nocciole", 0.40, 0.378, 0.20, 0.016),
        line("€ 11.00", 0.46, 0.396, 0.07, 0.012),
    ])
    expect(centred.map(\.price) == ["€8.00", "€11.00"], "prices under the dishes: \(centred.map(\.price))")
    expect(centred.last?.title == "Mammoli di patate bicolori con fonduta di gorgonzola e granella di nocciole", "a wrapped name")

    // Name in bigger type, then ingredients ending in the price, then allergens in smaller type.
    let described = read([
        line("Capasanta arrostita", 0.10, 0.200, 0.24, 0.020),
        line("limoncello, aglio orsino, fragole 13", 0.10, 0.224, 0.30, 0.015),
        line("solfiti, molluschi", 0.10, 0.242, 0.12, 0.011),
        line("Carne cruda", 0.10, 0.270, 0.15, 0.020),
        line("asparagi, uovo, patate 12", 0.10, 0.294, 0.22, 0.015),
    ])
    expect(described.map(\.title) == ["Capasanta arrostita", "Carne cruda"], "two dishes: \(described.map(\.title))")
    expect(described.first?.details == ["limoncello, aglio orsino, fragole", "solfiti, molluschi"] && described.first?.price == "€13",
           "ingredients, then allergens, and the price from the end of the ingredients: \(String(describing: described.first))")
}

// MARK: Menu reading: other languages

do {
    expect(detector.language(of: "Beef Tartare with sautéed mushrooms and parmesan foam") == .foreign, "English menu line")
    expect(detector.language(of: "Confit salt cod with creamy rice bean purée, tomato & red onion compote") == .foreign, "English menu line 2")
    expect(detector.language(of: "Maccheroncini Pasta al torchio with white veal ragout,") == .foreign, "English with Italian names in it")
    expect(detector.language(of: "Tartare di manzo con funghi saltati e spuma di parmigiano") == .italian, "Italian menu line")
    expect(detector.language(of: "Baccalà confit su vellutata di fagioli risina, composta di pomodoro") == .italian, "Italian menu line 2")
    expect(detector.language(of: "Carne cruda") != .foreign, "Italian that reads a bit Spanish stays")
    expect(detector.language(of: "Zeppole salate") != .foreign, "a short Italian name stays")
    expect(detector.language(of: "€ 29,00") == .unknown, "prices have no language")

    // Italian, then the menu's own English in smaller type, then the price.
    let menu = read([
        line("Tartare di manzo con funghi saltati e spuma di parmigiano", 0.10, 0.300, 0.80),
        line("Beef Tartare with sautéed mushrooms and parmesan foam", 0.15, 0.325, 0.70, 0.017),
        line("€ 29,00", 0.42, 0.347, 0.16),
        line("Pappardella fatta in casa ripiena di pappa al pomodoro, crema di aglione e", 0.08, 0.400, 0.84),
        line("olio al basilico", 0.40, 0.425, 0.20),
        line("Homemade stuffed pappardelle filled with \"pappa al pomodoro\", served with", 0.10, 0.450, 0.80, 0.017),
        line("aglione garlic cream and basil oil", 0.30, 0.470, 0.40, 0.017),
        line("€ 35,00", 0.42, 0.492, 0.16),
    ])
    expect(menu.map(\.title) == ["Tartare di manzo con funghi saltati e spuma di parmigiano",
                                 "Pappardella fatta in casa ripiena di pappa al pomodoro, crema di aglione e olio al basilico"],
           "only the Italian is read; the menu's English is left alone and never glued on: \(menu.map(\.title))")
    expect(menu.map(\.price) == ["€29.00", "€35.00"], "prices still find their dishes: \(menu.map(\.price))")

    let split = read([
        line("Baccalà confit su vellutata di fagioli", 0.05, 0.30, 0.50),
        line("risina, composta di pomodoro", 0.57, 0.302, 0.23),
        line("€ 38,00", 0.90, 0.30, 0.08),
    ])
    expect(split.map(\.title) == ["Baccalà confit su vellutata di fagioli risina, composta di pomodoro"] && split.first?.price == "€38.00",
           "a printed line Vision split is rejoined, the price stays apart: \(split.map(\.title))")

    let sideBySide = read([
        line("Tartare di manzo con funghi saltati", 0.05, 0.30, 0.42),
        line("Beef tartare with sautéed mushrooms", 0.49, 0.30, 0.42),
    ])
    expect(sideBySide.filter { !$0.isForeign }.map(\.title) == ["Tartare di manzo con funghi saltati"],
           "two-language columns stay apart: \(sideBySide.map(\.title))")
    expect(sideBySide.first { $0.isForeign }?.sources.isEmpty == true, "English is never sent to the translator")
}

// MARK: Menu reading: real OCR from the lab (camera-like frames of real menus)

do {
    let nerocarbone = fixture("nerocarbone-p1-page") // the menu from a TestFlight report, page tilted
    let dishes = nerocarbone.filter { $0.kind == .item }
    let unpriced = nerocarbone.filter { $0.kind == .text }.map(\.title)
    expect(dishes.count == 22, "every dish has its price: \(dishes.count) priced; without: \(unpriced)")
    expect(entry(nerocarbone, "Pere e pecorino")?.price == "€8", "Pere e pecorino €8")
    expect(entry(nerocarbone, "CAPRAIA")?.price == "€10" && entry(nerocarbone, "CAPRAIA")?.details.count == 1, "the last dish")
    let sections = nerocarbone.filter { $0.kind == .heading && !$0.isForeign }.map(\.title)
    expect(sections == ["PRIMI PIATTI •", "SECONDI PIATTI •", "CONTORNI•", "INSALATONE"], "four sections: \(sections)")

    let sanPastore = fixture("sanpastore-p1-page") // centred, price under each dish
    expect(sanPastore.filter { $0.kind == .item }.count == 9 && sanPastore.filter { $0.kind == .heading }.count == 2,
           "nine dishes with prices, two sections: \(sanPastore.map(\.title))")

    let conte = fixture("casadelconte-p1-middle") // two columns, name / ingredients + price / allergens
    let order = conte.filter { $0.kind == .heading }.map(\.title)
    expect(order == ["Antipasti", "Primi", "Secondi", "Dolci"], "left column first, then right: \(order)")
    expect(entry(conte, "Capasanta arrostita")?.details == ["limoncello, aglio orsino, fragole", "solfiti, molluschi"]
           && entry(conte, "Capasanta arrostita")?.price == "€13", "name, ingredients, allergens, price")
    expect(entry(conte, "Quaglia arrosto")?.details.first == "polenta, silene" && entry(conte, "Quaglia arrosto")?.price == "€15",
           "ingredients under a name aren't part of it")

    let piccadilly = fixture("piccadilly-p1-top") // Italian with English under each dish, prices on the right
    expect(piccadilly.filter { $0.kind == .item }.count >= 18, "dishes priced: \(piccadilly.filter { $0.kind == .item }.count)")
    expect(entry(piccadilly, "Melanzane alla parmigiana")?.price == "€14.00", "Melanzane alla parmigiana €14.00")
    expect(!piccadilly.contains { !$0.isForeign && $0.title.hasPrefix("Fillet of beef") }, "the menu's English isn't translated")

    let corniolo = fixture("corniolo-p1-page")
    expect(entry(corniolo, "Maccheroncini al torchio al ragout bianco di vitello, maggiorana e olive taggiasche")?.price == "€12.00",
           "a two-line Italian dish over two English lines: \(corniolo.map(\.title))")
}

// MARK: Captions

do {
    let dishes = [
        MenuEntry(kind: .item, title: "Angolo", details: ["dettaglio"], price: "€5", isForeign: false,
                  titleBox: CGRect(x: 0, y: 0, width: 0.2, height: 0.05), box: CGRect(x: 0, y: 0, width: 0.2, height: 0.05), lineCount: 1),
        MenuEntry(kind: .item, title: "Centro", details: [], price: nil, isForeign: false,
                  titleBox: CGRect(x: 0.4, y: 0.45, width: 0.2, height: 0.05), box: CGRect(x: 0.4, y: 0.45, width: 0.2, height: 0.05), lineCount: 1),
        MenuEntry(kind: .text, title: "Welcome", details: [], price: nil, isForeign: true,
                  titleBox: CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.05), box: CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.05), lineCount: 1),
    ]
    expect(Captions.priority(dishes, centralFirst: true) == ["Centro", "Angolo", "dettaglio"], "aiming: centre first, titles first")
    expect(Captions.priority(dishes, centralFirst: false) == ["Angolo", "Centro", "dettaglio"], "captured: in reading order")

    var tiramisu = Caption(id: 0, entry: MenuEntry(kind: .item, title: "Tiramisù", details: [], price: "€6", isForeign: false,
                                                   titleBox: .zero, box: .zero, lineCount: 1))
    expect(tiramisu.title == nil && !tiramisu.isTranslated, "nothing yet")
    tiramisu.english["Tiramisù"] = "Tiramisu"
    expect(tiramisu.isTranslated && !tiramisu.paintsTitle && !tiramisu.showsItalian, "a name that doesn't change isn't repeated")
    var tartare = Caption(id: 1, entry: dishes[0])
    tartare.english["Angolo"] = "Corner"
    expect(tartare.paintsTitle && tartare.showsItalian && !tartare.isTranslated, "title in, details still coming")
    expect(Caption(id: 2, entry: dishes[2]).title == "Welcome", "English on the page is its own translation")

    var page = dishes.prefix(2).map { $0 }
    page[0].title = "Tartare di manzo con funghi saltati"
    page[1].title = "Spaghetti della tradizione al pomodoro"
    var glance = page
    glance[0].title = "Tartare di manzo con funghl saltati"
    expect(Captions.sameView(page, glance), "same view, slightly misread")
    expect(!Captions.sameView(page, []), "nothing to compare")
    var moved = glance
    moved[0].box.origin.y += 0.1
    moved[1].box.origin.y += 0.1
    expect(!Captions.sameView(page, moved), "the text moved: not steady")
}

// MARK: Paper and ink colours

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
