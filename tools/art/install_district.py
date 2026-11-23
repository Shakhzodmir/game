#!/usr/bin/env python3
"""Installs the producer's pictures of a NEW district (districts 6+) from a folder of raw drawings:

  python3 tools/art/install_district.py <district id> <folder> <name in the file names>
  e.g.    tools/art/install_district.py beach assets/art_incoming/bossa bossa

Reads from the folder (drawn on magenta where a cut-out is needed):
  room_<name>_day.png, room_<name>_concert.png -> districts/<id>/bg.png, bg_concert.png   720x1280
  map_bg_<name>.png                            -> mapbg/bg_<id>.png                       720x1080
  gate_<name>.png                              -> mapbg/gate_<id>.png                     720x480
  deco_<name>.png   (sheet 3x2)                -> map/deco_<id>_1..6.png                  160x160
  items_<name>.png  (sheet, see ROOMS)         -> districts/<id>/<task>.png and <task>_ghost.png

The place of every item in the room is the table ROOMS below (x, y = centre in the 720x1280 room, y from the top;
w = width on screen). content/district_layouts.json gets the district; the files are recorded in
assets/art_ready/installed.json. Run python3 tools/gen_defold.py afterwards.

The map tile is made 720x1080 RGBA with the bottom 110 rows faded out whatever the picture was (PNG or JPEG, opaque, any size
of the 2:3 shape): tools/art/feather_mapbg.py. A map picture of another shape (a square) or with transparency of its own is
refused BEFORE anything is written. The pictures may be .png, .jpg or .jpeg. A picture that replaces a placeholder
of tools/art/make_part2_placeholders.py stops being one (its note in installed.json goes, an older .jpg/.png of the same
key is deleted).

  python3 tools/art/install_district.py selftest     # installs synthetic pictures into a temporary project (Pillow, numpy)
"""
import json
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import feather_mapbg as fm  # noqa: E402
import import_incoming as imp  # noqa: E402
import installed as inst  # noqa: E402
from gen_art import ghost_image  # noqa: E402

IMAGES = os.path.join(inst.ROOT, "assets", "images")
LAYOUTS = os.path.join(inst.ROOT, "content", "district_layouts.json")
SCALE = 0.7     # items are stored 1/SCALE bigger than they are shown, like the first five districts

