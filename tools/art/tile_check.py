#!/usr/bin/env python3
"""Do the map tiles keep their feather? Standard library only (so the test suite and CI run it without Pillow).

A map tile (assets/images/mapbg/bg_<district>.png) is a 720x1080 RGBA PNG whose bottom 110 rows fade from alpha 255 to 0
and whose other rows are opaque: the map (client/map_model.lua) lays the tiles of a district 740 px apart and blends
the faded bottom of one into the next. An OPAQUE tile (a JPEG, an RGB PNG, an RGBA PNG without the fade) shows a hard
horizontal seam every 740 px and next to every gate. Districts 16 and 17 had it: the producer's pictures were installed
as they came and tools/art/to_jpeg_backgrounds.py then turned them into JPEG. The check looks at:

  * every file mapbg/bg_*: a PNG (not a JPEG), 8-bit RGBA, the size of content/map.json (tile_h, width), alpha 255 in every
    row above the feather and, in the bottom tile_feather rows, exactly the ramp of tools/art/feather_mapbg.py;
  * the `bg` of every segment of content/map.json has such a file;
  * assets/art_ready/installed.json: every picture listed once and present, a note ("sources") only for a listed picture.

    python3 tools/art/tile_check.py [images_dir]     # default: assets/images; prints "map tiles ok" or the problems (exit 1)
    python3 tools/art/tile_check.py selftest         # the check can fail: synthetic tiles, an installed.json with notes

tests/client/map_tiles_test.lua runs both. The files are repaired with tools/art/feather_mapbg.py (needs Pillow).
"""
import itertools
import json
import os
import struct
import sys
import tempfile
import zlib

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
IMAGES = os.path.join(ROOT, "assets", "images")
INSTALLED = os.path.join(ROOT, "assets", "art_ready", "installed.json")
MAP = os.path.join(ROOT, "content", "map.json")
PNG = b"\x89PNG\r\n\x1a\n"


def geometry(path=MAP):
    """(width, tile height, feather) of the tiles, from content/map.json."""
    with open(path, encoding="utf-8") as f:
        m = json.load(f)
    return int(m.get("width", 720)), int(m["tile_h"]), int(m.get("tile_feather", 0))


def ramp(n):
    """The alpha of the n faded rows, top to bottom: numpy's (linspace(1, 0, n) * 255).astype(uint8) of feather_mapbg.py."""
    step = -1.0 / (n - 1)
    return [int((i * step + 1.0) * 255) for i in range(n - 1)] + [0]


def read_png(path):
    """(width, height, bit depth, colour type, interlace, IDAT bytes) of a PNG file."""
    with open(path, "rb") as f:
        return read_png_bytes(f.read())


def read_png_bytes(data):
    """The same for the bytes of a PNG."""
    if data[:8] != PNG:
        raise ValueError("not a PNG")
    pos, idat, ihdr = 8, [], None
    while pos + 8 <= len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + n]
        pos += 12 + n
        if kind == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", chunk)
        elif kind == b"IDAT":
            idat.append(chunk)
        elif kind == b"IEND":
            break
    if ihdr is None:
        raise ValueError("no IHDR")
    w, h, depth, ctype, _, _, interlace = ihdr
    return w, h, depth, ctype, interlace, b"".join(idat)


def alpha_rows(w, h, idat):
    """The alpha plane of an 8-bit RGBA PNG without interlacing, one bytes object per row. PNG filters work on each channel
    separately, so only the alpha bytes are unfiltered (a quarter of the work of a whole picture)."""
    stride = w * 4
    raw = zlib.decompress(idat)
    if len(raw) < h * (stride + 1):
        raise ValueError("the image data is short")
    rows, prev, pos = [], bytes(w), 0
    for _ in range(h):
        ftype = raw[pos]
        f = raw[pos + 1:pos + 1 + stride][3::4]
        pos += 1 + stride
        if ftype == 0:
            cur = f
        elif ftype == 1:                                           # Sub
            if f.count(0, 1) == w - 1:                             # the usual row of one alpha value
                cur = f[:1] * w
            else:
                cur = bytes(itertools.accumulate(f, lambda a, b: (a + b) & 255))
        elif ftype == 2:                                           # Up
            cur = prev if f.count(0) == w else bytes((a + b) & 255 for a, b in zip(f, prev))
        elif ftype == 3:                                           # Average
            out, left = bytearray(w), 0
            for x in range(w):
                left = out[x] = (f[x] + ((left + prev[x]) >> 1)) & 255
            cur = bytes(out)
        elif ftype == 4 and f.count(0, 1) == w - 1 and prev.count(prev[0]) == w:   # Paeth after a row of one value
            cur = bytes([(f[0] + prev[0]) & 255]) * w                              # (the predictor is then left or above)
        elif ftype == 4:                                           # Paeth
            out, a, c = bytearray(w), 0, 0
            for x in range(w):
                b = prev[x]
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                a = out[x] = (f[x] + pred) & 255
                c = b
            cur = bytes(out)
        else:
            raise ValueError("unknown PNG filter %d" % ftype)
        rows.append(cur)
        prev = cur
    return rows


