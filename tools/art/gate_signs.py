#!/usr/bin/env python3
"""Finds the blank signboard of every district gate (assets/images/mapbg/gate_<district>.png, 720x480) and writes
where the map must write the district name: content/map_gates.json  {district: {dx, dy, w}}.

dx, dy = centre of the signboard from the centre of the gate picture (x right, y UP), w = widest text that fits.
tools/gen_map.py copies it into content/map.json (segment field `sign`). Run after a gate picture is installed:

  python3 tools/art/gate_signs.py && python3 tools/gen_map.py
"""
import glob
import json
import os

import numpy as np
from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "content", "map_gates.json")


def board_mask(im, bright=0.86, pale=0.34):
    """Pixels of a pale, almost colourless, opaque surface: the empty signboard."""
    a = np.asarray(im.convert("RGBA")).astype(np.float32) / 255.0
    rgb, alpha = a[..., :3], a[..., 3]
    mx, mn = rgb.max(axis=2), rgb.min(axis=2)
    sat = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-6), 0)
    return (alpha > 0.9) & (mx > bright) & (sat < pale)


def longest_run(flags):
    best, start, cur = (0, 0), None, 0
    for i, f in enumerate(list(flags) + [False]):
        if f and start is None:
            start = i
        if not f and start is not None:
            if i - start > best[1] - best[0]:
                best = (start, i)
            start = None
    return best


def find_sign(path):
    # a white or cream board first; then a tinted one (a wooden plank, a lilac panel)
    return _find(path, 0.86, 0.34) or _find(path, 0.8, 0.5)


def _find(path, bright, pale):
    im = Image.open(path)
    w, h = im.size
    m = board_mask(im, bright, pale)
    # rows where the middle of the picture is board: the board is the tallest such run in the upper two thirds
    mid = m[:, w // 2 - 24: w // 2 + 24].mean(axis=1) > 0.8
    mid[int(h * 0.66):] = False
    y0, y1 = longest_run(mid)
    if y1 - y0 < 24:
        return None
    cy = (y0 + y1) // 2
    row = m[max(y0, cy - 6): min(y1, cy + 6), :].mean(axis=0) > 0.7
    # the run of board pixels that contains the middle column
    x0 = x1 = w // 2
    while x0 > 0 and row[x0 - 1]:
        x0 -= 1
    while x1 < w - 1 and row[x1 + 1]:
        x1 += 1
    return {"dx": int(round((x0 + x1) / 2.0 - w / 2.0)), "dy": int(round(h / 2.0 - cy)), "w": int((x1 - x0) * 0.95),
            "h": int(y1 - y0)}


def main():
    out = {}
    for path in sorted(glob.glob(os.path.join(ROOT, "assets", "images", "mapbg", "gate_*.png"))):
        did = os.path.basename(path)[5:-4]
        s = find_sign(path)
        if s:
            out[did] = s
            print(did, s)
        else:
            print(did, "no signboard found: the default place is used")
    with open(OUT, "w", encoding="utf-8", newline="") as f:
        f.write(json.dumps(out, indent=1, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
