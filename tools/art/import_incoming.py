#!/usr/bin/env python3
"""Turns the images the producer draws in ChatGPT (docs/art-brief-chatgpt.md) into game-ready sprites.

  python3 tools/art/import_incoming.py                 # process every known file found in assets/art_incoming/
  python3 tools/art/import_incoming.py check           # only the report (nothing is written)
  python3 tools/art/import_incoming.py status          # which pictures of the brief are done and which are missing
  python3 tools/art/import_incoming.py selftest        # the importer against synthetic sheets

Input: files named as in the brief (bit_idle_breathe.png, map_bg_cafe.png, ...), anywhere under --in.
Output: assets/art_ready/<group>/<name>[_<frame>].png (RGBA, sized for the game), manifest.json and a preview sheet per
group in assets/art_ready/_preview/. Nothing here goes into the build by itself: the tasks that use the pictures take
them from assets/art_ready/ (gen_defold.py scans only assets/images/).

What it does to every sprite or sheet: the flat magenta #FF00FF background is cut out (flood fill from the border, a
soft 3 px edge with the colour of the artwork put back, no pink fringe); a sheet is sliced into equal cells; the
frames of one animation are cropped by the same box and scaled by the same factor, standing on one ground line; a
set of different objects is cropped and fitted one by one. Opaque scenes are only cropped and scaled. The report says,
in Russian, what is wrong with a picture so that it can be drawn again.
"""

import argparse
import difflib
import json
import os
import re
import shutil
import sys
import tempfile
import time

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
KEY = np.array([255.0, 0.0, 255.0], np.float32)
T_HARD = 56.0      # distance to the key colour below which a pixel belongs to the background
T_PURE = 28.0      # a hole closed inside the artwork is cut out only when it is this close to the key
KEY_WARN = 25.0    # the colour of the picture border may differ from #FF00FF by this much without a remark
KEY_MAX = 90.0     # farther than this the picture was not drawn on magenta at all: nothing to cut out
RIM = 3            # width of the soft edge, pixels (at about 1000 px)
MARGIN = 0.04      # share of the output left empty round the artwork
EXTS = (".png", ".jpg", ".jpeg", ".webp")


# -- the list of pictures of the brief ---------------------------------------------------------------------------------

def build_spec():
    S = {}

    def add(name, group, kind, out, grid=None, names=None, uniform=False, anchor="center", aspect=None, align="cell"):
        S[name] = {"group": group, "kind": kind, "out": list(out), "grid": list(grid) if grid else None,
                   "names": names, "uniform": uniform, "anchor": anchor, "aspect": aspect, "align": align}

    for name, grid in (("bit_idle_breathe", (2, 2)), ("bit_idle_look", (2, 2)), ("bit_dance_a", (3, 2)),
                       ("bit_dance_b", (3, 2)), ("bit_cheer", (3, 2)), ("bit_surprised", (2, 2)),
                       ("bit_sleepy", (2, 2)), ("bit_write", (3, 2)), ("bit_listen", (2, 2)), ("bit_wave", (2, 2))):
        add(name, "bit", "set", (256, 256), grid, [str(i) for i in range(1, grid[0] * grid[1] + 1)], True, "bottom")
    add("paper_sheet", "notebook", "single", (640, 900))
    add("notebook_closed", "notebook", "single", (384, 384))
    add("stationery", "notebook", "set", (128, 128), (3, 3),
        ["pencil", "pencil_big", "eraser", "pen", "highlighter", "sticker_star", "clip", "tape", "bookmark"])
    add("doodles", "notebook", "set", (96, 96), (3, 3),
        ["note", "note2", "clef", "heart", "star", "flower", "sun", "cloud", "bolt"])
    add("stamp_ready", "notebook", "single", (192, 192))
    add("sparkle_burst", "notebook", "set", (128, 128), (3, 2), [str(i) for i in range(1, 7)], True)
    for d in ("cafe", "jazz", "square", "stadium", "garage"):
        add("map_bg_" + d, "map", "scene", (720, 1080), aspect=(2, 3))
        add("gate_" + d, "map", "single", (720, 480))
        add("deco_" + d, "map", "set", (160, 160), (3, 2), ["d%d" % i for i in range(1, 7)])
        add("room_%s_day" % d, "rooms", "scene", (720, 1280), aspect=(9, 16))
        add("room_%s_concert" % d, "rooms", "scene", (720, 1280), aspect=(9, 16))
    add("map_path", "map", "set", (256, 256), (2, 2), ["straight", "curve_l", "curve_r", "end"], True)
    add("node_day", "map", "set", (160, 160), (2, 2), ["locked", "available", "current", "done"], True)
    add("node_concert", "map", "set", (224, 224), (2, 2), ["locked", "available", "current", "done"], True)
    add("bonus_bar_frame", "bonus", "single", (640, 106))
    add("bonus_bar_fill", "bonus", "single", (640, 106))
    add("bonus_gift", "bonus", "set", (192, 192), (2, 2), ["closed", "shake", "glow", "open"], True)
    add("bonus_spark", "bonus", "set", (128, 128), (3, 2), [str(i) for i in range(1, 7)], True)
    add("super_star", "bonus", "set", (192, 192), (2, 2), ["full", "empty", "glow", "small"])
    for c in ("green", "blue", "gold", "pink", "purple"):
        add("btn_" + c, "ui", "set", (384, 128), (2, 2), ["normal", "pressed", "disabled", "focus"], True, align="center")
    add("panels", "ui", "set", (512, 512), (2, 2), ["window", "plain", "tint", "tab"])
    add("widgets", "ui", "set", (256, 256), (3, 3),
        ["close", "back", "toggle_on", "toggle_off", "slider", "check_on", "check_off", "bar_frame", "bar_fill"])
    add("genres_a", "genres", "set", (96, 96), (3, 3),
        ["classical", "folk", "pop", "hiphop", "edm", "rnb", "reggae", "country", "blues"])
    add("genres_b", "genres", "set", (96, 96), (3, 2), ["bossa", "ambient", "cinematic", "chiptune", "latin", "eastern"])
    return S


