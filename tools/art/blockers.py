"""Blockers and layers (bright candy style): record box, concrete, noise, balloons, dusty
column, wires, microphone cargo + its stand, dance floor tiles."""
import math
import os

import numpy as np

from artkit import (C, Canvas, F32, WHITE, bez, candy, fit, gblur, gloss_drop, inset, mix, noise2, opening, ramp,
                    rim_gloss, rng, sd_arc, sd_box, sd_capsule, sd_circle, sd_ellipse, sd_poly, sd_polyline,
                    sd_rect, sd_ring, sd_star, sd_taper, smoothstep, soft_shadow, sparkle4, text_sdf, SU, SUB, U, I)
from palette import PIECES, ORDER, PIECE_SHADOW, NOISE, WIRE, WIRE_CORE, CARD, CARD_DARK, FLOOR, FLOOR_LIT_A, \
    FLOOR_LIT_B

FONT_BLACK = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "fonts", "Rubik-Black.ttf")

CARD_PAL = ("#FFDDB0", CARD, "#F29A45", CARD_DARK)
FLAP_PAL = ("#FFF0D6", "#FFD39B", "#F5A95A", CARD_DARK)
CARD_IN = "#E0843A"            # inside of the box (warm, never dark)
VINYL = [("#FFB3D6", "#FF7EB6", "#F0508F", "#C22A6C"),
         ("#B8EEFF", "#5CD6FF", "#23A8E8", "#137DB8"),
         ("#E3CCFF", "#B78AFF", "#8B55F0", "#6230C2")]
LABELS = ["#FFDB1A", "#FFFFFF", "#8BE39A"]


def jag(pts, amp, seed, step=5.0):
    """Resample a polyline and jitter it perpendicular to itself (torn edges, cracks)."""
    g = rng(seed)
    out = []
    for i in range(len(pts) - 1):
        (ax, ay), (bx, by) = pts[i], pts[i + 1]
        L = math.hypot(bx - ax, by - ay)
        n = max(int(L / step), 1)
        nx, ny = -(by - ay) / L, (bx - ax) / L
        for k in range(n):
            t = k / n
            j = (g.random() * 2 - 1) * amp if (i or k) else 0
            out.append((ax + (bx - ax) * t + nx * j, ay + (by - ay) * t + ny * j))
    out.append(pts[-1])
    return out


def crack(cv, pts, width, seed, dark, light=None, amp=2.5, alpha=1.0, clip=None):
    p = jag(pts, amp, seed, step=4.0)
    radii = list(np.linspace(width, width * 0.2, len(p)))
    d = sd_polyline(cv.X, cv.Y, p, radii)
    if clip is not None:
        d = np.maximum(d, clip)
    if light is not None:
        dl = sd_polyline(cv.X, cv.Y, [(x + 1.1, y + 1.3) for x, y in p], radii)
        if clip is not None:
            dl = np.maximum(dl, clip)
        cv.fill(dl, light, 0.9 * alpha)
    cv.fill(d, dark, alpha)


# ------------------------------------------------------------ record box
def _record(cv, cx, cy, r, k, clip=None):
    X, Y = cv.X, cv.Y
    pal = VINYL[k % 3]
    d = sd_circle(X, Y, cx, cy, r)
    if clip is not None:
        d = np.maximum(d, clip)
    candy(cv, d, pal, lw=2.4, depth=8, lift=0.5, shade=0.3, bbox=(cx - r, cy - r, cx + r, cy + r))
    rr = np.hypot(X - cx, Y - cy)
    grooves = np.abs(((rr - r * 0.45) % 3.6) - 1.8) - 0.45
    g = np.maximum(grooves, np.maximum(rr - (r - 4), r * 0.45 - rr))
    if clip is not None:
        g = np.maximum(g, clip)
    cv.fill(g, pal[0], 0.45)
    lab = sd_circle(X, Y, cx, cy, r * 0.36)
    if clip is not None:
        lab = np.maximum(lab, clip)
    cv.fill(lab, LABELS[k % 3])
    cv.stroke(lab, 1.2, pal[3], 0.6)
    hole = sd_circle(X, Y, cx, cy, 2.2)
    if clip is not None:
        hole = np.maximum(hole, clip)
    cv.fill(hole, pal[3], 1)
    sh = np.maximum(sd_arc(X, Y, cx, cy, r * 0.72, math.radians(200), math.radians(255), 3.4), d + 2)
    cv.fill(sh, WHITE, 0.7, soft=0.8)


