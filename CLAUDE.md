# Traduci — notes for Claude

An iPhone app: point at an Italian menu or sign, read it in English. Everything runs on the
phone (Vision OCR, Apple Translation). README.md explains the app; CONTRIBUTING.md the rules.

## Rules that decide changes

- **Nothing leaves the phone.** No network calls, analytics or accounts. Ever.
- **Speed.** OCR reads only the newest frame. Translation runs ahead while aiming, and is cached.
- **Calm.** Nothing moves while someone is reading.
- The repo is **public**. No keys, tester emails, local paths or feedback text in commits, issues
  or PR bodies. TestFlight feedback is summarised in public only as the CHANGELOG does it.
- Match the code: small types, plain names, comments that say why. Docs and the CHANGELOG use
  short, plain sentences.

## Layout

- `Traduci/Core/` — camera-free logic (menu reader, OCR line merging, language detection, page
  colours, screen mapping). Imports only Foundation, CoreGraphics, NaturalLanguage. Most fixes
  land here, with a test.
- `Traduci/*.swift` — camera, Vision, translation queue, the SwiftUI screens, `AppModel` (the
  point-hold-read state machine, and `Demo` launch-argument mode for the Simulator).
- `Tests/CoreTests/` — plain-`swiftc` tests; `Fixtures/` is real OCR of real menus from the lab.
- `Traduci/Core/DishGlossary.swift` — dishes, course headings and kitchen words the translator gets
  wrong. Add what new menus show, each with a test; measure with `Tests/Lab/Benchmark`
  (`docs/translation-benchmark.md`), judging on menus the glossary hasn't seen.
- `Tests/Lab/` — real menus to camera-like frames (`fixtures.py`), read by the app's own OCR
  (`main.swift`). `english.json` is hand-checked English that stands in for the translator in the
  Simulator. `Translate/` runs Apple's real translator on the lab's results (Mac with the Italian
  pack); `Documents/` compares Vision's document reader with the menu reader.

## Commands

Xcode needs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` when `xcode-select`
points at the Command Line Tools.

```sh
# Core tests (seconds). Run before every commit.
xcrun swiftc -O Traduci/Core/*.swift Tests/CoreTests/main.swift -o "$TMPDIR/core-tests" && "$TMPDIR/core-tests"

# Menu lab: frames, then the app's OCR and menu reader on them (summary.md + annotated frames)
python3 -m venv .venv && .venv/bin/pip install -r Tests/Lab/requirements.txt
.venv/bin/python Tests/Lab/fixtures.py Tests/Lab/menus.json "$TMPDIR/lab/frames"
xcrun swiftc -O Traduci/Core/*.swift Traduci/TextRecognizer.swift Tests/Lab/Common.swift Tests/Lab/main.swift -o "$TMPDIR/lab/lab"
"$TMPDIR/lab/lab" "$TMPDIR/lab/frames" "$TMPDIR/lab/out"
xcrun swiftc -O Traduci/Core/*.swift Tests/Lab/Translate/main.swift -o "$TMPDIR/lab/translate"
"$TMPDIR/lab/translate" "$TMPDIR/lab/out"   # translations.md: the English a phone would show

# Simulator build (no signing), install, demo launch, screenshot
xcodebuild build -project Traduci.xcodeproj -scheme Traduci -configuration Debug \
  -destination "id=$UDID" -derivedDataPath "$TMPDIR/sim" -quiet CODE_SIGNING_ALLOWED=NO
xcrun simctl install "$UDID" "$TMPDIR/sim/Build/Products/Debug-iphonesimulator/Traduci.app"
DATA=$(xcrun simctl get_app_container "$UDID" com.twidtwid.Traduci data)
cp "$TMPDIR/lab/frames/"*.jpg Tests/Lab/english.json "$DATA/Documents/"
xcrun simctl launch --terminate-running-process "$UDID" com.twidtwid.Traduci \
  -demo nerocarbone-p1-page.jpg -demoTranslations english.json   # [-demoStage live] [-demoPanel peek|half|full] [-demoFocus N]
xcrun simctl io "$UDID" screenshot shot.png
```

The Simulator has no camera and no translation models. Real OCR and translation behaviour needs
a phone (TestFlight). The shared scheme's Run action is Release.

## Shipping

- Push to `main` with changes under `Traduci/**` → TestFlight build (~5 min, then 5–15 min to
  appear). Build number = workflow run number. Add a CHANGELOG entry per shipped build.
- Commits tagged `[lab]` skip TestFlight and the full iOS build.
- `ios.yml` builds with Xcode 26 and 27 on every push and PR.
- Work on a branch and merge by PR, as the history does.

## TestFlight feedback

`feedback.yml` (manual, or on a change to `scripts/feedback_public_key.pem`) fetches all
TestFlight feedback, screenshots and crash logs, seals them to that public key, and commits
`feedback/inbox.enc`. Each run replaces the whole bundle.

```sh
gh workflow run feedback.yml --ref main          # then wait for it to finish
git pull
python scripts/open_feedback.py feedback/inbox.enc PRIVATE_KEY_PEM OUTPUT_DIR   # needs `cryptography`
```

Open it outside the repo. Read `feedback.json` and look at every screenshot before diagnosing.
Where the private key lives on a given machine: `CLAUDE.local.md` (not in git).

## Working a TestFlight report

1. Reproduce with the lab first: add the menu or sign to `Tests/Lab/menus.json` (or a retyped
   page like `plaque.py`) and see what the reader does.
2. Fix in `Core/` where possible, with a core test using real OCR as a fixture.
3. Check the Simulator screenshots in demo mode, then ship and say what changed in the CHANGELOG.