SPEC = build_spec()


# -- cutting out the background -----------------------------------------------------------------------------------------

try:
    from scipy import ndimage as _ndi
except ImportError:  # the slow numpy path below is enough for the self test
    _ndi = None


def flood(seed, cand):
    """The part of cand that is connected to seed (4-neighbourhood)."""
    if _ndi is not None:
        lab, n = _ndi.label(cand)
        hit = np.unique(lab[seed & cand])
        hit = hit[hit > 0]
        return np.isin(lab, hit) if len(hit) else np.zeros_like(cand)
    cur = seed & cand
    n = int(cur.sum())
    while True:
        nxt = cur.copy()
        nxt[1:, :] |= cur[:-1, :]
        nxt[:-1, :] |= cur[1:, :]
        nxt[:, 1:] |= cur[:, :-1]
        nxt[:, :-1] |= cur[:, 1:]
        nxt &= cand
        m = int(nxt.sum())
        if m == n:
            return nxt
        cur, n = nxt, m


def dilate(mask, r):
    out = mask.copy()
    for _ in range(r):
        nxt = out.copy()
        nxt[1:, :] |= out[:-1, :]
        nxt[:-1, :] |= out[1:, :]
        nxt[:, 1:] |= out[:, :-1]
        nxt[:, :-1] |= out[:, 1:]
        out = nxt
    return out


def box_sum(a, k):
    """Sum of every k x k window (k odd), zero outside the array."""
    r = k // 2
    pad = np.pad(a.astype(np.float64), ((r + 1, r), (r + 1, r)) + ((0, 0),) * (a.ndim - 2))
    c = pad.cumsum(0).cumsum(1)
    return c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]


def estimate_key(rgb):
    """The colour of the picture border (median) and its distance to #FF00FF."""
    h, w, _ = rgb.shape
    b = max(2, int(min(h, w) * 0.01))
    edge = np.concatenate([rgb[:b].reshape(-1, 3), rgb[-b:].reshape(-1, 3),
                           rgb[:, :b].reshape(-1, 3), rgb[:, -b:].reshape(-1, 3)]).astype(np.float32)
    key = np.median(edge, axis=0).astype(np.float32)
    return key, float(np.sqrt(((key - KEY) ** 2).sum()))


def key_out(rgb, key=KEY):
    """rgb: uint8 HxWx3 on a magenta background -> (colour float32 HxWx3, alpha float32 HxW, info)."""
    h, w, _ = rgb.shape
    p = rgb.astype(np.float32)
    d = np.sqrt(((p - key) ** 2).sum(axis=2))
    cand = d < T_HARD
    border = np.zeros((h, w), bool)
    b = max(2, int(min(h, w) * 0.01))
    border[:b, :] = border[-b:, :] = border[:, :b] = border[:, -b:] = True
    bg = flood(cand & border, cand) | (d < T_PURE)
    kk = float((key ** 2).sum())
    s_ = np.clip((p * key).sum(-1) / max(kk, 1.0), 0.25, 1.0)
    d_sh = np.sqrt(((p - s_[..., None] * key) ** 2).sum(-1))
    gl = np.clip((p[..., 1] - key[1]) / max(255.0 - key[1], 1.0), 0.0, 0.85)
    d_gl = np.sqrt(((p - (key + gl[..., None] * (255.0 - key))) ** 2).sum(-1))
    trans = flood(bg, ((d_sh < 25.0) | (d_gl < 25.0)) | bg) & ~bg
    use_sh = d_sh <= d_gl
    a_t = np.clip(np.where(use_sh, 1.0 - s_, gl), 0.0, 1.0)
    bg_all = bg | trans
    r = max(1, int(round(RIM * min(h, w) / 1000.0)))
    rim = dilate(bg_all, r) & ~bg_all
    obj = ~bg_all & ~rim
    wobj = obj.astype(np.float32)
    k = 2 * r + 1
    cnt = box_sum(wobj, k)
    fg = box_sum(p * wobj[..., None], k) / np.maximum(cnt, 1e-6)[..., None]
    dF = fg - key
    denom = (dF ** 2).sum(-1)
    num = ((p - key) * dF).sum(-1)
    a_rim = np.where(denom < 400.0, 1.0, np.clip(num / np.maximum(denom, 1.0), 0.0, 1.0))
    a_rim = np.where(cnt < 0.5, 0.0, a_rim)
    thin = rim & (cnt < 0.5) & (d > T_HARD)
    iso = np.zeros_like(thin)
    if _ndi is not None and thin.any():
        lt, _n = _ndi.label(thin)
        big = np.bincount(lt.ravel()) >= 20
        big[0] = False
        iso = big[lt]
    a_rim = np.where(iso, 1.0, a_rim)
    a_rim = np.where(a_rim < 0.04, 0.0, a_rim)
    alpha = np.where(obj, 1.0, np.where(rim, a_rim, 0.0)).astype(np.float32)
    color = np.where(obj[..., None] | iso[..., None], p, np.where(rim[..., None], fg, 0.0)).astype(np.float32)
    alpha = np.where(trans, a_t, alpha).astype(np.float32)
    color = np.where(trans[..., None], np.where(use_sh[..., None], 0.0, 255.0), color).astype(np.float32)
    info = {
        "border_purity": float((d[border] < T_HARD * 1.5).mean()),
        "leftover": int(((alpha > 0.5) & (d < 50.0)).sum()),
    }
    return color, alpha, info