def draw_record_box(hp):
    cv = Canvas(160, 160)
    X, Y = cv.X, cv.Y
    top = 70 if hp == 3 else (74 if hp == 2 else 80)
    # records standing in the box (behind the front face)
    recs = {3: [(48, top - 12, 32, 0), (112, top - 8, 30, 1), (80, top - 22, 35, 2)],
            2: [(46, top - 6, 31, 0), (114, top - 2, 28, 1), (84, top - 16, 34, 2)],
            1: [(58, top - 4, 30, 0), (104, top - 14, 32, 2)]}[hp]
    back = opening(sd_poly(X, Y, [(20, top - 8), (140, top - 8), (144, top + 8), (16, top + 8)]), 3, cv.ss)
    candy(cv, back, ("#F7B173", CARD_IN, "#D8742A", CARD_DARK), lw=2.4, depth=4, rim=0.1)
    clip_top = Y - (top + 3)
    for (rx, ry, r, k) in recs:
        _record(cv, rx, ry, r, k, clip=clip_top)
    # open flaps
    if hp >= 2:
        lf = opening(sd_poly(X, Y, [(16, top), (48, top), (36, top - 22), (5, top - 12)]), 2.5, cv.ss)
        candy(cv, lf, FLAP_PAL, lw=2.4, depth=5, rim=0.2)
    if hp == 3:
        rf = opening(sd_poly(X, Y, [(112, top), (144, top), (155, top - 12), (124, top - 22)]), 2.5, cv.ss)
        candy(cv, rf, FLAP_PAL, lw=2.4, depth=5, rim=0.2)
    front_pts = [(15, top), (145, top), (140, 148), (20, 148)]
    front = opening(sd_poly(X, Y, front_pts), 6, cv.ss)
    if hp == 1:
        bite = sd_poly(X, Y, jag([(98, top - 4), (150, top - 4), (150, top + 44), (132, top + 30), (118, top + 12)],
                                 2.0, 17, step=4))
        front = SUB(front, bite)
    candy(cv, front, CARD_PAL, lw=3.0, depth=12, lift=0.5, shade=0.3, rim=0.35)
    # tape band (as in the mockup) + corrugation line
    band = I(sd_rect(X, Y, 10, top + 18, 150, top + 29, 0), front + 3)
    cv.fill(band, "#FFE6BF", 0.95)
    cv.fill(np.maximum(sd_capsule(X, Y, 20, top + 8, 140, top + 8, 0.9), front + 4), "#F29A45", 0.6)
    # printed stamp: a little heart-record + three lines
    sx, sy = 48, top + 52 if hp > 1 else top + 46
    stamp = U(sd_ring(X, Y, sx, sy, 10, 3.2), sd_circle(X, Y, sx, sy, 3.2))
    cv.fill(np.maximum(stamp, front + 3), "#FF7EB6", 0.9)
    for k in range(3):
        ln = sd_capsule(X, Y, 66, sy - 7 + k * 7, 104 - k * 10, sy - 7 + k * 7, 1.8)
        cv.fill(np.maximum(ln, front + 3), CARD_DARK, 0.45)
    if hp <= 2:
        # torn corner folded down, a crack and a dent
        tear = sd_poly(X, Y, jag([(106, top + 2), (138, top + 2), (136, top + 34)], 1.6, 13, step=4) +
                       [(120, top + 18)])
        tear = np.maximum(tear, front + 2)
        inset(cv, tear, CARD_IN, depth=5, shadow=0.45, hl=0.1, dark="#B85A18")
        flap = opening(sd_poly(X, Y, [(106, top + 2), (120, top + 18), (136, top + 34), (128, top + 42),
                                      (100, top + 14)]), 1.5, cv.ss)
        candy(cv, flap, FLAP_PAL, lw=2.2, depth=4, rim=0.2)
        crack(cv, [(28, top + 4), (40, top + 18), (36, top + 30)], 1.8, 11, dark=CARD_DARK, light="#FFF0D6",
              clip=front + 2)
    if hp == 1:
        hole_pts = []
        g = rng(5)
        for k in range(40):
            a = 2 * math.pi * k / 40
            r = 1 + 0.2 * (g.random() - 0.5)
            hole_pts.append((70 + 34 * r * math.cos(a), 120 + 19 * r * math.sin(a)))
        hole = np.maximum(sd_poly(X, Y, hole_pts), front + 3)
        inset(cv, hole, CARD_IN, depth=6, shadow=0.5, hl=0.1, dark="#B85A18")
        _record(cv, 64, 132, 24, 1, clip=hole + 0.5)
        cv.stroke(hole - 0.6, 2.4, "#FFF0D6", 0.95)
        cv.stroke(hole + 0.8, 1.2, CARD_DARK, 0.8)
        crack(cv, [(118, top + 34), (110, top + 50), (116, top + 60)], 1.8, 23, dark=CARD_DARK, light="#FFF0D6",
              clip=front + 2)
        # a loose scrap of flap stuck on the left
        scrap = opening(sd_poly(X, Y, [(14, top), (40, top), (30, top - 16), (8, top - 8)]), 2, cv.ss)
        candy(cv, scrap, FLAP_PAL, lw=2.2, depth=4, rim=0.2)
    rim_gloss(cv, front, 80, top + 40, -155, 22, 4.5, 5, alpha=0.55)
    gloss_drop(cv, 30, top + 38, 3.2, 8, math.radians(10), front + 5, alpha=0.6)
    soft_shadow(cv, 0, 2.6, 2.4, PIECE_SHADOW, 0.32)
    return cv


