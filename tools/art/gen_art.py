#!/usr/bin/env python3
"""Generate every image GLOW needs (deterministic, re-runnable from the repo root).

    python3 tools/art/gen_art.py              # everything (stale files in assets/images are removed after)
    python3 tools/art/gen_art.py --only pieces,icons --jobs 4
    python3 tools/art/gen_art.py --only districts --match bg     # just the district backgrounds
    python3 tools/art/gen_art.py --layout-only                   # re-check layouts + district docs, no render

Style: bright sunny cartoon festival, glossy candy pieces (docs/design/art-direction.md).
Everything is drawn with signed distance fields at 4x supersampling and downscaled with LANCZOS.

Outputs
  assets/images/**.png               game art (see manifest.json)
  assets/images/manifest.json        every file with its pixel size (+ nine-slice borders, notes)
  content/district_layouts.json      scene composition for the meta screen
  docs/media/art_sheet.png           contact sheet of everything except scenes
  docs/media/pieces_grayscale.png    grayscale check of the 6 pieces
  docs/media/district_<id>.png       each scene at 720x1280 with items in place (town UI areas outlined)
  docs/media/level_preview.png       720x1280 mock-up of a level screen built from the assets

Checks (the run exits with status 1 if any fails)
  * no sprite ends in a hard edge: alpha on the outer 1 px ring stays <= 30 (art meant to run off the
    edge or tile is exempt, see EDGE_EXEMPT)
  * every district item stays inside SAFE and its shape never touches a town-screen UI area (UI_ZONES)
  * no two items of a district overlap (shape masks, not boxes)
  * all PNGs together stay under BUDGET_MB

Drawing code lives next to this file: artkit (SDF painter + candy shading), palette, pieces,
blockers, ui (board/fx/ui/icons), bit (mascot), logo, items + districts (level bg and scenes).
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
FONT_HEAD = os.path.join(ROOT, "assets", "fonts", "Rubik-Black.ttf")

import numpy as np  # noqa: E402
from PIL import Image, ImageDraw, ImageFont  # noqa: E402

TRIM_PAD = 4          # district items are trimmed to their visible pixels + this padding
SCENE_W, SCENE_H = 720, 1280
SAFE = (40, 236, 680, 786)    # items must stay inside x0, y0, x1, y1 (scene px, y down)
# Town-screen UI over the scene (screens/town/town.gui_script, converted to 720x1280 y-down scene px).
# Item shapes (alpha > ZONE_ALPHA) must not touch these.
UI_ZONES = {
    "top_bar": (20, 20, 600, 120), "settings": (612, 22, 708, 118),
    "district_ribbon": (125, 136, 595, 224), "concert_toggle": (580, 148, 700, 212),
    "task_card": (60, 798, 660, 922), "streak_notes": (269, 908, 451, 962),
    "level_button": (125, 967, 595, 1103), "hard_tag": (445, 944, 615, 994),
    "bottom_nav": (0, 1147, 720, 1280),
}
ZONE_ALPHA = 16       # alpha (0..255) above which an item pixel counts as "touching"
OVERLAP_ALPHA = 64    # two items overlap if both are above this alpha at the same scene pixel
EDGE_ALPHA = 30       # no sprite may have alpha above this on its outer 1 px ring ...
EDGE_EXEMPT = ("board/cell_", "board/edge_", "blockers/wires_", "ui/bunting", "/garlands", "/strings", "/lamps", "/sign",
               "/garage_door")   # ... except art meant to tile or to run off the edge
GHOST_ALPHA = 0.75
BG_DITHER = 0.5       # ordered dither on the opaque backgrounds (breaks gradient banding)
BUDGET_MB = 9.0
GROUPS = ["pieces", "specials", "blockers", "board", "fx", "ui", "icons", "bit", "logo", "backgrounds", "districts"]


# ==========================================================================
# job list
# ==========================================================================
def load_districts():
    with open(os.path.join(CONTENT, "districts.json"), encoding="utf-8") as f:
        return json.load(f)["districts"]


def build_jobs():
    """Each job: (group, relpath, module, attr, key_or_args, opts)."""
    import palette
    import ui
    import bit
    import items

    J = []
    for c in palette.ORDER:
        J.append(("pieces", f"pieces/{c}.png", "pieces", "PIECE_FUNCS", c, {}))
    for s in ("riff", "sub", "bird", "disco"):
        J.append(("specials", f"specials/{s}.png", "pieces", "SPECIAL_FUNCS", s, {}))
    for hp in (3, 2, 1):
        J.append(("blockers", f"blockers/record_box_{hp}.png", "blockers", "draw_record_box", (hp,), {}))
    for hp in (2, 1):
        J.append(("blockers", f"blockers/concrete_{hp}.png", "blockers", "draw_concrete", (hp,), {}))
    J.append(("blockers", "blockers/noise.png", "blockers", "draw_noise", (), {}))
    for c in palette.ORDER:
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
    J.append(("board", "board/cell_a.png", "ui", "draw_cell", (palette.CELL_A,), {}))
    J.append(("board", "board/cell_b.png", "ui", "draw_cell", (palette.CELL_B,), {}))
    J.append(("board", "board/board_frame.png", "ui", "draw_board_frame", (), {}))
    for k in ui.FX_FUNCS:
        J.append(("fx", f"fx/{k}.png", "ui", "FX_FUNCS", k, {}))
    for k in ui.EDGE_KINDS:
        J.append(("board", f"board/edge_{k}.png", "ui", "draw_board_edge", (k,), {}))
    for k in palette.BUTTONS:
        J.append(("ui", f"ui/button_{k}.png", "ui", "draw_button", (k,), {}))
        J.append(("ui", f"ui/button_small_{k}.png", "ui", "draw_button_small", (k,), {}))
    J.append(("ui", "ui/badge_count.png", "ui", "draw_badge_count", (), {}))
    J.append(("ui", "ui/panel.png", "ui", "draw_panel", (), {}))
    J.append(("ui", "ui/panel_tint.png", "ui", "draw_panel_tint", (), {}))
    J.append(("ui", "ui/ribbon.png", "ui", "draw_ribbon", (), {}))
    J.append(("ui", "ui/moves_badge.png", "ui", "draw_moves_badge", (), {}))
    J.append(("ui", "ui/bunting.png", "ui", "draw_bunting", (), {}))
    for k in ui.ICON_FUNCS:
        J.append(("icons", f"ui/icons/{k}.png", "ui", "ICON_FUNCS", k, {}))
    for p in bit.POSE_ORDER:
        J.append(("bit", f"bit/{p}.png", "bit", "draw_bit", (p,), {}))
    J.append(("logo", "logo/logo.png", "logo", "draw_logo", (), {}))
    bg = {"opaque": True, "dither": BG_DITHER}
    J.append(("backgrounds", "backgrounds/level_bg.png", "districts", "bg_level", (), bg))
    for d in load_districts():
        did = d["id"]
        J.append(("districts", f"districts/{did}/bg.png", "districts", "BG_FUNCS", (did,), bg))
        J.append(("districts", f"districts/{did}/bg_concert.png", "districts", "concert", (did,), bg))
        for t in d["tasks"]:
            if t["id"] not in items.ITEM_FUNCS:
                raise SystemExit(f"no item drawing for task {did}/{t['id']}")
            J.append(("districts", f"districts/{did}/{t['id']}.png", "items", "ITEM_FUNCS", t["id"],
                      {"trim": t["id"] not in items.NO_TRIM, "ghost": True}))
    return J


def ghost_image(img):
    """How the town shows a not-yet-restored item: desaturated, luma pulled toward white (light grey, never
    dark) and semi-transparent (alpha x GHOST_ALPHA baked in). Exported as <task>_ghost.png."""
    arr = np.asarray(img.convert("RGBA")).astype(np.float32) / 255.0
    lum = arr[..., :3] @ np.array([0.299, 0.587, 0.114], np.float32)
    g = 0.6 + 0.38 * lum
    a = arr[..., 3] * GHOST_ALPHA
    g8 = np.clip(g * 255 + 0.5, 0, 255)
    out = np.dstack([g8, g8, g8, np.clip(a * 255 + 0.5, 0, 255)]).astype(np.uint8)
    out[out[..., 3] == 0] = 0
    return Image.fromarray(out, "RGBA")    # plain RGBA like every other sprite (safest for the atlas pipeline)


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
    img = cv.image(opaque=opts.get("opaque", False), dither=opts.get("dither", 0.0))
    if opts.get("trim"):
        a = np.asarray(img)[..., 3]
        ys, xs = np.nonzero(a > 2)
        x0, y0 = max(xs.min() - TRIM_PAD, 0), max(ys.min() - TRIM_PAD, 0)
        x1, y1 = min(xs.max() + 1 + TRIM_PAD, img.width), min(ys.max() + 1 + TRIM_PAD, img.height)
        img = img.crop((x0, y0, x1, y1))
    path = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, optimize=True)
    size = os.path.getsize(path)
    if opts.get("ghost"):
        gpath = path[:-4] + "_ghost.png"
        ghost_image(img).save(gpath, optimize=True)
        size += os.path.getsize(gpath)
    return rel, img.width, img.height, size, time.time() - t0


# ==========================================================================
# layouts
# ==========================================================================
def visible_bbox(img):
    a = np.asarray(img.convert("RGBA"))[..., 3]
    ys, xs = np.nonzero(a > 8)
    return xs.min(), ys.min(), xs.max() + 1, ys.max() + 1


def placed(img, x, y, s):
    """The item's alpha resampled into scene space: (alpha uint8 array, left, top)."""
    w, h = max(round(img.width * s), 1), max(round(img.height * s), 1)
    a = img.convert("RGBA").split()[3].resize((w, h), Image.BILINEAR)
    return np.asarray(a), round(x - w / 2), round(y - h / 2)