def bbox(alpha, thr=0.04):
    rows = np.where(alpha.max(axis=1) > thr)[0]
    cols = np.where(alpha.max(axis=0) > thr)[0]
    if len(rows) == 0:
        return None
    return int(cols[0]), int(rows[0]), int(cols[-1]) + 1, int(rows[-1]) + 1


def resize_rgba(color, alpha, size):
    """Resize with premultiplied alpha, so that no dark or pink halo appears."""
    pm = color * alpha[..., None]
    chans = [Image.fromarray(pm[..., i].astype(np.float32), "F").resize(size, Image.LANCZOS) for i in range(3)]
    a = np.clip(np.asarray(Image.fromarray(alpha.astype(np.float32), "F").resize(size, Image.LANCZOS)), 0.0, 1.0)
    rgb = np.stack([np.asarray(c) for c in chans], axis=-1) / np.maximum(a, 1e-4)[..., None]
    out = np.zeros(a.shape + (4,), np.uint8)
    out[..., :3] = np.clip(rgb, 0, 255).astype(np.uint8)
    out[..., 3] = np.round(a * 255).astype(np.uint8)
    return out


def place(sprite, out, anchor):
    """sprite: RGBA uint8 -> a canvas of size out with the sprite centred (or standing on the bottom margin)."""
    ow, oh = out
    canvas = Image.new("RGBA", (ow, oh), (0, 0, 0, 0))
    im = Image.fromarray(sprite, "RGBA")
    x = (ow - im.width) // 2
    mb = int(round(oh * MARGIN))
    y = oh - im.height - mb if anchor == "bottom" else (oh - im.height) // 2
    canvas.alpha_composite(im, (max(0, x), max(0, y)))
    return np.asarray(canvas)


def fit_scale(bw, bh, out):
    m = 1.0 - 2 * MARGIN
    return min(out[0] * m / bw, out[1] * m / bh)


def cell_boxes(w, h, cols, rows):
    return [(round(c * w / cols), round(r * h / rows), round((c + 1) * w / cols), round((r + 1) * h / rows))
            for r in range(rows) for c in range(cols)]


def drop_intruders(a, ratio=0.03):
    """Slivers and specks of the neighbouring cell that touch the cell border (and are far smaller than the biggest piece)
    are removed, so that they neither stay in the frame nor stretch its bounding box."""
    if _ndi is None:
        return a
    lab, n = _ndi.label(a > 0.2)
    if n < 2:
        return a
    areas = np.bincount(lab.ravel(), minlength=n + 1)
    areas[0] = 0
    big = areas.max()
    h, w = a.shape
    out = a
    for i, sl in enumerate(_ndi.find_objects(lab), start=1):
        if sl is None or areas[i] >= ratio * big:
            continue
        if sl[0].start == 0 or sl[1].start == 0 or sl[0].stop == h or sl[1].stop == w:
            if out is a:
                out = a.copy()
            out[lab == i] = 0
    return out


# -- one item -----------------------------------------------------------------------------------------------------------

def load_input(path):
    """-> (rgb uint8 HxWx3, alpha float32 HxW or None). The alpha is returned only for a picture with real transparency
    (a PNG that ChatGPT has already cut out): then it is used as it is and nothing is keyed."""
    im = Image.open(path)
    if im.mode in ("RGBA", "LA", "PA") or (im.mode == "P" and "transparency" in im.info):
        rgba = np.asarray(im.convert("RGBA"))
        if (rgba[..., 3] < 250).mean() > 0.01:
            return rgba[..., :3].copy(), rgba[..., 3].astype(np.float32) / 255.0
    return np.asarray(im.convert("RGB")).copy(), None


