# Changelog

Builds ship through TestFlight; the build number is the number of the workflow run that uploaded it.

## Build NEXT — 28 September 2026

**Five TestFlight reports from a day in Chianti.**

- **Stuck on "Reading…"** (a sign at a vineyard): a still that arrived when nothing was waiting
  for it left the camera paused, and the next picture waited forever. Now a picture that doesn't
  come within 2 seconds gets the camera restarted, and at 5 seconds the app says so and lets you
  try again. When the system takes the camera (a call, another app, the phone too warm in the sun)
  the app says that too, and reads less often while the phone runs hot.
- **Blurred in a moving car:** the picture is the sharpest of the last few frames, not just the
  last, and exposures stay short while the phone keeps shaking.
- **The same line twice:** a line cut by the edge of one of the two reading bands came out garbled
  and stayed as a second entry. Those half-read lines are dropped now.
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
