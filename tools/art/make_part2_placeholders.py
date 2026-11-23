#!/usr/bin/env python3
"""Placeholder pictures for the districts of Part 2 (districts 16-30, content/districts.json "part": 2) until the
producer draws them: the NIGHT version of the pictures of the "parent" district of Part 1 (the district of the same
genre: district 16 <- district 1, 17 <- 2 ... 30 <- 15).

  python3 tools/art/make_part2_placeholders.py                  # every Part 2 district that has no pictures yet
  python3 tools/art/make_part2_placeholders.py midnight_cafe    # one district (several ids may be given)
  python3 tools/art/make_part2_placeholders.py --force <id>     # redo it even over installed pictures (careful)
  python3 tools/art/make_part2_placeholders.py --status         # which Part 2 districts wear placeholders
  python3 tools/art/make_part2_placeholders.py selftest         # a run on a temporary project (Pillow, numpy)

A district is made once: one that has the producer's pictures, and one whose placeholders are already installed (every
picture listed in installed.json with the note "placeholder: ...", on disk, no stale copy under the other extension),
is skipped; --force redoes it. A run that makes nothing writes nothing, so running the script again changes no file.

What it writes for a district <id> with parent <p> (the same sizes as the parent's pictures):
  districts/<p>/bg, bg_concert                -> districts/<id>/bg.jpg, bg_concert.jpg   room, day and concert view
  districts/<p>/<task>.png                    -> districts/<id>/<task>.png + <task>_ghost.png  the task items
  mapbg/bg_<p>.png, mapbg/gate_<p>.png        -> mapbg/bg_<id>.png, mapbg/gate_<id>.png    map tile and gate
  map/deco_<p>_1..6.png                       -> map/deco_<id>_1..6.png                     map decorations
  districts/<p>/level_bg                      -> districts/<id>/level_bg.jpg               the sky behind the board
The room, concert and level backgrounds are JPEG files at once (a parent picture may be a .png or a .jpg): that is what
tools/art/to_jpeg_backgrounds.py makes of them, but it leaves a level background (under its 200 KB) a PNG, which
tests/client/level_sky_test.lua refuses, and a .png beside a .jpg of the same key is one image key twice (the
installer API inst.record deletes the one the new file replaces).
and the data that points at them, copied from the parent with the task ids renamed:
  content/district_layouts.json  (item places of the room), content/rooms.json (the living details of the room),
  content/map_gates.json (where the name goes on the gate: the signboard keeps its pale colour, so it is the
  parent's place; tools/art/gate_signs.py keeps such an entry when it finds no board), assets/art_ready/installed.json
  (the files, with the source "placeholder: ..." so that tools/art/gen_art.py leaves them alone and --status can tell
  them from the producer's pictures).
Then run:  python3 tools/gen_map.py && python3 tools/gen_defold.py

Task i of the district takes the item of task i of the parent (TASK_FROM can pair them by hand). When the producer's
pictures arrive, tools/art/install_district.py installs them over the placeholders (add the district to its ROOMS
table) and they stop being placeholders.

The night look: the colours are pulled toward a blue-violet ramp of their own brightness, the whole picture is a
little darker (rooms 0.78, concert 0.86, items 0.90: items must still stand out in the room), and bright warm spots
(lamps, signs, candles) keep most of their warm colour, like lights that are on at night. The level background only
gets a light lavender tint (LEVEL_TINT: the sky stays bright behind the board). A district of LOOK "day" (a sunny
version of its genre) gets the festival look instead: warmer, more saturated colours, the same brightness, and its
room keeps the parent's mood. Deterministic, numpy+PIL.
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import installed as inst  # noqa: E402

ROOT = inst.ROOT
IMAGES = os.path.join(ROOT, "assets", "images")
CONTENT = os.path.join(ROOT, "content")
PLACEHOLDER = "placeholder: "   # the source of a placeholder file in installed.json starts with it
# ... and goes on: "night version of <parent>" (or "day version of <parent>", LOOK)
JPEG_KINDS = ("room", "concert", "level")   # the big opaque backgrounds are written as JPEG files (see the docstring)

# district id -> {its task id: the parent's task id} when the order of the tasks does not pair them well
TASK_FROM = {
    "late_club": {"drums": "stage_light", "double_bass": "double_bass", "piano": "grand_piano", "vibes": "vibes",
                  "muted_trumpet": "trumpet", "note_sign": "neon"},
    "nations_fest": {"taiko": "fountain", "festival_tent": "truck_stage", "steel_pan": "tuba",
                     "flag_garland": "garlands", "accordion": "clarinet", "shell_stage": "trumpets"},
    "fan_meeting": {"small_stage": "stage", "piano": "choir", "photo_wall": "screens", "lightsticks": "lightsticks",
                    "gift_basket": "fireworks", "mic_stand": "lasers"},
    "punk_garage": {"drum_kit": "drum_kit", "amp_stack": "amp", "bass_guitar": "bass_guitar",
                    "garage_door": "garage_door", "mic_stand": "mic_stand", "gig_posters": "posters"},
}

# district id -> "night" (the default) or "day" (a sunny version of the genre: the festival look)
LOOK = {"nations_fest": "day", "sunset_bossa": "day"}

# the level background (night look): rgb -> M @ rgb + offset, the light lavender sky of district 16
LEVEL_TINT = np.array([[0.685, -0.057, -0.017], [-0.028, 0.697, -0.015], [-0.027, -0.053, 1.106]], np.float32)
LEVEL_OFFSET = np.array([-0.006, -0.003, 0.073], np.float32)

# the night ramp: brightness -> colour (dark navy, indigo, violet, lavender)
RAMP_L = np.array([0.0, 0.35, 0.65, 1.0], np.float32)
RAMP_C = np.array([[0.05, 0.05, 0.18], [0.16, 0.15, 0.44], [0.40, 0.33, 0.78], [0.76, 0.70, 1.00]], np.float32)
KEEP = 0.25          # share of the original colour in the mix (the picture stays recognisable)
DARK = {"room": 0.78, "concert": 0.86, "item": 0.90, "map": 0.78, "gate": 0.86, "deco": 0.90}


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def write_json(path, data, indent):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(json.dumps(data, indent=indent, ensure_ascii=False) + "\n")


def festival(img, kind, keep_mask=None):
    """The day version of a picture for a sunny district: more saturated (x1.3 around its grey) and a little warmer;
    the signboard of a gate (keep_mask) keeps its colour. Alpha is kept."""
    a = np.asarray(img.convert("RGBA")).astype(np.float32) / 255.0
    rgb, alpha = a[..., :3], a[..., 3:]
    grey = (rgb @ np.array([0.2126, 0.7152, 0.0722], np.float32))[..., None]
    out = (grey + 1.3 * (rgb - grey)) * np.array([1.05, 1.0, 0.9], np.float32)
    if keep_mask is not None:
        m = keep_mask[..., None].astype(np.float32)
        out = out * (1.0 - m) + rgb * m
    res8 = (np.concatenate([np.clip(out, 0, 1), alpha], axis=-1) * 255.0 + 0.5).astype(np.uint8)
    res8[res8[..., 3] == 0] = 0
    return Image.fromarray(res8, "RGBA")


def level_tint(img):
    """The night level background: the light lavender tint of district 16 (an RGB picture, no alpha)."""
    rgb = np.asarray(img.convert("RGB")).astype(np.float32) / 255.0
    out = np.clip(rgb @ LEVEL_TINT.T + LEVEL_OFFSET, 0, 1)
    return Image.fromarray((out * 255.0 + 0.5).astype(np.uint8), "RGB")


def recolour(img, kind, look, keep_mask=None):
    """The placeholder of one picture in the look of its district."""
    if look == "day":
        out = festival(img, kind, keep_mask)
        return out.convert("RGB") if kind == "level" else out
    return level_tint(img) if kind == "level" else night(img, kind, keep_mask)


def night(img, kind, keep_mask=None):
    """The night version of an RGBA/RGB picture; alpha is kept. keep_mask: pixels that keep a pale, almost original
    colour (the blank signboard of a gate, where the map writes the district name)."""
    im = img.convert("RGBA")
    a = np.asarray(im).astype(np.float32) / 255.0
    rgb, alpha = a[..., :3], a[..., 3:]
    lum = rgb @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    ramp = np.stack([np.interp(lum, RAMP_L, RAMP_C[:, c]) for c in range(3)], axis=-1)
    out = (KEEP * rgb + (1.0 - KEEP) * ramp) * DARK[kind]
    # warm lights stay warm: bright pixels that were warmer than they were blue
    warm = np.clip((lum - 0.68) / 0.25, 0, 1) * np.clip((rgb[..., 0] - rgb[..., 2]) / 0.25, 0, 1)
    w = (0.65 * warm)[..., None]
    out = out * (1.0 - w) + rgb * 0.97 * w
    if keep_mask is not None:
        pale = rgb * np.array([0.96, 0.96, 1.0], np.float32)
        m = keep_mask[..., None].astype(np.float32)
        out = out * (1.0 - m) + pale * m
    res = np.concatenate([np.clip(out, 0, 1), alpha], axis=-1)
    res8 = (res * 255.0 + 0.5).astype(np.uint8)
    res8[res8[..., 3] == 0] = 0
    return Image.fromarray(res8, "RGBA")


def part2_pairs(districts):
    """[(district, parent district)] for the Part 2 districts, in order: the k-th district of Part 2 has the k-th of
    Part 1 as its parent."""
    one = [d for d in districts if int(d.get("part", 1)) == 1]
    two = [d for d in districts if int(d.get("part", 1)) == 2]
    if len(two) > len(one):
        sys.exit("more districts in Part 2 than in Part 1: no parent for %s" % two[len(one)]["id"])
    return list(zip(two, one))


def task_pairs(d, parent):
    """[(task id, the parent's task id)] in the order of the district's tasks."""
    by_hand = TASK_FROM.get(d["id"], {})
    ptasks = [t["id"] for t in parent["tasks"]]
    out = []
    for i, t in enumerate(d["tasks"]):
        src = by_hand.get(t["id"]) or (ptasks[i] if i < len(ptasks) else None)
        if src not in ptasks:
            sys.exit("%s/%s: no item of %s to borrow (pair it in TASK_FROM)" % (d["id"], t["id"], parent["id"]))
        out.append((t["id"], src))
    return out


def targets(d, parent):
    """{relative path of the new picture: (relative path of the parent's picture, kind)}. The backgrounds (JPEG_KINDS)
    are named .jpg on both sides: find_picture() finds the parent's under either extension."""
    did, pid = d["id"], parent["id"]
    out = {
        "districts/%s/bg.jpg" % did: ("districts/%s/bg.jpg" % pid, "room"),
        "districts/%s/bg_concert.jpg" % did: ("districts/%s/bg_concert.jpg" % pid, "concert"),
        "mapbg/bg_%s.png" % did: ("mapbg/bg_%s.png" % pid, "map"),
        "mapbg/gate_%s.png" % did: ("mapbg/gate_%s.png" % pid, "gate"),
        "districts/%s/level_bg.jpg" % did: ("districts/%s/level_bg.jpg" % pid, "level"),
    }
    for i in range(1, 7):
        out["map/deco_%s_%d.png" % (did, i)] = ("map/deco_%s_%d.png" % (pid, i), "deco")
    for tid, src in task_pairs(d, parent):
        out["districts/%s/%s.png" % (did, tid)] = ("districts/%s/%s.png" % (pid, src), "item")
    return out


def find_picture(rel):
    """The file that holds the picture images/<rel>: itself, or the same key under the other extension (a big opaque
    background may have been turned into a JPEG, or not yet: tools/art/to_jpeg_backgrounds.py). None when neither is there."""
    for name in (rel, inst.sibling(rel)):
        if name and os.path.isfile(os.path.join(IMAGES, name)):
            return name
    return None


def listed(rel, files):
    """The name under which the picture rel is listed in installed.json (itself or the other extension), or None."""
    for name in (rel, inst.sibling(rel)):
        if name and name in files:
            return name
    return None


def real_art(rel, files, sources):
    """True when rel is a picture the producer drew (installed under either extension, and not by this script)."""
    name = listed(rel, files)
    return name is not None and not sources.get(name, "").startswith(PLACEHOLDER)


def pictures_of(todo):
    """Every file a district has: the targets and the ghost of every item."""
    out = []
    for rel, (_, kind) in sorted(todo.items()):
        out.append(rel)
        if kind == "item":
            out.append(rel[:-4] + "_ghost.png")
    return out


def placeholders_done(todo, files, sources):
    """True when every picture of the district is listed under its own name as a placeholder of this script and is on
    disk, and none has a copy under the other extension (a .png beside a .jpg is one image key twice): a run would
    write what is there. Anything else (a missing file, a background still listed as a .png, a stale copy) is made again."""
    for rel in pictures_of(todo):
        if rel not in files or not sources.get(rel, "").startswith(PLACEHOLDER):
            return False
        if not os.path.isfile(os.path.join(IMAGES, rel)):
            return False
        other = inst.sibling(rel)
        if other and (other in files or os.path.isfile(os.path.join(IMAGES, other))):
            return False
    return True


def make(d, parent, files, sources, force=False):
    did, pid = d["id"], parent["id"]
    todo = targets(d, parent)
    real = [rel for rel in todo if real_art(rel, files, sources)]
    if real and not force:
        print("skip %s: it has the producer's pictures (%s ...); --force redoes it" % (did, real[0]))
        return False
    if not force and placeholders_done(todo, files, sources):
        print("skip %s: its placeholders are already installed; --force redoes it" % did)
        return False
    from gen_art import ghost_image  # noqa: E402  (heavy import: only when something is drawn)
    from gate_signs import board_mask  # noqa: E402
    from to_jpeg_backgrounds import to_jpeg_bytes  # noqa: E402
    look = LOOK.get(did, "night")
    note = PLACEHOLDER + "%s version of %s" % (look, pid)
    for rel, (src, kind) in sorted(todo.items()):
        found = find_picture(src)
        if found is None:
            sys.exit("%s: the parent picture %s is missing" % (did, src))
        with Image.open(os.path.join(IMAGES, found)) as im:
            keep = board_mask(im) if kind == "gate" else None
            out = recolour(im, kind, look, keep)
        dst = os.path.join(IMAGES, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if kind in JPEG_KINDS:
            with open(dst, "wb") as f:
                f.write(to_jpeg_bytes(out))
        else:
            out.save(dst, optimize=True)
        inst.record(files, sources, rel, IMAGES)    # listed once; the same picture under the other extension is deleted
        sources[rel] = note                          # (record() took the note off: this one is a placeholder)
        if kind == "item":
            ghost = rel[:-4] + "_ghost.png"
            ghost_image(out).save(os.path.join(IMAGES, ghost), optimize=True)
            inst.record(files, sources, ghost, IMAGES)
            sources[ghost] = note
        print("wrote", rel, out.size)
    pairs = dict(task_pairs(d, parent))

    # the item places of the room: the parent's, under the new task ids and files
    path = os.path.join(CONTENT, "district_layouts.json")
    layouts = load_json(path)
    plo = layouts[pid]
    items = {}
    for tid in [t["id"] for t in d["tasks"]]:
        it = dict(plo["items"][pairs[tid]])
        it["image"] = "assets/images/districts/%s/%s.png" % (did, tid)
        it["ghost"] = "assets/images/districts/%s/%s_ghost.png" % (did, tid)
        items[tid] = it
    room = next(rel for rel, (_, kind) in todo.items() if kind == "room")
    concert = next(rel for rel, (_, kind) in todo.items() if kind == "concert")
    layouts[did] = {"bg": "assets/images/" + room, "bg_concert": "assets/images/" + concert,
                    "bg_scale": plo.get("bg_scale", 1.0), "items": items}
    write_json(path, layouts, 2)

    # the living details of the room (lights, steam, notes): the parent's, items renamed; sun shafts become moonlight
    path = os.path.join(CONTENT, "rooms.json")
    rooms = load_json(path)
    back = {src: tid for tid, src in pairs.items()}
    details = []
    for det in rooms["districts"].get(pid, {}).get("details", []):
        det = json.loads(json.dumps(det))
        if "item" in det:
            if det["item"] not in back:
                continue            # the parent's item has no counterpart here: its detail goes too
            det["item"] = back[det["item"]]
        if det.get("kind") == "shaft" and look == "night":
            det["color"] = "#C9D6FF"
        details.append(det)
    mood = "night" if look == "night" else rooms["districts"].get(pid, {}).get("mood", look)
    rooms["districts"][did] = {"mood": mood, "details": details}
    write_rooms(path, rooms)

    # where the name goes on the gate: the signboard kept its place and its pale colour
    path = os.path.join(CONTENT, "map_gates.json")
    gates = load_json(path)
    if pid in gates:
        gates[did] = dict(gates[pid])
        write_json(path, dict(sorted(gates.items())), 1)
    return True


def inline(v):
    """A JSON object or list on one line, the way content/rooms.json writes it: { "a": 1, "b": [1, 2] }."""
    t = json.dumps(v, ensure_ascii=False)
    return "{ " + t[1:-1] + " }" if isinstance(v, dict) else t


def rooms_text(rooms):
    """content/rooms.json in its hand-made layout (one detail per line)."""
    lines = ["{"]
    for k, v in rooms.items():
        if k == "districts":
            continue
        lines.append("  %s: %s," % (json.dumps(k), inline(v)))
    lines.append('  "districts": {')
    ds = list(rooms["districts"].items())
    for i, (did, room) in enumerate(ds):
        lines.append("    %s: {" % json.dumps(did))
        for k, v in room.items():
            if k != "details":
                lines.append("      %s: %s," % (json.dumps(k), inline(v)))
        dets = room.get("details", [])
        lines.append('      "details": [')
        for j, det in enumerate(dets):
            lines.append("        " + inline(det) + ("," if j < len(dets) - 1 else ""))
        lines.append("      ]")
        lines.append("    }" + ("," if i < len(ds) - 1 else ""))
    lines.append("  }")
    lines.append("}")
    return "\n".join(lines) + "\n"


def write_rooms(path, rooms):
    with open(path, encoding="utf-8") as f:
        old = f.read()
    if rooms_text(json.loads(old)) != old:
        sys.exit("content/rooms.json is not in the layout this script writes: add the district by hand")
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(rooms_text(rooms))


def status(pairs, files, sources):
    for d, parent in pairs:
        todo = targets(d, parent)
        real = sum(1 for rel in todo if real_art(rel, files, sources))
        ph = sum(1 for rel in todo if listed(rel, files) and sources.get(listed(rel, files), "").startswith(PLACEHOLDER))
        missing = sum(1 for rel in todo if find_picture(rel) is None)
        print("%-16s parent %-10s pictures %2d: producer %2d, placeholders %2d, missing %2d%s"
              % (d["id"], parent["id"], len(todo), real, ph, missing,
                 "   (placeholders installed: a run skips it)" if placeholders_done(todo, files, sources) else ""))


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["selftest"]:
        return selftest()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ids", nargs="*", help="Part 2 district ids (default: every one that has no pictures yet)")
    ap.add_argument("--force", action="store_true", help="redo a district even over installed pictures")
    ap.add_argument("--status", action="store_true", help="only report which districts wear placeholders")
    args = ap.parse_args(argv)
    districts = load_json(os.path.join(CONTENT, "districts.json"))["districts"]
    pairs = part2_pairs(districts)
    data = load_json(inst.PATH) if os.path.isfile(inst.PATH) else {}
    files = set(data.get("files", []))
    sources = dict(data.get("sources", {}))
    if args.status:
        status(pairs, files, sources)
        return 0
    known = {d["id"] for d, _ in pairs}
    for i in args.ids:
        if i not in known:
            sys.exit("%s is not a district of Part 2 (content/districts.json \"part\": 2)" % i)
    done = 0
    for d, parent in pairs:
        if args.ids and d["id"] not in args.ids:
            continue
        if make(d, parent, files, sources, force=args.force):
            done += 1
    if done:
        inst.save(files, sources)       # a run that made nothing writes nothing
        print("%d district(s) done; now: python3 tools/gen_map.py && python3 tools/gen_defold.py" % done)
    else:
        print("nothing to do: every Part 2 district has its pictures; --force <id> redoes one")
    return 0


def selftest():
    """The script on a temporary project of synthetic pictures. Checks that a run twice gives the same result (the second
    run writes nothing), that the backgrounds come out as JPEG files and never as a PNG next to a JPEG of the same key, that
    a stale copy is repaired, that the producer's pictures are left alone and that --force redoes a district exactly."""
    import contextlib
    import io
    import tempfile

    failed = []

    def check(ok, what):
        if not ok:
            failed.append(what)
            print("FAIL:", what)

    def say(argv):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = main(argv)
        return code, buf.getvalue()

    def snapshot(root):
        kept = {}
        for dp, _, fns in os.walk(root):
            for fn in fns:
                with open(os.path.join(dp, fn), "rb") as f:
                    kept[os.path.relpath(os.path.join(dp, fn), root).replace(os.sep, "/")] = f.read()
        return kept

    saved = (inst.ROOT, inst.PATH, ROOT, IMAGES, CONTENT)
    try:
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.join(tmp, "root")
            images, content = os.path.join(root, "assets", "images"), os.path.join(root, "content")
            os.makedirs(content)
            os.makedirs(os.path.join(root, "assets", "art_ready"))
            rng = np.random.RandomState(3)

            def photo(w, h):
                return Image.fromarray(rng.randint(0, 255, (h, w, 3), np.uint8), "RGB")

            def sprite(w, h):
                a = np.zeros((h, w, 4), np.uint8)
                a[h // 4: 3 * h // 4, w // 4: 3 * w // 4] = (200, 90, 60, 255)
                return Image.fromarray(a, "RGBA")

            def put(rel, im, **kw):
                path = os.path.join(images, rel)
                os.makedirs(os.path.dirname(path), exist_ok=True)
                im.save(path, **kw)

            tasks = lambda pre: [{"id": "%s%d" % (pre, i)} for i in range(1, 7)]   # noqa: E731
            dlist = [{"id": "pa", "tasks": tasks("pa")}, {"id": "pb", "tasks": tasks("pb")},
                     {"id": "xa", "part": 2, "tasks": tasks("xa")}, {"id": "xb", "part": 2, "tasks": tasks("xb")}]
            write_json(os.path.join(content, "districts.json"), {"districts": dlist}, 2)
            layouts, rooms, gates = {}, {"version": 1, "districts": {}}, {}
            for pid in ("pa", "pb"):
                # pa keeps its backgrounds as JPEG files (converted), pb as PNG files (not yet): the parent may be either
                for name in ("bg", "bg_concert", "level_bg"):
                    if pid == "pa" or name == "level_bg":
                        put("districts/%s/%s.jpg" % (pid, name), photo(72, 128), quality=90)
                    else:
                        put("districts/%s/%s.png" % (pid, name), photo(72, 128))
                put("mapbg/bg_%s.png" % pid, sprite(72, 108))
                board = np.zeros((48, 72, 4), np.uint8)
                board[...] = (90, 60, 30, 255)
                board[8:20, 12:60] = (250, 250, 245, 255)
                put("mapbg/gate_%s.png" % pid, Image.fromarray(board, "RGBA"))
                for i in range(1, 7):
                    put("map/deco_%s_%d.png" % (pid, i), sprite(16, 16))
                items = {}
                for i in range(1, 7):
                    put("districts/%s/%s%d.png" % (pid, pid, i), sprite(30, 30))
                    items["%s%d" % (pid, i)] = {"image": "assets/images/districts/%s/%s%d.png" % (pid, pid, i), "ghost": "g",
                                                "x": 100 + i, "y": 700, "scale": 0.7, "w": 30, "h": 30}
                layouts[pid] = {"bg": "assets/images/districts/%s/bg.jpg" % pid, "bg_concert": "x", "bg_scale": 1.0, "items": items}
                rooms["districts"][pid] = {"mood": "cosy", "details": [
                    {"kind": "shaft", "color": "#FFF1C0", "x": 10}, {"kind": "steam", "item": "%s2" % pid, "x": 5}]}
                gates[pid] = {"dx": 0, "dy": 100, "h": 12, "w": 40}
            write_json(os.path.join(content, "district_layouts.json"), layouts, 2)
            with open(os.path.join(content, "rooms.json"), "w", encoding="utf-8", newline="") as f:
                f.write(rooms_text(rooms))
            write_json(os.path.join(content, "map_gates.json"), gates, 1)

            inst.ROOT, inst.PATH = root, os.path.join(root, "assets", "art_ready", "installed.json")
            globals().update(ROOT=root, IMAGES=images, CONTENT=content)

            # 1. a first run makes both Part 2 districts
            code, out = say([])
            check(code == 0 and "2 district(s) done" in out, "the first run makes both districts: %s" % out)
            for did, item in (("xa", "xa"), ("xb", "xb")):
                for name in ("bg", "bg_concert", "level_bg"):
                    jpg = os.path.join(images, "districts", did, name + ".jpg")
                    check(os.path.isfile(jpg), "%s/%s is a .jpg" % (did, name))
                    if os.path.isfile(jpg):
                        with Image.open(jpg) as im:
                            check(im.format == "JPEG", "%s/%s.jpg is a real JPEG" % (did, name))
                    check(not os.path.isfile(os.path.join(images, "districts", did, name + ".png")),
                          "%s/%s has no .png beside the .jpg (one image key twice)" % (did, name))
                for i in range(1, 7):
                    for tail in (".png", "_ghost.png"):
                        check(os.path.isfile(os.path.join(images, "districts", did, "%s%d%s" % (item, i, tail))), "%s item %d%s" % (did, i, tail))
                    check(os.path.isfile(os.path.join(images, "map", "deco_%s_%d.png" % (did, i))), "%s deco %d" % (did, i))
                check(os.path.isfile(os.path.join(images, "mapbg", "bg_%s.png" % did)) and os.path.isfile(os.path.join(images, "mapbg", "gate_%s.png" % did)),
                      "%s has its map tile and gate" % did)
            files, notes = inst.load(), inst.load_sources()
            check(all(inst.sibling(f) not in files for f in files), "no picture is listed under both extensions")
            check(all(os.path.isfile(os.path.join(images, f)) for f in files), "every listed picture is on disk")
            check(all(notes.get(f, "").startswith(PLACEHOLDER) for f in files), "every listed picture is marked as a placeholder")
            check("districts/xa/bg.jpg" in files and "districts/xa/level_bg.jpg" in files and "districts/xa/bg.png" not in files,
                  "the backgrounds are listed as .jpg")
            lay = load_json(os.path.join(content, "district_layouts.json"))
            check(lay["xa"]["bg"] == "assets/images/districts/xa/bg.jpg" and lay["xb"]["bg_concert"] == "assets/images/districts/xb/bg_concert.jpg",
                  "the layouts point at the .jpg files: %s" % lay["xa"]["bg"])
            check(all(os.path.isfile(os.path.join(root, it["image"])) and os.path.isfile(os.path.join(root, it["ghost"]))
                      for did in ("xa", "xb") for it in lay[did]["items"].values()), "the layouts point at pictures that exist")
            check(load_json(os.path.join(content, "rooms.json"))["districts"]["xa"]["details"][1].get("item") == "xa2",
                  "the details of the room follow the new task ids")
            check(load_json(os.path.join(content, "map_gates.json"))["xb"] == gates["pb"], "the gate sign is the parent's")

            # 2. the same run again: nothing is made, nothing is written (not one byte of the project changes)
            first = snapshot(root)
            code, out = say([])
            check(code == 0 and "nothing to do" in out and out.count("skip") == 2, "a second run skips both districts: %s" % out)
            check(snapshot(root) == first, "a second run changes nothing")
            code, out = say(["xa"])
            check(snapshot(root) == first and "skip xa" in out, "a district named on the command line is skipped too: %s" % out)

            # 3. --force redoes a district: the very same files (the pictures are a function of the parent's)
            code, out = say(["--force", "xa"])
            check(code == 0 and "1 district(s) done" in out, "--force makes it again: %s" % out)
            check(snapshot(root) == first, "--force gives byte for byte the files that were there")

            # 4. a stale copy under the other extension (what the first version of this script left next to a .jpg) is repaired
            stale = os.path.join(images, "districts", "xa", "level_bg.png")
            photo(72, 128).save(stale)
            notes = inst.load_sources()
            notes["districts/xa/level_bg.png"] = PLACEHOLDER + "old"
            inst.save(inst.load() | {"districts/xa/level_bg.png"}, notes)
            code, out = say([])
            check("1 district(s) done" in out, "a district with a stale copy is made again by a plain run: %s" % out)
            check(not os.path.isfile(stale) and "districts/xa/level_bg.png" not in inst.load(), "the stale .png is deleted and unlisted")
            check(snapshot(root) == first, "after the repair the project is as it was")

            # 5. a background listed as a .png (the state before the pictures became JPEG files) is made a .jpg
            os.remove(os.path.join(images, "districts", "xb", "bg.jpg"))
            photo(72, 128).save(os.path.join(images, "districts", "xb", "bg.png"))
            inst.rename([("districts/xb/bg.jpg", "districts/xb/bg.png")])
            code, out = say([])
            check("1 district(s) done" in out and os.path.isfile(os.path.join(images, "districts", "xb", "bg.jpg"))
                  and not os.path.isfile(os.path.join(images, "districts", "xb", "bg.png")), "a .png background becomes a .jpg: %s" % out)
            check(snapshot(root) == first, "the project is as it was again")

            # 6. the producer's pictures are left alone, --force redoes them
            notes = inst.load_sources()
            notes.pop("districts/xb/bg.jpg")
            inst.save(inst.load(), notes)
            before = snapshot(root)
            code, out = say([])
            check("skip xb: it has the producer's pictures" in out and snapshot(root) == before, "a district with a picture of the producer is skipped: %s" % out)
            code, out = say(["--force", "xb"])
            check("1 district(s) done" in out and snapshot(root) == first, "--force redoes it, the note is back")

            # 7. --status
            code, out = say(["--status"])
            check(code == 0 and out.count("missing  0") == 2 and out.count("placeholders installed") == 2, "--status: nothing is missing: %s" % out)
            check(snapshot(root) == first, "--status writes nothing")
    finally:
        inst.ROOT, inst.PATH, root_, images_, content_ = saved
        globals().update(ROOT=root_, IMAGES=images_, CONTENT=content_)
    if failed:
        print("make_part2_placeholders selftest: %d failed" % len(failed))
        return 1
    print("make_part2_placeholders selftest: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
