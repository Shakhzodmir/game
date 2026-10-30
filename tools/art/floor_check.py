#!/usr/bin/env python3
"""Pixel facts the dance-floor art has to keep, or the floor stops being readable.

The producer's report (docs/handoff/dancefloor-readability.md): unlit tiles were barely darker than the ordinary
cells and the goal icon showed the end state, so players could not tell what was still to do. The facts:

  * an unlit tile (floor_1, floor_2) is clearly darker and more saturated than the lavender cell, and violet;
  * a lit tile (floor_lit) is gold;
  * the half stage (floor_half, a two-layer tile after its first hit) is a violet frame around a gold core;
  * the four stages look different from each other;
  * the goal icon is the unlit (violet) tile in front of the gold tile it turns into.

Standard library only (a small PNG reader), so the test suite and CI can run it without numpy or Pillow:

    python3 tools/art/floor_check.py [images_dir]     # default: assets/images
        prints "floor art ok" (exit status 0), or one line per problem (exit status 1)

tests/client/floor_art_test.lua runs it; tools/art/gen_art.py reports the same findings after a render.
"""
import colorsys
import os
import struct
import sys
import zlib

MIN_DARKER = 12.0      # L* the unlit plate has to be darker than the lavender cell
MIN_SATURATION = 0.22  # HSV saturation of the unlit plate (the cell has 0.09, the old plate had 0.18)


def read_png(path):
    """(width, height, channels, rows) of an 8-bit RGB / RGBA PNG without interlacing (rows are bytearrays)."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path}: not a PNG")
    pos, idat, ihdr = 8, [], None
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + n]
        pos += 12 + n
        if kind == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", chunk)
        elif kind == b"IDAT":
            idat.append(chunk)
        elif kind == b"IEND":
            break
    w, h, depth, ctype, _, _, interlace = ihdr
    if depth != 8 or ctype not in (2, 6) or interlace:
        raise ValueError(f"{path}: only 8-bit RGB / RGBA PNGs without interlacing are read (depth {depth}, type {ctype})")
    bpp = 3 if ctype == 2 else 4
    stride = w * bpp
    raw = zlib.decompress(b"".join(idat))
    rows, prev, i = [], bytearray(stride), 0
    for _ in range(h):
        ftype = raw[i]
        line = bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        if ftype == 1:                                           # Sub
            for x in range(bpp, stride):
                line[x] = (line[x] + line[x - bpp]) & 255
        elif ftype == 2:                                         # Up
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 255
        elif ftype == 3:                                         # Average
            for x in range(stride):
                left = line[x - bpp] if x >= bpp else 0
                line[x] = (line[x] + ((left + prev[x]) >> 1)) & 255
        elif ftype == 4:                                         # Paeth
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x - bpp] if x >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pred) & 255
        elif ftype != 0:
            raise ValueError(f"{path}: unknown PNG filter {ftype}")
        rows.append(line)
        prev = line
    return w, h, bpp, rows


class Image:
    def __init__(self, path):
        self.w, self.h, self.bpp, self.rows = read_png(path)

    def mean(self, box):
        """Mean colour (0..1 floats) of the pixels in box = (x0, y0, x1, y1), half-open."""
        x0, y0, x1, y1 = box
        tot, n = [0, 0, 0], 0
        for y in range(y0, y1):
            row = self.rows[y]
            for x in range(x0, x1):
                o = x * self.bpp
                tot[0] += row[o]
                tot[1] += row[o + 1]
                tot[2] += row[o + 2]
                n += 1
        return tuple(t / n / 255.0 for t in tot)

    def pixels(self):
        out = []
        for row in self.rows:
            out.extend(row[x * self.bpp:x * self.bpp + 3] for x in range(self.w))
        return out


def lstar(rgb):
    """CIE L* of an sRGB colour (0..1)."""
    def lin(c):
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    y = 0.2126 * lin(rgb[0]) + 0.7152 * lin(rgb[1]) + 0.0722 * lin(rgb[2])
    return 116 * y ** (1 / 3) - 16 if y > 0.008856 else 903.3 * y


def is_violet(c):
    return c[2] > c[0] > c[1]


def is_gold(c, blue_max):
    return c[0] > 0.9 and c[2] < blue_max and c[0] > c[1] > c[2]


def distance(a, b):
    """Mean absolute difference of two images of the same size (0..1)."""
    pa, pb = a.pixels(), b.pixels()
    tot = sum(abs(p[k] - q[k]) for p, q in zip(pa, pb) for k in range(3))
    return tot / (3 * len(pa) * 255.0)


def check(images_dir):
    """The list of problems (empty: the floor art is readable)."""
    def load(rel):
        return Image(os.path.join(images_dir, rel))

    try:
        cell = load("board/cell_b.png")
        stages = {k: load(f"blockers/floor_{k}.png") for k in ("2", "1", "half", "lit")}
        icon = load("ui/icons/goal_floor.png")
    except FileNotFoundError as e:
        return [f"dance floor art missing: {e.filename}"]
    problems = []
    lavender = lstar(cell.mean((10, 10, 86, 86)))
    for k in ("1", "2"):
        plate = stages[k].mean((8, 8, 152, 152))
        name = f"blockers/floor_{k}.png"
        if lavender - lstar(plate) < MIN_DARKER:
            problems.append(f"{name}: an unlit tile must be at least {MIN_DARKER:.0f} L* darker than the cell "
                            f"({lstar(plate):.0f} vs {lavender:.0f})")
        if colorsys.rgb_to_hsv(*plate)[1] < MIN_SATURATION:
            problems.append(f"{name}: an unlit tile must be saturated (S >= {MIN_SATURATION})")
        if not is_violet(plate):
            problems.append(f"{name}: an unlit tile must be violet")
    if not is_gold(stages["lit"].mean((8, 8, 152, 152)), 0.75):
        problems.append("blockers/floor_lit.png: a lit tile must be gold")
    half = stages["half"]
    if not is_gold(half.mean((60, 60, 100, 100)), 0.8):
        problems.append("blockers/floor_half.png: the core of a half-lit tile must be gold")
    if not is_violet(half.mean((8, 30, 16, 130))):
        problems.append("blockers/floor_half.png: the frame of a half-lit tile must stay violet")
    names = list(stages)
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            if distance(stages[names[i]], stages[names[j]]) < 0.02:
                problems.append(f"blockers/floor_{names[i]}.png and floor_{names[j]}.png look alike")
    # the goal icon is what the player is asked to do: the unlit tile as the board starts, with gold behind it
    if not is_violet(icon.mean((20, 30, 60, 70))):
        problems.append("ui/icons/goal_floor.png: the goal icon must show the unlit (violet) tile in front")
    if not is_gold(icon.mean((75, 30, 82, 60)), 0.6):
        problems.append("ui/icons/goal_floor.png: the goal icon must show the gold tile it turns into behind it")
    return problems


def main(argv):
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    images = argv[1] if len(argv) > 1 else os.path.join(root, "assets", "images")
    problems = check(images)
    if problems:
        for p in problems:
            print(p)
        return 1
    print("floor art ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