# -------------------------------------------------------------- concrete
STONE = ("#FFFBF3", "#EAE1D1", "#CFC2AA", "#9C8D74")
STONE_TOP = ("#FFFFFF", "#F6EFE3", "#E2D6C0", "#9C8D74")


def draw_concrete(hp):
    cv = Canvas(160, 160)
    X, Y = cv.X, cv.Y
    body = sd_rect(X, Y, 14, 20, 146, 148, 22)
    if hp == 1:
        chunk = sd_poly(X, Y, jag([(108, 10), (156, 10), (156, 72), (140, 58), (126, 50), (116, 30)], 1.5, 9,
                                  step=4))
        body = SUB(body, chunk)
        body = opening(body, 2.0, cv.ss)
    candy(cv, body, STONE, lw=3.0, depth=16, lift=0.55, shade=0.35, rim=0.35)
    # top face (slightly lighter slab)
    tex = noise2(cv.a.shape, 10 * cv.ss, seed=77 + hp, octaves=3)
    w = cv.win(body < 1)
    cv.paint(np.clip(0.5 - (body[w] + 4) * cv.ss, 0, 1) * np.clip(tex[w] - 0.55, 0, 1) * 1.6, C("#D9CDB6"), 0.35, "over", w)
    cv.paint(np.clip(0.5 - (body[w] + 4) * cv.ss, 0, 1) * np.clip(0.4 - tex[w], 0, 1) * 1.8, C("#FFFFFF"), 0.6, "over", w)
    slab = I(sd_rect(X, Y, 14, 20, 146, 56, 20), body)
    cv.fill(np.maximum(slab, body + 3), "#FFFFFF", 0.35, soft=1.5)
    cv.fill(np.maximum(sd_capsule(X, Y, 28, 57, 132, 57, 1.1), body + 5), "#D2C5AD", 0.9)
    cv.fill(np.maximum(sd_capsule(X, Y, 28, 59.5, 132, 59.5, 0.9), body + 5), "#FFFFFF", 0.8)
    # speckles
    g = rng(40 + hp)
    for _ in range(40):
        px, py = 24 + g.random() * 112, 64 + g.random() * 76
        r = 0.9 + g.random() * 1.7
        d = np.maximum(sd_circle(X, Y, px, py, r), body + 6)
        if g.random() < 0.55:
            cv.fill(d, "#C6B798", 0.8)
        else:
            cv.fill(d, "#FFFFFF", 0.85)
    # cute bolts
    for bx in (34, 126):
        if hp == 1 and bx == 126:
            continue
        candy(cv, sd_circle(X, Y, bx, 39, 5), ("#FFFFFF", "#E3E6EE", "#B7BCCB", "#8E8272"), lw=1.4, depth=3)
        cv.fill(sd_capsule(X, Y, bx - 2.6, 39, bx + 2.6, 39, 0.9), "#8E8272", 0.9)
    cdark, clight = "#8E7E64", "#FFFFFF"
    if hp == 1:
        crack(cv, [(116, 56), (98, 76), (104, 94), (84, 116), (90, 142)], 3.0, 3, dark=cdark, light=clight,
              clip=body + 2)
        crack(cv, [(98, 76), (70, 84), (56, 78)], 2.2, 4, dark=cdark, light=clight, clip=body + 2)
        crack(cv, [(30, 62), (42, 86), (36, 102)], 1.8, 5, dark=cdark, light=clight, clip=body + 2)
        crack(cv, [(84, 116), (62, 126), (52, 140)], 1.6, 6, dark=cdark, light=clight, clip=body + 2)
        for (px, py, r) in ((150, 140, 5.5), (140, 150, 3.8)):
            candy(cv, sd_circle(X, Y, px, py, r), STONE, lw=1.4, depth=3)
    else:
        crack(cv, [(124, 64), (112, 80), (118, 92), (108, 104)], 1.8, 7, dark=cdark, light=clight, clip=body + 2)
        crack(cv, [(34, 110), (46, 124), (42, 136)], 1.4, 8, dark=cdark, light=clight, clip=body + 2)
    rim_gloss(cv, body, 80, 84, -145, 30, 4, 5, alpha=0.6)
    soft_shadow(cv, 0, 2.6, 2.4, PIECE_SHADOW, 0.32)
    return cv


