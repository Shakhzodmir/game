#!/usr/bin/env python3
"""Placeholder pictures for the districts of Part 2 (districts 16-30, content/districts.json "part": 2) until the
producer draws them: the NIGHT version of the pictures of the "parent" district of Part 1 (the district of the same
genre: district 16 <- district 1, 17 <- 2 ... 30 <- 15).

  python3 tools/art/make_part2_placeholders.py                  # every Part 2 district that has no real pictures yet
  python3 tools/art/make_part2_placeholders.py midnight_cafe    # one district (several ids may be given)
  python3 tools/art/make_part2_placeholders.py --force <id>     # redo it even over real pictures (careful)
  python3 tools/art/make_part2_placeholders.py --status         # which Part 2 districts still wear placeholders

What it writes for a district <id> with parent <p> (the same sizes as the parent's pictures):
  districts/<p>/bg.png, bg_concert.png        -> districts/<id>/bg.png, bg_concert.png   room, day and concert view
  districts/<p>/<task>.png                    -> districts/<id>/<task>.png + <task>_ghost.png  the task items
  mapbg/bg_<p>.png, mapbg/gate_<p>.png        -> mapbg/bg_<id>.png, mapbg/gate_<id>.png    map tile and gate
  map/deco_<p>_1..6.png                       -> map/deco_<id>_1..6.png                     map decorations
  districts/<p>/level_bg.png                  -> districts/<id>/level_bg.png               the sky behind the board
and the data that points at them, copied from the parent with the task ids renamed:
  content/district_layouts.json  (item places of the room), content/rooms.json (the living details of the room),
  content/map_gates.json (where the name goes on the gate: the signboard keeps its pale colour, so it is the
  parent's place), assets/art_ready/installed.json (the files, with the source "placeholder: ..." so that
  tools/art/gen_art.py leaves them alone and --status can tell them from the producer's pictures).
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
    """{relative path of the new picture: (relative path of the parent's picture, kind)}."""
    did, pid = d["id"], parent["id"]
    out = {
        "districts/%s/bg.png" % did: ("districts/%s/bg.png" % pid, "room"),
        "districts/%s/bg_concert.png" % did: ("districts/%s/bg_concert.png" % pid, "concert"),
        "mapbg/bg_%s.png" % did: ("mapbg/bg_%s.png" % pid, "map"),
        "mapbg/gate_%s.png" % did: ("mapbg/gate_%s.png" % pid, "gate"),
        "districts/%s/level_bg.png" % did: ("districts/%s/level_bg.png" % pid, "level"),
    }
    for i in range(1, 7):
        out["map/deco_%s_%d.png" % (did, i)] = ("map/deco_%s_%d.png" % (pid, i), "deco")
    for tid, src in task_pairs(d, parent):
        out["districts/%s/%s.png" % (did, tid)] = ("districts/%s/%s.png" % (pid, src), "item")
    return out


def real_art(rel, files, sources):
    """True when rel is a picture the producer drew (installed, and not by this script)."""
    return rel in files and not sources.get(rel, "").startswith(PLACEHOLDER)


def make(d, parent, files, sources, force=False):
    did, pid = d["id"], parent["id"]
    todo = targets(d, parent)
    real = [rel for rel in todo if real_art(rel, files, sources)]
    if real and not force:
        print("skip %s: it has the producer's pictures (%s ...); --force redoes it" % (did, real[0]))
        return False
    from gen_art import ghost_image  # noqa: E402  (heavy import: only when something is drawn)
    from gate_signs import board_mask  # noqa: E402
    look = LOOK.get(did, "night")
    note = PLACEHOLDER + "%s version of %s" % (look, pid)
    for rel, (src, kind) in sorted(todo.items()):
        path = os.path.join(IMAGES, src)
        if not os.path.isfile(path) and os.path.isfile(path[:-4] + ".jpg"):
            path = path[:-4] + ".jpg"      # a big opaque background was turned into a JPEG (to_jpeg_backgrounds.py)
        if not os.path.isfile(path):
            sys.exit("%s: the parent picture %s is missing" % (did, src))
        with Image.open(path) as im:
            keep = board_mask(im) if kind == "gate" else None
            out = recolour(im, kind, look, keep)
        dst = os.path.join(IMAGES, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        out.save(dst, optimize=True)
        files.add(rel)
        sources[rel] = note
        if kind == "item":
            ghost = rel[:-4] + "_ghost.png"
            ghost_image(out).save(os.path.join(IMAGES, ghost), optimize=True)
            files.add(ghost)
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
    layouts[did] = {"bg": "assets/images/districts/%s/bg.png" % did,
                    "bg_concert": "assets/images/districts/%s/bg_concert.png" % did,
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


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ids", nargs="*", help="Part 2 district ids (default: every one without real pictures)")
    ap.add_argument("--force", action="store_true", help="redo a district even over the producer's pictures")
    ap.add_argument("--status", action="store_true", help="only report which districts wear placeholders")
    args = ap.parse_args()
    districts = load_json(os.path.join(CONTENT, "districts.json"))["districts"]
    pairs = part2_pairs(districts)
    data = load_json(inst.PATH) if os.path.isfile(inst.PATH) else {}
    files = set(data.get("files", []))
    sources = dict(data.get("sources", {}))
    if args.status:
        for d, parent in pairs:
            todo = targets(d, parent)
            real = sum(1 for rel in todo if real_art(rel, files, sources))
            ph = sum(1 for rel in todo if sources.get(rel, "").startswith(PLACEHOLDER))
            print("%-16s parent %-10s pictures %2d: producer %2d, placeholders %2d, missing %2d"
                  % (d["id"], parent["id"], len(todo), real, ph,
                     sum(1 for rel in todo if not os.path.isfile(os.path.join(IMAGES, rel)))))
        return
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
    inst.save(files, sources)
    print("%d district(s) done; now: python3 tools/gen_map.py && python3 tools/gen_defold.py" % done)


if __name__ == "__main__":
    main()
