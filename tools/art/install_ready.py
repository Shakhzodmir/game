#!/usr/bin/env python3
"""Puts the producer's finished drawings into the game (the step after tools/art/import_incoming.py).

  python3 tools/art/install_ready.py            # copy what is ready, record it, run tools/gen_defold.py
  python3 tools/art/install_ready.py status     # what is installed, what is ready, what is still procedural
  python3 tools/art/install_ready.py uninstall  # forget the installed pictures (then: gen_art.py --only bit,districts)
  python3 tools/art/install_ready.py selftest   # the installer against synthetic pictures

Reads assets/art_ready/<group>/<name>[_<frame>].png (what import_incoming.py wrote) and copies, by the names the
game reads (docs/handoff/WP-8.md):

  bit/bit_<anim>_<n>.png            -> assets/images/bit/<anim>_<n>.png        256x256, RGBA; an animation is installed
                                                                               only when ALL its frames are there
  rooms/room_<district>_day.png     -> assets/images/districts/<district>/bg.png          720x1280
  rooms/room_<district>_concert.png -> assets/images/districts/<district>/bg_concert.png  720x1280

and every other picture of the brief: the tables SINGLES and SETS below (notebook, map, mapbg, bonus, ui, icons,
genres, backgrounds, the still poses of Bit). A picture of the wrong size is reported and not installed.

Whatever is not there stays the procedural drawing of tools/art. The installed files are listed in
assets/art_ready/installed.json: tools/art/gen_art.py skips them, so a full redraw never overwrites the producer's art.
Standard library only (sizes are read from the PNG header).
"""
import argparse
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import installed as inst  # noqa: E402

ROOT = inst.ROOT
READY = os.path.join(ROOT, "assets", "art_ready")
IMAGES = os.path.join(ROOT, "assets", "images")

# animation -> number of frames (the same as tools/art/bit.py FRAMES and content/animations.json)
BIT_ANIMS = {"idle_breathe": 4, "idle_look": 4, "dance_a": 6, "dance_b": 6, "cheer": 6, "surprised": 4, "sleepy": 4,
             "write": 6, "listen": 4, "wave": 4}
BIT_SIZE = (256, 256)
ROOM_SIZE = (720, 1280)
DISTRICTS = ("cafe", "jazz", "square", "stadium", "garage")
COLOURS = ("green", "blue", "gold", "pink", "purple")
DOODLES = ["note", "note2", "clef", "heart", "star", "flower", "sun", "cloud", "bolt"]
ICON_SHEETS = (
    ["arrow", "chart", "check", "chest_closed", "chest_open", "city", "close", "coin", "col_light"],
    ["gift", "goal_floor", "hand", "haptics", "heart", "heart_infinite", "home", "jukebox", "lock"],
    ["map", "music_off", "music_on", "note_off", "note_on", "pause", "play", "plus", "remix"],
    ["retry", "row_light", "settings", "shop", "sound_off", "sound_on", "star", "star_empty", "stick"],
    ["streak", "super_star", "swap", "team"],
)