def process(path, name, spec):
    """-> (list of (suffix, RGBA uint8 array), warnings, errors)."""
    warns, errs = [], []
    rgb, alpha_in = load_input(path)
    if spec["kind"] == "scene":
        if alpha_in is not None:
            warns.append("в сцене есть прозрачные места: сцена должна занимать весь холст (прозрачное станет чёрным)")
        return process_scene(Image.fromarray(rgb), spec, warns, errs)
    h, w, _ = rgb.shape
    if min(h, w) < 700:
        warns.append("маленькая картинка (%dx%d): детали будут мягкими, лучше нарисовать крупнее" % (w, h))
    if alpha_in is not None:
        color, alpha, info = rgb.astype(np.float32), alpha_in, {"border_purity": 1.0, "leftover": 0}
    else:
        key, kd = estimate_key(rgb)
        if kd > KEY_MAX:
            errs.append("фон не розовый #FF00FF (по краям цвет %d,%d,%d): вырезать нечего, нужно нарисовать заново на ровном розовом фоне" % tuple(key))
            return [], warns, errs
        if kd > KEY_WARN:
            warns.append("фон розовый, но не совсем тот (%d,%d,%d вместо 255,0,255): вырезал по его цвету, проверьте края" % tuple(key))
        color, alpha, info = key_out(rgb, key)
    if info["border_purity"] < 0.95:
        warns.append("фон не ровно розовый #FF00FF (только %d%% краёв): вырезание может быть неточным"
                     % round(info["border_purity"] * 100))
    if info["leftover"] > 50:
        warns.append("внутри рисунка остались розовые пятна (%d точек): нет ли в картинке чистого #FF00FF?" % info["leftover"])
    grid = spec["grid"] or (1, 1)
    cols, rows = grid
    boxes = cell_boxes(w, h, cols, rows)
    frames = []
    for i, (x0, y0, x1, y1) in enumerate(boxes):
        a = drop_intruders(alpha[y0:y1, x0:x1])
        bb = bbox(a)
        label = (spec["names"][i] if spec["names"] else str(i + 1))
        if bb is None:
            errs.append("клетка %d (%s) пустая" % (i + 1, label))
            frames.append(None)
            continue
        cw, ch = x1 - x0, y1 - y0
        gx, gy = int(cw * 0.012) + 1, int(ch * 0.012) + 1
        if bb[0] <= gx or bb[1] <= gy or bb[2] >= cw - gx or bb[3] >= ch - gy:
            warns.append("рисунок в клетке %d (%s) упёрся в край (нужно поле не меньше 8%%): края могут быть обрезаны" % (i + 1, label))
        frames.append((color[y0:y1, x0:x1], a, bb))
    if errs:
        return [], warns, errs
    out = spec["out"]
    results = []
    if spec["uniform"] and spec.get("align") == "center" and len(frames) > 1:
        # states of one object (buttons): one scale for all, every frame centred on its own box (the positions in the sheet mean nothing)
        s = fit_scale(max(f[2][2] - f[2][0] for f in frames), max(f[2][3] - f[2][1] for f in frames), out)
        for c, a, (x0, y0, x1, y1) in frames:
            size = (max(1, round((x1 - x0) * s)), max(1, round((y1 - y0) * s)))
            results.append(place(resize_rgba(c[y0:y1, x0:x1], a[y0:y1, x0:x1], size), out, "center"))
    elif spec["uniform"] and len(frames) > 1:
        ux0 = min(f[2][0] for f in frames)
        uy0 = min(f[2][1] for f in frames)
        ux1 = max(f[2][2] for f in frames)
        uy1 = max(f[2][3] for f in frames)
        areas = [(f[2][2] - f[2][0]) * (f[2][3] - f[2][1]) for f in frames]
        if max(areas) > 2.2 * min(areas):
            warns.append("кадры очень разного размера (наибольший в %.1f раза больше наименьшего): герой должен быть одного размера" % (max(areas) / min(areas)))
        if spec["anchor"] == "bottom":
            bottoms = [f[2][3] / f[0].shape[0] for f in frames]
            if max(bottoms) - min(bottoms) > 0.08:
                warns.append("у кадров нет общей линии земли (ноги на разной высоте)")
        s = fit_scale(ux1 - ux0, uy1 - uy0, out)
        size = (max(1, round((ux1 - ux0) * s)), max(1, round((uy1 - uy0) * s)))
        for c, a, _ in frames:
            sp = resize_rgba(c[uy0:uy1, ux0:ux1], a[uy0:uy1, ux0:ux1], size)
            results.append(place(sp, out, spec["anchor"]))
    else:
        for c, a, bb in frames:
            x0, y0, x1, y1 = bb
            s = fit_scale(x1 - x0, y1 - y0, out)
            if s > 1.6:
                warns.append("предмет мал на картинке: его придётся растянуть в %.1f раза, будет мягким" % s)
            size = (max(1, round((x1 - x0) * s)), max(1, round((y1 - y0) * s)))
            sp = resize_rgba(c[y0:y1, x0:x1], a[y0:y1, x0:x1], size)
            results.append(place(sp, out, spec["anchor"]))
    names = spec["names"]
    if len(results) == 1 and not names:
        return [("", results[0])], warns, errs
    return [(("_" + names[i]) if names else "_%d" % (i + 1), r) for i, r in enumerate(results)], warns, errs


def process_scene(im, spec, warns, errs):
    w, h = im.size
    if min(w, h) < 700:
        warns.append("маленькая картинка (%dx%d)" % (w, h))
    rgb = np.asarray(im)
    d = np.sqrt(((rgb.astype(np.float32) - KEY) ** 2).sum(axis=2))
    if (d < 40.0).mean() > 0.003:
        warns.append("в сцене есть чистый розовый #FF00FF (%.1f%% площади): сцена должна занимать весь холст" % ((d < 40.0).mean() * 100))
    aw, ah = spec["aspect"]
    if w * ah > h * aw:          # too wide: cut the sides
        nw = round(h * aw / ah)
        x0 = (w - nw) // 2
        im = im.crop((x0, 0, x0 + nw, h))
    else:                        # too tall: cut top and bottom
        nh = round(w * ah / aw)
        y0 = (h - nh) // 2
        im = im.crop((0, y0, w, y0 + nh))
    im = im.resize(tuple(spec["out"]), Image.LANCZOS)
    arr = np.zeros((spec["out"][1], spec["out"][0], 4), np.uint8)
    arr[..., :3] = np.asarray(im)
    arr[..., 3] = 255
    return [("", arr)], warns, errs


# -- files, report, preview ---------------------------------------------------------------------------------------------

