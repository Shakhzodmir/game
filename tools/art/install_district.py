#!/usr/bin/env python3
"""Installs the producer's pictures of a NEW district (districts 6+) from a folder of raw drawings:

  python3 tools/art/install_district.py <district id> <folder> <name in the file names>
  e.g.    tools/art/install_district.py beach assets/art_incoming/bossa bossa

Reads from the folder (drawn on magenta where a cut-out is needed):
  room_<name>_day.png, room_<name>_concert.png -> districts/<id>/bg.png, bg_concert.png   720x1280
  map_bg_<name>.png                            -> mapbg/bg_<id>.png                       720x1080
  gate_<name>.png                              -> mapbg/gate_<id>.png                     720x480
  deco_<name>.png   (sheet 3x2)                -> map/deco_<id>_1..6.png                  160x160
  items_<name>.png  (sheet, see ROOMS)         -> districts/<id>/<task>.png and <task>_ghost.png

The place of every item in the room is the table ROOMS below (x, y = centre in the 720x1280 room, y from the top;
w = width on screen). content/district_layouts.json gets the district; the files are recorded in
assets/art_ready/installed.json. Run python3 tools/gen_defold.py afterwards.
"""
import json
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import import_incoming as imp  # noqa: E402
import installed as inst  # noqa: E402
from gen_art import ghost_image  # noqa: E402

IMAGES = os.path.join(inst.ROOT, "assets", "images")
LAYOUTS = os.path.join(inst.ROOT, "content", "district_layouts.json")
SCALE = 0.7     # items are stored 1/SCALE bigger than they are shown, like the first five districts

# district id -> (grid of the items sheet, [(task id, x, y, width on screen) in the order of the sheet])
ROOMS = {
    "beach": ("3x2", [
        ("guitar", 384, 700, 88),
        ("tiki_bar", 250, 688, 210),
        ("hammock", 596, 800, 200),
        ("surf_speaker", 668, 694, 86),
        ("palm_lights", 76, 694, 150),
        ("cajon", 478, 772, 118),
    ]),
}


def keyed(path):
    rgb, alpha = imp.load_input(path)
    if alpha is None:
        key, _ = imp.estimate_key(rgb)
        color, alpha, _ = imp.key_out(rgb, key)
    else:
        color = rgb.astype("float32")
    return color, alpha


def cut(color, alpha, box, size=None, width=None):
    """The drawing inside box, trimmed; fitted into size (w, h) or scaled to width."""
    x0, y0, x1, y1 = box
    a = alpha[y0:y1, x0:x1]
    b = imp.bbox(a)
    if not b:
        sys.exit("an empty cell in the sheet")
    bx0, by0, bx1, by1 = b
    bw, bh = bx1 - bx0, by1 - by0
    k = width / float(bw) if width else min(size[0] / float(bw), size[1] / float(bh))
    out = (max(1, round(bw * k)), max(1, round(bh * k)))
    return Image.fromarray(imp.resize_rgba(color[y0:y1, x0:x1][by0:by1, bx0:bx1], a[by0:by1, bx0:bx1], out), "RGBA")


def centred(im, size):
    canvas = Image.new("RGBA", size, (0, 0, 0, 0))
    canvas.alpha_composite(im, ((size[0] - im.width) // 2, (size[1] - im.height) // 2))
    return canvas


def main():
    did, folder, name = sys.argv[1], sys.argv[2], sys.argv[3]
    files = inst.load()

    def save(im, rel):
        path = os.path.join(IMAGES, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        im.save(path, optimize=True)
        files.add(rel)
        print("installed", rel, im.size)

    def src(n):
        return os.path.join(folder, n + ".png")

    for view, key in (("day", "bg"), ("concert", "bg_concert")):
        save(Image.open(src("room_%s_%s" % (name, view))).convert("RGB").resize((720, 1280), Image.LANCZOS),
             "districts/%s/%s.png" % (did, key))
    save(Image.open(src("map_bg_" + name)).convert("RGB").resize((720, 1080), Image.LANCZOS), "mapbg/bg_%s.png" % did)

    color, alpha = keyed(src("gate_" + name))
    h, w = alpha.shape
    save(centred(cut(color, alpha, (0, 0, w, h), size=(652, 442)), (720, 480)), "mapbg/gate_%s.png" % did)

    color, alpha = keyed(src("deco_" + name))
    h, w = alpha.shape
    for i, box in enumerate(imp.cell_boxes(w, h, 3, 2), 1):
        save(centred(cut(color, alpha, box, size=(150, 150)), (160, 160)), "map/deco_%s_%d.png" % (did, i))

    grid, places = ROOMS[did]
    cols, rows = (int(v) for v in grid.split("x"))
    color, alpha = keyed(src("items_" + name))
    h, w = alpha.shape
    items = {}
    for (task, x, y, width), box in zip(places, imp.cell_boxes(w, h, cols, rows)):
        im = cut(color, alpha, box, width=width / SCALE)
        rel = "districts/%s/%s.png" % (did, task)
        save(im, rel)
        save(ghost_image(im), rel[:-4] + "_ghost.png")
        items[task] = {"image": "assets/images/" + rel, "ghost": "assets/images/" + rel[:-4] + "_ghost.png",
                       "x": x, "y": y, "scale": SCALE, "w": im.width, "h": im.height}
    with open(LAYOUTS, encoding="utf-8") as f:
        layouts = json.load(f)
    with open(os.path.join(inst.ROOT, "content", "districts.json"), encoding="utf-8") as f:
        tasks = [t["id"] for d in json.load(f)["districts"] if d["id"] == did for t in d["tasks"]]
    if sorted(tasks) != sorted(items):
        sys.exit("the items of ROOMS do not match the tasks of content/districts.json: %s / %s" % (sorted(items), sorted(tasks)))
    layouts[did] = {"bg": "assets/images/districts/%s/bg.png" % did,
                    "bg_concert": "assets/images/districts/%s/bg_concert.png" % did, "bg_scale": 1.0,
                    "items": {t: items[t] for t in tasks}}
    with open(LAYOUTS, "w", encoding="utf-8", newline="") as f:
        f.write(json.dumps(layouts, indent=2, ensure_ascii=False) + "\n")
    inst.save(files)


if __name__ == "__main__":
    main()
