"""Placeholder art of the game map (WP-7): drawn by code until the real pictures arrive
(docs/art-brief-chatgpt.md, group A3). Every picture here has the name and size the map data
(content/map.json) asks for, so the real art drops in without a code change.

  map/node_day_<state>.png      160x160   level node, states locked | open | current | done
  map/node_concert_<state>.png  224x224   the same for a concert level
  map/path_dot.png, path_dot_done.png   48x48   one tile of the trail (the map repeats it along the path)
  map/deco_<district>_<1..6>.png 160x160   small things that decorate a district
  mapbg/bg_<district>.png       720x1080  background of a stretch of the map (street seen from above, free lane in the middle)
  mapbg/gate_<district>.png     720x480   the entrance arch of a district (the sign is empty: the game writes the name)

Drawn with the same kit as the other art (artkit: signed distance fields, candy shading) and plain
PIL for the big backgrounds.
"""
import math

import numpy as np
from PIL import Image, ImageDraw

from artkit import (Canvas, WHITE, opening, sd_circle, sd_poly, sd_polyline, sd_rect, sd_ring, sd_star, sd_capsule,
                    soft_shadow, sparkle4, U)
from palette import PIECE_SHADOW
from pieces import note_sdf
from ui import BLUE, CHROME, GOLD, GREEN, GREY_P, ORANGE, PINK, PURPLE, RED, CYAN, WOOD, hl_drop, obj

STATES = ("locked", "open", "current", "done")
DAY_SIZE, CONCERT_SIZE, DOT_SIZE, DECO_SIZE = 160, 224, 48, 160
BG_W, BG_H, GATE_W, GATE_H = 720, 1080, 720, 480

# per district: sky/ground colours of the background, the colour of the gate, and the six decorations
THEMES = {
    "cafe": {"top": "#FFF0D6", "bottom": "#F7D9B5", "wall": ("#FFD9A3", "#F5B37A", "#E8956A"), "accent": "#8BD99B",
             "deco": ("tree", "lamp", "bench", "plant", "cup", "cat")},
    "jazz": {"top": "#E8E0FF", "bottom": "#CFC3F2", "wall": ("#B9A6EC", "#9C86DC", "#F5C84B"), "accent": "#F5C84B",
             "deco": ("lamp", "plant", "sax", "bench", "star", "piano")},
    "square": {"top": "#D9F2FF", "bottom": "#BFE6D0", "wall": ("#FFB3A1", "#FFD36E", "#7FC8FF"), "accent": "#FF7A59",
               "deco": ("tree", "flags", "fountain", "bench", "horn", "lamp")},
    "stadium": {"top": "#FFE0F1", "bottom": "#CDEBFF", "wall": ("#FFB3D6", "#9ED8FF", "#C9A7FF"), "accent": "#3CE0FF",
                "deco": ("star", "stick", "flags", "lamp", "firework", "tree")},
    "garage": {"top": "#E6E1F2", "bottom": "#C5BFD9", "wall": ("#A59DC0", "#8C84AC", "#FF9A1F"), "accent": "#FF9A1F",
               "deco": ("amp", "guitar", "lamp", "flags", "tire", "plant")},
}
DISTRICTS = tuple(THEMES)


# ---------------------------------------------------------------------------------------------
# nodes
# ---------------------------------------------------------------------------------------------
def _lock(cv, cx, cy, s):
    X, Y = cv.X, cv.Y
    sh = U(sd_ring(X, Y, cx, cy - 10 * s, 11 * s, 5 * s), sd_rect(X, Y, cx - 11 * s, cy - 10 * s, cx + 11 * s, cy, 0))
    sh = np.maximum(sh, -(Y - (cy - 10 * s)) + 0.0)
    obj(cv, sh, CHROME, depth=4, rim=0.3)
    body = sd_rect(X, Y, cx - 17 * s, cy, cx + 17 * s, cy + 28 * s, 6 * s)
    obj(cv, body, GOLD, depth=8, rim=0.4)
    cv.fill(sd_circle(X, Y, cx, cy + 12 * s, 4 * s), "#C27400")