def norm_stem(f):
    s = os.path.splitext(f)[0].lower()
    s = re.sub(r"[ \-]+", "_", s)
    s = re.sub(r"_?\(\d+\)$", "", s)
    return s


DUPES = {}
ALT_EXTS = (".jfif", ".avif", ".heic", ".heif", ".gif", ".bmp", ".tif", ".tiff")


def outputs_of(name, spec):
    return [name + "_" + n + ".png" for n in spec["names"]] if spec["names"] else [name + ".png"]


def find_inputs(root):
    cands, unknown = {}, []
    DUPES.clear()
    for dp, _, fns in os.walk(root):
        for f in sorted(fns):
            ext = os.path.splitext(f)[1].lower()
            if ext not in EXTS and ext not in ALT_EXTS:
                continue
            key = norm_stem(f)
            if key in SPEC and ext in EXTS:
                cands.setdefault(key, []).append(os.path.join(dp, f))
            else:
                unknown.append(os.path.join(dp, f))
    found = {}
    for key, ps in cands.items():
        found[key] = max(ps, key=os.path.getmtime)
        if len(ps) > 1:
            DUPES[key] = sorted(ps)
    return found, unknown


def preview(group, outputs, path):
    cell, pad = 150, 12
    items = [(n, np.asarray(Image.open(p).convert("RGBA"))) for n, p in outputs]
    cols = min(6, max(1, len(items)))
    rows = (len(items) + cols - 1) // cols
    W, H = pad + cols * (cell + pad), 30 + pad + rows * (cell + 22 + pad)
    sheet = Image.new("RGBA", (W, H), (236, 229, 255, 255))
    d = ImageDraw.Draw(sheet)
    d.text((pad, 8), group, fill=(43, 35, 69, 255))
    for i, (n, arr) in enumerate(items):
        r, c = divmod(i, cols)
        x, y = pad + c * (cell + pad), 30 + pad + r * (cell + 22 + pad)
        for yy in range(0, cell, 15):
            for xx in range(0, cell, 15):
                if (xx // 15 + yy // 15) % 2:
                    d.rectangle([x + xx, y + yy, x + xx + 14, y + yy + 14], fill=(250, 247, 255, 255))
                else:
                    d.rectangle([x + xx, y + yy, x + xx + 14, y + yy + 14], fill=(214, 205, 240, 255))
        im = Image.fromarray(arr, "RGBA")
        k = min(cell / im.width, cell / im.height)
        im = im.resize((max(1, int(im.width * k)), max(1, int(im.height * k))), Image.LANCZOS)
        sheet.alpha_composite(im, (x + (cell - im.width) // 2, y + (cell - im.height) // 2))
        d.text((x, y + cell + 3), n[:26], fill=(43, 35, 69, 255))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    sheet.convert("RGB").save(path)


def run(inp, outdir, only=None, write=True):
    found, unknown = find_inputs(inp)
    for k in sorted(DUPES):
        print("замечание: для %s найдено несколько файлов (%s): взят самый новый %s" % (k, ", ".join(os.path.relpath(x, inp) for x in DUPES[k]), os.path.relpath(found[k], inp)))
    manifest, groups, bad = {}, {}, 0
    for name in sorted(found):
        if only and name not in only:
            continue
        spec = SPEC[name]
        try:
            files, warns, errs = process(found[name], name, spec)
        except Exception as e:  # a broken file must not stop the others
            files, warns, errs = [], [], ["не удалось обработать: %s" % e]
        entry = {"group": spec["group"], "source": os.path.relpath(found[name], inp), "files": [], "warnings": warns, "errors": errs}
        if write and files:
            d = os.path.join(outdir, spec["group"])
            os.makedirs(d, exist_ok=True)
            for suffix, arr in files:
                p = os.path.join(d, name + suffix + ".png")
                Image.fromarray(arr, "RGBA").save(p, optimize=True)
                entry["files"].append(os.path.relpath(p, outdir))
                groups.setdefault(spec["group"], []).append((name + suffix, p))
        manifest[name] = entry
        if write:
            for fn in outputs_of(name, spec):
                pth = os.path.join(outdir, spec["group"], fn)
                if os.path.join(spec["group"], fn) not in entry["files"] and os.path.exists(pth):
                    os.remove(pth)
        mark = "ОШИБКА" if errs else ("есть замечания" if warns else "ок")
        print("%-22s %s%s" % (name, mark, ("  (%d файлов)" % len(files)) if files else ""))
        for m in errs:
            print("    ошибка: " + m)
            bad += 1
        for m in warns:
            print("    замечание: " + m)
    for u in unknown:
        ext = os.path.splitext(u)[1].lower()
        if ext in ALT_EXTS:
            print("формат не поддержан: %s (сохрани как PNG, JPG или WebP)" % os.path.relpath(u, inp))
            continue
        near = difflib.get_close_matches(norm_stem(os.path.basename(u)), list(SPEC), n=1, cutoff=0.75)
        print("не знаю такого имени: %s%s (имена в docs/art-brief-chatgpt.md)"
              % (os.path.relpath(u, inp), (", возможно это %s?" % near[0]) if near else ""))
    if write and manifest:
        os.makedirs(outdir, exist_ok=True)
        mp = os.path.join(outdir, "manifest.json")
        merged = {}
        if only and os.path.exists(mp):
            try:
                merged = json.load(open(mp, encoding="utf-8"))
            except Exception:
                merged = {}
        merged.update(manifest)
        if not only:
            for n, sp in SPEC.items():
                if n not in found:
                    for fn in outputs_of(n, sp):
                        pth = os.path.join(outdir, sp["group"], fn)
                        if os.path.exists(pth):
                            os.remove(pth)
        with open(mp, "w", encoding="utf-8") as f:
            json.dump(merged, f, ensure_ascii=False, indent=1)
        allg = {}
        for n in sorted(merged):
            for rel in merged[n]["files"]:
                allg.setdefault(merged[n]["group"], []).append((os.path.splitext(os.path.basename(rel))[0], os.path.join(outdir, rel)))
        for g, outs in allg.items():
            preview(g, outs, os.path.join(outdir, "_preview", g + ".png"))
    print("обработано: %d, с ошибками: %d, предупреждений: %d" % (
        len(manifest), sum(1 for e in manifest.values() if e["errors"]), sum(len(e["warnings"]) for e in manifest.values())))
    return bad == 0


def status(inp, outdir):
    found, _ = find_inputs(inp)
    by = {}
    for name, spec in SPEC.items():
        by.setdefault(spec["group"], []).append(name)
    total = 0
    for g in sorted(by):
        have = [n for n in by[g] if n in found]
        total += len(have)
        print("%-9s %2d из %2d  %s" % (g, len(have), len(by[g]), "" if len(have) == len(by[g]) else "нет: " + ", ".join(n for n in by[g] if n not in found)))
    print("всего получено: %d из %d" % (total, len(SPEC)))


# -- self test ------------------------------------------------------------------------------------------------------------

def synth_cell(size, draw, scale=2):
    """A magenta canvas with anti-aliased shapes drawn by `draw(ImageDraw, k)` where k is the supersampling factor."""
    big = Image.new("RGB", (size[0] * scale, size[1] * scale), (255, 0, 255))
    draw(ImageDraw.Draw(big), scale)
    return big.resize(size, Image.LANCZOS)


def selftest():
    tmp = tempfile.mkdtemp(prefix="import-incoming-")
    problems = []
    try:
        inp, outdir = os.path.join(tmp, "in"), os.path.join(tmp, "out")
        os.makedirs(inp)
        # 1. an animation sheet 2x2 (1024x1024): a "character" (body + neon pink headphones) bobbing, same ground line
        sheet = Image.new("RGB", (1024, 1024), (255, 0, 255))
        for i in range(4):
            cx, cy = (i % 2) * 512, (i // 2) * 512
            sq = 10 * (i % 2)  # the body squashes a little from frame to frame
            cell = synth_cell((512, 512), lambda d, k, sq=sq: (
                d.ellipse([(150 - sq) * k, (170 + sq) * k, (360 + sq) * k, (430) * k], fill=(255, 201, 139), outline=(224, 135, 58), width=4 * k),
                d.ellipse([(170) * k, (200) * k, (200) * k, (250) * k], fill=(255, 79, 216)),
                d.ellipse([(310) * k, (200) * k, (340) * k, (250) * k], fill=(255, 79, 216))))
            sheet.paste(cell, (cx, cy))
        sheet.save(os.path.join(inp, "bit_idle_breathe.png"))
        # 2. bad sheets: (a) the background is not magenta at all; (b) magenta, but a cell is empty and a drawing sits on the edge
        bad = Image.new("RGB", (1024, 1024), (200, 120, 200))
        ImageDraw.Draw(bad).ellipse([5, 5, 300, 300], fill=(30, 200, 90))
        bad.save(os.path.join(inp, "bit_wave.jpg"))
        bad2 = Image.new("RGB", (1024, 1024), (255, 0, 255))
        ImageDraw.Draw(bad2).ellipse([0, 100, 200, 400], fill=(30, 200, 90))        # touches the left edge of cell 1
        ImageDraw.Draw(bad2).ellipse([650, 150, 850, 400], fill=(30, 200, 90))      # cell 2 is fine, cells 3 and 4 are empty
        bad2.save(os.path.join(inp, "bit_sleepy.png"))
        # 2b. a good sheet whose "magenta" is a little off (240,20,240) with noise: the colour of the border is used
        rng = np.random.RandomState(7)
        off = Image.new("RGB", (1024, 1024), (240, 20, 240))
        for i in range(4):
            ImageDraw.Draw(off).ellipse([(i % 2) * 512 + 150, (i // 2) * 512 + 160, (i % 2) * 512 + 360, (i // 2) * 512 + 430],
                                        fill=(60, 200, 190), outline=(20, 110, 120), width=5)
        noisy = np.clip(np.asarray(off).astype(int) + rng.randint(-4, 5, (1024, 1024, 3)), 0, 255).astype(np.uint8)
        Image.fromarray(noisy).save(os.path.join(inp, "bit_listen.png"))
        # 2c. a PNG that is already transparent (3x2 sheet): used as it is, six frames
        tr = Image.new("RGBA", (1536, 1024), (0, 0, 0, 0))
        for i in range(6):
            ImageDraw.Draw(tr).ellipse([(i % 3) * 512 + 150, (i // 3) * 512 + 140, (i % 3) * 512 + 360, (i // 3) * 512 + 430],
                                       fill=(255, 180, 60, 255), outline=(150, 90, 20, 255), width=5)
        tr.save(os.path.join(inp, "bit_dance_b.png"))
        # 2d. a hero with a soft contact shadow (30% black over magenta) under the feet, sheet 2x2
        sh_sheet = Image.new("RGB", (1024, 1024), (255, 0, 255))
        for i in range(4):
            cell = Image.new("RGB", (512, 512), (255, 0, 255))
            shadow = Image.new("L", (512, 512), 0)
            ImageDraw.Draw(shadow).ellipse([110, 400, 400, 450], fill=77)
            cell = Image.composite(Image.new("RGB", (512, 512), (0, 0, 0)), cell, shadow.filter(ImageFilter.GaussianBlur(6)))
            ImageDraw.Draw(cell).ellipse([150, 170, 360, 425], fill=(255, 201, 139), outline=(224, 135, 58), width=4)
            if i == 1:
                ImageDraw.Draw(cell).rectangle([0, 150, 5, 330], fill=(60, 200, 90))   # a sliver of the neighbouring cell
            sh_sheet.paste(cell, ((i % 2) * 512, (i // 2) * 512))
        sh_sheet.save(os.path.join(inp, "bit_surprised.png"))
        # 2e. a music note whose stem is 5 px wide and has no outline (single sprite)
        note = Image.new("RGB", (1024, 1024), (255, 0, 255))
        nd = ImageDraw.Draw(note)
        nd.ellipse([300, 700, 420, 790], fill=(60, 200, 190))
        nd.rectangle([415, 250, 420, 750], fill=(60, 200, 190))
        nd.polygon([(420, 250), (540, 330), (420, 310)], fill=(60, 200, 190))
        note.save(os.path.join(inp, "notebook_closed.png"))
        # 2f. the same name twice (an old drawing and a newer re-download): the newer one must win
        for fname, colour, age in (("bit_cheer.png", (200, 40, 40), 1000), ("bit_cheer (1).png", (40, 160, 60), 0)):
            twin = Image.new("RGB", (1536, 1024), (255, 0, 255))
            for i in range(6):
                ImageDraw.Draw(twin).ellipse([(i % 3) * 512 + 150, (i // 3) * 512 + 140, (i % 3) * 512 + 360, (i // 3) * 512 + 430], fill=colour)
            tp = os.path.join(inp, fname)
            twin.save(tp)
            os.utime(tp, (time.time() - age, time.time() - age))
        # 3. a scene (wide) cropped to 9:16
        Image.new("RGB", (1536, 1024), (120, 200, 255)).save(os.path.join(inp, "room_cafe_day.png"))
        # 4. a single sprite with a ring (a hole of magenta closed inside) and a file with a name the brief does not know
        ring = synth_cell((1024, 1024), lambda d, k: (d.ellipse([200 * k, 200 * k, 800 * k, 800 * k], fill=(255, 216, 77)),
                                                    d.ellipse([400 * k, 400 * k, 600 * k, 600 * k], fill=(255, 0, 255))))
        ring.save(os.path.join(inp, "stamp_ready.png"))
        Image.new("RGB", (64, 64)).save(os.path.join(inp, "something_else.png"))
        ok = run(inp, outdir)
        man = json.load(open(os.path.join(outdir, "manifest.json"), encoding="utf-8"))
        # sheet: four 256x256 frames, bottoms aligned, no pink fringe, the neon pink headphones kept opaque
        frames = [np.asarray(Image.open(os.path.join(outdir, "bit", "bit_idle_breathe_%d.png" % i))) for i in range(1, 5)]
        if any(f.shape != (256, 256, 4) for f in frames):
            problems.append("the frames are not 256x256")
        else:
            bottoms = {int(np.where(f[..., 3] > 10)[0].max()) for f in frames}
            if len(bottoms) != 1:
                problems.append("frames do not stand on one ground line: %s" % sorted(bottoms))
            for f in frames:
                op = f[f[..., 3] == 255][:, :3].astype(int)
                fringe = int(((np.minimum(op[:, 0], op[:, 2]) - op[:, 1] > 150) & (op[:, 0] > 230) & (op[:, 2] > 230) & (op[:, 1] < 40)).sum())
                if fringe > 0:
                    problems.append("pink fringe left: %d opaque pixels" % fringe)
                    break
            neon = sum(int(((f[..., 3] == 255) & (abs(f[..., 0].astype(int) - 255) < 6) & (abs(f[..., 1].astype(int) - 79) < 12) & (abs(f[..., 2].astype(int) - 216) < 12)).sum()) for f in frames)
            if neon < 200:
                problems.append("the neon pink of the artwork was keyed out (%d pixels kept)" % neon)
        if man["bit_idle_breathe"]["warnings"] or man["bit_idle_breathe"]["errors"]:
            problems.append("a good sheet got remarks: %s" % (man["bit_idle_breathe"]["warnings"] + man["bit_idle_breathe"]["errors"]))
        # the bad sheets are reported, and no files are written for them
        w = man["bit_wave"]
        if not any("фон не розовый" in m for m in w["errors"]) or w["files"]:
            problems.append("the sheet on a non-magenta background was not rejected: %s" % w)
        w2 = man["bit_sleepy"]
        if sum("пустая" in m for m in w2["errors"]) != 2 or not any("упёрся в край" in m for m in w2["warnings"]) or w2["files"]:
            problems.append("the sheet with empty cells and an edge drawing was not reported properly: %s" % w2)
        # the slightly-off magenta is keyed by the border colour: remark about the colour, clean cut-out
        w3 = man["bit_listen"]
        if w3["errors"] or not any("не совсем тот" in m for m in w3["warnings"]) or len(w3["files"]) != 4:
            problems.append("the off-magenta sheet was not handled properly: %s" % w3)
        else:
            for f in w3["files"]:
                a = np.asarray(Image.open(os.path.join(outdir, f)))
                op = a[a[..., 3] == 255][:, :3].astype(int)
                close = int(((np.abs(op - np.array([240, 20, 240])).sum(axis=1)) < 90).sum())
                if close > 0:
                    problems.append("background left in %s: %d opaque pixels close to the key" % (f, close))
                    break
                if not (0.04 < (a[..., 3] > 128).mean() < 0.9):
                    problems.append("%s: the opaque share is odd (%.2f)" % (f, (a[..., 3] > 128).mean()))
                    break
        # the soft shadow does not become an opaque pink oval, and the sheet is not reported
        w5 = man["bit_surprised"]
        if w5["errors"] or w5["warnings"] or len(w5["files"]) != 4:
            problems.append("the sheet with shadows got remarks: %s" % w5)
        else:
            for f in w5["files"]:
                a = np.asarray(Image.open(os.path.join(outdir, f)))
                op = a[a[..., 3] >= 250][:, :3].astype(int)
                if int(((op[:, 0] > 120) & (op[:, 2] > 120) & (op[:, 1] < 60)).sum()) > 30:
                    problems.append("the shadow stayed as opaque magenta in " + f)
                    break
            f0 = np.asarray(Image.open(os.path.join(outdir, w5["files"][0])))
            body = (f0[..., 3] >= 250) & (np.abs(f0[..., 0].astype(int) - 255) < 8) & (np.abs(f0[..., 1].astype(int) - 201) < 20)
            rows = np.where(body.any(axis=1))[0]
            if len(rows) == 0 or rows.max() - rows.min() < 190:
                problems.append("a sliver of the neighbouring cell shrank the hero (body height %d px)" % ((rows.max() - rows.min()) if len(rows) else 0))
        # a thin stem without an outline survives: one piece
        nb = np.asarray(Image.open(os.path.join(outdir, "notebook", "notebook_closed.png")))
        if _ndi is not None:
            pieces = _ndi.label(nb[..., 3] > 128)[1]
            if pieces != 1:
                problems.append("the 5 px note stem was cut: %d pieces" % pieces)
        # two files for one name: the newer one wins and the user is told
        if "bit_cheer" not in DUPES or not man["bit_cheer"]["source"].endswith("(1).png"):
            problems.append("the newer of two files for one name was not taken: %s" % man["bit_cheer"]["source"])
        else:
            cf = np.asarray(Image.open(os.path.join(outdir, man["bit_cheer"]["files"][0])))
            if not (cf[128, 128, 1] > cf[128, 128, 0]):
                problems.append("bit_cheer shows the old (red) drawing, not the new (green) one")
        # --only keeps the other entries of manifest.json
        run(inp, outdir, only=["stamp_ready"])
        man2 = json.load(open(os.path.join(outdir, "manifest.json"), encoding="utf-8"))
        if "bit_idle_breathe" not in man2 or "stamp_ready" not in man2:
            problems.append("--only lost entries of manifest.json: %s" % sorted(man2))
        # the transparent PNG is not keyed: six frames, transparent corners, opaque body
        w4 = man["bit_dance_b"]
        if w4["errors"] or len(w4["files"]) != 6:
            problems.append("the transparent sheet was not handled properly: %s" % w4)
        else:
            f4 = np.asarray(Image.open(os.path.join(outdir, w4["files"][0])))
            if f4[3, 3, 3] != 0 or f4[128, 128, 3] != 255:
                problems.append("the transparent sheet changed its alpha: corner %d, centre %d" % (f4[3, 3, 3], f4[128, 128, 3]))
        # the scene
        room = Image.open(os.path.join(outdir, "rooms", "room_cafe_day.png"))
        if room.size != (720, 1280):
            problems.append("the room is %s, expected 720x1280" % (room.size,))
        # the ring: the closed hole is transparent
        stamp = np.asarray(Image.open(os.path.join(outdir, "notebook", "stamp_ready.png")))
        if stamp[96, 96, 3] != 0:
            problems.append("the closed magenta hole of the ring was not cut out (alpha %d)" % stamp[96, 96, 3])
        if stamp[96, 20, 3] != 255:
            problems.append("the ring body is not opaque")
        if ok:
            problems.append("run() said everything is fine although a sheet has an error")
        print("selftest:", "OK" if not problems else "FAILED")
        for p in problems:
            print("  -", p)
        return not problems
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", nargs="?", default="run", choices=["run", "check", "status", "selftest"])
    ap.add_argument("--in", dest="inp", default=os.path.join(ROOT, "assets", "art_incoming"))
    ap.add_argument("--out", default=os.path.join(ROOT, "assets", "art_ready"))
    ap.add_argument("--only", help="comma-separated names")
    a = ap.parse_args()
    if a.cmd == "selftest":
        sys.exit(0 if selftest() else 1)
    if a.cmd == "status":
        status(a.inp, a.out)
        return
    only = [x.strip().lower() for x in a.only.split(",") if x.strip()] if a.only else None
    if not os.path.isdir(a.inp):
        print("папка с картинками не найдена: %s" % a.inp)
        sys.exit(2)
    if only:
        found, _ = find_inputs(a.inp)
        missing = [n for n in only if n not in found]
        if missing:
            print("нет такой картинки или нет файла для неё: %s" % ", ".join(missing))
            sys.exit(2)
    sys.exit(0 if run(a.inp, a.out, only, write=a.cmd == "run") else 1)


if __name__ == "__main__":
    main()
