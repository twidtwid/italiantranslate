# Contributing

Traduci does one thing: you point an iPhone at an Italian menu or sign and read it in English, fast
and entirely on the phone. Help that makes it better at that is welcome: menus it reads badly,
bugs, and code.

## The most useful thing: a menu it gets wrong

Open an issue with a photo of the menu (only one you're free to share), what the app showed, and
what it should have shown. Better still, add the menu to the lab (below): a menu that trips up the
reader is the best test there is.

## Building

You need a Mac with Xcode 26 or newer (Xcode 27 for iPhones on iOS 27). Open `Traduci.xcodeproj`,
pick your team under **Signing & Capabilities**, and run it on an iPhone. The README has the details.

The Simulator has no camera and no translation models, so the app has a demo mode for it: copy a
photo and a JSON dictionary of Italian → English into the app's Documents folder and launch it
with `-demo photo.jpg -demoTranslations english.json` (see `Demo` in `Traduci/AppModel.swift`).
That's how the lab screenshots the app.

## Tests

The camera-free logic lives in `Traduci/Core` and imports only Foundation, CoreGraphics and
NaturalLanguage, so it builds with plain `swiftc`. From the repository root, on a Mac:

```sh
xcrun swiftc -O Traduci/Core/*.swift Tests/CoreTests/main.swift -o /tmp/core-tests && /tmp/core-tests
```

`Tests/CoreTests/Fixtures` holds real OCR of real menus, straight from the lab. The tests check
what a diner would see (every dish with its price, the sections, the order of the columns) rather
than how the code gets there.

## The menu lab

`Tests/Lab` turns the menus listed in `menus.json` into phone-camera frames and reads them with the
app's own OCR and menu reader. To add a menu, add an entry to `menus.json`: a PDF from the
restaurant's own website, or an image you have the right to use. To run the lab on a Mac:

```sh
python3 -m venv .venv && .venv/bin/pip install -r Tests/Lab/requirements.txt
.venv/bin/python Tests/Lab/fixtures.py Tests/Lab/menus.json /tmp/lab/frames
xcrun swiftc -O Traduci/Core/*.swift Traduci/TextRecognizer.swift Tests/Lab/Common.swift Tests/Lab/main.swift -o /tmp/lab/lab
/tmp/lab/lab /tmp/lab/frames /tmp/lab/out   # summary.md, JSON, and every frame with what it found drawn on
```

On pushes to this repository, the **Menu lab** workflow does the same and screenshots the app in
the Simulator too.

## What guides the app

- **Nothing leaves the phone.** No network calls beyond iOS downloading Apple's language pack, no
  analytics, no accounts.
- **Speed.** OCR only ever reads the newest camera frame, and translation runs ahead while you aim.
- **Calm.** Nothing moves while someone is reading.

Match the code around you: small types, plain names, and comments that say why rather than what.

## Pull requests

Keep them small and focused, and say how you tested: core tests, the lab, which iPhone and iOS. CI
runs the core tests and builds the app with Xcode 26 and Xcode 27. (For maintainers: commits
tagged `[lab]` skip TestFlight and the full build.)

By contributing you agree that your work is released under the [MIT License](LICENSE).