def _scene_mask(a, left, top, thresh):
    m = np.zeros((SCENE_H, SCENE_W), bool)
    h, w = a.shape
    x0, y0 = max(left, 0), max(top, 0)
    x1, y1 = min(left + w, SCENE_W), min(top + h, SCENE_H)
    if x1 > x0 and y1 > y0:
        m[y0:y1, x0:x1] = a[y0 - top:y1 - top, x0 - left:x1 - left] > thresh
    return m


def write_layouts(districts):
    import districts as D
    out = {}
    problems = []
    for d in districts:
        did = d["id"]
        lay = D.LAYOUT[did]
        entry = {"bg": f"assets/images/districts/{did}/bg.png",
                 "bg_concert": f"assets/images/districts/{did}/bg_concert.png",
                 "bg_scale": 1.0, "items": {}}
        masks = {}
        for t in d["tasks"]:
            tid = t["id"]
            if tid not in lay:
                problems.append(f"{did}/{tid}: missing layout")
                continue
            x, y, s = lay[tid]
            img = Image.open(os.path.join(OUT, "districts", did, f"{tid}.png"))
            a, left, top = placed(img, x, y, s)
            shape = _scene_mask(a, left, top, ZONE_ALPHA)
            ys, xs = np.nonzero(a > ZONE_ALPHA)
            box = (left + xs.min(), top + ys.min(), left + xs.max() + 1, top + ys.max() + 1)
            if box[0] < SAFE[0] or box[1] < SAFE[1] or box[2] > SAFE[2] or box[3] > SAFE[3]:
                problems.append(f"{did}/{tid}: shape {box} leaves the safe area {SAFE}")
            for zname, (zx0, zy0, zx1, zy1) in UI_ZONES.items():
                n = int(shape[zy0:zy1, zx0:zx1].sum())
                if n:
                    problems.append(f"{did}/{tid}: {n} px under the town UI '{zname}'")
            masks[tid] = _scene_mask(a, left, top, OVERLAP_ALPHA)
            entry["items"][tid] = {"image": f"assets/images/districts/{did}/{tid}.png",
                                   "ghost": f"assets/images/districts/{did}/{tid}_ghost.png",
                                   "x": x, "y": y, "scale": s, "w": img.width, "h": img.height}
        ids = list(masks)
        for i in range(len(ids)):
            for j in range(i + 1, len(ids)):
                n = int((masks[ids[i]] & masks[ids[j]]).sum())
                if n:
                    problems.append(f"{did}: {ids[i]} overlaps {ids[j]} ({n} px)")
        out[did] = entry
    with open(os.path.join(CONTENT, "district_layouts.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
        f.write("\n")
    return problems


def check_edges(files):
    """Sprites must not be cut by their canvas: alpha on the outer 1 px ring stays <= EDGE_ALPHA."""
    problems = []
    for rel in files:
        if any(e in rel for e in EDGE_EXEMPT):
            continue
        with Image.open(os.path.join(OUT, rel)) as im:
            if im.mode != "RGBA":
                continue
            a = np.asarray(im)[..., 3]
        sides = {"top": a[0], "bottom": a[-1], "left": a[:, 0], "right": a[:, -1]}
        cut = {k: int((v > EDGE_ALPHA).sum()) for k, v in sides.items() if (v > EDGE_ALPHA).any()}
        if cut:
            problems.append(f"{rel}: art cut at the canvas edge {cut}")
    return problems


# ==========================================================================
# manifest + contact sheets
# ==========================================================================
BTN_SLICE = [30, 30, 30, 40]            # left, top, right, bottom
BTN_SMALL_SLICE = [16, 16, 16, 22]
NINE_SLICE = {
    "ui/panel.png": [40, 40, 40, 40], "ui/panel_tint.png": [40, 40, 40, 40],
    "ui/moves_badge.png": [64, 64, 64, 64], "ui/ribbon.png": [112, 0, 112, 0],
    "board/board_frame.png": [44, 44, 44, 44],
}
for _k in ("green", "blue", "gold", "pink", "purple"):
    NINE_SLICE[f"ui/button_{_k}.png"] = BTN_SLICE
    NINE_SLICE[f"ui/button_small_{_k}.png"] = BTN_SMALL_SLICE
NOTES = {
    "pieces/*.png": "160x160, the piece fills ~84% of the canvas (sparse shapes a little more); draw at cell size "
                    "(e.g. 0.5x for 80px cells)",
    "specials/*.png": "192x192 incl. glow, drawn at the same scale as pieces (overhangs the cell)",
    "specials/riff.png": "horizontal; rotate 90 degrees for the vertical riff",
    "board/board_frame.png": "nine-slice 44px on a 128px texture: soft blue shadow + lavender ring (6..10px), 4px "
                             "white frame (10..14px, corner radius 30), white 60% backing inside (from 14px). "
                             "Size = cell grid + 20px per side (14px frame + 6px backing padding)",
    "board/edge_*.png": "boards with gaps: one cell-sized tile per grid vertex (the corner shared by 4 cells), centred "
                        "on the vertex, drawn under the cells. Pick by which of the 4 cells around the vertex exist: "
                        "1 cell = outer (base: bottom-right cell), 2 side by side = side (base: the 2 lower cells), "
                        "2 diagonal = diag (base: top-left + bottom-right), 3 = inner (base: all but top-left), "
                        "4 = full, 0 = nothing. Rotate the base in 90 degree steps to match; tiles join seamlessly",
    "board/cell_*.png": "96x96 flat tiles (white / #EFE8FF, 95% alpha), scale to the cell size",
    "blockers/mic_stand.png": "exit marker drawn under the bottom cell of an exit column",
    "blockers/column_*.png": "2x2 cells",
    "blockers/wires_*.png": "overlay drawn above the piece; the centre stays transparent",
    "blockers/floor_*.png": "opaque dance-floor tiles drawn instead of the cell tile (lit tiles are gold edge to "
                            "edge so neighbours join)",
    "ui/button_*.png": "nine-slice [left, top, right, bottom]; the bottom border holds the darker shelf",
    "ui/button_small_*.png": "64px nine-slice [16, 16, 16, 22] for small buttons (smallest size 32x38), e.g. the "
                             "46px '+' button",
    "ui/badge_count.png": "booster count badge; print the number in white Rubik Black on top",
    "ui/moves_badge.png": "pink gradient badge; print the move count in white Rubik Black on top",
    "ui/bunting.png": "720px festive garland for the top edge of the level screen",
    "fx/*.png": "white / near-white, tint in the engine",
    "ui/icons/*.png": "96x96 glossy icons with a white sticker edge, all inside the central 88px",
    "ui/icons/goal_floor.png": "goal icon for 'light the dance floor'",
    "ui/icons/streak.png": "hit streak (Seriya hitov)",
    "backgrounds/level_bg.png": "720x1280, draw 1:1 behind the board",
    "districts/*/bg*.png": "720x1280, draw 1:1 under the items; bg_concert is the final-concert re-light "
                           "(neon on #3B2A8F -> #6B4CE0) of the same scene",
    "districts/*/<task>.png": "task item in full colour = restored (positions in content/district_layouts.json)",
    "districts/*/<task>_ghost.png": "the same item not yet restored: light grey, 75% alpha baked in - draw it with "
                                    "a plain white colour instead of tinting the full-colour image",
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
                e = {"w": im.width, "h": im.height, "alpha": im.mode == "RGBA", "bytes": os.path.getsize(p)}
            if rel in NINE_SLICE:
                e["nine_slice"] = NINE_SLICE[rel]
            files[rel] = e
    files = dict(sorted(files.items()))
    man = {"version": 2, "generator": "tools/art/gen_art.py", "style": "docs/design/art-direction.md (v2, bright)",
           "notes": NOTES, "files": files}
    with open(os.path.join(OUT, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(man, f, indent=2)
        f.write("\n")
    return files


def _font(size, head=False):
    return ImageFont.truetype(FONT_HEAD if head else FONT_UI, size)


def _checker(w, h, a="#FFFFFF", b="#EFE8FF", cell=12):
    im = Image.new("RGB", (w, h), a)
    dr = ImageDraw.Draw(im)
    for yy in range(0, h, cell):
        for xx in range(0, w, cell):
            if (xx // cell + yy // cell) % 2:
                dr.rectangle([xx, yy, xx + cell - 1, yy + cell - 1], fill=b)
    return im


def _ghost_of(rel):
    """The exported ghost (not yet restored) image of a district item - the docs show exactly what the game gets."""
    return Image.open(os.path.join(OUT, rel[:-4] + "_ghost.png")).convert("RGBA")


def _section(title, rels, cell, cols, bg=None, label=True, W=1600, cell_h=None, ghost=False):
    n = len(rels)
    rows = -(-n // cols)
    lab = 20 if label else 0
    head = 44 if title else 6
    ch = cell_h or cell
    Hh = head + rows * (ch + lab) + 8
    sec = Image.new("RGB", (W, Hh), "#F6F1FF")
    dr = ImageDraw.Draw(sec)
    if title:
        dr.text((14, 8), title, font=_font(24, head=True), fill="#2B2345")
    x_off = (W - cols * cell) // 2
    for i, rel in enumerate(rels):
        r, c = divmod(i, cols)
        x0, y0 = x_off + c * cell, head + r * (ch + lab)
        tw, th = cell - 8, ch - 8
        tile = _checker(tw, th) if bg is None else Image.new("RGB", (tw, th), bg)
        m = Image.new("L", tile.size, 0)
        ImageDraw.Draw(m).rounded_rectangle([0, 0, tile.width - 1, tile.height - 1], 14, fill=255)
        im = Image.open(os.path.join(OUT, rel)).convert("RGBA")
        slots = [im, _ghost_of(rel)] if ghost else [im]
        sh = (th - 8) / len(slots)
        for j, s_im in enumerate(slots):
            k = min((tw - 8) / s_im.width, (sh - 8) / s_im.height, 1.0)
            if k < 1:
                s_im = s_im.resize((max(int(s_im.width * k), 1), max(int(s_im.height * k), 1)), Image.LANCZOS)
            tile.paste(s_im, ((tw - s_im.width) // 2, int(4 + j * sh + (sh - s_im.height) / 2)), s_im)
        sec.paste(tile, (x0 + 4, y0 + 4), m)
        if label:
            name = os.path.splitext(os.path.basename(rel))[0]
            dr.text((x0 + cell / 2, y0 + ch - 2), name, font=_font(13), fill="#5B4B7A", anchor="mt")
    return sec


def _zones_overlay(scene):
    """Faint outlines of the town-screen UI (UI_ZONES) and the item safe band on a 720x1280 scene."""
    ov = Image.new("RGBA", scene.size, (0, 0, 0, 0))
    dr = ImageDraw.Draw(ov)
    for name, (x0, y0, x1, y1) in UI_ZONES.items():
        dr.rounded_rectangle([x0, y0, x1 - 1, y1 - 1], 14, fill=(255, 255, 255, 46), outline=(91, 23, 201, 150),
                             width=2)
        dr.text((x0 + 10, y0 + 6), name.replace("_", " "), font=_font(15), fill=(91, 23, 201, 190))
    x0, y0, x1, y1 = SAFE
    for yy in (y0, y1):
        for xx in range(x0, x1, 18):
            dr.line([(xx, yy), (min(xx + 9, x1), yy)], fill=(255, 77, 141, 170), width=2)
    for xx in (x0, x1):
        for yy in range(y0, y1, 18):
            dr.line([(xx, yy), (xx, min(yy + 9, y1))], fill=(255, 77, 141, 170), width=2)
    dr.text((x0 + 6, y0 + 4), "item safe area", font=_font(14), fill=(255, 77, 141, 200))
    scene.alpha_composite(ov)
    return scene


def compose_district(did, lays, ghosts=()):
    bg = Image.open(os.path.join(OUT, "districts", did, "bg.png")).convert("RGBA")
    scene = bg.resize((SCENE_W, SCENE_H), Image.BICUBIC) if bg.size != (SCENE_W, SCENE_H) else bg
    for tid, it in lays[did]["items"].items():
        im = Image.open(os.path.join(ROOT, it["ghost"] if tid in ghosts else it["image"])).convert("RGBA")
        s = it["scale"]
        im = im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS)
        scene.alpha_composite(im, (round(it["x"] - im.width / 2), round(it["y"] - im.height / 2)))
    return scene


def district_docs(districts):
    os.makedirs(DOCS, exist_ok=True)
    with open(os.path.join(CONTENT, "district_layouts.json"), encoding="utf-8") as f:
        lays = json.load(f)
    for d in districts:
        did = d["id"]
        scene = _zones_overlay(compose_district(did, lays))
        scene.convert("RGB").save(os.path.join(DOCS, f"district_{did}.png"), optimize=True)


def contact_sheets(districts):
    import palette
    import bit
    import ui
    os.makedirs(DOCS, exist_ok=True)

    def rels(prefix):
        return sorted(r for r in MANIFEST if r.startswith(prefix) and "/" not in r[len(prefix):])

    secs = [
        _section("GLOW art v2 - pieces 160", [f"pieces/{c}.png" for c in palette.ORDER], 210, 7),
        _section("specials 192", [f"specials/{s}.png" for s in ("riff", "sub", "bird", "disco")], 230, 6),
        _section("blockers 160 / column 320", rels("blockers/"), 200, 8),
        _section("board (frame 128 nine-slice, edge tiles for boards with gaps)", rels("board/"), 150, 10,
                 bg="#86DDFF"),
        _section("fx (white, tinted in the engine)", rels("fx/"), 150, 10, bg="#6B4CE0"),
        _section("ui", [r for r in rels("ui/") if r != "ui/bunting.png"], 150, 10, bg="#C9F2FF"),
        _section("bunting 720x64", ["ui/bunting.png"], 780, 2, bg="#86DDFF", label=False, cell_h=100),
        _section("icons 96", rels("ui/icons/"), 112, 14),
        _section("Bit 256", [f"bit/{p}.png" for p in bit.POSE_ORDER], 226, 7, bg="#C9F2FF"),
        _section("logo 640x320", ["logo/logo.png"], 700, 2, bg="#86DDFF", cell_h=380),
    ]
    for d in districts:
        secs.append(_section(f"{d['name']['en']} items (restored / not yet restored = *_ghost.png)",
                             [f"districts/{d['id']}/{t['id']}.png" for t in d["tasks"]], 170, 9, bg="#FFE9D6",
                             cell_h=300, ghost=True))
    W = 1600
    Htot = sum(s.height for s in secs)
    sheet = Image.new("RGB", (W, Htot), "#F6F1FF")
    y = 0
    for s in secs:
        sheet.paste(s, (0, y))
        y += s.height
    # 256-colour palette keeps the sheet small (it is a review aid, not game art)
    sheet = sheet.quantize(256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    sheet.save(os.path.join(DOCS, "art_sheet.png"), optimize=True)
    _ = ui

    # grayscale check
    tiles = [Image.open(os.path.join(OUT, f"pieces/{c}.png")).convert("RGBA") for c in palette.ORDER]
    g = Image.new("RGB", (6 * 180 + 20, 2 * 180 + 50), "#FFFFFF")
    dr = ImageDraw.Draw(g)
    dr.text((12, 10), "top: colour; bottom: grayscale (luma) - silhouettes and brightness must differ",
            font=_font(17), fill="#2B2345")
    for i, im in enumerate(tiles):
        g.paste(im, (i * 180 + 20, 44), im)
        lum = im.convert("LA").convert("RGBA")
        g.paste(lum, (i * 180 + 20, 224), lum)
    g.save(os.path.join(DOCS, "pieces_grayscale.png"), optimize=True)
    district_docs(districts)
    level_preview()


# ==========================================================================
# level preview: the in-game look assembled from the generated assets
# ==========================================================================
def _img(rel):
    return Image.open(os.path.join(OUT, rel)).convert("RGBA")


def _fit(im, w, h=None):
    h = h if h is not None else round(im.height * w / im.width)
    return im.resize((max(round(w), 1), max(round(h), 1)), Image.LANCZOS)


def nine_slice(im, w, h, b):
    l, t, r, bo = b if isinstance(b, (list, tuple)) else (b, b, b, b)
    W, H = im.size
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    xs = [(0, l, 0, l), (l, W - r, l, w - r), (W - r, W, w - r, w)]
    ys = [(0, t, 0, t), (t, H - bo, t, h - bo), (H - bo, H, h - bo, h)]
    for (sx0, sx1, dx0, dx1) in xs:
        for (sy0, sy1, dy0, dy1) in ys:
            if sx1 <= sx0 or sy1 <= sy0 or dx1 <= dx0 or dy1 <= dy0:
                continue
            part = im.crop((sx0, sy0, sx1, sy1)).resize((dx1 - dx0, dy1 - dy0), Image.LANCZOS)
            out.alpha_composite(part, (dx0, dy0))
    return out


def _paste_c(dst, im, cx, cy):
    dst.alpha_composite(im, (round(cx - im.width / 2), round(cy - im.height / 2)))


def _text(dst, xy, s, size, fill="#FFFFFF", stroke=None, head=True, anchor="mm", sw=0):
    dr = ImageDraw.Draw(dst)
    dr.text(xy, s, font=_font(size, head), fill=fill, anchor=anchor, stroke_width=sw, stroke_fill=stroke)


# vertex tile for the 4 cells around a grid vertex, as (TL, TR, BL, BR) -> (tile, clockwise quarter turns)
EDGE_TILES = {
    (0, 0, 0, 1): ("outer", 0), (0, 0, 1, 0): ("outer", 1), (1, 0, 0, 0): ("outer", 2), (0, 1, 0, 0): ("outer", 3),
    (0, 0, 1, 1): ("side", 0), (1, 0, 1, 0): ("side", 1), (1, 1, 0, 0): ("side", 2), (0, 1, 0, 1): ("side", 3),
    (1, 0, 0, 1): ("diag", 0), (0, 1, 1, 0): ("diag", 1),
    (0, 1, 1, 1): ("inner", 0), (1, 0, 1, 1): ("inner", 1), (1, 1, 1, 0): ("inner", 2), (1, 1, 0, 1): ("inner", 3),
    (1, 1, 1, 1): ("full", 0),
}


def board_backing(scr, present, bx, by, cell):
    """Reference use of board/edge_*.png: one tile per grid vertex, picked and rotated from the 4 cells
    around it (see the manifest note)."""
    rows, cols = len(present), len(present[0])

    def has(x, y):
        return 0 <= y < rows and 0 <= x < cols and present[y][x]
    cache = {}
    for j in range(rows + 1):
        for i in range(cols + 1):
            key = (int(has(i - 1, j - 1)), int(has(i, j - 1)), int(has(i - 1, j)), int(has(i, j)))
            if key not in EDGE_TILES:
                continue
            kind, turns = EDGE_TILES[key]
            if (kind, turns) not in cache:
                t = _fit(_img(f"board/edge_{kind}.png"), cell, cell)
                cache[(kind, turns)] = t.rotate(-90 * turns) if turns else t
            scr.alpha_composite(cache[(kind, turns)], (round(bx + i * cell - cell / 2), round(by + j * cell - cell / 2)))


def level_preview():
    scr = _img("backgrounds/level_bg.png")
    if scr.size != (SCENE_W, SCENE_H):
        scr = scr.resize((SCENE_W, SCENE_H), Image.BICUBIC)
    scr.alpha_composite(_img("ui/bunting.png"), (0, 0))
    # HUD: goals panel + moves badge
    panel = nine_slice(_img("ui/panel.png"), 540, 196, 40)
    scr.alpha_composite(panel, (8, 44))
    goals = [("pieces/red.png", "12"), ("blockers/record_box_3.png", "4"), ("ui/icons/goal_floor.png", "9"),
             ("blockers/mic.png", "2")]
    for i, (rel, n) in enumerate(goals):
        cx = 8 + 88 + i * 118
        _paste_c(scr, _fit(_img(rel), 80), cx, 110)
        _text(scr, (cx, 186), n, 36, fill="#2B2345")
    badge = _fit(_img("ui/moves_badge.png"), 170)
    _paste_c(scr, badge, 632, 142)
    _text(scr, (632, 128), "18", 72, fill="#FFFFFF", stroke="#D21E5E", sw=0)
    _text(scr, (632, 184), "ходов", 25, fill="#FFFFFF", head=False)
    # Bit + speech bubble + pause
    _paste_c(scr, _fit(_img("bit/dance_a.png"), 200), 110, 318)
    bub = nine_slice(_img("ui/panel.png"), 330, 104, 40)
    scr.alpha_composite(bub, (214, 262))
    _text(scr, (379, 311), "Бит танцует в такт", 26, fill="#7B4FFF", head=False)
    pbtn = nine_slice(_img("ui/button_purple.png"), 88, 88, BTN_SLICE)
    scr.alpha_composite(pbtn, (606, 266))
    _paste_c(scr, _fit(_img("ui/icons/pause.png"), 58), 650, 306)
    # board 8x8 with gaps ('.'), every board element present
    cell = 80
    bx, by = 40, 420
    grid = [
        ".YBRGPY.",
        "OXXGRCcB",
        "RXXPOccY",
        "GPrYBmRP",
        "YBnRPGsO",
        "PRGbYRkG",
        "OYPGRdKR",
        ".oRYOPYB",
    ]
    present = [[ch != "." for ch in row] for row in grid]
    board_backing(scr, present, bx, by, cell)
    code = {"R": "pieces/red.png", "O": "pieces/orange.png", "Y": "pieces/yellow.png", "G": "pieces/green.png",
            "B": "pieces/blue.png", "P": "pieces/purple.png", "r": "specials/riff.png", "s": "specials/sub.png",
            "b": "specials/bird.png", "d": "specials/disco.png", "n": "blockers/noise.png",
            "o": "blockers/balloon_blue.png", "m": "blockers/mic.png", "k": "blockers/concrete_2.png",
            "K": "blockers/concrete_1.png"}
    lit = {(2, 7), (3, 7), (4, 7), (3, 6), (2, 6)}
    floor = {(x, y) for y in range(5, 8) for x in range(1, 7)}
    wires = {(0, 4), (7, 5)}
    exits = {5}                 # the mic leaves the board at the bottom of column 5
    tile_cache = {}

    def T(rel, size):
        key = (rel, size)
        if key not in tile_cache:
            tile_cache[key] = _fit(_img(rel), size, size)
        return tile_cache[key]
    ca = _fit(_img("board/cell_a.png"), cell, cell)
    cb = _fit(_img("board/cell_b.png"), cell, cell)
    for y in range(8):
        for x in range(8):
            if not present[y][x]:
                continue
            px, py = bx + x * cell, by + y * cell
            if (x, y) in lit:
                t = T("blockers/floor_lit.png", cell)
            elif (x, y) in floor:
                t = T("blockers/floor_2.png" if (x + y) % 3 else "blockers/floor_1.png", cell)
            else:
                t = ca if (x + y) % 2 == 0 else cb
            scr.alpha_composite(t, (px, py))
    exit_markers = []
    for x in exits:
        st = _fit(_img("blockers/mic_stand.png"), cell)
        exit_markers.append((st, (bx + x * cell, by + 8 * cell - 12)))
    for y in range(8):
        for x in range(8):
            k = grid[y][x]
            cx, cy = bx + x * cell + cell / 2, by + y * cell + cell / 2
            if k in ".c":
                continue
            if k == "X":
                hp = 3 if (x + y) % 2 else 2
                _paste_c(scr, T(f"blockers/record_box_{hp}.png", cell), cx, cy)
                continue
            if k == "C":
                _paste_c(scr, T("blockers/column_2.png", 2 * cell), cx + cell / 2, cy + cell / 2)
                continue
            rel = code[k]
            size = cell if rel.startswith(("pieces", "blockers")) else round(cell * 1.2)
            _paste_c(scr, T(rel, size), cx, cy)
            if (x, y) in wires:
                _paste_c(scr, T("blockers/wires_2.png", cell), cx, cy)
    for st, pos in exit_markers:            # the exit marker sits under the bottom cell, on the frame
        scr.alpha_composite(st, pos)
    # hint glow on two cells
    hint = Image.new("RGBA", scr.size, (0, 0, 0, 0))
    hd = ImageDraw.Draw(hint)
    for (x, y) in ((4, 2), (4, 3)):
        px, py = bx + x * cell, by + y * cell
        hd.rounded_rectangle([px + 3, py + 3, px + cell - 4, py + cell - 4], 20, outline=(255, 255, 255, 255), width=5)
    scr.alpha_composite(hint)
    # praise word
    praise = Image.new("RGBA", (420, 140), (0, 0, 0, 0))
    dr = ImageDraw.Draw(praise)
    dr.text((210, 70), "Сочно!", font=_font(76, True), fill="#FF4D8D", anchor="mm", stroke_width=9,
            stroke_fill="#FFFFFF")
    praise = praise.rotate(4, resample=Image.BICUBIC)
    _paste_c(scr, praise, 360, 404)
    # level chips
    for (x0, w, txt, col) in ((28, 360, "Lo-fi-кафе · уровень 7", "#2F80ED"), (424, 268, "Серия хитов: 2", "#FF4D8D")):
        chip = nine_slice(_img("ui/panel.png"), w, 88, 40)
        scr.alpha_composite(chip, (x0, 1090))
        _text(scr, (x0 + w / 2 + (18 if x0 > 400 else 0), 1132), txt, 25, fill=col, head=False)
    _paste_c(scr, _fit(_img("ui/icons/streak.png"), 52), 454, 1133)
    # booster bar
    bar_y = 1160
    scr.alpha_composite(nine_slice(_img("ui/panel.png"), 704, 132, 40), (8, bar_y))
    boosters = [("stick", "pink", "3"), ("row_light", "gold", "2"), ("col_light", "blue", "+"), ("remix", "purple", "1")]
    for i, (ic, col, n) in enumerate(boosters):
        cx = 110 + i * 166
        btn = nine_slice(_img(f"ui/button_{col}.png"), 104, 96, BTN_SLICE)
        scr.alpha_composite(btn, (round(cx - 52), bar_y + 18))
        _paste_c(scr, _fit(_img(f"ui/icons/{ic}.png"), 72), cx, bar_y + 62)
        if n == "+":
            small = nine_slice(_img("ui/button_small_green.png"), 46, 46, BTN_SMALL_SLICE)
            _paste_c(scr, small, cx + 48, bar_y + 22)
            _paste_c(scr, _fit(_img("ui/icons/plus.png"), 34), cx + 48, bar_y + 20)
        else:
            _paste_c(scr, _fit(_img("ui/badge_count.png"), 46), cx + 48, bar_y + 22)
            _text(scr, (cx + 48, bar_y + 21), n, 22)
    scr.convert("RGB").save(os.path.join(DOCS, "level_preview.png"), optimize=True)


MANIFEST = {}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", default="", help="comma list of groups: " + ",".join(GROUPS))
    ap.add_argument("--match", default="", help="only render jobs whose output path contains this text")
    ap.add_argument("--layout-only", action="store_true", help="no rendering: re-check layouts, redo the docs")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 2)
    args = ap.parse_args()
    groups = set(g for g in args.only.split(",") if g)
    unknown = groups - set(GROUPS)
    if unknown:
        raise SystemExit(f"unknown groups: {sorted(unknown)}")
    jobs = [j for j in build_jobs() if (not groups or j[0] in groups) and args.match in j[1]]
    if args.layout_only:
        jobs = []
    full = not groups and not args.match and not args.layout_only
    os.makedirs(OUT, exist_ok=True)
    heavy = ("districts", "backgrounds", "bit", "blockers", "logo")
    jobs.sort(key=lambda j: (j[0] not in heavy, "/bg" not in j[1], j[1]))
    t0 = time.time()
    results = []
    if args.jobs > 1 and len(jobs) > 1:
        with Pool(args.jobs) as pool:
            for r in pool.imap_unordered(run_job, jobs):
                results.append(r)
    else:
        results = [run_job(j) for j in jobs]
    if full:
        # full run: remove stale files afterwards (the folder is never emptied while rendering)
        keep = {j[1] for j in jobs} | {j[1][:-4] + "_ghost.png" for j in jobs if j[5].get("ghost")}
        for dp, _, fns in os.walk(OUT):
            for fn in fns:
                rel = os.path.relpath(os.path.join(dp, fn), OUT).replace(os.sep, "/")
                if fn.endswith(".png") and rel not in keep:
                    os.remove(os.path.join(dp, fn))
        for dp, dns, fns in sorted(os.walk(OUT), reverse=True):
            if dp != OUT and not os.listdir(dp):
                os.rmdir(dp)
    districts = load_districts()
    touches_districts = full or args.layout_only or "districts" in groups or (not groups and args.match)
    problems = write_layouts(districts) if touches_districts else []
    MANIFEST.update(write_manifest())
    problems += check_edges(MANIFEST)
    if full:
        contact_sheets(districts)
    elif touches_districts:
        district_docs(districts)

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
          f"(budget {BUDGET_MB:g} MB) - rendered in {time.time() - t0:.1f}s")
    if full:
        print("contact sheets: docs/media/art_sheet.png, pieces_grayscale.png, district_<id>.png, level_preview.png")
    if total > BUDGET_MB * 1024 * 1024:
        problems.append(f"total PNG size {total / 1024 / 1024:.2f} MB exceeds {BUDGET_MB:g} MB")
    if problems:
        print("LAYOUT/EDGE/SIZE PROBLEMS:")
        for p in problems:
            print("  -", p)
        sys.exit(1)


if __name__ == "__main__":
    main()