# ---------------------------------------------------------------- noise
def draw_noise():
    cv = Canvas(160, 160)
    X, Y = cv.X, cv.Y
    ss = cv.ss
    g = rng(99)
    pts = []
    for k in range(72):
        a = 2 * math.pi * k / 72
        r = 1 + 0.03 * math.sin(5 * a + 1.3) + 0.02 * math.sin(9 * a) + 0.015 * (g.random() - 0.5)
        sq = 1 / max(abs(math.cos(a)), abs(math.sin(a))) ** 0.6
        pts.append((80 + 60 * r * sq * math.cos(a), 80 + 60 * r * sq * math.sin(a)))
    blob = opening(sd_poly(X, Y, pts), 14, ss)
    grain1 = np.repeat(np.repeat(g.random((160, 160)).astype(F32), ss, 0), ss, 1)
    grain2 = np.repeat(np.repeat(g.random((80, 80)).astype(F32), 2 * ss, 0), 2 * ss, 1)
    v = 0.55 * grain1 + 0.45 * grain2
    scan = ((np.floor(Y / 2.0) % 2) == 0).astype(F32)
    v = v * (0.85 + 0.15 * scan)
    for (y0, h, sh) in ((36, 5, 0.22), (90, 3, 0.3), (116, 6, -0.18)):
        band = (Y >= y0) & (Y < y0 + h)
        v = np.where(band, np.clip(v + sh, 0, 1), v)
    basec = C(NOISE)
    col = mix(mix(basec, C("#565A6C"), 0.55), mix(basec, WHITE, 0.62), v[..., None])
    d = np.maximum(-blob, 0)
    col = mix(col, C("#6E7386"), (1 - smoothstep(0, 14, d)) * 0.4)
    cv.paint(np.clip(0.5 - blob * ss, 0, 1), col, 1.0)
    # static dashes (as in the mockup)
    for (x0, y0, w, c, a) in ((34, 44, 18, "#FFFFFF", 0.75), (70, 36, 26, "#4A4E60", 0.8), (46, 70, 34, "#FFFFFF", 0.7),
                              (98, 62, 20, "#4A4E60", 0.8), (30, 98, 24, "#4A4E60", 0.8), (74, 106, 40, "#FFFFFF", 0.75),
                              (44, 124, 18, "#4A4E60", 0.8), (104, 128, 16, "#FFFFFF", 0.7)):
        cv.fill(np.maximum(sd_rect(X, Y, x0, y0, x0 + w, y0 + 5, 2), blob + 5), c, a)
    cv.stroke(blob + 1.5, 3.0, "#5C6072", 1.0)
    rim_gloss(cv, blob, 80, 80, -135, 36, 5, 6, alpha=0.45)
    gloss_drop(cv, 44, 38, 10, 4, math.radians(-30), blob + 6, alpha=0.4)
    soft_shadow(cv, 0, 2.6, 2.4, PIECE_SHADOW, 0.32)
    return cv


# -------------------------------------------------------------- balloon
def draw_balloon(color):
    pal = PIECES[color]
    light, base, shadow, line = pal
    cv = Canvas(160, 160)
    X, Y = cv.X, cv.Y
    s_pts = bez((80, 122), (68, 134), (94, 142), (80, 156), n=24)
    cv.fill(sd_polyline(X, Y, s_pts) - 1.9, line, 1)
    cv.fill(sd_polyline(X, Y, s_pts) - 0.8, WHITE, 0.8)
    body = sd_ellipse(X, Y, 80, 64, 52, 58)
    body = SU(body, sd_ellipse(X, Y, 80, 112, 10, 8), 12)
    candy(cv, body, pal, lw=3.0, depth=36, lift=0.6, shade=0.4, rim=0.5)
    knot = opening(sd_poly(X, Y, [(71, 128), (89, 128), (84, 116), (76, 116)]), 1.8, cv.ss)
    candy(cv, knot, pal, lw=2.2, depth=3, rim=0.2)
    clip = body + 5
    rim_gloss(cv, sd_ellipse(X, Y, 80, 64, 52, 58), 80, 64, -135, 40, 6, 9, alpha=0.8)
    gloss_drop(cv, 58, 38, 11, 7, math.radians(-40), clip, alpha=0.85)
    gloss_drop(cv, 42, 72, 3.6, 3.2, 0, clip, alpha=0.8)
    rim_gloss(cv, sd_ellipse(X, Y, 80, 64, 52, 58), 80, 64, 40, 30, 4, 3.5, alpha=0.35)
    soft_shadow(cv, 0, 2.6, 2.4, PIECE_SHADOW, 0.32)
    return cv


# ------------------------------------------------------ dusty column 2x2
COL_PAL = ("#E9E0FF", "#B8A6FF", "#8B75F0", "#5B45C9")
TRIM = ("#FFFFFF", "#FFFFFF", "#E6DDFF", "#5B45C9")