def _check(cv, cx, cy, s):
    d = sd_polyline(cv.X, cv.Y, [(cx - 20 * s, cy), (cx - 6 * s, cy + 14 * s), (cx + 22 * s, cy - 16 * s)]) - 7.5 * s
    obj(cv, d, ("#FFFFFF", "#FFFFFF", "#DCF7E6", "#18B85A"), lw=2.0, depth=6, rim=0.3)


def _note(cv, cx, cy, s, pal):
    d = note_sdf(cv.X, cv.Y, cx - 90 * s * 0.5, cy - 66 * s * 0.5, s * 0.5, bold=True)
    obj(cv, d, pal, lw=2.4, depth=8, rim=0.3)


def draw_node(kind, state):
    """A level node: a record on a little stage. `current` is bigger with a gold ring and a glow."""
    concert = kind == "concert"
    size = CONCERT_SIZE if concert else DAY_SIZE
    cv = Canvas(size, size)
    X, Y = cv.X, cv.Y
    k = 1.12 if concert else 1.0          # a concert stage is bigger than a day node
    c = size / 2
    cy = c + (14 if concert else 0)       # room above a concert node for the crown
    r = {"locked": 46, "open": 50, "current": 56, "done": 48}[state] * k
    if state == "locked":
        base, inner = GREY_P, ("#EDEAF6", "#D3CFE6", "#B7B1D0", "#8E86AE")
    elif concert:
        base, inner = (("#FFE98A", "#FFC83D", "#F59A00", "#B35F00"), ("#FFB3D6", "#FF5C9A", "#E0306F", "#A8124C")) if state != "done" \
            else (("#FFE98A", "#FFC83D", "#F59A00", "#B35F00"), GREEN)
    elif state == "done":
        base, inner = GREEN, ("#B5FFD0", "#3BE37F", "#18B85A", "#0E8A43")
    else:
        base, inner = PURPLE, PINK
    if state == "current":
        glow = cv.blank()
        obj(glow, sd_circle(X, Y, c, cy, r + 6 * k), GOLD, lw=3.0, depth=6)
        glow.glow_under(10 * k, "#FFE680", 0.8)
        cv.over(glow)
    obj(cv, sd_circle(X, Y, c, cy, r), base, lw=3.0, depth=14 * k, rim=0.4)
    cv.stroke(sd_ring(X, Y, c, cy, r * 0.80, 1.5 * k), 1.4, "#FFFFFF", 0.35)
    cv.stroke(sd_ring(X, Y, c, cy, r * 0.66, 1.5 * k), 1.4, "#FFFFFF", 0.25)
    obj(cv, sd_circle(X, Y, c, cy, r * 0.52), inner, lw=2.4, depth=8 * k, rim=0.3)
    s = k * 0.8
    if state == "locked":
        _lock(cv, c, cy - 10 * s, s * 0.9)
    elif state == "done":
        _check(cv, c, cy, s)
    else:
        _note(cv, c, cy, s * 0.95, ("#FFFFFF", "#FFFFFF", "#EADDFF", "#7B6AAE"))
    hl_drop(cv, c - r * 0.45, cy - r * 0.5, r * 0.16, r * 0.08, -40, sd_circle(X, Y, c, cy, r) + 4, alpha=0.8)
    if concert:
        # the crown star on top and two spotlight beams
        col = ("#FFF3B0", "#FFD23F", "#F5A300", "#C27400") if state != "locked" else GREY_P
        star = opening(sd_star(X, Y, c, cy - r - 4 * k, 17 * k, 8 * k), 2, 4)
        obj(cv, star, col, lw=2.4, depth=8, rim=0.3)
        for sx in (-1, 1):
            beam = sd_capsule(X, Y, c + sx * (r + 8 * k), cy + r * 0.2, c + sx * (r + 16 * k), cy - r * 0.5, 3.5 * k)
            obj(cv, beam, ("#FFFFFF", "#FFF3B0", "#F5C84B", "#B58A1A") if state != "locked" else GREY_P, lw=1.6, depth=4)
    if state != "locked":
        for (sx, sy, sz) in ((c + r * 0.8, cy - r * 0.6, 5 * k), (c - r * 0.85, cy + r * 0.4, 4 * k)):
            sparkle4(cv, sx, sy, sz, WHITE, 0.9)
    soft_shadow(cv, 0, 3, 3, PIECE_SHADOW, 0.3)
    return cv


