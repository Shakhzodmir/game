#!/usr/bin/env python3
"""Turns the big OPAQUE pictures of the loose image groups (room and map backgrounds) into JPEG files.

    python tools/art/to_jpeg_backgrounds.py            # convert (idempotent: run it again after adding pictures)
    python tools/art/to_jpeg_backgrounds.py --check    # list what is still a large opaque PNG (exit 1 if any)

Why: the whole game is one archive that the browser downloads before the first frame (about 120 MB in 2026-11);
60 opaque 720x1280 backgrounds were 58 MB as PNG and are 8 MB as JPEG. Keys do not change (the game asks for
"districts/<id>/bg", not for a file name); tools/gen_defold.py accepts .jpg for loose images. Pictures with
transparency (items, gates, the mascot) stay PNG. Baseline, 4:4:4 chroma, quality 90: flat coloured outlines
stay clean. A file is converted only when the JPEG is at least 3x smaller. The paths written in
assets/art_ready/installed.json (the list and the notes of its "sources", each file once) and
content/district_layouts.json follow.

The map tiles (mapbg/) are never converted: a tile has the feathered bottom (an alpha channel, see
tools/art/feather_mapbg.py) and a JPEG has none. Converting an opaque tile of the group would hide the missing feather
(it did for districts 16 and 17); tools/art/tile_check.py reports such a tile.
"""
import io
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import installed as inst  # noqa: E402

ROOT = inst.ROOT
IMAGES = os.path.join(ROOT, "assets", "images")
LOOSE = ("districts", "backgrounds")     # not mapbg: the tiles need their alpha
MIN_BYTES = 200 * 1024
QUALITY = 90


def candidates(images=IMAGES):
    out = []
    for g in LOOSE:
        for dp, _, fns in os.walk(os.path.join(images, g)):
            for fn in sorted(fns):
                if fn.lower().endswith(".png") and os.path.getsize(os.path.join(dp, fn)) >= MIN_BYTES:
                    out.append(os.path.join(dp, fn))
    return sorted(out)


def opaque(im):
    if im.mode in ("RGB", "L", "P") and "transparency" not in im.info:
        return True
    if im.mode == "RGBA":
        return im.getchannel("A").getextrema()[0] == 255
    return False


def to_jpeg_bytes(im):
    b = io.BytesIO()
    im.convert("RGB").save(b, "JPEG", quality=QUALITY, subsampling=0, optimize=True, progressive=False)
    return b.getvalue()


def rewrite_paths(renamed):
    if not renamed:
        return
    inst.rename(renamed)                 # the list and its notes, as data: a text replace listed a file twice
    p = os.path.join(ROOT, "content", "district_layouts.json")
    if os.path.isfile(p):
        with open(p, encoding="utf-8", newline="") as f:
            text = f.read()
        new = text
        for old, nw in renamed:
            new = new.replace(old, nw)
        if new != text:
            with open(p, "w", encoding="utf-8", newline="") as f:
                f.write(new)


def main(argv):
    check = "--check" in argv
    todo, renamed = [], []
    for path in candidates():
        im = Image.open(path)
        if not opaque(im):
            continue
        todo.append((path, im))
    if check:
        for path, _ in todo:
            print("still a large opaque PNG:", os.path.relpath(path, ROOT).replace(os.sep, "/"))
        return 1 if todo else 0
    saved = 0
    for path, im in todo:
        data = to_jpeg_bytes(im)
        size = os.path.getsize(path)
        if len(data) * 3 > size:
            continue
        rel = os.path.relpath(path, IMAGES).replace(os.sep, "/")
        with open(path[:-4] + ".jpg", "wb") as f:
            f.write(data)
        os.remove(path)
        renamed.append((rel, rel[:-4] + ".jpg"))
        saved += size - len(data)
    rewrite_paths(renamed)
    print("converted %d pictures, %.1f MB saved" % (len(renamed), saved / 1e6))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