# district id -> (grid of the items sheet, [(task id, x, y, width on screen) in the order of the sheet])
ROOMS = {
    "beach": ("3x2", [
        ("guitar", 384, 700, 88),
        ("tiki_bar", 250, 688, 210),
        ("hammock", 596, 800, 200),
        ("surf_speaker", 668, 694, 86),
        ("palm_lights", 76, 694, 150),
        ("cajon", 478, 772, 118),
    ]),
    "carnival": ("3x2", [
        ("congas", 210, 800, 150),
        ("maracas", 520, 812, 128),
        ("pinata", 92, 716, 136),
        ("headdress", 452, 716, 150),
        ("banner", 272, 722, 200),
        ("trumpet", 628, 700, 82),
    ]),
    "cinema": ("3x2", [
        ("drum", 520, 826, 170),
        ("harp", 108, 700, 128),
        ("cello", 606, 700, 104),
        ("projector", 286, 716, 150),
        ("timpani", 228, 812, 200),
        ("clapper", 452, 722, 146),
    ]),
    "bazaar": ("3x2", [
        ("oud", 628, 672, 104),
        ("lanterns", 98, 668, 124),
        ("tea_table", 300, 694, 190),
        ("darbuka", 196, 800, 108),
        ("flutes", 482, 682, 96),
        ("carpet", 506, 826, 190),
    ]),
    "skyclub": ("3x2", [
        ("dj_deck", 240, 822, 200),
        ("speaker", 322, 692, 100),
        ("synth", 484, 724, 150),
        ("light_truss", 128, 704, 180),
        ("disco_ball", 632, 692, 100),
        ("led_cubes", 524, 818, 150),
    ]),
    "block": ("3x2", [
        ("turntables", 232, 742, 200),
        ("boombox", 512, 752, 190),
        ("speakers", 322, 584, 110),
        ("hoop", 472, 580, 112),
        ("mic", 622, 586, 92),
        ("graffiti", 128, 596, 190),
    ]),
    "island": ("3x2", [
        ("bongos", 232, 762, 180),
        ("bass_guitar", 632, 584, 80),
        ("speaker_box", 322, 610, 130),
        ("organ", 482, 614, 150),
        ("steel_drum", 502, 752, 170),
        ("fruit_stand", 128, 590, 190),
    ]),
    "ranch": ("3x2", [
        ("banjo", 642, 588, 80),
        ("fiddle", 240, 752, 112),
        ("hay_stage", 138, 606, 210),
        ("boots_rack", 332, 596, 130),
        ("bench", 500, 616, 170),
        ("washboard_tub", 502, 760, 180),
    ]),
    "bluesclub": ("3x2", [
        ("guitar", 632, 594, 90),
        ("harmonica", 240, 760, 150),
        ("piano", 140, 606, 200),
        ("neon_sign", 332, 600, 100),
        ("mic", 522, 746, 100),
        ("amp", 482, 620, 130),
    ]),
    "arcade": ("3x2", [
        ("cabinet", 110, 604, 130),
        ("joystick", 222, 770, 170),
        ("synth", 612, 624, 150),
        ("tv_stack", 272, 604, 120),
        ("pixel_heart", 442, 624, 150),
        ("robot_dj", 502, 760, 160),
    ]),
    # Part 2 (docs/design/part2-districts.md): the places of the parent room of Part 1 (cafe), so the producer's room
    # can be drawn like the cafe one; until then tools/art/make_part2_placeholders.py puts night placeholders there
    "midnight_cafe": ("3x2", [
        ("radio", 370, 712, 148),
        ("string_lights", 360, 348, 142),
        ("rhodes", 160, 690, 190),
        ("umbrellas", 578, 694, 160),
        ("night_cat", 574, 418, 130),
        ("neon_sign", 360, 540, 110),
    ]),
    # district 17: the places of the jazz bar items its placeholders borrow (TASK_FROM of make_part2_placeholders.py)
    # district 17: the places fitted to the producer's club room (a round stage with bulbs at y 570-690, a free floor
    # below it; the top bar covers y < 235 and the task card y > 835): vibes, drums and piano on the stage, the double
    # bass, the neon note and the muted trumpet on the floor
    "late_club": ("3x2", [
        ("drums", 330, 600, 121),
        ("double_bass", 170, 765, 91),
        ("piano", 520, 575, 166),
        ("vibes", 135, 595, 154),
        ("muted_trumpet", 555, 770, 121),
        ("note_sign", 360, 765, 107),
    ]),
    # district 18: the places of the street band square items its placeholders borrow (TASK_FROM)
    "nations_fest": ("3x2", [
        ("taiko", 330, 700, 158),
        ("festival_tent", 380, 520, 173),
        ("steel_pan", 600, 580, 118),
        ("flag_garland", 360, 322, 456),
        ("accordion", 560, 716, 62),
        ("shell_stage", 596, 432, 93),
    ]),
    # district 19: the places of the K-pop stadium items its placeholders borrow (TASK_FROM)
    "fan_meeting": ("3x2", [
        ("small_stage", 360, 560, 181),
        ("piano", 140, 540, 204),
        ("photo_wall", 360, 330, 162),
        ("lightsticks", 560, 710, 140),
        ("gift_basket", 142, 330, 151),
        ("mic_stand", 578, 326, 128),
    ]),
}


def keyed(path):
    rgb, alpha = imp.load_input(path)
    if alpha is None:
        key, _ = imp.estimate_key(rgb)
        color, alpha, _ = imp.key_out(rgb, key)
    else:
        color = rgb.astype("float32")
    return color, alpha


def cut(color, alpha, box, size=None, width=None):
    """The drawing inside box, trimmed; fitted into size (w, h) or scaled to width."""
    x0, y0, x1, y1 = box
    a = alpha[y0:y1, x0:x1]
    b = imp.bbox(a)
    if not b:
        sys.exit("an empty cell in the sheet")
    bx0, by0, bx1, by1 = b
    bw, bh = bx1 - bx0, by1 - by0
    k = width / float(bw) if width else min(size[0] / float(bw), size[1] / float(bh))
    out = (max(1, round(bw * k)), max(1, round(bh * k)))
    return Image.fromarray(imp.resize_rgba(color[y0:y1, x0:x1][by0:by1, bx0:bx1], a[by0:by1, bx0:bx1], out), "RGBA")


