#!/usr/bin/env python3
"""Finds the blank signboard of every district gate (assets/images/mapbg/gate_<district>.png, 720x480) and writes
where the map must write the district name: content/map_gates.json  {district: {dx, dy, w, h}}.

dx, dy = centre of the signboard from the centre of the gate picture (x right, y UP), w = widest text that fits,
h = height of the board. tools/gen_map.py copies it into content/map.json (segment field `sign`). Run after a gate
picture is installed:

  python3 tools/art/gate_signs.py && python3 tools/gen_map.py
  python3 tools/art/gate_signs.py --check     # compare with content/map_gates.json and write nothing (exit 1 on a difference)
  python3 tools/art/gate_signs.py selftest    # the keep rule (standard library only), the finder on synthetic gates (Pillow, numpy)

A gate picture in which the finder sees no board KEEPS the entry its district already has in content/map_gates.json:
the file is not the finder's alone. That is the normal case of a placeholder gate (tools/art/make_part2_placeholders.py
copies the place of the board of the parent gate, and the warmer "day" recolour of a gate, district 21, makes a tinted
board too saturated for the finder) and of a place written by hand. A gate without a board and without an entry gets
none: the map then writes the name on its plain default sign. To drop an entry on purpose, delete it from the file.
Entries of districts that have no gate picture are dropped. Pillow and numpy are imported only where a picture is read.
"""
import glob
import json
import os
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
IMAGES = os.path.join(ROOT, "assets", "images")
OUT = os.path.join(ROOT, "content", "map_gates.json")


def board_mask(im, bright=0.86, pale=0.34):
    """Pixels of a pale, almost colourless, opaque surface: the empty signboard."""
    import numpy as np
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
    from PIL import Image
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


def merge(found, existing, ids):
    """The new content of map_gates.json for the districts that have a gate picture (ids, in order).
    found: {district: sign or None} (what the finder saw), existing: the file as it is now.
    Returns (signs, kept, without): signs = {district: sign}, kept = districts whose board was not found and that keep
    their entry, without = districts with neither (the map uses its default place). Standard library only."""
    signs, kept, without = {}, [], []
    for did in ids:
        if found.get(did):
            signs[did] = found[did]
        elif isinstance(existing.get(did), dict) and existing[did]:
            signs[did] = existing[did]
            kept.append(did)
        else:
            without.append(did)
    return signs, kept, without


def gate_pictures(images=None):
    """[(district, path)] of every assets/images/mapbg/gate_<district>.png, sorted."""
    pattern = os.path.join(images or IMAGES, "mapbg", "gate_*.png")
    return [(os.path.basename(p)[5:-4], p) for p in sorted(glob.glob(pattern))]


