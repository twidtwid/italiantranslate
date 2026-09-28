"""Blind-grade every candidate's English for every benchmark line with Claude: DIR/judged.jsonl.

Usage: judge.py DIR   (OPENROUTER_API_KEY in the environment; resumes where it stopped)
"""
import json, random, pathlib, sys, concurrent.futures as cf
import os, time
import httpx

here = pathlib.Path(sys.argv[1])
rows = json.load(open(here / "sources.json"))
candidates = {p.stem: json.load(open(p))["translations"] for p in sorted((here / "candidates").glob("*.json"))}
names = sorted(candidates)
done_path = here / "judged.jsonl"
done = {}
if done_path.exists():
    for line in open(done_path):
        item = json.loads(line)
        if set(item["scores"]) == set(names):
            done[item["text"]] = item

KIND = {"heading": "a section heading", "item": "a dish on a menu", "text": "running text (a paragraph, a note or a sign)"}
SCHEMA = {
    "type": "object",
    "properties": {"ratings": {"type": "array", "items": {
        "type": "object",
        "properties": {
            "label": {"type": "string"},
            "score": {"type": "integer", "enum": [0, 1, 2]},
            "misleading": {"type": "boolean"},
            "note": {"type": "string"},
        },
        "required": ["label", "score", "misleading", "note"], "additionalProperties": False}}},
    "required": ["ratings"], "additionalProperties": False,
}
JUDGE = "anthropic/claude-sonnet-5"  # through OpenRouter

def ask(prompt):
    for attempt in range(4):
        r = httpx.post("https://openrouter.ai/api/v1/chat/completions", timeout=300, headers={"Authorization": f"Bearer {os.environ['OPENROUTER_API_KEY']}"}, json={
            "model": JUDGE, "max_tokens": 8000, "reasoning": {"effort": "medium"},
            "response_format": {"type": "json_schema", "json_schema": {"name": "grades", "strict": True, "schema": SCHEMA}},
            "messages": [{"role": "user", "content": prompt}]})
        if r.status_code == 200:
            choice = r.json()["choices"][0]
            if choice.get("finish_reason") in ("length", "content_filter"):
                raise RuntimeError(f"{choice.get('finish_reason')}")
            return choice["message"]["content"]
        time.sleep(5 * (attempt + 1))
    raise RuntimeError(f"HTTP {r.status_code}: {r.text[:200]}")

def judge(row):
    labels = [chr(65 + i) for i in range(len(names))]
    order = names[:]
    random.Random(row["text"]).shuffle(order)
    options = "\n".join(f"{label}: {candidates[name].get(row['text'], '')}" for label, name in zip(labels, order))
    where = "a plaque at a vineyard" if row["frame"].startswith("plaque") else "an Italian restaurant menu"
    part = "its name" if row["kind"] == "title" else "its description, ingredients or allergens"
    prompt = f"""A diner in Italy points a phone at {where}. An app reads the text with OCR and shows it in English. Grade each English version of this Italian text, which is {part} of {KIND.get(row['entry'], 'an entry')}. The Italian may contain OCR mistakes; judge each English against what the Italian most plausibly says.

Italian: {row['text']}

English versions:
{options}

Scores: 2 = accurate and natural, what a knowledgeable translator would give a diner (a dish with no English name may keep its Italian name, ideally explained). 1 = understandable but off: awkward, partly untranslated, a minor error, or a dish name left unexplained where an explanation matters. 0 = wrong or misleading: wrong food or meaning, invented content, commentary instead of a translation, or important content missing.
misleading = true if a diner could be misled about what the food is or what is in it (ingredients, allergens, raw vs cooked, meat vs fish).
Rate every label. Keep each note under 15 words."""
    text = ask(prompt)
    by_label = {r["label"]: r for r in json.loads(text)["ratings"]}
    scores = {name: by_label[label] for label, name in zip(labels, order) if label in by_label}
    return {"text": row["text"], "kind": row["kind"], "entry": row["entry"], "frame": row["frame"], "scores": scores}

todo = [row for row in rows if row["text"] not in done]
print(f"{len(done)} judged already, {len(todo)} to go, candidates: {names}")
with open(done_path, "a") as out, cf.ThreadPoolExecutor(4) as pool:
    futures = {pool.submit(judge, row): row for row in todo}
    for count, future in enumerate(cf.as_completed(futures), 1):
        try:
            item = future.result()
        except Exception as error:
            print("error:", error, file=sys.stderr)
            continue
        if set(item["scores"]) != set(names):
            print("missing labels for", item["text"], file=sys.stderr)
            continue
        out.write(json.dumps(item, ensure_ascii=False) + "\n")
        out.flush()
        if count % 25 == 0:
            print(count, "done")
