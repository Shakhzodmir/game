#!/usr/bin/env python3
"""Writes content/map.json: where every level sits on the long vertical game map (WP-7).

    python3 tools/gen_map.py            # rewrite content/map.json
    python3 tools/gen_map.py --check    # exit 1 if the file would change

The file is data, not code: the producer's art arrives later and the layout can be edited by hand
(the tests only check the rules in tests/client/map_model_test.lua). Coordinates are world pixels,
x to the right (0..720), y UP from the bottom of the map. The format is described in
docs/handoff/WP-7.md. The five districts of content/districts.json take 20 levels each.
"""
import json
import math
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
OUT = os.path.join(ROOT, "content", "map.json")

LEVELS = 100
PER_SEGMENT = 20
STEP = 190          # vertical distance between two levels
GAP = 480           # extra distance where the path crosses a district gate
FIRST_Y = 430       # y of level 1
TOP_ROOM = 800      # room above level 100 for the "new levels soon" sign
AMPLITUDE = 170     # how far the path swings to the sides
DECO_PER_SEGMENT = 12


def level_y(n):
    seg = (n - 1) // PER_SEGMENT
    return FIRST_Y + (n - 1) * STEP + seg * GAP


def level_x(n):
    first = (n - 1) % PER_SEGMENT == 0
    last = n % PER_SEGMENT == 0
    if first or last or (n >= 60 and n % 10 == 0):     # at a gate and at the concert levels (60, 70 ... 100) the path is in the middle
        return 360
    return 360 + int(round(AMPLITUDE * math.sin(n * 0.8)))


def build():
    with open(os.path.join(ROOT, "content", "districts.json"), encoding="utf-8") as f:
        ids = [d["id"] for d in json.load(f)["districts"]]
    assert len(ids) * PER_SEGMENT == LEVELS, "five districts of 20 levels"
    world_h = level_y(LEVELS) + TOP_ROOM
    nodes = [{"level": n, "x": level_x(n), "y": level_y(n)} for n in range(1, LEVELS + 1)]
    segments = []
    for i, did in enumerate(ids):
        first, last = i * PER_SEGMENT + 1, (i + 1) * PER_SEGMENT
        y0 = 0 if i == 0 else (level_y(first - 1) + level_y(first)) // 2
        y1 = world_h if i == len(ids) - 1 else (level_y(last) + level_y(last + 1)) // 2
        gate_y = 230 if i == 0 else y0
        deco = []
        span = (y1 - y0) - 900 if i < len(ids) - 1 else (level_y(last) - y0)
        for j in range(DECO_PER_SEGMENT):
            side = -1 if j % 2 == 0 else 1
            y = y0 + 420 + int(span * (j + 0.5) / DECO_PER_SEGMENT) - 200
            deco.append({
                "image": "map/deco_%s_%d" % (did, j % 6 + 1),
                "x": 360 + side * (270 + (j * 17) % 20),
                "y": y,
                "scale": round(0.8 + ((j * 37) % 5) * 0.06, 2),
            })
        segments.append({
            "id": did, "district": did, "first": first, "last": last, "y0": y0, "y1": y1,
            "bg": "mapbg/bg_" + did, "gate": "mapbg/gate_" + did, "gate_y": gate_y,
            "tint": {"cafe": "#F7D9B5", "jazz": "#CFC3F2", "square": "#BFE6D0", "stadium": "#CDEBFF", "garage": "#C5BFD9"}.get(did, "#E6E1F2"),
            "deco": deco,
        })
    return {
        "version": 1,
        "width": 720,
        "world_height": world_h,
        "level_count": LEVELS,
        "tile_h": 1080,
        "node": {
            "day": {"size": 160, "hit": 52, "states": {s: "map/node_day_" + s for s in ("locked", "open", "current", "done")}},
            "concert": {"size": 224, "hit": 66, "states": {s: "map/node_concert_" + s for s in ("locked", "open", "current", "done")}},
        },
        "path": {"dot": "map/path_dot", "dot_done": "map/path_dot_done", "spacing": 34, "size": 44},
        "bit": {"size": 150, "dy": 96},
        "soon": {"y": level_y(LEVELS) + 470},
        "segments": segments,
        "nodes": nodes,
    }


def text(data):
    # compact: one line per node / deco item, readable diffs
    s = json.dumps(data, indent=1, ensure_ascii=False)
    return s + "\n"


def main():
    new = text(build())
    if "--check" in sys.argv:
        with open(OUT, encoding="utf-8") as f:
            if f.read() != new:
                print("content/map.json is stale: run python3 tools/gen_map.py")
                sys.exit(1)
        return
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(new)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
