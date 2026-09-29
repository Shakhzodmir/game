#!/usr/bin/env python3
"""Generate every image GLOW needs (deterministic, re-runnable from the repo root).

    python3 tools/art/gen_art.py              # everything
    python3 tools/art/gen_art.py --only pieces,icons --jobs 4

Outputs
  assets/images/**.png               game art (see manifest.json)
  assets/images/manifest.json        every file with its pixel size (+ nine-slice notes)
  content/district_layouts.json      scene composition for the meta screen
  docs/media/art_sheet.png           contact sheet of everything except scenes
  docs/media/pieces_grayscale.png    colour-blind / grayscale check of the 6 pieces
  docs/media/district_<id>.png       each scene at 720x1280 with items in place

Drawing code lives next to this file: artkit (SDF painter), pieces, blockers,
ui (board/fx/ui/icons), bit (mascot), logo, items + districts (meta scenes).
"""
import argparse
import importlib
import json
import os
import sys
import time
from multiprocessing import Pool

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "assets", "images")
DOCS = os.path.join(ROOT, "docs", "media")
CONTENT = os.path.join(ROOT, "content")
FONT_UI = os.path.join(ROOT, "assets", "fonts", "Nunito-Bold.ttf")

import numpy as np  # noqa: E402
from PIL import Image, ImageDraw, ImageFont  # noqa: E402

TRIM_PAD = 4          # district items are trimmed to their visible pixels + this padding
SCENE_W, SCENE_H = 720, 1280
SAFE = (60, 180, 660, 1000)   # items must stay inside x0, y0, x1, y1 (scene px)


# ==========================================================================
# job list
# ==========================================================================
def load_districts():
    with open(os.path.join(CONTENT, "districts.json"), encoding="utf-8") as f:
        return json.load(f)["districts"]


def build_jobs():
    """Each job: (group, relpath, module, attr, key_or_args, opts)."""
    import pieces
    import ui
    import bit
    import items

    J = []
    for c in pieces.ORDER:
        J.append(("pieces", f"pieces/{c}.png", "pieces", "PIECE_FUNCS", c, {}))
    for s in ("riff", "sub", "bird", "disco"):
        J.append(("specials", f"specials/{s}.png", "pieces", "SPECIAL_FUNCS", s, {}))
    for hp in (3, 2, 1):
        J.append(("blockers", f"blockers/record_box_{hp}.png", "blockers", "draw_record_box", (hp,), {}))
    for hp in (2, 1):
        J.append(("blockers", f"blockers/concrete_{hp}.png", "blockers", "draw_concrete", (hp,), {}))
    J.append(("blockers", "blockers/noise.png", "blockers", "draw_noise", (), {}))
    for c in pieces.ORDER:
        J.append(("blockers", f"blockers/balloon_{c}.png", "blockers", "draw_balloon", (c,), {}))
    for st in (3, 2, 1):
        J.append(("blockers", f"blockers/column_{st}.png", "blockers", "draw_column", (st,), {}))
    J.append(("blockers", "blockers/column_on.png", "blockers", "draw_column", (0,), {}))
    for hp in (2, 1):
        J.append(("blockers", f"blockers/wires_{hp}.png", "blockers", "draw_wires", (hp,), {}))
    J.append(("blockers", "blockers/mic.png", "blockers", "draw_mic_cargo", (), {}))
    J.append(("blockers", "blockers/mic_stand.png", "blockers", "draw_mic_stand", (), {}))
    for k in (2, 1):
        J.append(("blockers", f"blockers/floor_{k}.png", "blockers", "draw_floor", (k,), {"opaque": True}))
    J.append(("blockers", "blockers/floor_lit.png", "blockers", "draw_floor", ("lit",), {"opaque": True}))
    J.append(("board", "board/cell_a.png", "ui", "draw_cell", ("#1B1F3B",), {}))
    J.append(("board", "board/cell_b.png", "ui", "draw_cell", ("#232851",), {}))
    J.append(("board", "board/board_frame.png", "ui", "draw_board_frame", (), {}))
    for k in ui.FX_FUNCS:
        J.append(("fx", f"fx/{k}.png", "ui", "FX_FUNCS", k, {}))
    for k in ui.BUTTONS:
        J.append(("ui", f"ui/button_{k}.png", "ui", "draw_button", (k,), {}))
    J.append(("ui", "ui/panel.png", "ui", "draw_panel", (), {}))
    J.append(("ui", "ui/panel_dark.png", "ui", "draw_panel_dark", (), {}))
    J.append(("ui", "ui/ribbon.png", "ui", "draw_ribbon", (), {}))
    for k in ui.ICON_FUNCS:
        J.append(("icons", f"ui/icons/{k}.png", "ui", "ICON_FUNCS", k, {}))
    for p in bit.POSE_ORDER:
        J.append(("bit", f"bit/{p}.png", "bit", "draw_bit", (p,), {}))
    J.append(("logo", "logo/logo.png", "logo", "draw_logo", (), {}))
    for d in load_districts():
        did = d["id"]
        J.append(("districts", f"districts/{did}/bg.png", "districts", "BG_FUNCS", (did, False), {"opaque": True}))
        J.append(("districts", f"districts/{did}/bg_night.png", "districts", "BG_FUNCS", (did, True),
                  {"opaque": True}))
        for t in d["tasks"]:
            if t["id"] not in items.ITEM_FUNCS:
                raise SystemExit(f"no item drawing for task {did}/{t['id']}")
            J.append(("districts", f"districts/{did}/{t['id']}.png", "items", "ITEM_FUNCS", t["id"], {"trim": True}))
    return J


