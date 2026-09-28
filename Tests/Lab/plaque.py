#!/usr/bin/env python3
"""Draws plaque.png: a winery's corten-steel plaque, light letters on rust, paragraphs of prose.

From a TestFlight report (a plaque read as dishes, with "prices" and repeated lines); the wording
is a paraphrase, not the real plaque. Usage: plaque.py OUT.png [FONT.ttf] (needs pillow)
"""
import random
import sys

from PIL import Image, ImageDraw, ImageFont

WIDTH, HEIGHT, MARGIN = 1100, 1200, 90
TITLE = "LA SCALA ELICOIDALE"
PARAGRAPHS = [
    "La rampa elicoidale che sale a spirale verso la vigna è un'opera scultorea che deve essere "
    "percorsa con attenzione, perché i gradini di differente altezza seguono il percorso ascendente "
    "in modo variato.",
    "La lunghezza della «passeggiata architettonica» è di circa 101 metri: dalla cantina alla terrazza "
    "sul lato opposto della collina si sale attraverso 117 gradini.",
    "La costruzione è stata realizzata da una carpenteria metallica toscana nel periodo che va da "
    "luglio a ottobre dell'anno 2012: un'opera d'arte e di ingegno in acciaio corten, dal peso di "
    "105 tonnellate.",
    "Architetti, artisti, ingegneri e maestranze ringraziano la famiglia per l'audacia, il coraggio e "
    "la volontà di realizzare un progetto che permette di preservare e ammirare un frammento di uno "
    "dei territori più belli del mondo: la Toscana e il Chianti Classico.",
]


def wrap(draw, text, font, width):
    lines, line = [], ""
    for word in text.split():
        candidate = f"{line} {word}".strip()
        if draw.textlength(candidate, font=font) <= width:
            line = candidate
        else:
            lines.append(line)
            line = word
    return lines + [line]


def main():
    out = sys.argv[1]
    regular = sys.argv[2] if len(sys.argv) > 2 else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
    bold = regular.replace("DejaVuSans.ttf", "DejaVuSans-Bold.ttf")
    random.seed(7)
    image = Image.new("RGB", (WIDTH, HEIGHT), (96, 50, 28))
    pixels = image.load()
    for y in range(HEIGHT):  # weathered steel: blotches of darker and redder rust
        for x in range(0, WIDTH, 2):
            shade = random.randint(-10, 10) + (8 if (x // 90 + y // 70) % 3 == 0 else 0)
            color = (96 + shade, 50 + shade // 2, 28 + shade // 3)
            pixels[x, y] = color
            if x + 1 < WIDTH:
                pixels[x + 1, y] = color
    draw = ImageDraw.Draw(image)
    ink = (238, 228, 214)
    title_font = ImageFont.truetype(bold, 46)
    body_font = ImageFont.truetype(regular, 33)
    y = MARGIN
    draw.text(((WIDTH - draw.textlength(TITLE, font=title_font)) / 2, y), TITLE, font=title_font, fill=ink)
    y += 110
    for paragraph in PARAGRAPHS:
        for line in wrap(draw, paragraph, body_font, WIDTH - 2 * MARGIN):
            draw.text((MARGIN, y), line, font=body_font, fill=ink)
            y += 47
        y += 38
    image.save(out)
    print(f"wrote {out} ({WIDTH}x{HEIGHT}), text ends at y={y}")


if __name__ == "__main__":
    main()
