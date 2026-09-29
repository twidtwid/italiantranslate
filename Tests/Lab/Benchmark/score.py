"""One row per candidate from DIR/judged.jsonl. Usage: score.py DIR"""
import json, sys, pathlib, random
here = pathlib.Path(sys.argv[1])
items = [json.loads(l) for l in open(here / "judged.jsonl")]
summaries = {p.stem: json.load(open(p))["summary"] for p in (here / "candidates").glob("*.json")}
names = sorted(items[0]["scores"])

def stats(rows, name):
    s = [r["scores"][name]["score"] for r in rows]
    if not s:
        return (float("nan"),) * 3
    return (sum(s) / (2 * len(s)) * 100, sum(x == 0 for x in s) / len(s) * 100,
            sum(r["scores"][name]["misleading"] for r in rows) / len(rows) * 100)

def interval(rows, name, rounds=1000):
    rng = random.Random(0)
    means = sorted(stats([rng.choice(rows) for _ in rows], name)[0] for _ in range(rounds))
    return means[25], means[975]

titles = [r for r in items if r["kind"] == "title"]
details = [r for r in items if r["kind"] == "detail"]
print(f"{len(items)} lines ({len(titles)} names, {len(details)} descriptions)\n")
print(f"| candidate | score % (95% CI) | wrong % | misleading % | names score % | descriptions score % | median ms (Mac) |")
print("|---|---|---|---|---|---|---|")
rows = []
for name in names:
    score, wrong, misleading = stats(items, name)
    low, high = interval(items, name)
    rows.append((score, f"| {name} | {score:.0f} ({low:.0f}–{high:.0f}) | {wrong:.0f} | {misleading:.0f} | {stats(titles, name)[0]:.0f} | {stats(details, name)[0]:.0f} | {summaries.get(name, {}).get('median_ms', '?')} |"))
for _, row in sorted(rows, reverse=True):
    print(row)