def run_job(job):
    group, rel, mod, attr, key, opts = job
    t0 = time.time()
    m = importlib.import_module(mod)
    fn = getattr(m, attr)
    if isinstance(fn, dict):
        if isinstance(key, tuple):
            cv = fn[key[0]](*key[1:])
        else:
            cv = fn[key]()
    else:
        cv = fn(*key)
    img = cv.image(opaque=opts.get("opaque", False))
    if opts.get("trim"):
        a = np.asarray(img)[..., 3]
        ys, xs = np.nonzero(a > 2)
        x0, y0 = max(xs.min() - TRIM_PAD, 0), max(ys.min() - TRIM_PAD, 0)
        x1, y1 = min(xs.max() + 1 + TRIM_PAD, img.width), min(ys.max() + 1 + TRIM_PAD, img.height)
        img = img.crop((x0, y0, x1, y1))
    path = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, optimize=True)
    return rel, img.width, img.height, os.path.getsize(path), time.time() - t0


# ==========================================================================
# layouts
# ==========================================================================
def visible_bbox(img):
    a = np.asarray(img.convert("RGBA"))[..., 3]
    ys, xs = np.nonzero(a > 8)
    return xs.min(), ys.min(), xs.max() + 1, ys.max() + 1


def scene_rect(img, x, y, s):
    bx0, by0, bx1, by1 = visible_bbox(img)
    left = x - img.width * s / 2
    top = y - img.height * s / 2
    return (left + bx0 * s, top + by0 * s, left + bx1 * s, top + by1 * s)