def _column_base(cv, on):
    X, Y = cv.X, cv.Y
    body = sd_rect(X, Y, 24, 16, 296, 304, 34)
    candy(cv, body, TRIM, lw=4.0, depth=14, lift=0.4, shade=0.3, rim=0.2)
    cab = sd_rect(X, Y, 38, 30, 282, 290, 24)
    candy(cv, cab, COL_PAL, lw=3.0, depth=26, lift=0.5, shade=0.35, rim=0.4, grad_dir=(0.4, 1.0))
    # tweeter horn
    horn = sd_rect(X, Y, 106, 50, 214, 98, 18)
    candy(cv, horn, ("#FFFFFF", "#F4F0FF", "#CFC4FF", "#5B45C9"), lw=3.0, depth=10, rim=0.2)
    throat = sd_rect(X, Y, 128, 62, 192, 86, 11)
    inset(cv, throat, "#FF6FD8" if on else "#E6B8DA", depth=6, shadow=0.45, hl=0.4, dark="#C2279F" if on else "#B98AB0",
          light="#FFE1F8")
    # woofer
    cx, cy = 160.0, 196.0
    sur = sd_circle(X, Y, cx, cy, 82)
    candy(cv, sur, ("#FFFFFF", "#F4F0FF", "#CFC4FF", "#5B45C9"), lw=3.2, depth=12, rim=0.2)
    ring = sd_ring(X, Y, cx, cy, 75, 6)
    candy(cv, ring, ("#FFF7B0", "#FFDB1A", "#F5B800", "#C28A00") if on else
          ("#FFF7DA", "#F2DC8A", "#D9BD60", "#A88A30"), lw=1.2, depth=3)
    cone = sd_circle(X, Y, cx, cy, 68)
    if on:
        inset(cv, cone, "#FF6FD8", depth=22, shadow=0.5, hl=0.4, dark="#C2279F", light="#FFD6F5")
    else:
        inset(cv, cone, "#D9A6D0", depth=22, shadow=0.45, hl=0.3, dark="#A6739E", light="#F6DDF0")
    r = np.hypot(X - cx, Y - cy)
    rings = np.abs(((r - 26) % 13.0) - 6.5) - 1.0
    cv.fill(np.maximum(rings, np.maximum(cone + 3, 27 - r)), "#FFFFFF", 0.3)
    cap = sd_circle(X, Y, cx, cy, 26)
    candy(cv, cap, ("#FFFFFF", "#FFE1F8", "#FF9BE5", "#C2279F") if on else
          ("#FFFFFF", "#F6E6F2", "#DDB9D4", "#A6739E"), lw=2.4, depth=16, rim=0.3)
    cv.fill(sd_ellipse(X, Y, cx - 8, cy - 9, 7, 4, -0.6), WHITE, 0.9, soft=0.5)
    # yellow screws
    for (qx, qy) in ((56, 48), (264, 48), (56, 272), (264, 272)):
        candy(cv, sd_circle(X, Y, qx, qy, 6.5), ("#FFF7B0", "#FFDB1A", "#F5B800", "#C28A00"), lw=1.6, depth=4)
    rim_gloss(cv, body, 160, 160, -135, 32, 5, 9, alpha=0.7)
    gloss_drop(cv, 64, 120, 6, 36, math.radians(4), cab + 5, alpha=0.35)
    return body, (cx, cy)