def draw_dot(done):
    """A tile of the trail: a white-rimmed pastel pebble with a light dot."""
    cv = Canvas(DOT_SIZE, DOT_SIZE)
    c = DOT_SIZE / 2
    pal = ("#FFFFFF", "#FFE680", "#F5C84B", "#C99A1A") if done else ("#FFFFFF", "#E6DBFF", "#B9A6EC", "#8B7BB8")
    obj(cv, sd_circle(cv.X, cv.Y, c, c, 15), pal, lw=2.0, depth=6, rim=0.3)
    cv.fill(sd_circle(cv.X, cv.Y, c, c - 1, 4.5), "#FFFFFF", 0.95)
    soft_shadow(cv, 0, 1.5, 1.5, PIECE_SHADOW, 0.22)
    return cv


# ---------------------------------------------------------------------------------------------
# decorations: six small things per district, 160x160
# ---------------------------------------------------------------------------------------------
def _deco(kind, accent):
    cv = Canvas(DECO_SIZE, DECO_SIZE)
    X, Y = cv.X, cv.Y
    if kind in ("tree", "plant"):
        r = 40 if kind == "tree" else 26
        obj(cv, sd_capsule(X, Y, 80, 136, 80, 100, 7), WOOD, lw=2.4, depth=5)
        obj(cv, U(sd_circle(X, Y, 80, 82, r), sd_circle(X, Y, 80 - r * 0.6, 94, r * 0.7), sd_circle(X, Y, 80 + r * 0.6, 94, r * 0.7)),
            GREEN, lw=3.0, depth=14)
    elif kind == "lamp":
        obj(cv, sd_capsule(X, Y, 80, 150, 80, 60, 5), CHROME, lw=2.4, depth=4)
        glow = cv.blank()
        obj(glow, sd_circle(X, Y, 80, 48, 20), GOLD, lw=2.4, depth=8)
        glow.glow_under(14, "#FFE680", 0.7)
        cv.over(glow)
    elif kind == "bench":
        obj(cv, sd_rect(X, Y, 28, 100, 132, 114, 6), WOOD, lw=2.4, depth=4)
        obj(cv, sd_rect(X, Y, 26, 76, 134, 92, 6), WOOD, lw=2.4, depth=4)
        for x in (36, 124):
            obj(cv, sd_capsule(X, Y, x, 112, x, 146, 4), CHROME, lw=2.0, depth=3)
    elif kind == "cup":
        obj(cv, sd_rect(X, Y, 44, 70, 112, 140, 14), ("#FFFFFF", "#FFF4E0", "#F2D7B0", "#C28A4E"), lw=2.6, depth=12)
        obj(cv, sd_ring(X, Y, 120, 100, 16, 7), ("#FFFFFF", "#FFF4E0", "#F2D7B0", "#C28A4E"), lw=2.0, depth=3)
        cv.fill(sd_rect(X, Y, 50, 76, 106, 90, 6), "#7A4A2A", 0.9)
    elif kind == "cat":
        obj(cv, U(sd_circle(X, Y, 80, 110, 34), sd_circle(X, Y, 80, 66, 24)), ORANGE, lw=3.0, depth=10)
        for sx in (-1, 1):
            obj(cv, sd_poly(X, Y, [(80 + sx * 10, 48), (80 + sx * 26, 44), (80 + sx * 22, 62)]), ORANGE, lw=2.0, depth=3)
            cv.fill(sd_circle(X, Y, 80 + sx * 9, 68, 3.2), "#2B2345")
    elif kind in ("sax", "horn"):
        d = U(sd_polyline(X, Y, [(60, 30), (60, 110), (90, 134)]) - 10, sd_circle(X, Y, 104, 128, 22))
        obj(cv, d, GOLD, lw=3.0, depth=10)
        cv.fill(sd_circle(X, Y, 104, 128, 12), "#C27400", 0.8)
    elif kind in ("star", "firework"):
        obj(cv, opening(sd_star(X, Y, 80, 82, 56, 26), 4, 4), GOLD if kind == "star" else PINK, lw=3.0, depth=14)
        sparkle4(cv, 120, 36, 10, WHITE, 0.9)
    elif kind == "piano":
        obj(cv, sd_rect(X, Y, 20, 60, 140, 128, 10), ("#4B3B7A", "#2F2557", "#1E1840", "#120E2C"), lw=2.6, depth=10)
        for i in range(6):
            cv.fill(sd_rect(X, Y, 30 + i * 18, 96, 44 + i * 18, 124, 2), "#FFFFFF", 0.95)
    elif kind == "flags":
        pts = [(14, 40), (80, 62), (146, 40)]
        cv.stroke(sd_polyline(X, Y, pts), 3, "#6B5E8F", 1.0)
        for i, col in enumerate((RED, GOLD, BLUE, GREEN, PINK)):
            fx = 26 + i * 27
            fy = 44 + 22 * math.sin(math.pi * (fx - 14) / 132)
            obj(cv, sd_poly(X, Y, [(fx - 9, fy), (fx + 9, fy), (fx, fy + 24)]), col, lw=1.6, depth=3)
    elif kind == "fountain":
        obj(cv, sd_rect(X, Y, 20, 108, 140, 138, 14), CHROME, lw=2.6, depth=8)
        obj(cv, sd_rect(X, Y, 68, 60, 92, 112, 6), CHROME, lw=2.0, depth=5)
        for sx in (-1, 1):
            cv.stroke(sd_polyline(X, Y, [(80, 58), (80 + sx * 22, 62), (80 + sx * 34, 100)]), 4, "#7FD6FF", 0.9)
    elif kind == "stick":
        for sx, col in ((-24, PINK), (0, CYAN), (24, GOLD)):
            obj(cv, sd_capsule(X, Y, 80 + sx, 140, 80 + sx * 1.3, 40, 9), col, lw=2.4, depth=6)
    elif kind == "amp":
        obj(cv, sd_rect(X, Y, 28, 40, 132, 146, 10), ("#5A5280", "#3C3560", "#262046", "#161230"), lw=2.6, depth=10)
        obj(cv, sd_circle(X, Y, 80, 104, 30), GREY_P, lw=2.4, depth=8)
        cv.fill(sd_circle(X, Y, 80, 104, 8), "#3C3560")
        for i in range(4):
            cv.fill(sd_circle(X, Y, 48 + i * 21, 58, 4.5), "#FF9A1F")
    elif kind == "guitar":
        obj(cv, sd_capsule(X, Y, 100, 30, 70, 90, 6), WOOD, lw=2.4, depth=4)
        obj(cv, U(sd_circle(X, Y, 62, 108, 26), sd_circle(X, Y, 50, 126, 20)), RED, lw=3.0, depth=10)
    elif kind == "tire":
        obj(cv, sd_ring(X, Y, 80, 100, 36, 18), ("#5A5280", "#3C3560", "#262046", "#161230"), lw=2.6, depth=8)
    else:
        obj(cv, sd_circle(X, Y, 80, 80, 36), PURPLE, lw=3.0, depth=10)
    soft_shadow(cv, 0, 3, 3, PIECE_SHADOW, 0.28)
    return cv


