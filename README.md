# Traduci

Point your iPhone at Italian and read English. Traduci opens straight into the camera and paints English over the Italian as you move.

- **Fully offline.** Apple's Vision reads the text and Apple's Translation framework translates it, both on the device. After a one-time download of the Italian language pack, it works in airplane mode.
- **Built for speed.** OCR always runs on the newest camera frame and never works through a backlog. While you aim, the text nearest the centre is translated ahead, so it's ready the moment you hold still. Every result is cached, and the translation model is loaded before the first text shows up.
- **Calm to read.** Translations are laid over a locked, sharp frame instead of chasing a shaking camera, the same way Apple's Translate app freezes the frame and Google Translate uses Scan mode for menus.

## Install with TestFlight (no Mac)

GitHub's Mac runners build the app, Apple's cloud signing signs it, and it's uploaded to TestFlight. The setup is one-time and happens in a browser; a phone is fine.

1. **API key.** In App Store Connect, go to **Users and Access → Integrations → App Store Connect API → Team Keys → +** and pick the role **Admin**, which cloud signing needs. If you see **Request Access**, do that first. Download the `.p8` (Apple only lets you do this once) and note the **Key ID** and **Issuer ID**.
2. **Team ID.** It's under **Membership details** at [developer.apple.com/account](https://developer.apple.com/account).
3. **GitHub secrets.** In this repo, go to **Settings → Secrets and variables → Actions → New repository secret** and add:
   - `ASC_KEY_ID`
   - `ASC_ISSUER_ID`
   - `APPLE_TEAM_ID`
   - `ASC_PRIVATE_KEY`: the whole `.p8` file, including the `BEGIN`/`END` lines.

   Put the key straight into GitHub; don't paste it anywhere else.
4. **Run the TestFlight workflow.** It runs by itself on every push that changes the app, on `main` or this branch. To run it by hand, open the latest **TestFlight** run in **Actions** and choose **Re-run all jobs**, or use **Actions → TestFlight → Run workflow** once this code is on `main`. The first run registers the bundle ID `com.twidtwid.Traduci`, then stops and asks for the app record, which Apple only allows creating on the web. In App Store Connect, go to **Apps → + → New App**, choose iOS, and give it any unique name, e.g. "Traduci Live" (the home-screen name stays "Traduci"). Pick that bundle ID and any SKU. Run the workflow again and it archives, signs and uploads in about 5 minutes.
5. **TestFlight.** In App Store Connect, open your app, then **TestFlight → Internal Testing → +**. Add yourself and turn on automatic distribution. Install the TestFlight app on the iPhone. Each build appears there 5 to 15 minutes after upload, and builds last 90 days.

To use a different bundle ID, set a repository **variable** named `BUNDLE_ID`.

Then **do the first launch while you're online**: allow camera access and tap **Download** when iOS offers the Italian pack. The status pill turns green with `IT → EN · offline` once everything is local.

## Install from Xcode

You need a Mac with Xcode 26 or newer. An iPhone on iOS 27 needs Xcode 27.

1. Clone this repo and open `Traduci.xcodeproj`.
2. In Xcode, click the **Traduci** target, open **Signing & Capabilities**, and pick your Team. A free Apple ID works, but apps signed that way expire after 7 days; just run it again from Xcode.
3. If Xcode says the bundle ID is taken, change it to anything unique, e.g. `com.yourname.traduci`.
4. On the iPhone, turn on **Settings → Privacy & Security → Developer Mode**. Plug the phone in, select it in Xcode, and press ⌘R.
5. **Do the first launch while you're online.** Allow camera access, then tap **Download** when iOS offers the Italian pack. The status pill turns green with `IT → EN · offline` once everything is local.

The shared scheme runs the **Release** build, so the phone gets the optimised binary.

## Using it

**Aim, then read.**
- **Aim:** point the phone at Italian. The camera stays clean while you move, and translation is already running in the background.
- **Read:** hold still for a moment. Traduci locks a sharp frame, gives a light tap, and lays the English over the Italian in the page's own paper and ink colours. Nothing moves while you read.
- **Move on:** turn to the next part of the menu and it goes back to aiming by itself, then locks again when you're steady.

| | |
|---|---|
| Pinch the locked frame | Zoom into small print; drag to look around |
| Tap a translation | Read it full size, next to the original |
| Centre button | Lock now, or go back to the camera |
| Flashlight | Torch, for dark restaurants |
| Pinch while aiming / `1×` button | Camera zoom. The button cycles 1× → 2× → 5× (telephoto) |
| `Accurate` / `Fast` chip | OCR mode. Fast suits big clean signs; Accurate suits menus and small print |
| Top-left pill | Status, plus the latest OCR and translation (MT) times in ms |

- English that's already printed on bilingual menus is left alone; only the Italian gets translated.
- The phone switches to the ultra-wide lens by itself for close-up (macro) text.
- Hold it upright: the app is portrait-only, so text shot with the phone sideways isn't read.

## How it works

```
aiming:  camera ─► Vision OCR (it-IT) ─► lines → blocks ─► drop English ─► translate ahead, centre first (cached)
                   newest frame only      paragraphs join,
                                          menu lines don't
reading: gyro says "still" ─► sharp frame ─► English painted in the page's paper and ink colours ─► pinch, tap
```

| File | Role |
|---|---|
| `Traduci/CameraController.swift` | Capture session, frame dropping, freeze, torch, zoom |
| `Traduci/TextRecognizer.swift` | Vision OCR settings (`minimumTextHeight` trades small text against speed) |
| `Traduci/TranslationEngine.swift` | On-device translation queue, cache, warm-up, self-healing session |
| `Traduci/AppModel.swift`, `Traduci/MotionMonitor.swift` | Aim-and-read: when to lock a still and when to aim again |
| `Traduci/Core/` | Camera-free logic: line grouping, language detection, page colours, screen mapping |
| `Tests/CoreTests/main.swift` | Tests for `Core/`, run by CI |
| `.github/workflows/ios.yml` | Every push: core tests plus an iOS build with Xcode 26 and Xcode 27 |
| `.github/workflows/testflight.yml`, `scripts/asc_preflight.py` | On demand: check the Apple setup, then archive, cloud-sign and upload to TestFlight |
