#!/usr/bin/env python3
"""Draws a stretch of the game map the way the game shows it, without building the game: the background tiles of
the district, the gate, the level nodes (content/map.json). For looking at new map art before it goes in.

  python3 tools/art/map_preview.py <out.png> [first_level] [levels] [--bg district=picture.png ...]

--bg tries a picture as the background of a district without installing it.
"""
import json
import os
import sys

from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
IMAGES = os.path.join(ROOT, "assets", "images")


def load(rel):
    return Image.open(os.path.join(IMAGES, rel + ".png")).convert("RGBA")


def main():
    args, bgs = [], {}
    it = iter(sys.argv[1:])
    for a in it:
        if a == "--bg":
            k, v = next(it).split("=", 1)
            bgs[k] = v
        else:
            args.append(a)
    out = args[0]
    first = int(args[1]) if len(args) > 1 else 1
    count = int(args[2]) if len(args) > 2 else 8
    with open(os.path.join(ROOT, "content", "map.json"), encoding="utf-8") as f:
        m = json.load(f)
    nodes = [n for n in m["nodes"] if first <= n["level"] < first + count]
    lo, hi = nodes[0]["y"] - 330, nodes[-1]["y"] + 330
    th = m["tile_h"]
    img = Image.new("RGBA", (720, hi - lo), (255, 255, 255, 255))

    def put(im, x, y):  # centre at world x, y (y up)
        img.alpha_composite(im, (int(x - im.width / 2), int(hi - y - im.height / 2)))

    for sg in m["segments"]:
        if sg["y1"] < lo or sg["y0"] > hi:
            continue
        did = sg["district"]
        bg = Image.open(bgs[did]).convert("RGBA") if did in bgs else load(sg["bg"])
        bg = bg.resize((720, th), Image.LANCZOS)
        layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
        idx = 0
        while sg["y0"] + idx * th < min(sg["y1"], hi):
            y = sg["y0"] + idx * th + th / 2
            if y + th / 2 >= lo:
                layer.alpha_composite(bg, (0, int(hi - y - th / 2))) if -th < hi - y - th / 2 < img.height else None
            idx += 1
        # a stretch ends at y1: the next district covers what is above
        top = max(0, int(hi - sg["y1"]))
        bottom = min(img.height, int(hi - sg["y0"]))
        if bottom > top:
            img.alpha_composite(layer.crop((0, top, 720, bottom)), (0, top))
        for d in sg["deco"]:
            if lo <= d["y"] <= hi:
                im = load(d["image"])
                s = d.get("scale", 1)
                put(im.resize((int(im.width * s), int(im.height * s)), Image.LANCZOS), d["x"], d["y"])
        if lo <= sg["gate_y"] <= hi:
            put(load(sg["gate"]).resize((720, 480), Image.LANCZOS), 360, sg["gate_y"])
    for n in nodes:
        size = m["node"]["day"]["size"]
        key = "done" if n["level"] < first + count // 2 else "locked"
        put(load(m["node"]["day"]["states"][key]).resize((size, size), Image.LANCZOS), n["x"], n["y"])
    img.convert("RGB").save(out)
    print("wrote", out, img.size)


if __name__ == "__main__":
    main()