# ---------------------------------------------------------------------------------------------
# backgrounds (plain PIL at 2x, opaque): a street seen from above, the lane in the middle is free
# ---------------------------------------------------------------------------------------------
def _hex(c):
    c = c.lstrip("#")
    return tuple(int(c[i:i + 2], 16) for i in (0, 2, 4))


def _lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def bg_image(did):
    th = THEMES[did]
    S = 2
    w, h = BG_W * S, BG_H * S
    top, bot = _hex(th["top"]), _hex(th["bottom"])
    arr = np.zeros((h, w, 3), np.uint8)
    for y in range(h):
        arr[y, :] = _lerp(top, bot, y / (h - 1))
    im = Image.fromarray(arr, "RGB")
    dr = ImageDraw.Draw(im, "RGBA")
    # the free lane: a lighter pavement band in the middle
    lane = _hex("#FFFFFF")
    for i in range(24):
        a = int(70 * (1 - i / 24))
        dr.rectangle([(150 + i * 3) * S, 0, (570 - i * 3) * S, h], fill=lane + (a // 6,))
    walls = [_hex(c) for c in th["wall"]]
    acc = _hex(th["accent"])
    # buildings on both sides, deterministic positions; the vertical pattern repeats so tiles can be mirrored
    for side in (0, 1):
        y = 40
        i = 0
        while y < BG_H - 120:
            bh = 150 + (i * 53 + side * 31) % 90
            bw = 120 + (i * 37 + side * 17) % 40
            x0 = 0 if side == 0 else BG_W - bw
            col = walls[(i + side) % 3]
            dr.rounded_rectangle([x0 * S, y * S, (x0 + bw) * S, (y + bh) * S], radius=22 * S, fill=col + (255,))
            dr.rounded_rectangle([x0 * S, y * S, (x0 + bw) * S, (y + 26) * S], radius=14 * S, fill=acc + (255,))
            for wy in range(y + 50, y + bh - 20, 44):
                for wx in range(x0 + 18, x0 + bw - 36, 40):
                    dr.rounded_rectangle([wx * S, wy * S, (wx + 24) * S, (wy + 28) * S], radius=6 * S,
                                         fill=(255, 255, 255, 190))
            y += bh + 24
            i += 1
    # a few pastel puffs along the lane edges
    for k in range(14):
        cx = 150 if k % 2 == 0 else 570
        cy = 40 + k * 76
        dr.ellipse([(cx - 22) * S, (cy - 14) * S, (cx + 22) * S, (cy + 14) * S], fill=acc + (70,))
    return im.resize((BG_W, BG_H), Image.LANCZOS)


def gate_cv(did):
    cv = Canvas(GATE_W // 2, GATE_H // 2, ss=4, out=2)
    X, Y = cv.X, cv.Y
    pal = {"cafe": PINK, "jazz": PURPLE, "square": ORANGE, "stadium": CYAN, "garage": RED}[did]
    # two pillars and an arch over a free lane (180 px wide in the middle), then an empty sign
    for sx in (-1, 1):
        obj(cv, sd_rect(X, Y, 180 + sx * 100 - 22, 70, 180 + sx * 100 + 22, 214, 8), pal, lw=3.0, depth=12)
    arch = sd_rect(X, Y, 28, 30, 332, 92, 28)
    obj(cv, arch, pal, lw=3.0, depth=14)
    sign = sd_rect(X, Y, 108, 40, 252, 84, 14)
    obj(cv, sign, ("#FFFFFF", "#FFF9EA", "#F1E6C8", "#B58A1A"), lw=2.6, depth=8)
    for i in range(9):
        cv.fill(sd_circle(X, Y, 44 + i * 34, 34, 4), "#FFE680", 0.95)
    soft_shadow(cv, 0, 4, 4, PIECE_SHADOW, 0.3)
    return cv


# ---------------------------------------------------------------------------------------------
# job table: (relpath, drawing function, args, kind) consumed by tools/art/gen_art.py
# ---------------------------------------------------------------------------------------------
def jobs():
    out = []
    for st in STATES:
        out.append(("map", f"map/node_day_{st}.png", "draw_node", ("day", st), {}))
        out.append(("map", f"map/node_concert_{st}.png", "draw_node", ("concert", st), {}))
    out.append(("map", "map/path_dot.png", "draw_dot", (False,), {}))
    out.append(("map", "map/path_dot_done.png", "draw_dot", (True,), {}))
    for did in DISTRICTS:
        for i, kind in enumerate(THEMES[did]["deco"]):
            out.append(("map", f"map/deco_{did}_{i + 1}.png", "draw_deco", (kind, THEMES[did]["accent"]), {}))
        out.append(("mapbg", f"mapbg/bg_{did}.png", "bg_image", (did,), {"pil": True}))
        out.append(("mapbg", f"mapbg/gate_{did}.png", "gate_cv", (did,), {}))
    return out


def draw_deco(kind, accent):
    return _deco(kind, accent)
