import Foundation

/// Italian that on-device translation gets wrong: dishes and kitchen words ("Ribollita" → "Boiled",
/// "Fagioli all'uccelletto" → "Bird beans"), the menu's own words ("Coperto" → "Covered"), and the
/// signs a visitor must not misread ("Varco attivo" → "Active sling", where it means a camera will
/// fine you for driving in). Known by name, the English comes from here; a line that only contains
/// such a word gets it spelled out in plain Italian first, which the translator reads well. The
/// Italian is still shown under the English, to order by or match the sign.
enum Glossary {
    enum Prepared: Equatable {
        /// A dish known by name: this is its English.
        case known(String)
        /// Send this to the translator.
        case translate(String)
    }

    /// What to do with `source` (as OCR read it): its English, or the text to translate.
    static func prepare(_ source: String) -> Prepared {
        let key = key(source)
        if let english = courses[key] ?? signs[key] ?? dishes[key] ?? course(misread: key) { return .known(english) }
        return .translate(rewrite(TextNormalizer.translationInput(source)))
    }

    /// Known by name, however short: "ZTL" is three letters and the most expensive sign in Italy.
    static func knows(_ text: String) -> Bool {
        let key = key(text)
        return courses[key] != nil || signs[key] != nil || dishes[key] != nil
    }

    /// A course heading OCR got a letter or two wrong ("Primi Pialli", "Secondi Pialli"). Headings
    /// are few and unalike, so a close reading of one about as long can only be that one; a longer
    /// line that contains one ("Con un primo piatto") says more, and goes to the translator.
    static func course(misread key: String) -> String? {
        let letters = key.filter(\.isLetter).count
        guard letters >= 7 else { return nil }
        let alike = courses.filter { abs($0.key.filter(\.isLetter).count - letters) <= 2 }
        let best = alike.max { TextNormalizer.similarity($0.key, key) < TextNormalizer.similarity($1.key, key) }
        guard let best, TextNormalizer.similarity(best.key, key) >= 0.7 else { return nil }
        return best.value
    }

    /// Spells out the kitchen words the translator doesn't know, in plain Italian.
    static func rewrite(_ text: String) -> String {
        var result = text
        for (pattern, plain) in terms {
            var searchStart = result.startIndex
            while let range = result.range(of: pattern, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<result.endIndex) {
                let before = range.lowerBound == result.startIndex ? nil : result[result.index(before: range.lowerBound)]
                let after = range.upperBound == result.endIndex ? nil : result[range.upperBound]
                guard before.map({ !$0.isLetter }) ?? true, after.map({ !$0.isLetter }) ?? true else {
                    searchStart = range.upperBound
                    continue
                }
                let startsText = result[..<range.lowerBound].allSatisfy { !$0.isLetter }
                let replacement = startsText ? plain.prefix(1).uppercased() + plain.dropFirst() : plain
                result.replaceSubrange(range, with: replacement)
                searchStart = result.index(range.lowerBound, offsetBy: replacement.count)
            }
        }
        return result
    }

