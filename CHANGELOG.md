# Changelog

Builds ship through TestFlight; the build number is the number of the workflow run that uploaded it.

## Build 23.1 — 29 September 2026

**Street signs, and more Italian dishes.**

- **ZTL signs:** "ZTL" came out unchanged and "Varco attivo" as "Active sling"; now they say it's a
  limited traffic zone, and whether its camera is on (don't drive in: a fine each time). "ZTL" was
  also too short to be read at all. Signs for no entry, towing, parking discs, tolls ("Solo
  Telepass"), tickets to validate, platforms, toilets and beaches read right too, and "feriali" says
  Monday to Saturday.
- **Hours aren't prices:** a sign's "19,30 - 02,00" was listed at €02.00.
- **More dishes the translator didn't know:** common Tuscan and Roman dishes and menu words
  ("Coda di rospo" was "Toad", "Prosciutto crudo" "Raw ham", "Linguine allo scoglio" "Linguine with
  rock"). On four menus it had never seen, the lines it changes went from 42 to 84 out of 100.

## Build 22.1 — 28 September 2026

**The right price, and dishes by their real names.**

- **Allergen numbers aren't prices:** a dish with its allergen numbers on a line of their own and
  the price under them ("1, 7", then "€16.00") showed €1.70. The price with a currency or cents now
  wins over a bare number.
- **No more half-lines:** where the camera frame read one printed line as two pieces and the closer
  reading got it whole, the second piece stayed in the list as nonsense ("con uno sguardo").
- **Dishes the translator doesn't know** come out right: "Ribollita" was "Boiled", "Fagioli
  all'uccelletto" "Bird beans", "Secondi" "Seconds" and "Coperto" "Covered". A glossary of dishes,
  course headings and kitchen words fixes these, still entirely on the phone.
- **Other translators, measured:** Gemma 4, TranslateGemma, Qwen3.5 and Opus-MT, all small enough
  for an iPhone, against Apple's translator on 499 menu lines. None is more accurate and all are
  much slower, so Apple's stays ([docs/translation-benchmark.md](docs/translation-benchmark.md)).

## Build 21.1 — 28 September 2026

**Faster to the list, easier to read on the picture.**

- **"The picture didn't come", again and again:** the retry restarted the camera only when it had
  stopped. Now it also restarts a camera that runs but sends no frames, and cancels a text read
  that has hung. Dropped frames are logged, so a next report says why.
- **The list shows up with the picture.** The frame's own reading, mostly translated while you
  aimed, is listed at once; the closer reading (prices, small print) comes in a moment later, and
  the entries both found stay where they are.
- **The English on the photo stays readable:** at the Italian's size. A one-line name or
  description runs on into the blank paper beside it, up to the price column, instead of shrinking
  to fit the Italian's width; a paragraph wraps as printed. Too long, it ends in "…"; the list has
  it in full.
- **Allergens under a price on its own line** stay with their dish instead of becoming an entry.
- **Cooler and lighter on the battery:** with no text in view for a couple of seconds (the phone on
  the table), or in Low Power Mode, the camera is read less often.
- **The menu lab** now translates every menu for real with Apple's translator on the Mac, and tries
  Vision's new document reader on the same pages for comparison.

## Build 20.1 — 28 September 2026

**Five TestFlight reports from a day in Chianti.**

- **Stuck on "Reading…"** (a sign at a vineyard): a still that arrived when nothing was waiting
  for it left the camera paused, and the next picture waited forever. Now a picture that doesn't
  come within 2 seconds gets the camera restarted, and at 5 seconds the app says so and lets you
  try again. When the system takes the camera (a call, another app, the phone too warm in the sun)
  the app says that too, and reads less often while the phone runs hot.
- **Blurred in a moving car:** the picture is the sharpest of the last few frames, not just the
  last, and exposures stay short while the phone keeps shaking.
- **The same line twice:** a line cut by the edge of one of the two reading bands came out garbled
  and stayed as a second entry. Those half-read lines are dropped now, and of two readings of a
  line the closer look wins ("glutine, pesce", not "alutine. cesce").
- **Plaques and notices:** running text is read as whole paragraphs in one style and translated
  whole, without the Italian repeated under each, and a number at the end of a line ("lunga 101")
  is no longer taken for a price.
- **A picked entry** is drawn over its neighbours on the photo.

## Build 11.1 — 27 September 2026

**Point, hold, read.** Rebuilt around reading a menu at the table, after TestFlight feedback that
the translation vanished as soon as the phone moved and the overlays were unreadable.

- The shutter's ring fills while the phone is held still over text, then takes the picture; tap it
  to take the picture at once. The picture stays until **Scan**: moving the phone never ends reading.
- A menu reader: dishes, their ingredients and allergens, prices (in a price column, under a
  centred dish, or at the end of the ingredients), sections, two-column pages in reading order, and
  the menu's own English left alone. Spanish never counts as "already translated".
- A capture is read again in two overlapping bands, so a whole-page shot keeps its small print.
- The menu in English at a readable size (dish, ingredients, price, the Italian name to order by),
  with the photo above and the English painted over the Italian in the page's own colours. Drag the
  panel between a peek, half and full; tap a dish to find it on the photo and the other way round;
  share the page as text.
- The menu lab: real Italian menus through the app's OCR and reader on a Mac, and the app itself in
  the Simulator, on every change.

## Build 3.1 — 27 September 2026

**Aim, then read.** Translations on a locked still instead of a shaking camera, painted in the
page's paper and ink colours; the phone's motion decided when to lock and when to aim again.

## Build 2.1 — 27 September 2026

First round of TestFlight feedback: steadier overlays, dense text (bullets, headings) kept apart,
the menu's own English left alone, split lines rejoined, and a working zoom button.

## Build 1.4 — 27 September 2026

First TestFlight build: live camera translation from Italian to English with Apple's Vision and
Translation frameworks, entirely on the device.