# One file per picture: (folder in art_ready, brief name, game key without .png, size in px).
# The names and sizes are the same as in tools/art/import_incoming.py SPEC (a selftest checks it).
SINGLES = [
    ("bit", "bit_idle", "bit/idle", (256, 256)),
    ("bit", "bit_happy", "bit/happy", (256, 256)),
    ("bit", "bit_sad", "bit/sad", (256, 256)),
    ("bit", "bit_worried", "bit/worried", (256, 256)),
    ("bit", "bit_scratch", "bit/scratch", (256, 256)),
    ("notebook", "paper_sheet", "notebook/paper_sheet", (640, 900)),
    ("notebook", "notebook_closed", "notebook/closed", (384, 384)),
    ("notebook", "stamp_ready", "notebook/stamp_ready", (192, 192)),
    ("notebook", "stationery_pencil", "notebook/stationery_1", (128, 128)),
    ("notebook", "stationery_star", "notebook/stationery_6", (128, 128)),
    ("map", "map_path_dot", "map/path_dot", (48, 48)),
    ("map", "map_path_dot_done", "map/path_dot_done", (48, 48)),
    ("bonus", "bonus_bar_frame", "bonus/bar_frame", (640, 106)),
    ("bonus", "bonus_bar_fill", "bonus/bar_fill", (640, 106)),
    ("ui", "panel", "ui/panel", (128, 128)),
    ("ui", "ribbon", "ui/ribbon", (320, 80)),
    ("ui", "moves_badge", "ui/moves_badge", (192, 192)),
    ("ui", "badge_count", "ui/badge_count", (56, 56)),
    ("ui", "bunting", "ui/bunting", (720, 64)),
    ("backgrounds", "level_bg", "backgrounds/level_bg", (720, 1280)),
] + [("map", "map_bg_%s" % d, "mapbg/bg_%s" % d, (720, 1080)) for d in DISTRICTS] \
  + [("map", "gate_%s" % d, "mapbg/gate_%s" % d, (720, 480)) for d in DISTRICTS] \
  + [("ui", "btn_%s" % c, "ui/button_%s" % c, (384, 128)) for c in COLOURS] \
  + [("rooms", "room_%s_%s" % (d, v), "districts/%s/%s" % (d, k), ROOM_SIZE)
     for d in DISTRICTS for v, k in (("day", "bg"), ("concert", "bg_concert"))]

# Sheets cut into cells: (folder, brief name, cell names in order, game key template, cell size).
# Cell file = <brief name>_<cell name>.png. A template with %d takes the 1-based position of the cell, else the name.
SETS = [
    ("notebook", "doodles", DOODLES, "notebook/doodle_%d", (96, 96)),
    ("map", "node_day", ["locked", "open", "current", "done"], "map/node_day_%s", (160, 160)),
    ("map", "node_concert", ["locked", "open", "current", "done"], "map/node_concert_%s", (224, 224)),
    ("bonus", "bonus_gift", ["closed", "shake", "glow", "open"], "bonus/gift_%s", (192, 192)),
    ("bonus", "bonus_spark", ["1", "2", "3", "4", "5", "6"], "bonus/spark_%d", (128, 128)),
    ("genres", "genres_a", ["classical", "folk", "pop", "hiphop", "edm", "rnb", "reggae", "country", "blues"],
     "ui/genres/%s", (96, 96)),
    ("genres", "genres_b", ["bossa", "ambient", "cinematic", "chiptune", "latin", "eastern"], "ui/genres/%s", (96, 96)),
] + [("map", "deco_%s" % d, ["d%d" % i for i in range(1, 7)], "map/deco_%s_%%d" % d, (160, 160)) for d in DISTRICTS] \
  + [("ui", "icons_%d" % k, names, "ui/icons/%s", (96, 96)) for k, names in enumerate(ICON_SHEETS, 1)]


def brief_names():
    """The names of the pictures of the brief (docs/art-brief-chatgpt.md) that this installer knows."""
    return {s[1] for s in SINGLES} | {s[1] for s in SETS} | {"bit_" + a for a in BIT_ANIMS}


def png_info(path):
    """(width, height, color type) of a PNG from its header, or None when it is not a PNG."""
    try:
        with open(path, "rb") as f:
            head = f.read(26)
    except OSError:
        return None
    if len(head) < 26 or head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        return None
    w, h = struct.unpack(">II", head[16:24])
    return w, h, head[25]