def write_layouts(districts):
    import districts as D
    out = {}
    problems = []
    for d in districts:
        did = d["id"]
        lay = D.LAYOUT[did]
        entry = {"bg": f"assets/images/districts/{did}/bg.png",
                 "bg_night": f"assets/images/districts/{did}/bg_night.png",
                 "bg_scale": 2.0, "items": {}}
        rects = {}
        for t in d["tasks"]:
            tid = t["id"]
            if tid not in lay:
                problems.append(f"{did}/{tid}: missing layout")
                continue
            x, y, s = lay[tid]
            img = Image.open(os.path.join(OUT, "districts", did, f"{tid}.png"))
            r = scene_rect(img, x, y, s)
            rects[tid] = r
            # the whole (trimmed) image rect must also stay inside the safe area
            full = (x - img.width * s / 2, y - img.height * s / 2, x + img.width * s / 2, y + img.height * s / 2)
            if full[0] < SAFE[0] - 0.5 or full[1] < SAFE[1] - 0.5 or full[2] > SAFE[2] + 0.5 or full[3] > SAFE[3] + 0.5:
                problems.append(f"{did}/{tid}: outside safe area {tuple(round(v) for v in full)}")
            entry["items"][tid] = {"image": f"assets/images/districts/{did}/{tid}.png", "x": x, "y": y, "scale": s,
                                   "w": img.width, "h": img.height}
        ids = list(rects)
        for i in range(len(ids)):
            for j in range(i + 1, len(ids)):
                a, b = rects[ids[i]], rects[ids[j]]
                ox = min(a[2], b[2]) - max(a[0], b[0])
                oy = min(a[3], b[3]) - max(a[1], b[1])
                if ox > 0 and oy > 0:
                    problems.append(f"{did}: {ids[i]} overlaps {ids[j]} by {ox:.0f}x{oy:.0f}px")
        out[did] = entry
    # Scene space is 720x1280, y=0 at the top; x/y = centre of the item image, scale multiplies its
    # pixel size; bg images are 360x640 and are drawn at bg_scale.
    with open(os.path.join(CONTENT, "district_layouts.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
        f.write("\n")
    return problems


# ==========================================================================
# manifest + contact sheets
# ==========================================================================
NINE_SLICE = {
    "ui/button_green.png": 28, "ui/button_blue.png": 28, "ui/button_gold.png": 28, "ui/button_red.png": 28,
    "ui/panel.png": 32, "ui/panel_dark.png": 28, "board/board_frame.png": 24,
}


def write_manifest():
    files = {}
    for dp, _, fns in os.walk(OUT):
        for fn in sorted(fns):
            if not fn.endswith(".png"):
                continue
            p = os.path.join(dp, fn)
            rel = os.path.relpath(p, OUT).replace(os.sep, "/")
            with Image.open(p) as im:
                e = {"w": im.width, "h": im.height, "alpha": im.mode == "RGBA"}
            if rel in NINE_SLICE:
                e["nine_slice"] = NINE_SLICE[rel]
            files[rel] = e
    files = dict(sorted(files.items()))
    man = {"version": 1, "generator": "tools/art/gen_art.py",
           "notes": {
               "specials/riff.png": "horizontal; rotate 90 degrees for the vertical riff",
               "board/board_frame.png": "nine-slice 24px; 3px stroke whose outer edge is 10px from the texture "
                                        "edge (inner edge at 13px) - size the frame to board rect + 13px per side",
               "blockers/mic_stand.png": "exit marker drawn under the bottom cell of an exit column",
               "blockers/column_*.png": "2x2 cells",
               "fx/*.png": "white / near-white, tint in the engine (bolt is cyan-white)",
               "districts/*/bg*.png": "360x640, draw at 2x",
           },
           "files": files}
    with open(os.path.join(OUT, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(man, f, indent=2)
        f.write("\n")
    return files


def _font(size):
    return ImageFont.truetype(FONT_UI, size)


def _checker(w, h, a="#262A4A", b="#2E3358", cell=12):
    im = Image.new("RGB", (w, h), a)
    dr = ImageDraw.Draw(im)
    for yy in range(0, h, cell):
        for xx in range(0, w, cell):
            if (xx // cell + yy // cell) % 2:
                dr.rectangle([xx, yy, xx + cell - 1, yy + cell - 1], fill=b)
    return im


def _section(title, rels, cell, cols, bg=None, label=True):
    n = len(rels)
    rows = -(-n // cols)
    lab = 18 if label else 0
    W = cols * cell
    Hh = 34 + rows * (cell + lab)
    sec = Image.new("RGB", (W, Hh), "#15132E")
    dr = ImageDraw.Draw(sec)
    dr.text((10, 6), title, font=_font(20), fill="#FFE66D")
    for i, rel in enumerate(rels):
        r, c = divmod(i, cols)
        x0, y0 = c * cell, 34 + r * (cell + lab)
        tile = _checker(cell - 6, cell - 6) if bg is None else Image.new("RGB", (cell - 6, cell - 6), bg)
        im = Image.open(os.path.join(OUT, rel)).convert("RGBA")
        k = min((cell - 12) / im.width, (cell - 12) / im.height, 1.0)
        if k < 1:
            im = im.resize((max(int(im.width * k), 1), max(int(im.height * k), 1)), Image.LANCZOS)
        tile.paste(im, ((tile.width - im.width) // 2, (tile.height - im.height) // 2), im)
        sec.paste(tile, (x0 + 3, y0 + 3))
        if label:
            name = os.path.splitext(os.path.basename(rel))[0]
            dr.text((x0 + cell / 2, y0 + cell + 1), name, font=_font(12), fill="#C9C3EA", anchor="mt")
    return sec


def contact_sheets(districts):
    os.makedirs(DOCS, exist_ok=True)
    W = 1600

    def rels(prefix):
        return sorted(r for r in MANIFEST if r.startswith(prefix) and "/" not in r[len(prefix):])

    import pieces
    secs = [
        _section("pieces 160", [f"pieces/{c}.png" for c in pieces.ORDER], 200, 8),
        _section("specials 192", [f"specials/{s}.png" for s in ("riff", "sub", "bird", "disco")], 200, 8),
        _section("blockers 160 / column 320", rels("blockers/"), 200, 8),
        _section("board + fx", rels("board/") + rels("fx/"), 160, 10, bg="#1B1F3B"),
        _section("ui (sunset bg)", rels("ui/"), 200, 8, bg="#FF8E72"),
        _section("icons 96", rels("ui/icons/"), 100, 16, bg="#2463D1"),
        _section("Bit 256 (dark / sunset)", [f"bit/{p}.png" for p in __import__("bit").POSE_ORDER], 228, 7,
                 bg="#1E1B4B"),
        _section("", [f"bit/{p}.png" for p in __import__("bit").POSE_ORDER], 228, 7, bg="#FF8E72", label=False),
        _section("logo", ["logo/logo.png"], 660, 2, bg="#1E1B4B"),
    ]
    for d in districts:
        secs.append(_section(f"{d['id']} items", [f"districts/{d['id']}/{t['id']}.png" for t in d["tasks"]], 160, 10,
                             bg="#3A2E5E"))
    Htot = sum(s.height for s in secs)
    sheet = Image.new("RGB", (W, Htot), "#15132E")
    y = 0
    for s in secs:
        sheet.paste(s, (0, y))
        y += s.height
    sheet.save(os.path.join(DOCS, "art_sheet.png"), optimize=True)

    # grayscale check
    tiles = [Image.open(os.path.join(OUT, f"pieces/{c}.png")).convert("RGBA") for c in pieces.ORDER]
    g = Image.new("RGB", (6 * 180, 2 * 180 + 30), "#1B1F3B")
    dr = ImageDraw.Draw(g)
    dr.text((10, 4), "top: colour, bottom: grayscale (luma) - silhouettes and brightness must differ",
            font=_font(16), fill="#FFFFFF")
    for i, im in enumerate(tiles):
        g.paste(im, (i * 180 + 10, 30), im)
        lum = im.convert("LA").convert("RGBA")
        g.paste(lum, (i * 180 + 10, 210), lum)
    g.save(os.path.join(DOCS, "pieces_grayscale.png"), optimize=True)

    # scenes
    with open(os.path.join(CONTENT, "district_layouts.json"), encoding="utf-8") as f:
        lays = json.load(f)
    for d in districts:
        did = d["id"]
        bg = Image.open(os.path.join(OUT, "districts", did, "bg.png")).convert("RGBA")
        scene = bg.resize((SCENE_W, SCENE_H), Image.BILINEAR)
        for tid, it in lays[did]["items"].items():
            im = Image.open(os.path.join(ROOT, it["image"])).convert("RGBA")
            s = it["scale"]
            im = im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS)
            scene.alpha_composite(im, (round(it["x"] - im.width / 2), round(it["y"] - im.height / 2)))
        scene.convert("RGB").save(os.path.join(DOCS, f"district_{did}.png"), optimize=True)


MANIFEST = {}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", default="", help="comma list of groups: pieces,specials,blockers,board,fx,ui,"
                                                 "icons,bit,logo,districts")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 2)
    args = ap.parse_args()
    groups = set(g for g in args.only.split(",") if g)
    jobs = [j for j in build_jobs() if not groups or j[0] in groups]
    # heaviest first for better packing
    heavy = ("districts", "bit", "blockers", "logo")
    jobs.sort(key=lambda j: (j[0] not in heavy, j[1]))
    t0 = time.time()
    results = []
    if args.jobs > 1:
        with Pool(args.jobs) as pool:
            for r in pool.imap_unordered(run_job, jobs):
                results.append(r)
    else:
        results = [run_job(j) for j in jobs]
    districts = load_districts()
    problems = write_layouts(districts) if (not groups or "districts" in groups) else []
    MANIFEST.update(write_manifest())
    if not groups:
        contact_sheets(districts)

    # summary
    results.sort()
    by_group = {}
    for rel, w, h, size, dt in results:
        g = rel.split("/")[0]
        by_group.setdefault(g, [0, 0])
        by_group[g][0] += 1
        by_group[g][1] += size
    print(f"{'file':52s} {'size':>9s} {'bytes':>8s}")
    for rel, w, h, size, dt in results:
        print(f"{rel:52s} {w:4d}x{h:<4d} {size:8d}")
    total = sum(os.path.getsize(os.path.join(OUT, r)) for r in MANIFEST)
    print("-" * 72)
    for g, (n, size) in sorted(by_group.items()):
        print(f"{g:14s} {n:4d} files {size / 1024:9.1f} KB")
    print(f"all assets/images PNGs: {len(MANIFEST)} files, {total / 1024 / 1024:.2f} MB "
          f"(budget 8 MB) - rendered in {time.time() - t0:.1f}s")
    if total > 8 * 1024 * 1024:
        problems.append(f"total PNG size {total / 1024 / 1024:.2f} MB exceeds 8 MB")
    if problems:
        print("LAYOUT/SIZE PROBLEMS:")
        for p in problems:
            print("  -", p)
        sys.exit(1)


if __name__ == "__main__":
    main()
