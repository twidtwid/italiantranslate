"""The benchmark's lines: every Italian title and description the menu reader found on whole-page
frames (*-page.json in a lab results folder), once each. Usage: sources.py LAB_OUT DIR"""
import glob, json, os, pathlib, sys

out, seen = pathlib.Path(sys.argv[2]), {}
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*-page.json"))):
    frame = os.path.basename(path)[:-5]
    for entry in json.load(open(path))["entries"]:
        if entry["foreign"]:
            continue
        for kind, text in [("title", entry["title"])] + [("detail", d) for d in entry["details"]]:
            seen.setdefault(text, {"text": text, "kind": kind, "entry": entry["kind"], "frame": frame})
out.mkdir(parents=True, exist_ok=True)
json.dump(list(seen.values()), open(out / "sources.json", "w"), ensure_ascii=False, indent=1)
print(f"{len(seen)} lines in {out / 'sources.json'}")