def sha1(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def plan(ready):
    """-> (items, notes): items = [(source relative to ready, target relative to images)], notes = lines (Russian)."""
    items, notes = [], []
    for anim, n in BIT_ANIMS.items():
        srcs = ["bit/bit_%s_%d.png" % (anim, i) for i in range(1, n + 1)]
        have = [s for s in srcs if os.path.isfile(os.path.join(ready, s))]
        if not have:
            notes.append("bit_%s: нет в art_ready, остаётся заглушка" % anim)
            continue
        if len(have) < n:
            notes.append("bit_%s: готово %d кадров из %d, анимация не ставится (кадры одной анимации ставятся вместе)"
                         % (anim, len(have), n))
            continue
        bad = []
        for s in srcs:
            info = png_info(os.path.join(ready, s))
            if info is None or (info[0], info[1]) != BIT_SIZE or info[2] != 6:
                bad.append(s)
        if bad:
            notes.append("bit_%s: %s не PNG RGBA 256x256, анимация не ставится" % (anim, ", ".join(bad)))
            continue
        for i, s in enumerate(srcs, 1):
            items.append((s, "bit/%s_%d.png" % (anim, i)))
    for group, name, key, size in SINGLES:
        _one(ready, "%s/%s.png" % (group, name), key, size, items, notes, name)
    for group, name, names, template, size in SETS:
        for n in names:
            pos = names.index(n) + 1
            key = template % pos if "%d" in template else template % n
            _one(ready, "%s/%s_%s.png" % (group, name, n), key, size, items, notes, "%s_%s" % (name, n))
    return items, notes


def _one(ready, src, key, size, items, notes, label):
    """A picture that is in art_ready is planned for assets/images/<key>.png if it is a PNG RGBA of the right size.
    A missing one is not a remark (status counts them); a wrong one is."""
    p = os.path.join(ready, src)
    if not os.path.isfile(p):
        return
    info = png_info(p)
    if info is None or (info[0], info[1]) != tuple(size):
        notes.append("%s: не PNG %dx%d, не ставится" % (label, size[0], size[1]))
        return
    items.append((src, key + ".png"))


def install(ready=READY, images=IMAGES, state=inst.PATH, gen=True, out=print):
    if not os.path.isdir(ready):
        out("нет папки %s: сначала tools/art/import_incoming.py" % ready)
        return 2
    items, notes = plan(ready)
    files, sources = inst.load(state), {}
    try:
        with open(state, encoding="utf-8") as f:
            sources = dict(json.load(f).get("sources", {}))
    except (OSError, ValueError):
        pass
    copied = 0
    for src, dst in items:
        sp, dp = os.path.join(ready, src), os.path.join(images, dst)
        digest = sha1(sp)
        if dst in files and sources.get(dst) == digest and os.path.isfile(dp):
            continue
        os.makedirs(os.path.dirname(dp), exist_ok=True)
        shutil.copyfile(sp, dp)
        files.add(dst)
        sources[dst] = digest
        copied += 1
    inst.save(files, sources, state)
    for n in notes:
        out("  " + n)
    out("установлено: %d файлов новых или изменённых, всего в installed.json: %d" % (copied, len(files)))
    if gen and copied:
        out("gen_defold…")
        r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "gen_defold.py")], cwd=ROOT)
        if r.returncode != 0:
            return r.returncode
    return 0


def status(ready=READY, images=IMAGES, state=inst.PATH, out=print):
    items, notes = plan(ready) if os.path.isdir(ready) else ([], ["нет папки %s" % ready])
    files = inst.load(state)
    out("установлено: %d" % len(files))
    out("готово к установке: %d" % len([1 for _, d in items if d not in files]))
    for n in notes:
        out("  " + n)
    return 0


def uninstall(state=inst.PATH, out=print):
    files = inst.load(state)
    inst.save(set(), None, state)
    out("забыто %d файлов; чтобы вернуть заглушки: python3 tools/art/gen_art.py --only bit,districts" % len(files))
    return 0


# -- self test --------------------------------------------------------------------------------------------------------------

