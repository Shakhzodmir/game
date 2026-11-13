#!/usr/bin/env python3
"""Makes the map backgrounds of the game from the producer's pictures: assets/art_ready/map/map_bg_<district>.png
-> assets/images/mapbg/bg_<district>.png (720x1080) with the bottom FEATHER px fading to transparent.

The map lays the tiles of a district one over another (content/map.json tile_step, tile_feather): the faded bottom
of a tile lies over the top of the tile below, so the sky of the picture is hidden and the ground runs on.

  python3 tools/art/feather_mapbg.py [district ...]      # default: every map_bg_*.png of art_ready
"""
import glob
import os
import sys

import numpy as np
from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
READY = os.path.join(ROOT, "assets", "art_ready", "map")
OUT = os.path.join(ROOT, "assets", "images", "mapbg")
FEATHER = 110   # the same as tools/gen_map.py TILE_FEATHER


def feather(im):
    im = im.convert("RGB").resize((720, 1080), Image.LANCZOS)
    a = np.full((1080, 720), 255, np.uint8)
    a[1080 - FEATHER:, :] = (np.linspace(1.0, 0.0, FEATHER) * 255).astype(np.uint8)[:, None]
    im.putalpha(Image.fromarray(a))
    return im


def main():
    ids = sys.argv[1:] or sorted(os.path.basename(p)[3:-4] for p in glob.glob(os.path.join(OUT, "bg_*.png")))
    for did in ids:
        src = os.path.join(READY, "map_bg_%s.png" % did)
        out = os.path.join(OUT, "bg_%s.png" % did)
        if not os.path.isfile(src):          # a district installed by tools/art/install_district.py: its own file
            src = out
            if Image.open(src).mode == "RGBA":
                print("mapbg/bg_%s.png is feathered already" % did)
                continue
        feather(Image.open(src)).save(out, optimize=True)
        print("wrote mapbg/bg_%s.png" % did)


if __name__ == "__main__":
    main()
