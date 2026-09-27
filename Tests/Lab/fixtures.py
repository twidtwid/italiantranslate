#!/usr/bin/env python3
"""Turns menu pages (PDFs and images) into phone-camera frames for the lab.

Each page is shot the way people hold a phone over a menu at the table: the whole page from arm's
length, and closer looks at the top and the middle. Frames are 1080x1920 portrait, like the app's
camera, with a little perspective and tilt, uneven warm light, focus blur and sensor noise.

Usage: fixtures.py MANIFEST OUTDIR   (needs pymupdf, numpy, opencv-python-headless)
"""
import json
import pathlib
import random
import sys
import urllib.request

import cv2
import numpy as np
import pymupdf

W, H = 1080, 1920

SHOTS = {
    # name: (None: the whole page fills the width; else the printed text fills the width, centred
    # on this point of the text's own extent: a closer look, the way people frame what they read)
    "page": None,
    "top": (0.5, 0.25),
    "middle": (0.5, 0.6),
    "page4k": None,  # the whole page again at 3840x2160, to see what a sharper capture buys
}


def ink_extent(page):
    """The part of the page with print on it, as fractions of its width and height."""
    gray = cv2.cvtColor(page, cv2.COLOR_BGR2GRAY)
    ink = gray < 160
    columns, rows = np.nonzero(ink.any(axis=0))[0], np.nonzero(ink.any(axis=1))[0]
    height, width = gray.shape
    if len(columns) < 2 or len(rows) < 2:
        return 0.0, 0.0, 1.0, 1.0
    return columns[0] / width, rows[0] / height, columns[-1] / width, rows[-1] / height


def load_pages(entry, root):
    if "file" in entry and not entry["file"].endswith(".pdf"):
        image = cv2.imread(str(root / entry["file"]), cv2.IMREAD_COLOR)
        if image is None:
            raise RuntimeError(f"can't read {entry['file']}")
        return [image]
    if "file" in entry:
        data = (root / entry["file"]).read_bytes()
    else:
        request = urllib.request.Request(entry["url"], headers={"User-Agent": "Mozilla/5.0 (Macintosh) Traduci-lab"})
        data = urllib.request.urlopen(request, timeout=60).read()
    document = pymupdf.open(stream=data, filetype="pdf")
    pages = []
    for index in entry.get("pages", [0]):
        if index >= len(document):
            continue
        pixmap = document[index].get_pixmap(dpi=entry.get("dpi", 200))
        rgb = np.frombuffer(pixmap.samples, dtype=np.uint8).reshape(pixmap.height, pixmap.width, pixmap.n)[:, :, :3]
        pages.append(cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR))
    return pages


def halves(page):
    """A landscape spread (two menu pages side by side) is shot one page at a time."""
    height, width = page.shape[:2]
    if width < height * 1.2:
        return [page]
    return [page[:, : width // 2], page[:, width // 2 :]]


def table(rng, W, H):
    """Dark wood under the menu."""
    base = np.array([34, 52, 78], dtype=np.float32)  # BGR
    grain = cv2.resize(rng.normal(0, 1, (H // 8, 24)).astype(np.float32), (W, H), interpolation=cv2.INTER_CUBIC)
    wood = base + grain[..., None] * np.array([5, 8, 12], dtype=np.float32)
    return np.clip(wood + rng.normal(0, 3, (H, W, 1)), 0, 255).astype(np.float32)


def shoot(page, shot, seed):
    rng = np.random.default_rng(seed)
    factor = 2 if shot.endswith("4k") else 1
    W, H = globals()["W"] * factor, globals()["H"] * factor
    height, width = page.shape[:2]
    if SHOTS[shot] is None:
        scale, cx, cy = 0.92 * W / width, 0.5, 0.5
    else:
        left, top, right, bottom = ink_extent(page)
        fx, fy = SHOTS[shot]
        scale = 0.96 * W / (max(right - left, 0.2) * width)
        cx, cy = left + fx * (right - left), top + fy * (bottom - top)
    angle = np.deg2rad(rng.uniform(-3, 3))
    keystone = rng.uniform(0.03, 0.07)  # the top of the page is a bit further away

    corners = np.array([[0, 0], [width, 0], [width, height], [0, height]], dtype=np.float32)
    centred = (corners - [cx * width, cy * height]) * scale
    centred[:2, 0] *= 1 - keystone  # top edge narrower
    centred[2:, 0] *= 1 + keystone / 2
    rotation = np.array([[np.cos(angle), -np.sin(angle)], [np.sin(angle), np.cos(angle)]], dtype=np.float32)
    target = centred @ rotation.T + [W / 2, H / 2]
    matrix = cv2.getPerspectiveTransform(corners, target.astype(np.float32))

    paper = page.astype(np.float32) * np.array([0.93, 0.95, 0.97], dtype=np.float32)  # not quite white
    warped = cv2.warpPerspective(paper, matrix, (W, H), flags=cv2.INTER_AREA, borderValue=(0, 0, 0))
    mask = cv2.warpPerspective(np.ones((height, width), np.float32), matrix, (W, H), flags=cv2.INTER_LINEAR)
    frame = warped * mask[..., None] + table(rng, W, H) * (1 - mask[..., None])

    # Restaurant light: warm, falling off across the page, darker corners.
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float32)
    direction = rng.uniform(0, 2 * np.pi)
    ramp = ((xs / W - 0.5) * np.cos(direction) + (ys / H - 0.5) * np.sin(direction))
    light = 0.86 + 0.16 * ramp - 0.18 * (((xs / W - 0.5) ** 2 + (ys / H - 0.5) ** 2) * 2)
    frame = frame * light[..., None] * np.array([0.84, 0.94, 1.0], dtype=np.float32)

    frame = cv2.GaussianBlur(frame, (0, 0), (0.9 if shot.startswith("page") else 1.2) * factor)
    frame = frame + rng.normal(0, 3.0, frame.shape).astype(np.float32)
    return np.clip(frame, 0, 255).astype(np.uint8)


def main():
    manifest, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    root = pathlib.Path.cwd()
    made = []
    for entry in json.loads(manifest.read_text()):
        try:
            pages = [half for page in load_pages(entry, root) for half in halves(page)]
        except Exception as error:  # a menu that moved or vanished shouldn't sink the others
            print(f"skip {entry['name']}: {error}")
            continue
        for number, page in enumerate(pages, start=1):
            for shot in entry.get("shots", list(SHOTS)):
                name = f"{entry['name']}-p{number}-{shot}"
                seed = random.Random(name.replace("page4k", "page")).randrange(2**32)  # same framing
                cv2.imwrite(str(out / f"{name}.jpg"), shoot(page, shot, seed), [cv2.IMWRITE_JPEG_QUALITY, 88])
                made.append(name)
    print(f"{len(made)} frames: " + ", ".join(made))


if __name__ == "__main__":
    main()