def draw_column(stage):
    """stage 3 = most dust, 1 = least; 0 = switched on."""
    cv = Canvas(320, 320)
    X, Y = cv.X, cv.Y
    on = stage == 0
    body, (cx, cy) = _column_base(cv, on)
    if not on:
        amount = {3: 0.95, 2: 0.62, 1: 0.3}[stage]
        n = noise2(cv.a.shape, 44 * cv.ss, seed=300, octaves=4)
        n2 = noise2(cv.a.shape, 3 * cv.ss, seed=301, octaves=2)
        topness = smoothstep(220, 20, Y) * 0.35
        edge = smoothstep(26, 0, -body) * 0.25
        field = n * 0.8 + topness + edge
        thr = np.quantile(field[cv.a > 0.5], 1 - amount * 0.9)
        dust = smoothstep(thr - 0.25, thr + 0.15, field) * np.clip(cv.a, 0, 1)
        dust = dust * (0.62 + 0.25 * amount) * (0.8 + 0.2 * n2)
        dcol = mix(C("#D8CFC0"), C("#F3EDE2"), n2[..., None])
        # desaturate what is under the dust first, then lay the powder on top
        lum = (cv.rgb @ np.array([0.3, 0.55, 0.15], F32))[..., None]
        grey = np.repeat(lum, 3, -1)
        k = (dust * 0.8)[..., None]
        cv.rgb = cv.rgb * (1 - k) + grey * k
        cv.paint(dust, dcol, 0.9, "atop")
        g = rng(302)
        grain = np.repeat(np.repeat(g.random((320, 320)).astype(F32), cv.ss, 0), cv.ss, 1)
        cv.paint((dust > 0.3) * (grain > 0.93), C("#FFFFFF"), 0.45, "atop")
        cv.paint((dust > 0.3) * (grain < 0.06), C("#A89880"), 0.35, "atop")
        # powdery lumps on the top edge
        g2 = rng(303 + stage)
        lumps = None
        n_l = {3: 14, 2: 9, 1: 4}[stage]
        for k_ in range(n_l):
            lx = 44 + (232 * (k_ + 0.5) / n_l) + (g2.random() - 0.5) * 12
            lr = (4 + 2.5 * stage) + g2.random() * (3 + 3 * stage)
            dl = sd_ellipse(X, Y, lx, 19, lr * 1.6, lr * 0.8)
            lumps = dl if lumps is None else SU(lumps, dl, 6)
        lumps = np.maximum(lumps, Y - 24)
        candy(cv, lumps, ("#FFFFFF", "#EEE7DA", "#CFC3AE", "#A89880"), lw=1.4, depth=5, rim=0.2)
        # dust bunnies on the woofer rim
        for (bx, by, br) in {3: [(92, 262, 11), (224, 250, 9), (250, 132, 8)], 2: [(96, 260, 9), (236, 140, 7)],
                             1: [(100, 258, 7)]}[stage]:
            bunny = sd_ellipse(X, Y, bx, by, br * 1.4, br)
            candy(cv, bunny, ("#FFFFFF", "#EEE7DA", "#CFC3AE", "#A89880"), lw=1.2, depth=4, rim=0.2)
        # cobwebs
        webs = {3: [(40, 32, 1, 1), (280, 288, -1, -1)], 2: [(280, 32, -1, 1)], 1: []}[stage]
        for (wx, wy, sx, sy) in webs:
            spokes = []
            for k_ in range(5):
                a = math.radians(4 + k_ * 20.5)
                spokes.append(sd_capsule(X, Y, wx, wy, wx + sx * 66 * math.cos(a), wy + sy * 66 * math.sin(a), 0.8))
            web = U(*spokes)
            for rr_ in (18, 32, 46, 60):
                arc_pts = []
                for k_ in range(5):
                    a = math.radians(4 + k_ * 20.5)
                    rw = rr_ * (1 - 0.08 * (k_ % 2))
                    arc_pts.append((wx + sx * rw * math.cos(a), wy + sy * rw * math.sin(a)))
                sag = []
                for i in range(len(arc_pts) - 1):
                    (ax, ay), (bx, by) = arc_pts[i], arc_pts[i + 1]
                    mx, my = (ax + bx) / 2 - sx * 3, (ay + by) / 2 - sy * 3
                    sag += bez((ax, ay), (mx, my), (bx, by), n=6)
                web = np.minimum(web, sd_polyline(X, Y, sag) - 0.8)
            cv.fill(web - 0.8, "#A89880", 0.35)
            cv.fill(web, "#FFFFFF", 0.95)
    else:
        glow = gblur(np.clip(0.5 - sd_circle(X, Y, cx, cy, 68) * cv.ss, 0, 1), 14 * cv.ss / 2)
        cv.paint(np.clip(glow, 0, 1) * np.clip(cv.a, 0, 1), C("#FFB8EE"), 0.35, "atop")
        # rainbow LED strip
        led = sd_capsule(X, Y, 70, 286, 250, 286, 3.6)
        t = np.clip((X - 70) / 180, 0, 1)
        cols = ramp(t, [(i / 5, PIECES[k][1]) for i, k in enumerate(ORDER)])
        w = cv.win(led < 8)
        cv.glow_from(np.clip(0.5 - led * cv.ss, 0, 1), 8, "#FFFFFF", 0.7, mode="over")
        cv.paint(np.clip(0.5 - led[w] * cv.ss, 0, 1), cols[w], 1.0, win=w)
        cv.fill(led + 1.8, WHITE, 0.8)
        for k_ in range(3):
            for (a0, a1, colr) in ((-36, 36, "#3CF2FF"), (144, 216, "#FF4FD8")):
                arc = sd_arc(X, Y, cx, cy, 104 + k_ * 17, math.radians(a0), math.radians(a1), 7 - k_ * 1.5)
                cv.fill(arc, colr, 0.95 - 0.25 * k_)
                cv.fill(arc + 2.2, WHITE, 0.8 - 0.2 * k_)
        for (sx, sy, sz, c) in ((56, 22, 12, "#FFE66D"), (272, 110, 10, "#FFFFFF"), (40, 200, 9, "#FFFFFF"),
                                (286, 250, 12, "#FFE66D")):
            sparkle4(cv, sx, sy, sz, C(c), glow=5, glow_color="#FFFFFF")
        cv.glow_under(22, "#FF6FD8", 0.8)
        cv.glow_under(10, "#3CF2FF", 0.5)
    soft_shadow(cv, 0, 4, 4, PIECE_SHADOW, 0.3)
    return cv