def _png(path, w, h, color=6):
    import zlib

    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + b"\x10" * (w * (4 if color == 6 else 3)) for _ in range(h))
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, color, 0, 0, 0)) + \
        chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def selftest():
    ok = True

    def check(cond, what):
        nonlocal ok
        print(("ok   " if cond else "FAIL ") + what)
        ok = ok and cond
    tmp = tempfile.mkdtemp(prefix="install_ready_")
    try:
        ready, images, state = [os.path.join(tmp, x) for x in ("ready", "images", "installed.json")]
        for i in range(1, 7):
            _png(os.path.join(ready, "bit/bit_cheer_%d.png" % i), 256, 256)
        for i in range(1, 4):   # wave: 3 of 4 frames only
            _png(os.path.join(ready, "bit/bit_wave_%d.png" % i), 256, 256)
        for i in range(1, 5):   # listen: wrong size
            _png(os.path.join(ready, "bit/bit_listen_%d.png" % i), 200 if i == 2 else 256, 256)
        _png(os.path.join(ready, "rooms/room_jazz_day.png"), 720, 1280, 2)
        _png(os.path.join(ready, "rooms/room_cafe_day.png"), 720, 1000, 2)   # wrong size
        os.makedirs(os.path.join(images, "bit"))
        with open(os.path.join(images, "bit", "cheer_1.png"), "wb") as f:
            f.write(b"procedural")
        lines = []
        rc = install(ready, images, state, gen=False, out=lines.append)
        text = "\n".join(lines)
        check(rc == 0, "install returns 0")
        check(inst.load(state) == {"bit/cheer_%d.png" % i for i in range(1, 7)} | {"districts/jazz/bg.png"},
              "only whole animations and right-sized rooms are installed: %s" % sorted(inst.load(state)))
        check(open(os.path.join(images, "bit", "cheer_1.png"), "rb").read() != b"procedural", "an installed frame replaced the procedural one")
        check("bit_wave" in text and "3 кадров из 4" in text, "a partial animation is reported")
        check("bit_listen" in text and "256x256" in text, "a wrong size is reported")
        check("room_cafe_day" in text and "720x1280" in text, "a wrong room is reported")
        check(not os.path.exists(os.path.join(images, "bit", "wave_1.png")), "a partial animation is not copied")
        # again: nothing changes
        lines.clear()
        install(ready, images, state, gen=False, out=lines.append)
        check("0 файлов новых" in "\n".join(lines), "a second run copies nothing")
        # the producer redraws one frame: only that one is copied again
        _png(os.path.join(ready, "bit/bit_cheer_3.png"), 256, 256, 6)
        with open(os.path.join(ready, "bit/bit_cheer_3.png"), "ab") as f:
            f.write(b"\0")
        lines.clear()
        install(ready, images, state, gen=False, out=lines.append)
        check("1 файлов новых" in "\n".join(lines), "a redrawn frame is copied again")
        # status and uninstall
        lines.clear()
        status(ready, images, state, out=lines.append)
        check("установлено: 7" in "\n".join(lines), "status counts the installed files")
        uninstall(state, out=lines.append)
        check(inst.load(state) == set(), "uninstall forgets the list")
        check(inst.load(os.path.join(tmp, "nothing.json")) == set(), "no list, nothing installed")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("install_ready selftest: %s" % ("ok" if ok else "FAILED"))
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", nargs="?", default="install", choices=["install", "status", "uninstall", "selftest"])
    ap.add_argument("--ready", default=READY)
    ap.add_argument("--images", default=IMAGES)
    ap.add_argument("--no-gen", action="store_true", help="do not run tools/gen_defold.py")
    a = ap.parse_args()
    if a.cmd == "selftest":
        sys.exit(0 if selftest() else 1)
    if a.cmd == "status":
        sys.exit(status(a.ready, a.images))
    if a.cmd == "uninstall":
        sys.exit(uninstall())
    sys.exit(install(a.ready, a.images, gen=not a.no_gen))


if __name__ == "__main__":
    main()
