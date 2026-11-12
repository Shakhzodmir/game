#!/usr/bin/env python3
"""Cuts a sheet of icons drawn on magenta into game icons (assets/images/ui/icons/<name>.png, 96x96).

  python3 tools/art/install_icon_sheet.py <sheet.png> <cols>x<rows> name1,name2,...   # '-' skips a cell

Uses the keying of tools/art/import_incoming.py (no pink fringe). The names are the icon names of the game
(ui/icons/<name>); the files are recorded in assets/art_ready/installed.json, so tools/art/gen_art.py keeps them.
Run python3 tools/gen_defold.py afterwards.
"""
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import import_incoming as imp  # noqa: E402
import installed as inst  # noqa: E402

SIZE = 96


def main():
    path, grid, names = sys.argv[1], sys.argv[2], sys.argv[3].split(",")
    cols, rows = (int(v) for v in grid.split("x"))
    rgb, alpha = imp.load_input(path)
    if alpha is None:
        key, _ = imp.estimate_key(rgb)
        color, alpha, _ = imp.key_out(rgb, key)
    else:
        color = rgb.astype("float32")
    h, w = alpha.shape
    files = inst.load()
    for name, (x0, y0, x1, y1) in zip(names, imp.cell_boxes(w, h, cols, rows)):
        if name == "-":
            continue
        a = alpha[y0:y1, x0:x1]
        box = imp.bbox(a)
        if not box:
            sys.exit("empty cell for " + name)
        bx0, by0, bx1, by1 = box
        k = min((SIZE - 4) / (bx1 - bx0), (SIZE - 4) / (by1 - by0))
        size = (max(1, round((bx1 - bx0) * k)), max(1, round((by1 - by0) * k)))
        sprite = imp.resize_rgba(color[y0:y1, x0:x1][by0:by1, bx0:bx1], a[by0:by1, bx0:bx1], size)
        canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
        im = Image.fromarray(sprite, "RGBA")
        canvas.alpha_composite(im, ((SIZE - im.width) // 2, (SIZE - im.height) // 2))
        rel = "ui/icons/%s.png" % name
        canvas.save(os.path.join(inst.ROOT, "assets", "images", rel), optimize=True)
        files.add(rel)
        print("installed", rel)
    inst.save(files)


if __name__ == "__main__":
    main()