# ------------------------------------------------------------- wires
WIRE_PAL = ("#9A89C2", WIRE, "#46385F", "#34284A")


def _cable(cv, pts, r=5.2):
    X, Y = cv.X, cv.Y
    d = sd_polyline(X, Y, pts) - r
    candy(cv, d, WIRE_PAL, lw=1.6, depth=r * 0.95, bulge=1.3, lift=0.6, shade=0.5, rim=0.3, grad_dir=(0.0, 1.0),
          stops=(0.0, 0.4, 1.0))
    core = sd_polyline(X, Y, [(x, y - r * 0.28) for x, y in pts]) - 1.25
    cv.fill(core, WIRE_CORE, 1.0)
    shine = sd_polyline(X, Y, [(x, y - r * 0.62) for x, y in pts]) - 0.7
    cv.fill(np.maximum(shine, d + 1.5), "#FFFFFF", 0.5)
    return d


def _plug(cv, x, y, ang):
    X, Y = cv.X, cv.Y
    ca, sa = math.cos(ang), math.sin(ang)
    b = sd_box(X, Y, x, y, 10, 6.5, 3.5, ang=ang)
    candy(cv, b, ("#FFE1F8", "#FF7EB6", "#F0508F", "#B3124F"), lw=1.6, depth=4, rim=0.3)
    tipx, tipy = x + ca * 16, y + sa * 16
    t = sd_capsule(X, Y, x + ca * 9, y + sa * 9, tipx, tipy, 2.8)
    candy(cv, t, ("#FFFBD6", "#FFD84D", "#F2A500", "#B87400"), lw=1.2, depth=2.5, rim=0.3)
    cv.fill(sd_circle(X, Y, tipx - ca * 3, tipy - sa * 3, 3.2) + 0.0, "#B87400", 0.0)


def _tie(cv, x, y, ang):
    z = sd_box(cv.X, cv.Y, x, y, 3.2, 10, 1.6, ang=ang)
    candy(cv, z, ("#FFFFFF", "#FFFFFF", "#DAD3EA", "#8E82A8"), lw=1.2, depth=2)


def draw_wires(hp):
    cv = Canvas(160, 160)
    if hp == 2:
        a = bez((-10, 30), (44, 62), (110, 2), (170, 40), n=40)
        _cable(cv, a, 7.0)
        b = bez((-10, 132), (40, 100), (112, 156), (170, 118), n=40)
        _cable(cv, b, 7.0)
        _tie(cv, 36, 48, 0.35)
        _tie(cv, 122, 132, -0.45)
        _tie(cv, 128, 22, -0.5)
    else:
        b = bez((-10, 130), (40, 98), (100, 152), (136, 122), n=40)
        _cable(cv, b, 7.0)
        _plug(cv, 142, 112, math.radians(-50))
        _tie(cv, 52, 112, -0.4)
    soft_shadow(cv, 0, 2.4, 2.2, PIECE_SHADOW, 0.35)
    return cv


# ----------------------------------------------------------- microphone
CHROME = ("#FFFFFF", "#E3E9F7", "#AEB9D3", "#6E7A9C")
GOLD = ("#FFF6C2", "#FFD23F", "#F29E0C", "#B86E00")
PINK = ("#FFB3D6", "#FF5C9A", "#E0306F", "#A8124C")


def draw_mic(size=160, cx=80.0, top=10.0, cv=None, s=1.0):
    """Retro 'capsule' microphone: chrome slatted head, gold yoke, candy-pink handle."""
    cv = cv or Canvas(size, size)
    X, Y = cv.X, cv.Y
    hy = top + 46 * s
    stub = sd_taper(X, Y, cx, hy + 48 * s, cx, top + 138 * s, 14 * s, 10 * s)
    candy(cv, stub, PINK, lw=2.6, depth=9 * s, lift=0.6, rim=0.4, grad_dir=(1.0, 0.25))
    for yy in (top + 112 * s, top + 124 * s):
        cv.fill(np.maximum(np.abs(Y - yy) - 1.3, stub + 2.8), GOLD[1], 0.95)
    yoke = sd_arc(X, Y, cx, hy + 6 * s, 44 * s, math.radians(18), math.radians(162), 9 * s)
    candy(cv, yoke, GOLD, lw=2.4, depth=5 * s, rim=0.3, lift=0.7)
    knob = sd_box(X, Y, cx, hy + 50 * s, 13 * s, 7.5 * s, 4 * s)
    candy(cv, knob, GOLD, lw=2.0, depth=4 * s, rim=0.3)
    head = sd_box(X, Y, cx, hy, 37 * s, 44 * s, 31 * s)
    candy(cv, head, CHROME, lw=3.0, depth=20 * s, lift=0.6, shade=0.45, rim=0.5)
    slat = np.abs(((Y - hy) % (7.0 * s)) - 3.5 * s) - 1.0 * s
    slat = np.maximum(slat, head + 6 * s)
    cv.fill(slat, "#8E99B8", 0.55)
    spine = I(sd_box(X, Y, cx, hy, 5.5 * s, 44 * s, 0), head + 2.5)
    candy(cv, spine, GOLD, lw=1.4, depth=3, rim=0.2)
    badge = opening(sd_star(X, Y, cx, hy + 5 * s, 12 * s, 5.5 * s), 1.5 * s, cv.ss)
    candy(cv, badge, PINK, lw=2.0, depth=5 * s, rim=0.3, lift=0.7)
    rim_gloss(cv, head, cx, hy, -140, 32, 4.5 * s, 7 * s, alpha=0.85)
    gloss_drop(cv, cx - 18 * s, hy - 26 * s, 9 * s, 4.5 * s, math.radians(-40), head + 5, alpha=0.9)
    return cv


