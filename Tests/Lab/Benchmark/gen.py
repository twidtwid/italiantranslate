"""Translate every benchmark line with one on-device candidate model: DIR/candidates/NAME.json.

Usage: gen.py DIR NAME REPO   (DIR holds sources.json and inputs.json; REPO a Hugging Face model)
NAME picks the prompt: opus-mt (Marian), translategemma-* (its own template), gemma4-* (mlx-vlm),
anything else an mlx-lm chat model.
"""
import json, sys, time, pathlib
here = pathlib.Path(sys.argv[1])
name, repo = sys.argv[2], sys.argv[3]
inputs = json.load(open(here / "inputs.json"))
rows = json.load(open(here / "sources.json"))
out, times = {}, []
SYSTEM = ("You translate Italian restaurant menus and signs into English for a diner. Translate the text into "
          "natural English. Keep proper names (places, producers, brands, named dishes with no English name) as "
          "they are. Output only the English translation of the text, nothing else.")

if name == "opus-mt":
    from transformers import MarianMTModel, MarianTokenizer
    import torch
    tok = MarianTokenizer.from_pretrained(repo); model = MarianMTModel.from_pretrained(repo).eval()
    for row in rows:
        text = inputs[row["text"]]
        t0 = time.time()
        with torch.no_grad():
            ids = model.generate(**tok([text], return_tensors="pt"), num_beams=1, max_new_tokens=256)
        out[row["text"]] = tok.decode(ids[0], skip_special_tokens=True)
        times.append(time.time() - t0)
elif name.startswith("gemma4"):
    from mlx_vlm import load, generate
    from mlx_vlm.prompt_utils import apply_chat_template
    model, processor = load(repo)
    for row in rows:
        text = inputs[row["text"]]
        messages = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": text}]
        prompt = apply_chat_template(processor, model.config, messages, num_images=0)
        t0 = time.time()
        result = generate(model, processor, prompt, max_tokens=300, temperature=0.0, verbose=False)
        times.append(time.time() - t0)
        out[row["text"]] = getattr(result, "text", result).strip()
else:
    from mlx_lm import load, generate
    from mlx_lm.sample_utils import make_sampler
    model, tok = load(repo)
    for stop in ["<end_of_turn>", "<|im_end|>", "<turn|>", "<end_of_turn>\n"]:
        try:
            tok.add_eos_token(stop)
        except Exception:
            pass
    sampler = make_sampler(temp=0.0)
    for row in rows:
        text = inputs[row["text"]]
        if name.startswith("translategemma"):
            messages = [{"role": "user", "content": [{"type": "text", "source_lang_code": "it", "target_lang_code": "en", "text": text}]}]
            prompt = tok.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)
        else:
            messages = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": text}]
            try:
                prompt = tok.apply_chat_template(messages, add_generation_prompt=True, tokenize=False, enable_thinking=False)
            except TypeError:
                prompt = tok.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)
        t0 = time.time()
        result = generate(model, tok, prompt=prompt, max_tokens=300, sampler=sampler)
        times.append(time.time() - t0)
        for stop in ["<end_of_turn>", "<|im_end|>", "<turn|>"]:
            result = result.split(stop)[0]
        out[row["text"]] = result.strip()
times.sort()
summary = {"name": name, "repo": repo, "median_ms": round(times[len(times) // 2] * 1000), "p90_ms": round(times[int(len(times) * 0.9)] * 1000)}
(here / "candidates").mkdir(exist_ok=True)
json.dump({"summary": summary, "translations": out}, open(here / "candidates" / f"{name}.json", "w"), ensure_ascii=False, indent=1)
print(summary)
