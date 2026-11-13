#!/usr/bin/env python3
"""Cuts a sheet of room items drawn on magenta into the items of a district (assets/images/districts/<id>/<task>.png
and <task>_ghost.png) and writes their new size into content/district_layouts.json (place and scale are kept).

  python3 tools/art/install_items_sheet.py <sheet.png> <cols>x<rows> <district> task1,task2,...   # '-' skips a cell

An item keeps the area it had in the room (its old w x h), with the proportions of the new drawing, and is at most
GROW times wider or taller than before. Uses the keying of tools/art/import_incoming.py. The files are recorded in
assets/art_ready/installed.json. Run python3 tools/gen_defold.py afterwards.
"""
import json
import math
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import import_incoming as imp  # noqa: E402
import installed as inst  # noqa: E402
from gen_art import ghost_image  # noqa: E402

GROW = 1.3
LAYOUTS = os.path.join(inst.ROOT, "content", "district_layouts.json")


def main():
    path, grid, did, names = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].split(",")
    cols, rows = (int(v) for v in grid.split("x"))
    with open(LAYOUTS, encoding="utf-8") as f:
        layouts = json.load(f)
    items = layouts[did]["items"]
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
        if name not in items:
            sys.exit("district %s has no item %s" % (did, name))
        a = alpha[y0:y1, x0:x1]
        box = imp.bbox(a)
        if not box:
            sys.exit("empty cell for " + name)
        bx0, by0, bx1, by1 = box
        if bx0 == 0 or by0 == 0 or bx1 == x1 - x0 or by1 == y1 - y0:
            print("WARNING %s touches the edge of its cell: check the picture" % name)
        it = items[name]
        bw, bh = bx1 - bx0, by1 - by0
        k = math.sqrt(it["w"] * it["h"] / float(bw * bh))
        k = min(k, GROW * it["w"] / bw, GROW * it["h"] / bh)
        size = (max(1, round(bw * k)), max(1, round(bh * k)))
        sprite = imp.resize_rgba(color[y0:y1, x0:x1][by0:by1, bx0:bx1], a[by0:by1, bx0:bx1], size)
        im = Image.fromarray(sprite, "RGBA")
        rel = "districts/%s/%s.png" % (did, name)
        out = os.path.join(inst.ROOT, "assets", "images", rel)
        im.save(out, optimize=True)
        ghost_image(im).save(out[:-4] + "_ghost.png", optimize=True)
        files.add(rel)
        files.add(rel[:-4] + "_ghost.png")
        print("installed %s %dx%d (was %dx%d)" % (rel, size[0], size[1], it["w"], it["h"]))
        it["w"], it["h"] = size
    inst.save(files)
    with open(LAYOUTS, "w", encoding="utf-8", newline="") as f:
        f.write(TEXT(layouts))


def TEXT(layouts):
    return json.dumps(layouts, indent=2, ensure_ascii=False) + "\n"


if __name__ == "__main__":
    main()