def check_tile(path, name, geo):
    """The problems of one tile file (a list of strings, empty when it is right)."""
    w, h, feather = geo
    did = os.path.splitext(name)[0][3:]
    fix = "python3 tools/art/feather_mapbg.py %s" % did
    if not name.lower().endswith(".png"):
        return ["mapbg/%s: a map tile must be a PNG with an alpha channel, a JPEG has none (hard seams): %s" % (name, fix)]
    try:
        pw, ph, depth, ctype, interlace, idat = read_png(path)
    except (OSError, ValueError, struct.error) as e:
        return ["mapbg/%s: cannot read it (%s)" % (name, e)]
    if (pw, ph) != (w, h):
        return ["mapbg/%s: %dx%d, a map tile is %dx%d: %s" % (name, pw, ph, w, h, fix)]
    if ctype != 6 or depth != 8 or interlace:
        what = {0: "grey", 2: "RGB", 3: "palette", 4: "grey+alpha", 6: "RGBA"}.get(ctype, "type %d" % ctype)
        why = "opaque, no alpha channel" if ctype in (0, 2) else "only 8-bit RGBA without interlacing is read"
        return ["mapbg/%s: %d-bit %s PNG (%s): the bottom %d rows must fade out: %s" % (name, depth, what, why, feather, fix)]
    try:
        rows = alpha_rows(pw, ph, idat)
    except (zlib.error, ValueError) as e:
        return ["mapbg/%s: cannot read the alpha (%s)" % (name, e)]
    want = [255] * (h - feather) + ramp(feather)
    bad = [y for y, row in enumerate(rows) if row.count(want[y]) != w]
    if bad:
        y = bad[0]
        return ["mapbg/%s: the alpha is wrong in %d rows, first row %d (alpha %d..%d, expected %d everywhere): "
                "the bottom %d rows must fade 255 -> 0 and the rest be opaque: %s"
                % (name, len(bad), y, min(rows[y]), max(rows[y]), want[y], feather, fix)]
    return []