def draw_mic_cargo():
    cv = draw_mic()
    cv = fit(cv, 134, 80, 78)
    sparkle4(cv, 130, 30, 9, WHITE, glow=4, glow_color="#FFE66D")
    sparkle4(cv, 30, 118, 6, WHITE, glow=3, glow_color="#FFE66D")
    soft_shadow(cv, 0, 2.6, 2.4, PIECE_SHADOW, 0.32)
    return cv


def draw_mic_stand():
    cv = Canvas(160, 96)
    X, Y = cv.X, cv.Y
    pool = sd_ellipse(X, Y, 80, 82, 64, 12)
    cv.fill(pool, "#FFE66D", 0.55, soft=10)
    pole = sd_capsule(X, Y, 80, 44, 80, 84, 5.5)
    candy(cv, pole, CHROME, lw=2.0, depth=4, rim=0.3, grad_dir=(1.0, 0.0))
    base = sd_ellipse(X, Y, 80, 86, 36, 8)
    candy(cv, base, PINK, lw=2.2, depth=5, rim=0.4)
    cradle = sd_arc(X, Y, 80, 16, 26, math.radians(20), math.radians(160), 9)
    candy(cv, cradle, GOLD, lw=2.4, depth=4.5, rim=0.3, lift=0.7)
    knob = sd_box(X, Y, 80, 44, 10, 5.5, 3)
    candy(cv, knob, GOLD, lw=1.8, depth=3, rim=0.3)
    for k, yy in enumerate((4, 18)):
        ch = sd_polyline(X, Y, [(67, yy), (80, yy + 10), (93, yy)]) - 3.4
        cv.fill(ch - 1.8, "#FF4D8D", 0.9 - 0.3 * k)
        cv.fill(ch, "#FFFFFF", 1.0 - 0.3 * k)
    cv.glow_under(8, "#FFE66D", 0.6)
    soft_shadow(cv, 0, 2, 2, PIECE_SHADOW, 0.25)
    return cv


# ------------------------------------------------------- dance floor tiles
def draw_floor(kind):
    """kind: 2 (double white border), 1 (single border), 'lit' (gold + pink glow). Opaque 160x160."""
    lit = kind == "lit"
    cv = Canvas(160, 160, bg=FLOOR if not lit else FLOOR_LIT_A)
    X, Y = cv.X, cv.Y
    full = sd_rect(X, Y, -4, -4, 164, 164, 0)
    if not lit:
        cv.fill_grad(full, [(0, "#E6DDFF"), (0.5, FLOOR), (1, "#CDBFFA")], axis=(1, 1), p0=0, p1=320)
        refl = np.maximum(np.abs((X - Y) * 0.7071 + 26) - 9, 0 * X)
        cv.fill(refl, "#FFFFFF", 0.18, soft=6)
        borders = (5.0, 19.0) if kind == 2 else (5.0,)
        for k, o in enumerate(borders):
            b = sd_rect(X, Y, o, o, 160 - o, 160 - o, 16 - k * 4)
            cv.stroke(b, 3.6 if k == 0 else 3.0, "#FFFFFF", 1.0)
    else:
        cv.fill_grad(full, [(0, FLOOR_LIT_A), (1, FLOOR_LIT_B)], axis=(1, 1), p0=0, p1=320)
        edge = sd_rect(X, Y, 5, 5, 155, 155, 16)
        ig = smoothstep(-34, 0, edge)
        cv.paint(ig ** 1.6, C("#FF6FD8"), 0.5)
        cv.fill(sd_rect(X, Y, 34, 34, 126, 126, 30), "#FFFFFF", 0.35, soft=22)
        cv.stroke(edge, 3.6, "#FFFFFF", 1.0)
        for (sx, sy, sz) in ((44, 40, 13), (118, 116, 10), (116, 46, 6), (46, 112, 5)):
            sparkle4(cv, sx, sy, sz, WHITE, 0.95)
    return cv
