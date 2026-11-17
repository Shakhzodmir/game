"""Redraws only the common level background (assets/images/backgrounds/level_bg.png) WITHOUT clouds: the game draws
drifting clouds over it (client/level_sky.lua, sprite fx/cloud). The full generator (gen_art.py) can no longer run
as a whole: the districts use the producer's installed drawings.

    python tools/art/install_level_sky.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import districts  # noqa: E402
from gen_art import BG_DITHER  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "images", "backgrounds", "level_bg.png")


def main():
    img = districts.bg_level(False).image(opaque=True, dither=BG_DITHER)
    img.save(OUT, optimize=True)
    print("wrote", os.path.normpath(OUT), img.size)


if __name__ == "__main__":
    main()
