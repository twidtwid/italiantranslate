# Traduci

Point your iPhone at Italian and read English. Traduci opens straight into the camera and paints English over the Italian as you move.

- **Fully offline.** Apple's Vision reads the text and Apple's Translation framework translates it, both on the device. After a one-time download of the Italian language pack, it works in airplane mode.
- **Built for speed.** OCR always runs on the newest camera frame and never works through a backlog. Only text that's on screen right now gets translated, starting with whatever is nearest the centre. Every result is cached, and the translation model is loaded before the first text shows up.

## Install

You need a Mac with Xcode 26 or newer. An iPhone on iOS 27 needs Xcode 27.

1. Clone this repo and open `Traduci.xcodeproj`.
2. In Xcode, click the **Traduci** target, open **Signing & Capabilities**, and pick your Team. A free Apple ID works, but apps signed that way expire after 7 days; just run it again from Xcode.
3. If Xcode says the bundle ID is taken, change it to anything unique, e.g. `com.yourname.traduci`.
4. On the iPhone, turn on **Settings → Privacy & Security → Developer Mode**. Plug the phone in, select it in Xcode, and press ⌘R.
5. **Do the first launch while you're online.** Allow camera access, then tap **Download** when iOS offers the Italian pack. The status pill turns green with `IT → EN · offline` once everything is local.

The shared scheme runs the **Release** build, so the phone gets the optimised binary.

## Using it

| | |
|---|---|
| Point at text | English covers the Italian it translates |
| ⏸ (centre button) | Freezes the frame; tap any translation to read it full size, next to the original |
| Flashlight | Torch, for dark restaurants |
| Pinch / `1×` button | Zoom for far-away signs; tap to reset |
| `Accurate` / `Fast` chip | Switches OCR modes. Fast wins on big clean signs, Accurate wins on menus and small print |
| Top-left pill | Status, plus the latest OCR and translation (MT) times in ms |

The phone switches to the ultra-wide lens by itself for close-up (macro) text.

## How it works

```
camera (1080p) ──► Vision OCR, it-IT ──► lines → blocks ──► overlay tracker ──► SwiftUI overlays
                   newest frame only      paragraphs join,    stable positions,          ▲
                                          menu lines don't    centre-first queue ──► Translation (on-device, cached)
```

| File | Role |
|---|---|
| `Traduci/CameraController.swift` | Capture session, frame dropping, freeze, torch, zoom |
| `Traduci/TextRecognizer.swift` | Vision OCR settings (`minimumTextHeight` trades small text against speed) |
| `Traduci/TranslationEngine.swift` | On-device translation queue, cache, warm-up, self-healing session |
| `Traduci/Core/` | Camera-free logic: line grouping, overlay tracking, screen mapping |
| `Tests/CoreTests/main.swift` | Tests for `Core/`, run by CI |

CI (`.github/workflows/ios.yml`) runs the core tests and builds the app for iOS on GitHub's macOS runners with Xcode 26 and Xcode 27.
