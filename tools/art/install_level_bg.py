#!/usr/bin/env python3
"""Installs the producer's level backgrounds (the picture behind the board of a district's levels):

  python tools/art/install_level_bg.py <folder> [district id ...]
  e.g.  python tools/art/install_level_bg.py assets/art_incoming bazaar skyclub

Reads <folder>/level_bg_<district id>.png (ChatGPT portrait 2:3, 1024x1536; any portrait size of at least 720 px
wide is fine), cuts the middle 9:16 out of it, scales it to 720x1280 and lifts it by 7% (see LIFT)
-> assets/images/districts/<id>/level_bg.png.
Without district ids every level_bg_<id>.png found in the folder is installed. The files are recorded in
assets/art_ready/installed.json (gen_art.py leaves them alone). Run python tools/gen_defold.py afterwards: it puts
the pictures into the registry (client/assets_index.lua); the level screen uses them at once
(assets.level_bg_key), the other districts keep the common backdrop. The clouds are NOT drawn on the picture: the
game moves its own (client/level_sky.lua).
"""
import json
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import installed as inst  # noqa: E402

IMAGES = os.path.join(inst.ROOT, "assets", "images")
SIZE = (720, 1280)
# ChatGPT puts the scenery at the very bottom edge of the picture; there the booster bar and the bonus bar cover it.
# The picture is lifted: its top LIFT of the height is cut off (calm sky) and the bottom is refilled with the last row
# (hidden behind the bars), so the scenery shows between the board and the bar.
LIFT = 0.07


def district_ids():
    with open(os.path.join(inst.ROOT, "content", "districts.json"), encoding="utf-8") as f:
        return [d["id"] for d in json.load(f)["districts"]]


def fit_916(im):
    """The middle 9:16 of the picture (a 2:3 canvas loses about 8% of its width on each side)."""
    w, h = im.size
    want = SIZE[0] / SIZE[1]
    if w / h > want:
        nw = round(h * want)
        x0 = (w - nw) // 2
        im = im.crop((x0, 0, x0 + nw, h))
    else:
        nh = round(w / want)
        y0 = (h - nh) // 2
        im = im.crop((0, y0, w, y0 + nh))
    im = im.resize(SIZE, Image.LANCZOS)
    lift = round(SIZE[1] * LIFT)
    if lift > 0:
        out = Image.new("RGB", SIZE)
        out.paste(im.crop((0, lift, SIZE[0], SIZE[1])), (0, 0))
        out.paste(im.crop((0, SIZE[1] - 1, SIZE[0], SIZE[1])).resize((SIZE[0], lift), Image.NEAREST), (0, SIZE[1] - lift))
        im = out
    return im


def main(argv):
    if not argv:
        sys.exit(__doc__)
    folder, wanted = argv[0], argv[1:]
    ids = district_ids()
    for d in wanted:
        if d not in ids:
            sys.exit("unknown district '%s' (known: %s)" % (d, ", ".join(ids)))
    files, sources = inst.load(), inst.load_sources()
    done = 0
    for did in wanted or ids:
        src = os.path.join(folder, "level_bg_%s.png" % did)
        if not os.path.isfile(src):
            if wanted:
                sys.exit("no %s" % src)
            continue
        im = Image.open(src).convert("RGB")
        if im.width < SIZE[0] or im.height < SIZE[1] * 0.9:
            sys.exit("%s is %dx%d: too small (need at least %d px wide, portrait)" % (src, im.width, im.height, SIZE[0]))
        out = fit_916(im)
        rel = "districts/%s/level_bg.png" % did
        path = os.path.join(IMAGES, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        out.save(path, optimize=True)
        inst.record(files, sources, rel, IMAGES)      # listed, no longer a placeholder, no JPEG of the same key left
        done += 1
        print("installed", rel, "from", im.size)
    if done == 0:
        sys.exit("no level_bg_<district>.png in %s" % folder)
    inst.save(files, sources)


if __name__ == "__main__":
    main(sys.argv[1:])