def centred(im, size):
    canvas = Image.new("RGBA", size, (0, 0, 0, 0))
    canvas.alpha_composite(im, ((size[0] - im.width) // 2, (size[1] - im.height) // 2))
    return canvas


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["selftest"]:
        return selftest()
    did, folder, name = argv[0], argv[1], argv[2]
    files, sources = inst.load(), inst.load_sources()

    def save(im, rel):
        path = os.path.join(IMAGES, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        im.save(path, optimize=True)
        inst.record(files, sources, rel, IMAGES)      # listed, no longer a placeholder, no JPEG of the same key left
        print("installed", rel, im.size)

    def src(n):             # a PNG or a JPEG, as the producer saved it
        for ext in (".png", ".jpg", ".jpeg"):
            if os.path.isfile(os.path.join(folder, n + ext)):
                return os.path.join(folder, n + ext)
        return os.path.join(folder, n + ".png")

    # the map tile: 720x1080 RGBA with the bottom 110 rows faded out (the map overlaps the tiles of a district: an opaque
    # tile shows a hard seam every 740 px), whatever the picture was: tools/art/feather_mapbg.py. It is made FIRST: a picture
    # that is refused (not 2:3, transparent) must stop the install before the rooms are written (save() deletes the old
    # .jpg of a key and the list is saved only at the end)
    try:
        with Image.open(src("map_bg_" + name)) as picture:
            tile = fm.feather(picture)
    except ValueError as e:
        sys.exit("map_bg_%s: %s" % (name, e))
    for view, key in (("day", "bg"), ("concert", "bg_concert")):
        save(Image.open(src("room_%s_%s" % (name, view))).convert("RGB").resize((720, 1280), Image.LANCZOS),
             "districts/%s/%s.png" % (did, key))
    save(tile, "mapbg/bg_%s.png" % did)

    color, alpha = keyed(src("gate_" + name))
    h, w = alpha.shape
    save(centred(cut(color, alpha, (0, 0, w, h), size=(652, 442)), (720, 480)), "mapbg/gate_%s.png" % did)

    color, alpha = keyed(src("deco_" + name))
    h, w = alpha.shape
    for i, box in enumerate(imp.cell_boxes(w, h, 3, 2), 1):
        save(centred(cut(color, alpha, box, size=(150, 150)), (160, 160)), "map/deco_%s_%d.png" % (did, i))

    grid, places = ROOMS[did]
    cols, rows = (int(v) for v in grid.split("x"))
    color, alpha = keyed(src("items_" + name))
    h, w = alpha.shape
    items = {}
    for (task, x, y, width), box in zip(places, imp.cell_boxes(w, h, cols, rows)):
        im = cut(color, alpha, box, width=width / SCALE)
        rel = "districts/%s/%s.png" % (did, task)
        save(im, rel)
        save(ghost_image(im), rel[:-4] + "_ghost.png")
        items[task] = {"image": "assets/images/" + rel, "ghost": "assets/images/" + rel[:-4] + "_ghost.png",
                       "x": x, "y": y, "scale": SCALE, "w": im.width, "h": im.height}
    with open(LAYOUTS, encoding="utf-8") as f:
        layouts = json.load(f)
    with open(os.path.join(inst.ROOT, "content", "districts.json"), encoding="utf-8") as f:
        tasks = [t["id"] for d in json.load(f)["districts"] if d["id"] == did for t in d["tasks"]]
    if sorted(tasks) != sorted(items):
        sys.exit("the items of ROOMS do not match the tasks of content/districts.json: %s / %s" % (sorted(items), sorted(tasks)))
    layouts[did] = {"bg": "assets/images/districts/%s/bg.png" % did,
                    "bg_concert": "assets/images/districts/%s/bg_concert.png" % did, "bg_scale": 1.0,
                    "items": {t: items[t] for t in tasks}}
    with open(LAYOUTS, "w", encoding="utf-8", newline="") as f:
        f.write(json.dumps(layouts, indent=2, ensure_ascii=False) + "\n")
    inst.save(files, sources)


def selftest():
    """Installs a district of synthetic pictures into a temporary project: the map tile comes out feathered (here from an
    opaque JPEG of another size), a placeholder is replaced for good, nothing else of installed.json is lost."""
    import tempfile

    import numpy as np
    from PIL import ImageDraw

    failed = []

    def check(ok, what):
        if not ok:
            failed.append(what)
            print("FAIL:", what)

    def sheet(cols, rows, size=240):
        im = Image.new("RGB", (cols * size, rows * size), (255, 0, 255))
        d = ImageDraw.Draw(im)
        for r in range(rows):
            for c in range(cols):
                x0, y0 = c * size + size // 4, r * size + size // 4
                d.rectangle((x0, y0, x0 + size // 2, y0 + size // 2), fill=(40 + c * 20, 160 + r * 30, 220))
        return im

    saved = (inst.ROOT, inst.PATH, IMAGES, LAYOUTS, dict(ROOMS))
    try:
        with tempfile.TemporaryDirectory() as tmp:
            root = os.path.join(tmp, "root")
            for d in ("assets/images/mapbg", "assets/images/districts/zz_test", "assets/art_ready", "content"):
                os.makedirs(os.path.join(root, d))
            tasks = ["t1", "t2", "t3", "t4", "t5", "t6"]
            with open(os.path.join(root, "content", "districts.json"), "w") as f:
                json.dump({"districts": [{"id": "zz_test", "tasks": [{"id": t} for t in tasks]}]}, f)
            with open(os.path.join(root, "content", "district_layouts.json"), "w") as f:
                json.dump({}, f)
            folder = os.path.join(tmp, "pictures")
            os.makedirs(folder)
            rng = np.random.RandomState(1)
            for n, shape in (("room_zz_day.png", (1280, 720, 3)), ("room_zz_concert.png", (1280, 720, 3))):
                Image.fromarray(rng.randint(0, 255, shape, np.uint8)).save(os.path.join(folder, n))
            tile_jpeg = os.path.join(folder, "map_bg_zz.jpg")           # the producer's map picture: an opaque JPEG, 1024x1536
            Image.fromarray(rng.randint(0, 255, (1536, 1024, 3), np.uint8)).save(tile_jpeg, quality=90)
            sheet(1, 1, 480).save(os.path.join(folder, "gate_zz.png"))
            sheet(3, 2).save(os.path.join(folder, "deco_zz.png"))
            sheet(3, 2).save(os.path.join(folder, "items_zz.png"))
            ROOMS["zz_test"] = ("3x2", [(t, 100 + 50 * i, 700, 100) for i, t in enumerate(tasks)])
            inst.ROOT, inst.PATH = root, os.path.join(root, "assets", "art_ready", "installed.json")
            images = os.path.join(root, "assets", "images")
            globals()["IMAGES"], globals()["LAYOUTS"] = images, os.path.join(root, "content", "district_layouts.json")
            # the district wears placeholders (the map tile and the day room as JPEG files); another file has a note of its own
            inst.save({"mapbg/bg_zz_test.jpg", "districts/zz_test/bg.jpg", "keep.png"},
                      {"mapbg/bg_zz_test.jpg": "placeholder: night version of cafe",
                       "districts/zz_test/bg.jpg": "placeholder: night version of cafe", "keep.png": "placeholder: other"})
            for rel in ("mapbg/bg_zz_test.jpg", "districts/zz_test/bg.jpg"):
                with open(os.path.join(images, rel), "wb") as f:
                    f.write(b"placeholder")

            # a map picture that is not 2:3 (a square from ChatGPT) is refused BEFORE anything is written: no room JPEG is
            # deleted, installed.json and the layouts stay as they were (the rooms are installed ahead of the tile)
            def snapshot():
                kept = {}
                for dp, _, fns in os.walk(root):
                    for fn in fns:
                        with open(os.path.join(dp, fn), "rb") as fh:
                            kept[os.path.relpath(os.path.join(dp, fn), root)] = fh.read()
                return kept
            good_tile = open(tile_jpeg, "rb").read()
            Image.fromarray(rng.randint(0, 255, (1024, 1024, 3), np.uint8)).save(tile_jpeg, quality=90)
            before = snapshot()
            try:
                main(["zz_test", folder, "zz"])
                check(False, "a square map picture is refused")
            except SystemExit as e:
                check("map_bg_zz" in str(e.code) and "2:3" in str(e.code), "the refusal names the picture and the shape: %s" % e.code)
            check(snapshot() == before, "a refused map picture leaves the project as it was (nothing written, no JPEG deleted)")
            with open(tile_jpeg, "wb") as f:
                f.write(good_tile)

            main(["zz_test", folder, "zz"])

            tile = Image.open(os.path.join(images, "mapbg", "bg_zz_test.png"))
            check(tile.mode == "RGBA" and tile.size == (720, 1080), "the map tile is a 720x1080 RGBA PNG: %s %s" % (tile.mode, tile.size))
            with Image.open(tile_jpeg) as src:
                want = np.asarray(fm.feather(src))
            check(np.array_equal(np.asarray(tile), want), "the tile is the feathered picture (alpha 255 -> 0 in the bottom 110 rows)")
            check(np.array_equal(np.asarray(tile)[..., 3], fm.mask()), "the alpha is exactly the feather of feather_mapbg.py")
            check(not os.path.isfile(os.path.join(images, "mapbg", "bg_zz_test.jpg")), "the old JPEG of the tile is gone")
            check(not os.path.isfile(os.path.join(images, "districts", "zz_test", "bg.jpg")), "the old JPEG of the room is gone")
            files = inst.load()
            check({"mapbg/bg_zz_test.png", "districts/zz_test/bg.png", "keep.png"} <= files, "the new pictures are listed")
            check("mapbg/bg_zz_test.jpg" not in files and "districts/zz_test/bg.jpg" not in files, "the old files are not listed")
            check(inst.load_sources() == {"keep.png": "placeholder: other"},
                  "the district stopped being a placeholder, the other note stays: %s" % inst.load_sources())
            with open(inst.PATH, encoding="utf-8") as f:
                listed = json.load(f)["files"]
            check(len(listed) == len(set(listed)), "every picture is listed once")
    finally:
        inst.ROOT, inst.PATH, IMAGES_, LAYOUTS_, rooms = saved
        globals()["IMAGES"], globals()["LAYOUTS"] = IMAGES_, LAYOUTS_
        ROOMS.clear()
        ROOMS.update(rooms)
    if failed:
        print("install_district selftest: %d failed" % len(failed))
        return 1
    print("install_district selftest: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
