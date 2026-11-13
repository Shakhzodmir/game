#!/usr/bin/env python3
"""Draws the template of the winding map road that the producer gives to the painter (ChatGPT) with the prompt of a
map background: assets/art_incoming/_road_template.png, 1024x1536. The cream shape is the road, the green is the
town. The same curve is tools/gen_map.py road_x, so the levels stand on the painted road.

  python3 tools/art/road_template.py [out.png]
"""
import math
import os
import sys

from PIL import Image, ImageDraw

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
W, H = 1024, 1536
SWING = 120 * W / 720.0      # tools/gen_map.py ROAD_SWING in the pixels of the template
HALF = 145                   # half the width of the road: 204 px of the 720 px map, a level node is 160


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "assets", "art_incoming", "_road_template.png")
    im = Image.new("RGB", (W, H), (150, 200, 140))
    d = ImageDraw.Draw(im)
    for y in range(-HALF, H + HALF, 2):
        x = W / 2 + SWING * math.sin(2 * math.pi * y / H)
        d.ellipse((x - HALF, y - HALF, x + HALF, y + HALF), fill=(245, 232, 205))
    im.save(out)
    print("wrote", out)


if __name__ == "__main__":
    main()