def read_signs(path):
    """The file as a dict ({} without it or when it is not a JSON object)."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def run(images=None, out=None, check=False, say=print):
    """Reads the gate pictures, writes the file (or, with check, only compares). Returns the exit code."""
    out = out or OUT
    existing = read_signs(out)
    pictures = gate_pictures(images)
    found = {}
    for did, path in pictures:
        found[did] = find_sign(path)
    signs, kept, without = merge(found, existing, [did for did, _ in pictures])
    for did, _ in pictures:
        if did in kept:
            say(did, "no signboard found: the entry of content/map_gates.json is kept", signs[did])
        elif did in without:
            say(did, "no signboard found: the default place is used")
        else:
            say(did, signs[did])
    if check:
        differ = sorted(d for d in set(signs) | set(existing) if signs.get(d) != existing.get(d))
        for d in differ:
            say("%s: the file has %s, the gate pictures give %s: run python3 tools/art/gate_signs.py"
                % (d, existing.get(d), signs.get(d)))
        if differ:
            return 1
        say("map gates ok: %d signboards, the file is what the gate pictures give" % len(signs))
        return 0
    with open(out, "w", encoding="utf-8", newline="") as f:
        f.write(json.dumps(signs, indent=1, sort_keys=True) + "\n")
    return 0


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["selftest"]:
        return selftest()
    if any(a != "--check" for a in argv):
        print(__doc__)
        return 2
    return run(check="--check" in argv)


def selftest():
    failed = []

    def check(ok, what):
        if not ok:
            failed.append(what)
            print("FAIL:", what)

    # the keep rule: standard library only, so it runs where there is no Pillow (the CI)
    old = {"dx": 1, "dy": 100, "w": 200, "h": 50}
    new = {"dx": 2, "dy": 110, "w": 210, "h": 60}
    signs, kept, without = merge({"a": new, "b": None, "c": None, "d": None, "e": None},
                                 {"a": old, "b": old, "d": "oops", "e": {}, "gone": old}, ["a", "b", "c", "d", "e"])
    check(signs == {"a": new, "b": old}, "a found board wins over the entry; a missing one keeps it: %s" % signs)
    check(kept == ["b"], "only b keeps its entry: %s" % kept)
    check(without == ["c", "d", "e"], "no board and no usable entry: the default place: %s" % without)
    check("gone" not in signs, "the entry of a district without a gate picture is dropped")
    check(merge({}, {}, []) == ({}, [], []), "nothing in, nothing out")
    print("gate_signs selftest (the keep rule): ok" if not failed else "gate_signs selftest (the keep rule): failed")

    try:
        import numpy  # noqa: F401
        from PIL import Image, ImageDraw
    except ImportError:
        print("gate_signs selftest (pictures): skipped, Pillow or numpy is not installed")
        return 1 if failed else 0
    before = len(failed)

    def gate(path, colour=None):
        im = Image.new("RGBA", (720, 480), (77, 51, 26, 255))
        if colour:
            ImageDraw.Draw(im).rectangle((230, 60, 490, 129), fill=tuple(int(c * 255 + 0.5) for c in colour) + (255,))
        im.save(path)

    with tempfile.TemporaryDirectory() as tmp:
        images = os.path.join(tmp, "images")
        os.makedirs(os.path.join(images, "mapbg"))
        out = os.path.join(tmp, "map_gates.json")
        gate(os.path.join(images, "mapbg", "gate_white.png"), (0.97, 0.97, 0.95))   # a white board: the first pass
        gate(os.path.join(images, "mapbg", "gate_plank.png"), (0.84, 0.78, 0.46))   # a tinted plank: the second pass
        gate(os.path.join(images, "mapbg", "gate_warm.png"), (0.84, 0.70, 0.25))    # too warm for both: not found
        gate(os.path.join(images, "mapbg", "gate_wall.png"))                        # no board at all
        placed = {"dx": 5, "dy": 100, "w": 200, "h": 50}
        with open(out, "w", encoding="utf-8") as f:
            json.dump({"warm": placed, "white": {"dx": 99, "dy": 99, "w": 9, "h": 9}, "wall": "oops", "gone": placed}, f)
        quiet = lambda *a: None  # noqa: E731
        check(find_sign(os.path.join(images, "mapbg", "gate_warm.png")) is None, "the warm board is not found (the case this rule is for)")
        check(run(images, out, say=quiet) == 0, "the run succeeds")
        data = read_signs(out)
        check(sorted(data) == ["plank", "warm", "white"], "white, plank (found) and warm (kept) have an entry; wall (none usable) and gone (no picture) do not: %s" % sorted(data))
        check(data.get("warm") == placed, "the district whose board is not found keeps its entry as it was: %s" % data.get("warm"))
        for did in ("white", "plank"):
            s = data.get(did) or {}
            check(abs(s.get("dx", 99)) <= 1 and abs(s.get("dy", 0) - 145) <= 2 and abs(s.get("w", 0) - 247) <= 3 and abs(s.get("h", 0) - 70) <= 2,
                  "%s: the board is found where it was drawn: %s" % (did, s))
        def raw():
            with open(out, "rb") as f:
                return f.read()

        first = raw()
        check(run(images, out, say=quiet) == 0 and raw() == first, "a second run gives the same file")
        check(run(images, out, check=True, say=quiet) == 0, "--check passes on the file the run wrote")
        data["white"] = {"dx": 0, "dy": 0, "w": 1, "h": 1}              # an entry the finder disagrees with
        with open(out, "w", encoding="utf-8") as f:
            json.dump(data, f)
        tampered = raw()
        check(run(images, out, check=True, say=quiet) == 1, "--check fails when the file differs from what the gate pictures give")
        check(raw() == tampered and tampered != first, "--check writes nothing")
        os.remove(os.path.join(images, "mapbg", "gate_warm.png"))
        check(run(images, out, say=quiet) == 0 and "warm" not in read_signs(out), "the entry of a district whose gate picture is gone is dropped")
    print("gate_signs selftest (pictures): ok" if len(failed) == before else "gate_signs selftest (pictures): failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
