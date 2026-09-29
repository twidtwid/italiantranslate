# Translation benchmark

Which on-device translator gives a diner the right English, fast? Measured on 28 September 2026.

## Method

- **Lines:** every Italian dish name and description the app's own OCR and menu reader found on
  whole-page frames: 303 lines from the lab's menus, and 196 from three menus the lab had never
  used (held out). OCR mistakes stay in, as on the phone.
- **Candidates:** each gets the same input the app sends Apple's translator.
- **Grading:** blind. Claude Sonnet 5 sees each Italian line with every candidate's English,
  shuffled and unlabeled. Each gets 2 (accurate, natural), 1 (understandable but off) or 0 (wrong),
  and a flag when a diner could be misled about the food (ingredients, allergens, raw or cooked).
  The score is the mean as a percentage.
- **Speed:** measured on a Mac whose GPU was shared with another model server, so only the ranking
  holds, not the figures. Apple Translation runs on the phone's own models; the others would have
  to ship in the app.

Tools: `Tests/Lab/Benchmark` (see the bottom of this page).

## Results

Held-out menus (196 lines), the fair test:

| Candidate | Score (95% CI) | Wrong | Misleading | Per line (Mac) | Size |
|---|---|---|---|---|---|
| Apple + glossary | 77 (72–82) | 10% | 13% | 0.18 s | in iOS |
| Apple Translation | 76 (71–80) | 11% | 13% | 0.18 s | in iOS |
| Gemma 4 E4B (4-bit) | 75 (70–79) | 10% | 12% | 2.1 s | 6.4 GB |
| Gemma 4 E2B (4-bit) | 70 (65–75) | 13% | 21% | 1.6 s | 4.1 GB |
| TranslateGemma 4B (4-bit) | 64 (59–70) | 22% | 27% | 4.6 s | 2.1 GB |
| Qwen3.5 4B (4-bit) | 61 (56–67) | 19% | 22% | 2.9 s | 2.9 GB |
| Opus-MT it→en | 55 (50–60) | 22% | 22% | 1.0 s | 0.3 GB |
| Qwen3.5 2B (4-bit) | 49 (44–54) | 32% | 34% | 2.3 s | 1.6 GB |

The lab's menus (303 lines). The glossary was written after seeing these, so its score here shows
what it fixes, not what it will do on a new menu:

| Candidate | Score (95% CI) | Wrong | Misleading |
|---|---|---|---|
| Apple + glossary | 82 (79–86) | 7% | 8% |
| Gemma 4 E4B | 75 (71–79) | 12% | 16% |
| Apple Translation | 74 (70–78) | 14% | 15% |
| Gemma 4 E2B | 69 (65–74) | 16% | 21% |
| TranslateGemma 4B | 66 (61–70) | 23% | 28% |
| Qwen3.5 4B | 61 (56–65) | 23% | 26% |
| Opus-MT it→en | 56 (52–60) | 27% | 29% |
| Qwen3.5 2B | 45 (40–50) | 40% | 41% |

Apple's on-device Foundation Models (iOS 26) was tried by hand and left out: it answered with
recipes and made things up ("Battuta di fassona", raw beef, became a slow-cooked stew).

## What it means

- **Apple Translation stays.** No model that fits on the phone is more accurate, and every one is
  5 to 25 times slower and gigabytes to download. The best of them, Gemma 4 E4B, ties Apple.
- **The mistakes that matter are named dishes and menu words**, not grammar: "Ribollita" →
  "Boiled", "Fagioli all'uccelletto" → "Bird beans", "Secondi" → "Seconds", "Coperto" → "Covered".
  The open models have the same problem in other forms ("Peposo" → "Pork", "nocciole" →
  "walnuts", "Pere e pecorino" → "Goats and goat cheese").
- **The glossary** (`Traduci/Core/Glossary.swift`) fixes those where it knows the words: 74 →
  82 on the lab's menus, with misleading English halved. On new menus it moves the score only as
  far as it covers their words (76 → 77, touching 8 of 196 lines). It grows by adding the words new
  menus show; every addition gets a test.
- **Translating a dish's name with its description** changed 53 of 157 names, mostly word order,
  some better and some worse: not worth splitting the English back apart.

## Running it

On an Apple silicon Mac with the Italian translation pack, from the repository root, after a lab
run (`CONTRIBUTING.md`) has left its results in `$LAB/out`:

```sh
B=Tests/Lab/Benchmark; W=/tmp/benchmark
python3 $B/sources.py "$LAB/out" $W                        # the lines
xcrun swiftc -O Traduci/Core/*.swift $B/Inputs/main.swift -o $W/inputs && $W/inputs $W/sources.json > $W/inputs.json
xcrun swiftc -O Traduci/Core/*.swift $B/Apple/main.swift -o $W/apple && $W/apple $W   # Apple, with and without the glossary
python3 -m venv .venv-bench && .venv-bench/bin/pip install -r $B/requirements.txt
.venv-bench/bin/python $B/gen.py $W gemma4-e4b lmstudio-community/gemma-4-E4B-it-MLX-4bit   # any candidate
OPENROUTER_API_KEY=… .venv-bench/bin/python $B/judge.py $W  # grading, a few dollars
.venv-bench/bin/python $B/score.py $W
```
