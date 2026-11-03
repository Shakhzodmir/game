#!/usr/bin/env python3
"""Reference sheets of the existing art, to attach to ChatGPT when drawing new art (docs/art-brief-chatgpt.md).

  python3 tools/art/make_reference_sheets.py            # writes docs/media/art-reference/*.png

Every sheet is at most 2048 px on a side, labelled, on a light lavender background that shows white edges.
"""

import os
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ASSETS = os.path.join(ROOT, "assets", "images")
MEDIA = os.path.join(ROOT, "docs", "media")
OUT = os.path.join(MEDIA, "art-reference")
BG = (236, 229, 255)
INK = (43, 35, 69)
FONT = os.path.join(ROOT, "assets", "fonts", "Nunito-Bold.ttf")


def font(size):
    return ImageFont.truetype(FONT, size)


def load(path):
    return Image.open(path).convert("RGBA")


def sheet(title, items, cols, cell, scale=1.0, label=True, pad=16, max_w=2048):
    """items = [(label, image)]; every image is fitted into a cell x cell box (after scale)."""
    box = int(cell * scale)
    rows = (len(items) + cols - 1) // cols
    head = 56
    foot = 28 if label else 0
    w = min(max_w, pad + cols * (box + pad))
    h = head + pad + rows * (box + foot + pad)
    im = Image.new("RGBA", (w, h), BG + (255,))
    d = ImageDraw.Draw(im)
    d.text((pad, 12), title, font=font(30), fill=INK)
    for i, (name, img) in enumerate(items):
        r, c = divmod(i, cols)
        x = pad + c * (box + pad)
        y = head + pad + r * (box + foot + pad)
        k = min(box / img.width, box / img.height)
        if k != 1:
            img = img.resize((max(1, int(img.width * k)), max(1, int(img.height * k))), Image.LANCZOS)
        im.alpha_composite(img, (x + (box - img.width) // 2, y + (box - img.height) // 2))
        if label:
            d.text((x, y + box + 2), name[: max(8, box // 9)], font=font(15), fill=INK)
    return im


def files(sub, exclude=()):
    d = os.path.join(ASSETS, sub)
    out = []
    for f in sorted(os.listdir(d)):
        if f.endswith(".png") and not f.endswith("_ghost.png") and f not in exclude:
            out.append((f[:-4], load(os.path.join(d, f))))
    return out


def save(im, name):
    os.makedirs(OUT, exist_ok=True)
    p = os.path.join(OUT, name)
    im.convert("RGB").save(p, optimize=True)
    print("%-34s %dx%d  %d KB" % (name, im.width, im.height, os.path.getsize(p) // 1024))


def main():
    ui = files("ui")
    save(sheet("01  Buttons, panels, ribbon, badges (native size)", ui, 3, 330, 1.0), "01_ui_buttons_panels.png")
    save(sheet("02  Icons (96 px)", files("ui/icons"), 8, 96, 1.15), "02_icons.png")
    pieces = files("pieces") + files("specials")
    save(sheet("03  Pieces (160) and special pieces (192)", pieces, 5, 192, 1.0), "03_pieces_specials.png")
    blockers = files("blockers") + files("board")
    save(sheet("04  Blockers and board tiles", blockers, 8, 160, 0.9), "04_blockers_board.png")
    save(sheet("05  Mascot Bit: seven poses (256 px)", files("bit"), 4, 256, 1.0), "05_bit.png")
    rows = []
    for dist in ("cafe", "jazz", "square", "stadium", "garage"):
        rows += files("districts/" + dist)
    save(sheet("06  Room items of the five districts (restored versions)", rows, 9, 150, 1.0), "06_district_items.png")
    shots = [("town: Lo-fi Cafe", "client_town.png"), ("town: concert mode", "client_town_concert.png"),
             ("town: task", "client_town_task.png"), ("level", "client_level.png"), ("shop", "client_shop.png"),
             ("jukebox", "client_jukebox.png"), ("start window", "client_start.png"), ("results", "client_board_result.png")]
    items = [(n, load(os.path.join(MEDIA, f))) for n, f in shots if os.path.exists(os.path.join(MEDIA, f))]
    save(sheet("07  Screens of the game (540 x 960)", items, 4, 480, 0.8, label=True), "07_screens.png")
    extra = [("logo", load(os.path.join(ASSETS, "logo", "logo.png"))),
             ("level background", load(os.path.join(ASSETS, "backgrounds", "level_bg.png")))]
    for dist in ("cafe", "jazz", "square", "stadium", "garage"):
        p = os.path.join(MEDIA, "district_%s.png" % dist)
        if os.path.exists(p):
            extra.append(("district_" + dist, load(p)))
    save(sheet("08  Logo, level background, district screens", extra, 4, 480, 0.9), "08_logo_backgrounds_districts.png")


if __name__ == "__main__":
    sys.exit(main())