    /// A dish name as a lookup key: lower case, no accents, no list marker, footnote star or colon.
    static func key(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "it"))
            .replacingOccurrences(of: "’", with: "'")
        let trimmed = TextNormalizer.removingListMarker(folded)
            .trimmingCharacters(in: CharacterSet(charactersIn: " *•·:.,"))
        return TextNormalizer.collapseWhitespace(trimmed)
    }

    /// The menu's own words: courses and charges ("Secondi" → "Seconds", "Coperto" → "Covered").
    static let courses: [String: String] = [
        "antipasti": "Starters", "antipasto": "Starter",
        "primi": "First courses", "primi piatti": "First courses", "i primi": "First courses", "primo piatto": "First course",
        "secondi": "Main courses", "secondi piatti": "Main courses", "i secondi": "Main courses", "secondo piatto": "Main course",
        "contorni": "Side dishes", "contorno": "Side dish",
        "dolci": "Desserts", "i dolci": "Desserts", "formaggi": "Cheeses",
        "insalata": "Salad", "insalate": "Salads", "insalatone": "Large salads", "zuppe": "Soups", "minestre": "Soups",
        "pizze": "Pizzas", "le pizze": "Pizzas", "schiacciate": "Tuscan flatbread sandwiches",
        "taglieri": "Boards of cured meats and cheeses", "piatti del giorno": "Today's dishes",
        "bevande": "Drinks", "bibite": "Soft drinks", "vini": "Wines", "vini rossi": "Red wines",
        "vini bianchi": "White wines", "birre": "Beers", "aperitivi": "Aperitifs", "digestivi": "Digestifs",
        "amari": "Digestifs", "caffetteria": "Coffee",
        "coperto": "Cover charge", "coperto e servizio": "Cover and service charge",
    ]

    /// Street, station and shop signs, by their words (keys as `key` makes them). Driving into a ZTL
    /// while its camera is on ("varco attivo") costs a fine every time; "feriali" includes Saturday.
    static let signs: [String: String] = [
        // Limited traffic zones
        "ztl": "Limited traffic zone (ZTL): no driving in without a permit",
        "zona a traffico limitato": "Limited traffic zone (ZTL): no driving in without a permit",
        "zona traffico limitato": "Limited traffic zone (ZTL): no driving in without a permit",
        "traffico limitato": "Limited traffic zone (ZTL): no driving in without a permit",
        "varco attivo": "ZTL camera ON: do not drive in",
        "varco ztl attivo": "ZTL camera ON: do not drive in",
        "ztl varco attivo": "ZTL camera ON: do not drive in",
        "ztl attiva": "ZTL camera ON: do not drive in",
        "varco non attivo": "ZTL camera off: you may drive in",
        "varco ztl non attivo": "ZTL camera off: you may drive in",
        "ztl varco non attivo": "ZTL camera off: you may drive in",
        "ztl non attiva": "ZTL camera off: you may drive in",
        "varco elettronico": "Camera-checked entry (ZTL)",
        "controllo elettronico degli accessi": "Entry checked by camera",
        "eccetto autorizzati": "Except vehicles with a permit",
        "eccetto veicoli autorizzati": "Except vehicles with a permit",
        // Driving and parking
        "senso vietato": "No entry (one-way street)",
        "divieto di accesso": "No entry",
        "divieto di transito": "No vehicles",
        "divieto di sosta": "No parking",
        "divieto di fermata": "No stopping",
        "zona rimozione": "Tow-away zone",
        "rimozione forzata": "Illegally parked cars will be towed",
        "passo carrabile": "Driveway: no parking",
        "sosta consentita": "Parking allowed",
        "disco orario": "Parking disc required: show your arrival time",
        "zona disco": "Parking disc required: show your arrival time",
        "giorni feriali": "Monday to Saturday",
        "feriali": "Monday to Saturday",
        "giorni festivi": "Sundays and public holidays",
        "festivi": "Sundays and public holidays",
        "lavori in corso": "Roadworks",
        "deviazione": "Diversion",
        "rallentare": "Slow down",
        "tangenziale": "Ring road",
        "solo telepass": "Telepass lane only: electronic toll tag, no cash or cards",
        "telepass": "Telepass lane: electronic toll tag only",
        // Stations, shops and beaches
        "obliterare il biglietto": "Validate your ticket",
        "convalidare il biglietto": "Validate your ticket",
        "binario": "Platform",
        "bagni": "Toilets",
        "servizi": "Toilets",
        "servizi igienici": "Toilets",
        "spingere": "Push",
        "tirare": "Pull",
        "guasto": "Out of order",
        "tabacchi": "Tobacconist (bus tickets, stamps)",
        "farmacia di turno": "Pharmacy open out of hours",
        "orario continuato": "Open all day, no lunch break",
        "vietato l'accesso ai non addetti ai lavori": "Authorised personnel only",
        "vietato l'ingresso ai non addetti ai lavori": "Authorised personnel only",
        "stabilimento balneare": "Beach club (paid entry)",
        "spiaggia libera": "Public beach (free)",
        "divieto di balneazione": "No swimming",
    ]

    /// Dishes by name (keys as `key` makes them). The English says what it is, briefly.
    static let dishes: [String: String] = [
        // Tuscany
        "ribollita": "Tuscan bread, bean and cabbage soup",
        "ribollita toscana": "Tuscan bread, bean and cabbage soup",
        "pappa al pomodoro": "Tuscan tomato and bread soup",
        "panzanella": "Tuscan bread and tomato salad",
        "acquacotta": "Tuscan vegetable soup with egg",
        "peposo": "Peppery Tuscan beef stew",
        "peposo alla fiorentina": "Peppery Tuscan beef stew",
        "peposo all'imprunetana": "Peppery Tuscan beef stew",
        "trippa alla fiorentina": "Florentine tripe in tomato sauce",
        "lampredotto": "Slow-cooked beef tripe, Florentine style",
        "bistecca alla fiorentina": "Florentine T-bone steak",
        "fagioli all'uccelletto": "Beans stewed with tomato and sage",
        "cantucci": "Almond biscuits",
        "cantucci e vin santo": "Almond biscuits with Vin Santo",
        "crostini toscani": "Toasts with chicken liver pâté",
        "crostini di fegatini": "Toasts with chicken liver pâté",
        "crostone": "Toasted bread",
        "crostoni": "Toasted bread",
        "schiacciata": "Tuscan flatbread",
        "fagioli al fiasco": "Beans slow-cooked in a glass flask",
        "zuccotto": "Dome-shaped sponge cake with cream",
        "finocchiona": "Fennel salami",
        "lardo di colonnata": "Cured pork fat from Colonnata",
        "pici cacio e pepe": "Thick hand-rolled pasta with pecorino and black pepper",
        "carne cruda": "Raw beef tartare",
        "carne cruda all'albese": "Raw beef tartare, Alba style",
        "battuta di fassona": "Hand-chopped raw Fassona beef",
        "battuta di fassona all'albese": "Hand-chopped raw Fassona beef, Alba style",
        // Rome and Lazio
        "cacio e pepe": "Pasta with pecorino and black pepper",
        "spaghetti cacio e pepe": "Spaghetti with pecorino and black pepper",
        "carbonara": "Pasta with egg, guanciale and pecorino",
        "spaghetti alla carbonara": "Spaghetti with egg, guanciale and pecorino",
        "saltimbocca alla romana": "Veal with prosciutto and sage",
        "carciofi alla giudia": "Deep-fried whole artichokes",
        "carciofi alla romana": "Braised artichokes with mint and garlic",
        "puntarelle": "Chicory shoots with anchovy dressing",
        "abbacchio a scottadito": "Grilled lamb chops",
        "coda alla vaccinara": "Braised oxtail in tomato sauce",
        "suppli": "Fried rice balls with mozzarella",
        // The north
        "vitello tonnato": "Cold sliced veal with tuna sauce",
        "ossobuco": "Braised veal shank",
        "ossobuco alla milanese": "Braised veal shank, Milanese style",
        "risotto alla milanese": "Saffron risotto",
        "cotoletta alla milanese": "Breaded veal cutlet",
        "baccala mantecato": "Whipped salt cod",
        "sarde in saor": "Sweet-and-sour sardines with onions",
        "fegato alla veneziana": "Calf's liver with onions",
        "bagna cauda": "Warm garlic and anchovy dip with vegetables",
        "agnolotti del plin": "Small pinched ravioli filled with meat",
        "tajarin": "Thin egg pasta",
        "bonet": "Chocolate and amaretti pudding",
        "bunet": "Chocolate and amaretti pudding",
        // The south
        "arancini": "Fried stuffed rice balls",
        "arancine": "Fried stuffed rice balls",
        "caponata": "Sweet-and-sour aubergine stew",
        "pasta alla norma": "Pasta with aubergine, tomato and salted ricotta",
        "pasta con le sarde": "Pasta with sardines and wild fennel",
        "orecchiette con cime di rapa": "Orecchiette with turnip greens",
        "parmigiana di melanzane": "Baked aubergine with tomato, mozzarella and parmesan",
        "melanzane alla parmigiana": "Baked aubergine with tomato, mozzarella and parmesan",
        "friarielli": "Sautéed broccoli rabe",
        "sfogliatella": "Flaky pastry filled with ricotta",
        "baba": "Rum baba",
        "zeppole": "Fritters",
        "zeppole salate": "Savoury fritters",
        // Everywhere
        "insalata caprese": "Tomato, mozzarella and basil salad",
        "caprese": "Tomato, mozzarella and basil salad",
        "affettati misti": "Mixed cold cuts",
        "tagliere misto": "Board of cured meats and cheeses",
        "fritto misto": "Mixed fried platter",
        "bollito misto": "Mixed boiled meats",
        "zuppa inglese": "Custard and liqueur trifle",
        "semifreddo": "Semi-frozen dessert",
        "affogato": "Ice cream with espresso poured over",
        "affogato al caffe": "Ice cream with espresso poured over",
    ]

    /// Words inside a line, spelled out in plain Italian before translation. Longer patterns come
    /// first, so "pici cacio e pepe" is handled before "cacio e pepe".
    static let terms: [(pattern: String, plain: String)] = [
        ("obliterare", "convalidare"), // "Obliterate the ticket"
        ("obliterate", "convalidate"),
        // Phrases that contain a shorter entry below come first.
        ("schiacciata alla fiorentina", "torta soffice all'arancia"),
        ("cacciucco alla livornese", "zuppa di pesce alla livornese"),
        ("inzimino di seppie", "seppie in umido con bietole"),
        ("in inzimino", "in umido con bietole"),
        ("arista di maiale", "lombo di maiale arrosto"),
        ("pinzimonio di verdure", "verdure crude con olio, sale e pepe"),
        ("coratella d'abbacchio", "frattaglie di agnello"),
        ("mezze maniche", "rigatoni corti"),
        ("crostini neri", "fettine di pane tostato con paté di fegatini"),
        ("soppressata toscana", "head cheese toscano"),
        ("zuppa frantoiana", "zuppa di verdure e fagioli con olio nuovo"),
        ("coda di rospo", "rana pescatrice"),
        ("prosciutto crudo", "cured ham"),
        ("fior di latte", "mozzarella di latte vaccino"),
        ("pollo al mattone", "pollo cotto sotto un mattone"),
        ("caffe corretto", "caffè con un goccio di liquore"),
        ("amaro della casa", "liquore digestivo della casa"),
        ("pane sciocco", "pane toscano senza sale"),
        ("sugo finto", "sugo di pomodoro senza carne"),
        ("supplì al telefono", "crocchette di riso fritte con mozzarella filante"),
        ("caciocavallo impiccato", "caciocavallo fuso alla brace"),
        ("in dolceforte", "in salsa agrodolce al cioccolato"),
        ("allo scoglio", "ai frutti di mare"),
        ("alla pescatora", "ai frutti di mare"),
        ("alla norcina", "con salsiccia e panna"),
        ("frittura di paranza", "frittura di pesciolini"),
        // Tuscany
        ("cacciucco", "zuppa di pesce alla livornese"),
        ("cecina", "torta di farina di ceci"),
        ("castagnaccio", "torta di farina di castagne"),
        ("fettunta", "pane tostato con aglio"),
        ("panforte", "dolce di frutta secca e spezie"),
        ("ricciarelli", "biscotti senesi di mandorle"),
        ("buristo", "sanguinaccio toscano"),
        ("soppressata", "soppressata salami"),
        ("rosticciana", "costine di maiale"),
        ("arista", "lombo di maiale arrosto"),
        ("scottiglia", "stufato di carni miste"),
        ("pinzimonio", "verdure crude con olio, sale e pepe"),
        ("triglie", "red mullet"), // no Italian the translator reads well: the English name passes through
        // Rome
        ("abbacchio", "agnello da latte"),
        ("pajata", "intestino di vitello da latte"),
        ("pagliata", "intestino di vitello da latte"),
        ("coratella", "frattaglie di agnello"),
        ("picchiapò", "bollito di manzo ripassato con pomodoro e cipolla"),
        ("trapizzino", "tasca di pizza bianca ripiena"),
        ("maritozzo", "brioche dolce"),
        ("maritozzi", "brioche dolci"),
        ("ripassata", "saltata"),
        ("ripassati", "saltati"),
        ("ripassate", "saltate"),
        ("animelle", "sweetbreads"),
        ("visciole", "ciliegie aspre"),
        ("moscardini", "polipetti"),
        ("totani", "calamari"),
        ("guanciale", "guanciale di maiale stagionato"),
        ("all'uccelletto", "in umido con pomodoro e salvia"),
        ("alla vignarola", "con fave, piselli e carciofi"),
        ("all'amatriciana", "con pomodoro, guanciale e pecorino"),
        ("alla gricia", "con guanciale e pecorino"),
        ("alla carbonara", "con uova, guanciale e pecorino"),
        ("alla norma", "con melanzane, pomodoro e ricotta salata"),
        ("alla puttanesca", "con pomodoro, olive, capperi e acciughe"),
        ("all'arrabbiata", "con pomodoro piccante"),
        ("cacio e pepe", "con pecorino e pepe nero"),
        ("trifolati", "saltati in padella con aglio e prezzemolo"),
        ("trifolate", "saltate in padella con aglio e prezzemolo"),
        ("trifolato", "saltato in padella con aglio e prezzemolo"),
        ("trifolata", "saltata in padella con aglio e prezzemolo"),
        ("battuta di", "tartare di"),
        ("crostone", "fetta di pane tostato"),
        ("crostoni", "fette di pane tostato"),
        ("crostini", "fettine di pane tostato"),
        ("peposo", "stufato di manzo al pepe"),
        ("ribollita", "zuppa toscana di pane, fagioli e cavolo nero"),
        ("zeppole", "frittelle"),
        ("schiacciata", "focaccia toscana"),
        ("schiacciate", "focacce toscane"),
        ("panzanella", "insalata toscana di pane e pomodoro"),
        ("farrotto", "risotto di farro"),
        ("zuccotto", "dolce a cupola"),
        ("giardiniera", "verdure sott'aceto"),
        ("caprini", "formaggi di capra"),
        ("al fondente", "al cioccolato fondente"),
        ("peperone crusco", "peperone secco croccante"),
        ("peperoni cruschi", "peperoni secchi croccanti"),
        ("pizza margherita", "pizza con pomodoro, mozzarella e basilico"),
        ("pinsa margherita", "pinsa con pomodoro, mozzarella e basilico"),
        ("bollito misto", "bollito misto di carni"),
        ("finferli", "chanterelle"), // no Italian the translator reads well: the English name passes through
        ("spadellati", "saltati in padella"),
        ("spadellate", "saltate in padella"),
        ("spadellato", "saltato in padella"),
        ("soppressa", "salame soppressa"),
        ("pici", "spaghettoni fatti a mano"),
        ("tajarin", "tagliolini all'uovo"),
        ("cinta senese", "maiale di cinta senese"),
    ]
}