def check_installed(path=INSTALLED, images=IMAGES):
    """The problems of assets/art_ready/installed.json."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        return ["installed.json: cannot read it (%s)" % e]
    files = [p for p in data.get("files", []) if isinstance(p, str)]
    problems = []
    seen = set()
    for p in files:
        if p in seen:
            problems.append("installed.json: %s is listed twice" % p)
        seen.add(p)
        if not os.path.isfile(os.path.join(images, p)):
            problems.append("installed.json: %s is listed but there is no such file" % p)
    for k in data.get("sources", {}):
        if k not in seen:
            problems.append("installed.json: a note for %s, which is not listed" % k)
    return problems


def check(images=IMAGES, installed=INSTALLED, map_path=MAP, geo=None):
    """The list of problems (empty: every map tile is right)."""
    geo = geo or geometry(map_path)
    folder = os.path.join(images, "mapbg")
    problems = []
    if not os.path.isdir(folder):
        return ["%s: there is no mapbg folder" % images]
    for n in sorted(n for n in os.listdir(folder) if n.startswith("bg_")):
        problems += check_tile(os.path.join(folder, n), n, geo)
    if map_path:
        with open(map_path, encoding="utf-8") as f:
            segments = json.load(f).get("segments", [])
        for s in segments:
            key = s.get("bg", "")
            if key.startswith("mapbg/") and not os.path.isfile(os.path.join(images, key + ".png")):
                problems.append("content/map.json: segment %s wants %s.png, there is no such tile" % (s.get("id"), key))
    if installed:
        problems += check_installed(installed, images)
    return problems


# -- self test -------------------------------------------------------------------------------------------------------------

def make_png(w, h, ctype, rows, filters=None, depth=8):
    """A PNG from unfiltered rows (bytes); filters: the filter type per row (default: none), applied the way the
    standard says, so the reader can be tested against all of them."""
    bpp = {0: 1, 2: 3, 4: 2, 6: 4}[ctype]
    out, prev = bytearray(), bytes(w * bpp)
    for y, row in enumerate(rows):
        ft = (filters or [0] * h)[y]
        line = bytearray()
        for x in range(w * bpp):
            a = row[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if ft == 0:
                pred = 0
            elif ft == 1:
                pred = a
            elif ft == 2:
                pred = b
            elif ft == 3:
                pred = (a + b) >> 1
            else:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line.append((row[x] - pred) & 255)
        out += bytes([ft]) + line
        prev = row

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (PNG + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, depth, ctype, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(out), 9)) + chunk(b"IEND", b""))


def selftest():
    failed = []

    def expect(ok, what):
        if not ok:
            failed.append(what)
            print("FAIL:", what)

    w, h, f = 24, 60, 10            # a small tile of the same shape: the reader and the rules do not care about the size
    geo = (w, h, f)
    want = [255] * (h - f) + ramp(f)

    def rgba(alphas):
        return [bytes(v for x in range(w) for v in ((x * 7 + y) & 255, (x + y * 5) & 255, (x * 3) & 255, alphas[y])) for y in range(h)]

    expect(ramp(110)[0] == 255 and ramp(110)[-1] == 0 and len(ramp(110)) == 110, "the ramp runs 255 -> 0 in 110 rows")
    with tempfile.TemporaryDirectory() as tmp:
        images = os.path.join(tmp, "images")
        folder = os.path.join(images, "mapbg")
        os.makedirs(folder)

        def put(name, data):
            with open(os.path.join(folder, name), "wb") as fh:
                fh.write(data)

        def problems(name):
            return check_tile(os.path.join(folder, name), name, geo)

        good = rgba(want)
        # the reader follows every PNG filter, on rows that differ from each other
        for ft in range(5):
            put("bg_f%d.png" % ft, make_png(w, h, 6, good, [ft] * h))
            expect(problems("bg_f%d.png" % ft) == [], "a right tile is accepted (filter %d): %s" % (ft, problems("bg_f%d.png" % ft)))
        put("bg_mixed.png", make_png(w, h, 6, good, [(y * 3) % 5 for y in range(h)]))
        expect(problems("bg_mixed.png") == [], "a right tile is accepted (filters mixed)")
        # ... also when the alpha is not one value per row (the shortcuts for such rows must not be taken)
        noisy = [bytes(v for x in range(w) for v in (x, y, 7, (x * 37 + y * 11 + (y // 7) * 90) & 255)) for y in range(h)]
        for ft in range(5):
            png = make_png(w, h, 6, noisy, [ft] * h)
            back = alpha_rows(w, h, read_png_bytes(png)[5])
            expect(back == [r[3::4] for r in noisy], "the alpha of rows with every value is read back (filter %d)" % ft)
        mixed = make_png(w, h, 6, noisy, [(y * 3) % 5 for y in range(h)])
        expect(alpha_rows(w, h, read_png_bytes(mixed)[5]) == [r[3::4] for r in noisy], "the alpha is read back (filters mixed)")
        # what must be refused
        put("bg_opaque.png", make_png(w, h, 2, [bytes(w * 3)] * h))
        expect(len(problems("bg_opaque.png")) == 1 and "opaque" in problems("bg_opaque.png")[0], "an RGB PNG is refused as opaque")
        put("bg_flat.png", make_png(w, h, 6, rgba([255] * h)))
        expect(len(problems("bg_flat.png")) == 1 and "alpha is wrong" in problems("bg_flat.png")[0], "RGBA with alpha 255 everywhere is refused")
        put("bg_short.png", make_png(w, h, 6, rgba([255] * (h - 4) + [200, 120, 60, 0])))
        expect(len(problems("bg_short.png")) == 1, "a feather of 4 rows is refused")
        put("bg_hole.png", make_png(w, h, 6, rgba([0 if y == 5 else want[y] for y in range(h)])))
        expect(len(problems("bg_hole.png")) == 1 and "first row 5" in problems("bg_hole.png")[0], "a transparent row above the feather is refused")
        put("bg_size.png", make_png(w + 1, h, 6, [r + bytes(4) for r in good]))
        expect(len(problems("bg_size.png")) == 1 and "25x60" in problems("bg_size.png")[0], "a tile of the wrong size is refused")
        put("bg_grey.png", make_png(w, h, 4, [bytes(w * 2)] * h))
        expect(len(problems("bg_grey.png")) == 1, "a grey+alpha PNG is refused (only RGBA is read)")
        put("bg_jpeg.jpg", b"\xff\xd8\xff\xe0" + bytes(40))
        expect(len(problems("bg_jpeg.jpg")) == 1 and "JPEG" in problems("bg_jpeg.jpg")[0], "a JPEG tile is refused")
        put("bg_junk.png", b"not a png at all")
        expect(len(problems("bg_junk.png")) == 1, "a broken file is refused")
        # the whole check over a folder: only the bad ones are named
        os.remove(os.path.join(folder, "bg_junk.png"))
        names = sorted(n for n in os.listdir(folder))
        all_problems = check(images, None, None, geo)
        bad = sorted(n for n in names if any(("mapbg/%s:" % n) in p for p in all_problems))
        expect(bad == ["bg_flat.png", "bg_grey.png", "bg_hole.png", "bg_jpeg.jpg", "bg_opaque.png", "bg_short.png", "bg_size.png"],
               "check() names exactly the bad tiles: %s" % bad)

        # installed.json: a file listed twice or missing, a note for an unlisted file
        state = os.path.join(tmp, "installed.json")
        with open(os.path.join(images, "a.png"), "wb") as fh:
            fh.write(b"x")
        with open(state, "w", encoding="utf-8") as fh:
            json.dump({"version": 1, "files": ["a.png", "a.png", "gone.png"], "sources": {"a.png": "n", "other.png": "n"}}, fh)
        got = check_installed(state, images)
        expect(any("twice" in p for p in got) and any("gone.png is listed but" in p for p in got)
               and any("other.png" in p for p in got) and len(got) == 3, "installed.json problems are named: %s" % got)
        # the list module keeps the notes when an installer that knows only the files saves it
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import installed as inst
        inst.save({"a.png", "b.png", "d/bg.png"}, {"a.png": "placeholder: x", "d/bg.png": "placeholder: y"}, state)
        inst.save({"a.png", "b.png", "c.png", "d/bg.png"}, None, state)
        expect(inst.load_sources(state) == {"a.png": "placeholder: x", "d/bg.png": "placeholder: y"}, "save(files) keeps the notes")
        inst.save({"b.png"}, None, state)
        expect(inst.load_sources(state) == {}, "a note goes with its file")
        inst.save({"d/bg.png", "d/bg.jpg", "e.png"}, {"d/bg.png": "placeholder: y", "d/bg.jpg": "placeholder: old"}, state)
        inst.rename([("d/bg.png", "d/bg.jpg")], state)
        expect(inst.load(state) == {"d/bg.jpg", "e.png"} and inst.load_sources(state) == {"d/bg.jpg": "placeholder: y"},
               "rename lists a file once and moves its note")
        marks = {"d/bg.png": "placeholder: y", "d/bg.jpg": "placeholder: y", "x.png": "z"}
        inst.unmark(marks, "d/bg.png")
        expect(marks == {"x.png": "z"}, "an installed picture is no placeholder, under either extension")
        # what an installer does with a picture it wrote: listed, no placeholder, an older file of the same key is gone
        pics = os.path.join(tmp, "pics")
        os.makedirs(pics)
        with open(os.path.join(pics, "d.jpg"), "wb") as fh:
            fh.write(b"x")
        listed, notes = {"d.jpg", "keep.png"}, {"d.jpg": "placeholder: z", "keep.png": "placeholder: z"}
        inst.record(listed, notes, "d.png", pics)
        expect(listed == {"d.png", "keep.png"} and notes == {"keep.png": "placeholder: z"}
               and not os.path.isfile(os.path.join(pics, "d.jpg")), "record: listed once, no longer a placeholder, the JPEG of the key is gone")
    if failed:
        print("tile_check selftest: %d failed" % len(failed))
        return 1
    print("tile_check selftest: ok")
    return 0


def main(argv):
    if argv[:1] == ["selftest"]:
        return selftest()
    images = argv[0] if argv else IMAGES
    problems = check(images, INSTALLED if images == IMAGES else None)
    if problems:
        for p in problems:
            print(p)
        return 1
    n = len([f for f in os.listdir(os.path.join(images, "mapbg")) if f.startswith("bg_")])
    print("map tiles ok: %d tiles" % n)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
