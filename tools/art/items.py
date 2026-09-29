"""District task items: one bright candy-style object per task (<= 256x256).

Colourful objects with outlines in a darker shade of their own colour (never black), so they read
on the pastel scenes and still read when the engine shows them desaturated and semi-transparent
as "not yet restored".
"""
import math
import os

import numpy as np

from artkit import (C, Canvas, WHITE, bez, candy, contact_shadow, darken, edge_fade, grow, lighten, droplet, gblur,
                    gloss_drop, inset, mix, opening, ramp, rim_gloss, rng,
                    sd_arc, sd_box, sd_capsule, sd_circle, sd_ellipse, sd_poly, sd_polyline, sd_rect, sd_ring,
                    sd_star, sd_taper, smoothstep, soft_shadow, sparkle4, text_sdf, SU, SUB, U, I)
from pieces import note_sdf, pick_sdf
from palette import PIECES
import blockers

FONT = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "fonts", "Rubik-Black.ttf")
INK = "#4A3B6B"          # soft plum ink for small details (never pure black)
EYE = "#2B2345"

# candy palettes: (light, base, shadow, outline)
BRASS = ("#FFF6C2", "#FFD23F", "#F5A300", "#B86E00")
SILVER = ("#FFFFFF", "#E3E9F7", "#AEB9D3", "#6E7A9C")
WOOD = ("#FFD9A3", "#F5A45A", "#DB7A30", "#A5541A")
DKWOOD = ("#FFC79A", "#E08A50", "#C06A30", "#8A4418")
BLACK = ("#C9BCFF", "#8C7BEA", "#6A58D0", "#4632A8")      # "dark" hardware is lavender-violet here
PINKP = ("#FFD1E6", "#FF7EB6", "#F0508F", "#C22A6C")
CREAMP = ("#FFFFFF", "#FFF4E0", "#F2D7B0", "#C28A4E")
SKIN = ("#FFF6EC", "#FFD9B8", "#F2B48A", "#C77A4A")
PIECE_COLS = [PIECES[k][1] for k in ("red", "orange", "yellow", "green", "blue", "purple")]


def _pal(col, light=None, dark=None, line=None):
    if isinstance(col, tuple) and len(col) == 4:
        return col
    if isinstance(col, tuple) and len(col) == 3:
        col, light, dark = col
    b = C(col)
    lt = C(light) if light is not None else mix(b, WHITE, 0.55)
    dk0 = C(dark) if dark is not None else mix(b, C("#3B1E8A"), 0.35)
    sh = mix(b, dk0, 0.5)
    ln = C(line) if line is not None else mix(dk0, C("#2A1650"), 0.15)
    return (lt, b, sh, ln)


def P(cv, d, col, light=None, dark=None, lw=2.6, depth=None, spec=None, line=None, **kw):
    pal = _pal(col, light, dark, line)
    for k in ("grad", "lift_", "spec_pow", "grad_dir_"):
        kw.pop(k, None)
    kw.setdefault("rim", 0.35)
    candy(cv, d, pal, lw=lw, depth=depth, **kw)


def glow(cv, d, color, radius=10, alpha=0.6, mode="under"):
    cv.glow_from(np.clip(0.5 - d * cv.ss, 0, 1), radius, color, alpha, mode=mode)


def hl(cv, pts, r0, r1, clip, alpha=0.7):
    from artkit import droplet
    droplet(cv, bez(*pts, n=10), np.linspace(r0, r1, 11), alpha=alpha, clip_sdf=clip)


def line(cv, pts, w, color=INK, alpha=1.0, clip=None):
    d = sd_polyline(cv.X, cv.Y, pts) - w / 2
    if clip is not None:
        d = np.maximum(d, clip)
    cv.fill(d, color, alpha)


def sparkle(cv, x, y, r, color="#FFFFFF"):
    d = opening(sd_star(cv.X, cv.Y, x, y, r, r * 0.3, n=4, rot=-math.pi / 2), 0.4)
    cv.fill(d - 1.6, "#FFFFFF", 1.0)
    cv.fill(d, color, 1.0)


def keys(cv, x0, y0, x1, y1, n=14, black=True):
    X, Y = cv.X, cv.Y
    bed = sd_rect(X, Y, x0, y0, x1, y1, 1.5)
    cv.fill(bed, "#FFFFFF")
    kw = (x1 - x0) / n
    for i in range(1, n):
        line(cv, [(x0 + i * kw, y0), (x0 + i * kw, y1)], 1.2, "#B9AEDD")
    if black:
        for i in range(n - 1):
            if i % 7 in (2, 6):
                continue
            bx = x0 + (i + 1) * kw
            cv.fill(sd_rect(X, Y, bx - kw * 0.3, y0, bx + kw * 0.3, y0 + (y1 - y0) * 0.6, 1.2), "#4A3B6B")
    cv.stroke(bed, 2.0, INK)


# ============================================================== CAFE
def item_turntable():
    cv = Canvas(240, 230)
    X, Y = cv.X, cv.Y
    for lx in (46, 194):
        P(cv, sd_taper(X, Y, lx, 196, lx + (6 if lx < 100 else -6), 224, 6, 4.5), DKWOOD)
    cab = sd_rect(X, Y, 26, 110, 214, 204, 10)
    P(cv, cab, WOOD, depth=12)
    shelf = sd_rect(X, Y, 40, 124, 200, 192, 6)
    inset(cv, shelf, "#FFE3C2", depth=8, shadow=0.45, dark="#E0A060", light="#FFFFFF")
    for k, c in enumerate(("#FF4FD8", "#3CF2FF", "#FFE66D", "#22D98A", "#FF8C1A", "#8E3DFF")):
        x = 48 + k * 25
        sl = sd_rect(X, Y, x, 132 + (k % 2) * 6, x + 20, 190, 2)
        P(cv, sl, c, lw=1.8, depth=4, spec=0.2)
        cv.fill(np.maximum(sd_circle(X, Y, x + 10, 158 + (k % 2) * 3, 5.5), sl + 2), "#FFFFFF", 0.85)
    base = sd_rect(X, Y, 34, 70, 206, 112, 8)
    P(cv, base, ("#E4D6FF", "#B89CFF", "#8B6BF0", "#5A2FE0"), depth=10)
    plat = sd_ellipse(X, Y, 108, 82, 60, 17)
    P(cv, plat, ("#9C8CFF", "#6B4CE0", "#4B35C0", "#3B2A8F"), lw=2.4, depth=6)
    rr = np.hypot((X - 108) / 60, (Y - 82) / 17)
    gro = np.maximum(np.abs(((rr * 10) % 1.0) - 0.5) - 0.2, np.maximum(plat + 3, 0.36 - rr))
    cv.fill(gro * 2, "#A99AFF", 0.7)
    cv.fill(sd_ellipse(X, Y, 108, 82, 20, 6), "#FF4FD8")
    cv.fill(sd_ellipse(X, Y, 108, 82, 3, 1.5), INK)
    cv.fill(np.maximum(sd_arc(X, Y, 108, 82, 44, math.radians(200), math.radians(250), 3), plat + 3), WHITE, 0.35)
    # tonearm
    P(cv, sd_circle(X, Y, 184, 76, 9), SILVER, lw=2, depth=5)
    arm = sd_polyline(X, Y, [(184, 76), (176, 94), (146, 100)]) - 3
    P(cv, arm, SILVER, lw=1.8, depth=3)
    P(cv, sd_box(X, Y, 142, 101, 7, 4, 2, ang=0.2), "#FF4FD8", lw=1.6, depth=2)
    for kx in (50, 66):
        P(cv, sd_circle(X, Y, kx, 100, 5), BRASS, lw=1.6, depth=3)
    return cv


def item_lamps():
    cv = Canvas(220, 256)
    X, Y = cv.X, cv.Y
    lamps = [(48, 120, 64, "#2FA7A0"), (116, 176, 70, "#E8A33A"), (180, 104, 58, "#D9476A")]
    for (x, y, w, col) in lamps:
        line(cv, [(x, 0), (x, y - 40)], 3.2)
    for (x, y, w, col) in lamps:
        bulb = sd_circle(X, Y, x, y + 4, w * 0.2)
        glow(cv, sd_ellipse(X, Y, x, y + 20, w * 0.55, 30), "#FFD27A", 16, 0.55, mode="over")
        P(cv, bulb, "#FFF3C4", "#FFFFFF", "#FFC24A", lw=2.2, depth=6, spec=0.2)
        shade = I(sd_ellipse(X, Y, x, y, w / 2, w * 0.5), Y - y)
        shade = SU(shade, sd_capsule(X, Y, x, y - w * 0.45, x, y - w * 0.62, 6), 4)
        P(cv, shade, col, depth=14, spec=0.5)
        cv.fill(np.maximum(np.abs(Y - (y - 4)) - 1.8, shade + 2.5), lighten(col, 0.5), 0.7)
    return cv


def item_piano():
    cv = Canvas(256, 240)
    X, Y = cv.X, cv.Y
    body = sd_rect(X, Y, 20, 26, 236, 222, 10)
    P(cv, body, PINKP, depth=14)
    top = sd_rect(X, Y, 12, 16, 244, 36, 6)
    P(cv, top, ("#FFE1EE", "#FF9CC6", "#F0508F", "#C22A6C"), depth=6)
    panel = sd_rect(X, Y, 40, 44, 216, 110, 8)
    inset(cv, panel, "#FFB3D1", depth=6, shadow=0.45, dark="#F0508F", light="#FFFFFF")
    # sheet music
    sheet = sd_box(X, Y, 128, 76, 34, 26, 2, ang=-0.04)
    P(cv, sheet, "#FFF8E8", "#FFFFFF", "#D8C8A8", lw=2, depth=4, spec=0.0)
    for k in range(4):
        line(cv, [(100, 62 + k * 8), (156, 62 + k * 8 - 2)], 1.0, "#6A5A70", 0.8)
    for (nx, ny) in ((108, 66), (122, 78), (138, 70), (150, 82)):
        cv.fill(sd_ellipse(X, Y, nx, ny, 3.2, 2.4, ang=-0.4), "#2B2345")
    # candles
    for cx in (30, 226):
        P(cv, sd_rect(X, Y, cx - 4, 16, cx + 4, 30, 2), "#FFF3E0", "#FFFFFF", "#D9C4A0", lw=1.8, depth=3)
    for cx in (30, 226):
        fl = SU(sd_circle(X, Y, cx, 12, 4.2), sd_poly(X, Y, [(cx - 3, 11), (cx + 3, 11), (cx, 1)]), 2)
        glow(cv, fl, "#FFD27A", 8, 0.8, mode="over")
        P(cv, fl, "#FFD23F", "#FFFBD8", "#FF8C1A", lw=1.4, depth=3, spec=0.2)
    ledge = sd_rect(X, Y, 16, 112, 240, 126, 4)
    P(cv, ledge, ("#FFE1EE", "#FF9CC6", "#F0508F", "#C22A6C"), depth=5)
    keys(cv, 24, 126, 232, 152, n=21)
    lower = sd_rect(X, Y, 40, 160, 216, 208, 8)
    inset(cv, lower, "#FFB3D1", depth=6, shadow=0.45, dark="#F0508F", light="#FFFFFF")
    cv.stroke(sd_rect(X, Y, 54, 170, 202, 198, 6), 2.4, "#FFE1EE", 0.9)
    for px in (112, 128, 144):
        P(cv, sd_box(X, Y, px, 220, 4, 6, 2), BRASS, lw=1.6, depth=3)
    hl(cv, ((30, 170), (28, 90), (40, 40)), 4, 1.5, body + 4, alpha=0.3)
    return cv


def _leaf(cv, x, y, L, W, ang, col=("#3DBB6E", "#9CF0B8", "#1C7A45"), split=True):
    X, Y = cv.X, cv.Y
    ca, sa = math.cos(ang), math.sin(ang)
    tip = (x + ca * L, y + sa * L)
    mid = (x + ca * L * 0.5, y + sa * L * 0.5)
    d = sd_ellipse(X, Y, mid[0], mid[1], L / 2, W / 2, ang=ang)
    if split:
        for k in (-1, 1):
            for t in (0.35, 0.6):
                px, py = x + ca * L * t, y + sa * L * t
                nx, ny = -sa * k, ca * k
                cut = sd_capsule(X, Y, px + nx * W * 0.2, py + ny * W * 0.2, px + nx * W * 0.6 + ca * 6,
                                 py + ny * W * 0.6 + sa * 6, 2.2)
                d = SUB(d, cut)
    P(cv, d, col, lw=2.2, depth=8, spec=0.35)
    line(cv, [(x, y), tip], 1.8, col[2], 0.8, clip=d + 2)
    return d


def item_plants():
    cv = Canvas(180, 240)
    X, Y = cv.X, cv.Y
    for (x, y, L, W, a) in ((90, 140, 96, 50, -2.3), (90, 140, 100, 52, -0.85), (90, 140, 110, 54, -1.6),
                            (88, 150, 80, 42, -2.9), (92, 150, 80, 42, -0.2), (90, 146, 70, 38, -1.95),
                            (90, 146, 72, 38, -1.2)):
        line(cv, [(90, 170), (x + math.cos(a) * 10, y + math.sin(a) * 10)], 4, "#1C7A45")
        _leaf(cv, x + math.cos(a) * 8, y + math.sin(a) * 8, L, W, a)
    pot = opening(sd_poly(X, Y, [(40, 160), (140, 160), (128, 234), (52, 234)]), 6)
    P(cv, pot, "#E07A4A", "#FFC09A", "#8E3A1A", depth=14)
    rim = sd_rect(X, Y, 34, 152, 146, 172, 6)
    P(cv, rim, "#EE8A58", "#FFD0B0", "#8E3A1A", depth=6)
    cv.fill(np.maximum(sd_ring(X, Y, 90, 204, 14, 3), pot + 4), "#FFE3C9", 0.7)
    return cv


def item_cat():
    cv = Canvas(210, 150)
    X, Y = cv.X, cv.Y
    fur = ("#F29E4C", "#FFD9A8", "#A8541A")
    tail = sd_polyline(X, Y, bez((150, 132), (196, 130), (200, 90), (180, 74), n=16),
                       list(np.linspace(9, 6, 17)))
    P(cv, tail, fur, depth=6)
    body = SU(sd_ellipse(X, Y, 118, 104, 64, 40), sd_ellipse(X, Y, 84, 120, 40, 22), 10)
    P(cv, body, fur, depth=22, spec=0.2)
    for k in range(4):
        x = 120 + k * 16
        line(cv, bez((x, 66), (x + 6, 80), (x + 2, 94), n=6), 4.5, "#C86A26", 0.8, clip=body + 3)
    head = SU(sd_circle(X, Y, 60, 74, 34),
              U(opening(sd_poly(X, Y, [(30, 58), (34, 16), (58, 42)]), 3),
                opening(sd_poly(X, Y, [(66, 40), (90, 14), (92, 56)]), 3)), 6)
    P(cv, head, fur, depth=18, spec=0.25)
    for (a, b, c) in (((36, 50), (38, 26), (52, 42)), ((72, 42), (86, 24), (86, 50))):
        cv.fill(opening(sd_poly(X, Y, [a, b, c]), 2), "#FF9EB5", 0.9)
    for ex in (46, 74):
        cv.fill(sd_arc(X, Y, ex, 70, 8, math.radians(20), math.radians(160), 3.2), INK)
    cv.fill(sd_poly(X, Y, [(56, 84), (64, 84), (60, 89)]), "#FF6F91")
    line(cv, [(60, 89), (60, 94)], 1.8)
    for k in (-1, 1):
        for dy in (-3, 4):
            line(cv, [(60 + k * 16, 88), (60 + k * 40, 88 + dy * 1.6)], 1.4, INK, 0.8)
    paw = U(sd_ellipse(X, Y, 50, 132, 14, 9), sd_ellipse(X, Y, 78, 134, 14, 9))
    P(cv, paw, "#FFE3C0", "#FFFFFF", "#C98A50", depth=5)
    return cv


def item_sign():
    cv = Canvas(256, 160)
    X, Y = cv.X, cv.Y
    for x in (70, 186):
        line(cv, [(x, 0), (x, 24)], 3.0, "#3A3050")
    board = sd_rect(X, Y, 10, 20, 246, 150, 18)
    P(cv, board, PINKP, depth=10)
    face = sd_rect(X, Y, 22, 32, 234, 138, 12)
    inset(cv, face, "#FFFFFF", depth=8, shadow=0.35, dark="#FFB3D1", light="#FFFFFF")
    # marquee bulbs
    for k in range(18):
        t = k / 18
        per = 2 * (212 + 106)
        s = t * per
        if s < 212:
            bx, by = 22 + s, 26
        elif s < 212 + 106:
            bx, by = 240, 32 + (s - 212)
        elif s < 424 + 106:
            bx, by = 234 - (s - 318), 144
        else:
            bx, by = 16, 138 - (s - 530)
        glow(cv, sd_circle(X, Y, bx, by, 3), "#FFE66D", 5, 0.6, mode="over")
        P(cv, sd_circle(X, Y, bx, by, 4.2), "#FFF3B0", "#FFFFFF", "#E0A000", lw=1.5, depth=3, spec=0.5)
    txt = text_sdf(cv, "CAFÉ", FONT, 44, 160, 90)
    cv.fill(txt - 3.0, "#FFFFFF")
    P(cv, txt, ("#FFB3D6", "#FF5C9A", "#E0306F", "#A8124C"), lw=2.2, depth=5)
    # coffee cup
    cup = U(sd_rect(X, Y, 34, 82, 66, 116, 9), sd_ring(X, Y, 68, 96, 7, 4.5))
    P(cv, cup, "#FFF6E5", "#FFFFFF", "#D9C4A0", lw=2.2, depth=6)
    cv.fill(sd_ellipse(X, Y, 50, 84, 14, 3.5), "#C77A4A")
    for sx in (44, 56):
        line(cv, bez((sx, 76), (sx - 5, 66), (sx + 4, 58), (sx - 2, 48), n=10), 3, "#FFB3D1", 0.9)
    return cv


# ============================================================== JAZZ
def item_stage_light():
    cv = Canvas(220, 240)
    X, Y = cv.X, cv.Y
    beams = cv.blank()
    for (x, ang) in ((62, 0.25), (158, -0.25)):
        ca, sa = math.sin(ang), math.cos(ang)
        pts = [(x - 10, 70), (x + 10, 70), (x + 10 + 150 * ca + 44, 70 + 150 * sa), (x - 10 + 150 * ca - 44, 70 + 150 * sa)]
        beams.fill(sd_poly(X, Y, pts), "#FFE066", 0.7, soft=6)
        core = [(x - 5, 70), (x + 5, 70), (x + 5 + 150 * ca + 18, 70 + 150 * sa), (x - 5 + 150 * ca - 18, 70 + 150 * sa)]
        beams.fill(sd_poly(X, Y, core), "#FFFFFF", 0.6, soft=5)
    beams.paint(smoothstep(90, 236, Y), C("#000000"), 1.0, "erase")
    cv.over(beams)
    truss = sd_rect(X, Y, 4, 10, 216, 26, 4)
    P(cv, truss, SILVER, depth=5)
    for k in range(11):
        x = 12 + k * 19.5
        line(cv, [(x, 12), (x + 10, 24)], 1.6, "#6A6F85", 0.8, clip=truss + 2)
    for (x, ang) in ((62, 0.25), (158, -0.25)):
        line(cv, [(x, 24), (x, 40)], 5, INK)
        yoke = sd_arc(X, Y, x, 56, 24, math.radians(200), math.radians(340), 5)
        P(cv, yoke, BLACK, lw=2, depth=3)
        can = sd_box(X, Y, x, 60, 18, 24, 7, ang=ang)
        P(cv, can, BLACK, depth=10, spec=0.5)
        lx, ly = x + math.sin(ang) * 26, 60 + math.cos(ang) * 24
        lens = sd_ellipse(X, Y, lx, ly, 17, 6, ang=-ang)
        glow(cv, lens, "#FFE66D", 10, 0.9, mode="over")
        P(cv, lens, "#FFF6C0", "#FFFFFF", "#FFC83D", lw=2, depth=4, spec=0.6)
    return cv


def item_grand_piano():
    cv = Canvas(256, 210)
    X, Y = cv.X, cv.Y
    for (x0, x1) in ((40, 48), (196, 204), (120, 128)):
        P(cv, sd_taper(X, Y, (x0 + x1) / 2, 150, (x0 + x1) / 2, 198, 7, 5), BLACK, depth=4)
        P(cv, sd_ellipse(X, Y, (x0 + x1) / 2, 200, 9, 5), BRASS, lw=1.8, depth=3)
    # lid (propped open)
    lid = opening(sd_poly(X, Y, [(40, 92), (236, 92), (224, 30), (120, 8), (60, 40)]), 4)
    P(cv, lid, BLACK, depth=12, spec=0.7)
    line(cv, [(150, 92), (132, 30)], 4, "#3A3456")
    body_pts = [(20, 96)] + bez((200, 96), (250, 100), (246, 150), n=10) + [(200, 156), (20, 156)]
    body = opening(sd_poly(X, Y, [(20, 96)] + bez((196, 96), (250, 100), (240, 156), n=12) + [(20, 156)]), 6)
    P(cv, body, BLACK, depth=14, spec=0.8)
    cv.fill(np.maximum(np.abs(Y - 108) - 2.0, body + 3), "#FFC23D", 0.9)
    keysbed = sd_rect(X, Y, 8, 116, 66, 140, 3)
    P(cv, keysbed, BLACK, depth=4)
    keys(cv, 12, 118, 64, 134, n=8)
    hl(cv, ((110, 104), (160, 100), (210, 104)), 3.5, 1.5, body + 4, alpha=0.5)
    hl(cv, ((80, 60), (120, 34), (160, 26)), 3.5, 1.3, lid + 4, alpha=0.45)
    del body_pts
    return cv


def item_double_bass():
    cv = Canvas(150, 256)
    X, Y = cv.X, cv.Y
    lay = cv.blank()
    Xl, Yl = lay.X, lay.Y
    body = SU(SU(sd_ellipse(Xl, Yl, 75, 190, 52, 52), sd_ellipse(Xl, Yl, 75, 126, 40, 38), 18),
              sd_ellipse(Xl, Yl, 75, 158, 30, 20), 6)
    body = SUB(body, U(sd_circle(Xl, Yl, 26, 158, 14), sd_circle(Xl, Yl, 124, 158, 14)))
    body = opening(body, 3)
    P(lay, body, ("#C8682E", "#FFB77A", "#6E2A0A"), depth=22, spec=0.5)
    for sx in (-1, 1):
        fh = sd_polyline(Xl, Yl, bez((75 + sx * 20, 140), (75 + sx * 12, 160), (75 + sx * 22, 184), n=10)) - 2.2
        lay.fill(fh, INK)
    neck = sd_rect(Xl, Yl, 68, 18, 82, 176, 5)
    P(lay, neck, BLACK, depth=5)
    scroll = U(sd_circle(Xl, Yl, 75, 14, 10), sd_rect(Xl, Yl, 69, 14, 81, 40, 4))
    P(lay, scroll, ("#C8682E", "#FFB77A", "#6E2A0A"), depth=6)
    for k in (-1, 1):
        P(lay, sd_box(Xl, Yl, 75 + k * 12, 28, 5, 3, 1.5), BRASS, lw=1.4, depth=2)
    bridge = sd_rect(Xl, Yl, 60, 196, 90, 204, 2)
    P(lay, bridge, "#F4D7A8", "#FFFFFF", "#B8904A", lw=1.8, depth=3)
    tp = opening(sd_poly(Xl, Yl, [(66, 208), (84, 208), (80, 238), (70, 238)]), 2)
    P(lay, tp, BLACK, lw=2, depth=3)
    for k in range(4):
        x = 70.5 + k * 3
        lay.fill(sd_capsule(Xl, Yl, x, 30, x + (k - 1.5) * 1.2, 232, 0.55), "#F4F0E0", 0.9)
    P(lay, sd_capsule(Xl, Yl, 75, 240, 75, 254, 3), SILVER, lw=1.5, depth=2)
    hl(lay, ((36, 196), (36, 164), (52, 146)), 4, 1.5, body + 4, alpha=0.5)
    lay = grow(lay, 10, 0, 10, 16)
    return lay.transformed(8, pivot=(85, 250))


def item_neon():
    cv = Canvas(256, 150)
    X, Y = cv.X, cv.Y
    board = sd_rect(X, Y, 8, 14, 248, 138, 16)
    P(cv, board, ("#9C8CFF", "#6B4CE0", "#4B35C0", "#3B2A8F"), depth=8)
    for (x, y) in ((22, 26), (234, 26), (22, 126), (234, 126)):
        P(cv, sd_circle(X, Y, x, y, 4), SILVER, lw=1.4, depth=2)
    txt = text_sdf(cv, "JAZZ", FONT, 64, 128, 70, tracking=4)
    tube = np.abs(txt + 3.2) - 2.6
    glow(cv, tube, "#FF4FD8", 12, 1.0, mode="over")
    cv.fill(tube - 1.2, "#7A0F68", 0.9)
    cv.fill(tube, "#FFB8F1")
    cv.fill(tube + 1.4, "#FFFFFF", 0.9)
    # underline swoosh + note in cyan
    sw = sd_polyline(X, Y, bez((40, 118), (100, 104), (160, 124), (214, 108), n=20)) - 2.6
    glow(cv, sw, "#3CF2FF", 8, 1.0, mode="over")
    cv.fill(sw, "#B8FCFF")
    cv.fill(sw + 1.3, "#FFFFFF", 0.9)
    return cv


def item_sax():
    cv = Canvas(170, 250)
    X, Y = cv.X, cv.Y
    tube_pts = bez((96, 40), (92, 120), (86, 196), (110, 214), n=24) + bez((110, 214), (132, 226), (138, 170), n=12)[1:]
    radii = list(np.linspace(10, 20, len(tube_pts)))
    tube = sd_polyline(X, Y, tube_pts, radii)
    bell = sd_ellipse(X, Y, 138, 162, 26, 12, ang=-0.25)
    body = SU(tube, bell, 6)
    P(cv, body, BRASS, depth=14, spec=0.8)
    inset(cv, sd_ellipse(X, Y, 138, 160, 20, 7, ang=-0.25), "#F5B530", depth=4, shadow=0.45, dark="#C27400", light="#FFF3B0")
    neck = sd_polyline(X, Y, bez((96, 44), (96, 20), (70, 12), (52, 20), n=14), list(np.linspace(7, 4, 15)))
    P(cv, neck, BRASS, lw=2.2, depth=5, spec=0.8)
    P(cv, sd_box(X, Y, 44, 24, 12, 5, 3, ang=0.3), BLACK, lw=2, depth=3)
    for k in range(7):
        t = 0.15 + k * 0.1
        kx, ky = tube_pts[int(t * 24)]
        P(cv, sd_circle(X, Y, kx - 12, ky, 5.2), "#FFF6E0", "#FFFFFF", "#B8904A", lw=1.6, depth=3, spec=0.6)
        line(cv, [(kx - 12, ky), (kx - 2, ky)], 1.6, "#B86E00")
    hl(cv, ((84, 60), (82, 120), (80, 170)), 3.2, 1.2, body + 4, alpha=0.7)
    return cv


def item_vibes():
    cv = Canvas(256, 190)
    X, Y = cv.X, cv.Y
    for x in (40, 216):
        P(cv, sd_rect(X, Y, x - 5, 96, x + 5, 170, 2), SILVER, lw=2, depth=3)
        P(cv, sd_circle(X, Y, x, 176, 8), BLACK, lw=2, depth=4)
    P(cv, sd_rect(X, Y, 36, 140, 220, 148, 3), SILVER, lw=2, depth=3)
    frame = sd_rect(X, Y, 14, 64, 242, 100, 8)
    P(cv, frame, "#3A2E4E", "#7A6C9E", "#18122A", depth=8)
    n = 11
    for k in range(n):
        x = 24 + k * 19.5
        L = 60 - k * 2.4
        tube = sd_rect(X, Y, x + 4, 100, x + 12, 100 + L * 0.9, 3)
        P(cv, tube, "#C9CCD8", "#FFFFFF", "#6E7390", lw=1.6, depth=3, spec=0.6)
        bar = sd_rect(X, Y, x, 70 - (60 - L) * 0.1, x + 16, 96 + (60 - L) * 0.1, 3)
        P(cv, bar, BRASS if k % 2 == 0 else ("#E8ECF5", "#FFFFFF", "#8A90A8"), lw=1.8, depth=4, spec=0.7)
    for (x0, y0, x1, y1) in ((70, 58, 110, 16), (150, 60, 186, 20)):
        line(cv, [(x0, y0), (x1, y1)], 3.2, "#6A3616")
        P(cv, sd_circle(X, Y, x1, y1, 9), "#FF4FD8", "#FFB8F1", "#8E1680", lw=2, depth=5)
    return cv


def item_trumpet(mute=True, h=150, rot=-10):
    cv = Canvas(240, h)
    X, Y = cv.X, cv.Y
    lay = cv.blank()
    Xl, Yl = lay.X, lay.Y
    loop = sd_polyline(Xl, Yl, [(60, 76), (150, 76)] + bez((150, 76), (176, 76), (176, 104), (150, 104), n=10) +
                       [(80, 104)] + bez((80, 104), (56, 104), (56, 90), n=6), None) - 5
    P(lay, loop, BRASS, lw=2.2, depth=4, spec=0.8)
    lead = sd_capsule(Xl, Yl, 20, 76, 150, 76, 6)
    P(lay, lead, BRASS, lw=2.2, depth=5, spec=0.8)
    bell = opening(sd_poly(Xl, Yl, [(150, 70), (150, 82), (200, 106), (206, 46)]), 3)
    bell = SU(bell, sd_ellipse(Xl, Yl, 204, 76, 12, 32), 4)
    P(lay, bell, BRASS, depth=12, spec=0.9)
    P(lay, sd_rect(Xl, Yl, 10, 70, 26, 82, 4), SILVER, lw=2, depth=3)
    for k in range(3):
        x = 96 + k * 18
        P(lay, sd_rect(Xl, Yl, x - 6, 58, x + 6, 112, 3), BRASS, lw=2, depth=4, spec=0.8)
        P(lay, sd_ellipse(Xl, Yl, x, 54, 9, 5), "#FFF6E0", "#FFFFFF", "#B8904A", lw=1.8, depth=3)
    if mute:
        m = opening(sd_poly(Xl, Yl, [(198, 58), (198, 94), (230, 86), (230, 66)]), 4)
        P(lay, m, PINKP, lw=2.4, depth=8)
        P(lay, sd_ellipse(Xl, Yl, 230, 76, 6, 11), ("#FFB3D6", "#F0508F", "#C22A6C", "#8A1450"), lw=2, depth=4)
    hl(lay, ((160, 64), (180, 58), (196, 52)), 2.6, 1.0, bell + 3, alpha=0.7)
    cv.over(lay.transformed(rot, pivot=(120, 80)) if rot else lay)
    return cv


# ============================================================== SQUARE
def item_fountain():
    cv = Canvas(256, 210)
    X, Y = cv.X, cv.Y
    stone = ("#E3CFA8", "#FFF3DA", "#9A7A52")
    water = ("#5FD3FF", "#D8F6FF", "#1A7FC9")
    base = sd_ellipse(X, Y, 128, 176, 118, 28)
    P(cv, base, stone, depth=14)
    rim_top = sd_ellipse(X, Y, 128, 162, 110, 22)
    P(cv, rim_top, stone, depth=8)
    pool = sd_ellipse(X, Y, 128, 162, 96, 15)
    inset(cv, pool, water[0], depth=6, shadow=0.5, dark=water[2], light=water[1])
    for k in range(3):
        cv.fill(np.maximum(sd_ellipse(X, Y, 128, 164, 30 + k * 22, 5 + k * 3.2) , pool + 2) * 1
                if False else np.maximum(np.abs(sd_ellipse(X, Y, 128, 164, 30 + k * 22, 5 + k * 3.2)) - 1.0, pool + 2),
                "#FFFFFF", 0.5)
    col = sd_rect(X, Y, 116, 90, 140, 160, 6)
    P(cv, col, stone, depth=8)
    bowl = I(sd_ellipse(X, Y, 128, 88, 48, 20), Y - 84)
    bowl = U(bowl, sd_ellipse(X, Y, 128, 84, 50, 9))
    P(cv, bowl, stone, depth=8)
    inset(cv, sd_ellipse(X, Y, 128, 84, 42, 6), water[0], depth=3, shadow=0.4, dark=water[2], light=water[1])
    top = sd_rect(X, Y, 122, 50, 134, 84, 4)
    P(cv, top, stone, depth=4)
    # jets and falling water
    jet = sd_polyline(X, Y, [(128, 52), (128, 14)], [4, 2]) if False else sd_taper(X, Y, 128, 52, 128, 12, 4.5, 2)
    P(cv, jet, water, lw=1.6, depth=3, spec=0.5)
    for sgn in (-1, 1):
        arc = sd_polyline(X, Y, bez((128, 16), (128 + sgn * 40, -2), (128 + sgn * 46, 60), n=16),
                          list(np.linspace(3.2, 2.2, 17)))
        P(cv, arc, water, lw=1.4, depth=2, spec=0.5)
        fall = sd_polyline(X, Y, bez((128 + sgn * 48, 90), (128 + sgn * 62, 110), (128 + sgn * 66, 158), n=14),
                           list(np.linspace(4, 2.5, 15)))
        P(cv, fall, water, lw=1.4, depth=2, spec=0.5)
    for (x, y, r) in ((60, 150, 4), (190, 152, 4.5), (84, 140, 3), (170, 142, 3), (128, 6, 3.5)):
        P(cv, sd_circle(X, Y, x, y, r), water, lw=1.2, depth=2, spec=0.6)
    return cv


PIECE_COLS = ["#FF3B5C", "#FF8C1A", "#FFD60A", "#22D98A", "#2F9BFF", "#8E3DFF"]


def item_garlands():
    """Bunting strung between the two side houses of the square (hooks drawn by the background)."""
    cv = Canvas(300, 96)
    X, Y = cv.X, cv.Y
    pts = bez((2, 10), (150, 50), (298, 10), n=48)
    for k in range(13):
        t = (k + 0.5) / 13
        i = int(t * 48)
        x, y = pts[i]
        (xa, ya), (xb, yb) = pts[max(i - 1, 0)], pts[min(i + 1, 48)]
        ang = math.atan2(yb - ya, xb - xa)
        ca, sa = math.cos(ang), math.sin(ang)
        w, h = 9.5, 27
        tri = [(x - ca * w, y - sa * w), (x + ca * w, y + sa * w), (x - sa * h, y + ca * h)]
        d = opening(sd_poly(X, Y, tri), 1.5)
        col = PIECE_COLS[k % 6]
        P(cv, d, col, lw=2.0, depth=5, spec=0.4)
    line(cv, pts, 2.6, INK)
    for k in range(12):
        t = (k + 1) / 13
        x, y = pts[int(t * 48)]
        glow(cv, sd_circle(X, Y, x, y + 4, 2.6), "#FFE66D", 5, 0.8, mode="over")
        P(cv, sd_circle(X, Y, x, y + 4, 3.6), "#FFF3B0", "#FFFFFF", "#E0A000", lw=1.3, depth=3, spec=0.6)
    return cv


def item_truck_stage():
    cv = Canvas(256, 220)
    X, Y = cv.X, cv.Y
    # cab
    cab = opening(sd_poly(X, Y, [(186, 96), (232, 96), (250, 140), (250, 186), (186, 186)]), 8)
    P(cv, cab, "#FF8C1A", "#FFC380", "#A84A00", depth=14)
    win = opening(sd_poly(X, Y, [(196, 106), (228, 106), (240, 138), (196, 138)]), 4)
    inset(cv, win, "#7FD8FF", depth=4, shadow=0.4, dark="#2A7AB8", light="#E0F8FF")
    P(cv, sd_rect(X, Y, 236, 160, 252, 170, 3), "#FFF3B0", "#FFFFFF", "#E0A000", lw=1.6, depth=3)
    # stage box (open side)
    box = sd_rect(X, Y, 6, 60, 190, 186, 8)
    P(cv, box, "#8E3DFF", "#C9A3FF", "#4A0FA0", depth=12)
    inner = sd_rect(X, Y, 18, 72, 178, 164, 6)
    inset(cv, inner, "#E6DAFF", depth=10, shadow=0.45, dark="#9B7BF0", light="#FFFFFF")
    floor = sd_rect(X, Y, 14, 160, 182, 176, 3)
    P(cv, floor, WOOD, lw=2.2, depth=4)
    for x in (34, 158):
        spk = sd_rect(X, Y, x - 14, 118, x + 14, 160, 4)
        P(cv, spk, BLACK, lw=2.2, depth=5)
        P(cv, sd_circle(X, Y, x, 144, 9), "#FF4FD8", "#FFB8F1", "#8E1680", lw=1.8, depth=5)
        P(cv, sd_circle(X, Y, x, 126, 4.5), "#3CF2FF", "#E0FFFF", "#1A8AA8", lw=1.4, depth=3)
    st = opening(sd_star(X, Y, 96, 112, 30, 13), 3)
    glow(cv, st, "#FFE66D", 10, 0.7, mode="over")
    P(cv, st, "#FFE66D", "#FFFBD8", "#E0A000", lw=2.2, depth=8)
    # awning + lights
    aw = opening(sd_poly(X, Y, [(0, 48), (196, 48), (184, 66), (12, 66)]), 3)
    P(cv, aw, "#FF4D6D", "#FFA3B5", "#A01838", depth=5)
    for k in range(7):
        x = 12 + k * 28
        cv.fill(I(sd_rect(X, Y, x, 48, x + 14, 66, 0), aw + 2.5), "#FFF6E5", 0.9)
    for k in range(4):
        x = 30 + k * 44
        P(cv, sd_box(X, Y, x, 38, 8, 9, 3), BLACK, lw=2, depth=3)
        glow(cv, sd_circle(X, Y, x, 44, 4), "#FFE66D", 6, 0.8, mode="over")
    # wheels
    for x in (50, 150, 214):
        P(cv, sd_circle(X, Y, x, 190, 22), BLACK, depth=8)
        P(cv, sd_circle(X, Y, x, 190, 9), SILVER, lw=2, depth=4)
    return cv


def item_tuba():
    """Upright tuba: big bell opening upward, conical body, bottom bow, valve cluster, leadpipe."""
    cv = Canvas(200, 262)
    X, Y = cv.X, cv.Y
    # bottom bow + second branch that climbs to the valves (drawn behind the body)
    bow = sd_polyline(X, Y, bez((118, 196), (118, 240), (52, 244), (50, 196), n=24),
                      list(np.linspace(21, 14, 25)))
    P(cv, bow, BRASS, depth=10, spec=0.8)
    branch = sd_capsule(X, Y, 50, 196, 50, 150, 13)
    P(cv, branch, BRASS, depth=8, spec=0.8)
    # tuning slide loop on the right
    loop = sd_polyline(X, Y, [(138, 120)] + bez((150, 120), (184, 120), (184, 150), (150, 150), n=12)
                       + [(138, 150)]) - 7
    P(cv, loop, BRASS, lw=2.2, depth=5, spec=0.8)
    # main conical body flaring into the bell
    prof = [(96, 206), (94, 150), (90, 104), (78, 70), (58, 44), (46, 30)]
    right = [(2 * 110 - x, y) for (x, y) in prof]
    body = opening(sd_poly(X, Y, prof + right[::-1]), 6)
    mouth = sd_ellipse(X, Y, 110, 30, 66, 17)
    body = SU(body, mouth, 6)
    P(cv, body, BRASS, depth=22, spec=0.9)
    inset(cv, sd_ellipse(X, Y, 110, 28, 56, 11), "#F5B530", depth=7, shadow=0.5, dark="#C27400", light="#FFF3B0")
    cv.stroke(sd_ellipse(X, Y, 110, 30, 66, 17), 2.4, "#B86E00", 0.9)
    for yy in (116, 176):
        band = I(sd_rect(X, Y, 80, yy - 4, 140, yy + 4, 0), body + 0.5)
        P(cv, band, ("#FFFBE0", "#FFE680", "#F5B800", "#B86E00"), lw=1.6, depth=3, spec=0.9)
    # valve cluster on the left branch
    for k in range(3):
        vx = 36 + k * 15
        P(cv, sd_rect(X, Y, vx - 6.5, 112, vx + 6.5, 168, 3.5), BRASS, lw=2, depth=4, spec=0.8)
        P(cv, sd_capsule(X, Y, vx, 98, vx, 110, 3.2), SILVER, lw=1.6, depth=2)
        P(cv, sd_ellipse(X, Y, vx, 96, 7.5, 4.2), ("#FFFFFF", "#FFF6E0", "#E8D8B0", "#B8904A"), lw=1.6, depth=2)
    P(cv, sd_rect(X, Y, 26, 126, 84, 134, 3), BRASS, lw=1.8, depth=3, spec=0.8)
    # leadpipe + mouthpiece
    lp = sd_polyline(X, Y, bez((30, 150), (12, 136), (14, 96), (26, 80), n=14), list(np.linspace(6, 4.2, 15)))
    P(cv, lp, BRASS, lw=2, depth=4, spec=0.8)
    P(cv, sd_taper(X, Y, 26, 80, 34, 66, 4.2, 6.5), SILVER, lw=1.8, depth=3)
    hl(cv, ((78, 190), (74, 120), (58, 60)), 4.5, 1.5, body + 5, alpha=0.75)
    hl(cv, ((60, 36), (84, 24), (116, 20)), 3.0, 1.0, mouth + 3, alpha=0.6)
    return cv


def _mirror(cv):
    out = cv.blank()
    out.rgb = cv.rgb[:, ::-1, :].copy()
    out.a = cv.a[:, ::-1].copy()
    return out


def item_trumpets():
    """Two crossed trumpets with a ribbon."""
    base = item_trumpet(mute=False, h=210, rot=0)
    right = base.transformed(-32, pivot=(120, 80), sx=0.98, sy=0.98, dx=8, dy=40)
    left = _mirror(base).transformed(32, pivot=(120, 80), sx=0.98, sy=0.98, dx=-8, dy=40)
    cv = Canvas(240, 210)
    cv.over(left)
    cv.over(right)
    X, Y = cv.X, cv.Y
    rib = opening(sd_poly(X, Y, [(100, 150), (140, 150), (150, 196), (120, 180), (90, 196)]), 3)
    P(cv, rib, "#FF4D6D", "#FFA3B5", "#A01838", depth=6)
    P(cv, sd_circle(X, Y, 120, 144, 13), "#FF4D6D", "#FFA3B5", "#A01838", depth=6)
    return cv


def item_clarinet():
    cv = Canvas(130, 256)
    lay = cv.blank()
    X, Y = lay.X, lay.Y
    body = sd_taper(X, Y, 65, 30, 65, 200, 9, 11)
    P(lay, body, BLACK, depth=6, spec=0.7)
    bell = opening(sd_poly(X, Y, [(54, 196), (76, 196), (92, 246), (38, 246)]), 4)
    P(lay, bell, BLACK, depth=10, spec=0.7)
    mp = sd_taper(X, Y, 65, 30, 65, 6, 8, 5)
    P(lay, mp, "#3A3450", "#8A80B0", "#18122A", depth=4)
    for y in (36, 96, 150, 198):
        P(lay, sd_rect(X, Y, 53, y - 4, 77, y + 4, 2), SILVER, lw=1.6, depth=2.5, spec=0.8)
    for k in range(8):
        y = 50 + k * 18
        P(lay, sd_circle(X, Y, 65 + (4 if k % 2 else -3), y, 3.6), SILVER, lw=1.2, depth=2, spec=0.8)
        if k % 2 == 0:
            line(lay, [(58, y + 6), (74, y + 10)], 2.0, "#C9CCD8")
    hl(lay, ((60, 190), (59, 120), (60, 50)), 2.0, 1.0, body + 2.5, alpha=0.6)
    cv.over(lay.transformed(14, pivot=(65, 128)))
    return cv


def item_lanterns():
    cv = Canvas(180, 272)
    X, Y = cv.X, cv.Y
    iron = ("#C4F7E6", "#4FD1AE", "#2BA888", "#17806A")
    P(cv, sd_rect(X, Y, 84, 40, 96, 236, 3), iron, depth=4)
    P(cv, opening(sd_poly(X, Y, [(62, 256), (118, 256), (106, 226), (74, 226)]), 3), iron, depth=6)
    for sgn in (-1, 1):
        arm = sd_polyline(X, Y, bez((90, 60), (90 + sgn * 30, 40), (90 + sgn * 60, 48), n=12)) - 3
        P(cv, arm, iron, lw=2, depth=2)
        curl = sd_arc(X, Y, 90 + sgn * 22, 72, 10, 0, 2 * math.pi * 0.8, 3)
        P(cv, curl, iron, lw=1.6, depth=2)
        lx = 90 + sgn * 60
        line(cv, [(lx, 48), (lx, 62)], 3)
        glass = opening(sd_poly(X, Y, [(lx - 16, 72), (lx + 16, 72), (lx + 12, 112), (lx - 12, 112)]), 3)
        glow(cv, glass, "#FFD27A", 16, 0.9, mode="under")
        P(cv, glass, "#FFE9A8", "#FFFFFF", "#FFB030", lw=2.4, depth=8, spec=0.3)
        P(cv, sd_capsule(X, Y, lx, 80, lx, 100, 2.6), "#FFFFFF", "#FFFFFF", "#FFE9A8", lw=0, depth=2)
        cap = opening(sd_poly(X, Y, [(lx - 20, 72), (lx + 20, 72), (lx + 8, 58), (lx - 8, 58)]), 2)
        P(cv, cap, iron, lw=2.2, depth=4)
        P(cv, sd_rect(X, Y, lx - 14, 110, lx + 14, 118, 2), iron, lw=2, depth=2)
    P(cv, sd_circle(X, Y, 90, 36, 8), BRASS, lw=2, depth=4)
    return cv


def item_confetti():
    cv = Canvas(220, 214)
    X, Y = cv.X, cv.Y
    g = rng(77)
    burst = cv.blank()
    mx, my = 84 + 50 * math.cos(math.radians(-35)), 130 + 50 * math.sin(math.radians(-35))
    for k in range(3):
        a = math.radians(-78 + k * 24)
        s_ = bez((mx, my), (mx + 50 * math.cos(a) - 16, my + 50 * math.sin(a)),
                 (mx + 86 * math.cos(a), my + 86 * math.sin(a) + 12), n=20)
        line(burst, s_, 4.5, PIECE_COLS[(k * 2 + 1) % 6])
    for k in range(40):
        a = math.radians(-40 + (g.random() - 0.5) * 80)
        r = 26 + g.random() * 96
        x, y = mx + r * math.cos(a), my + r * math.sin(a)
        if not (18 < x < 202 and 16 < y < 150):
            continue
        col = PIECE_COLS[k % 6]
        if k % 3 == 0:
            d = sd_circle(burst.X, burst.Y, x, y, 4.2)
        else:
            d = sd_box(burst.X, burst.Y, x, y, 5.5, 3.2, 1.2, ang=g.random() * 3)
        P(burst, d, col, lw=1.4, depth=2, spec=0.2)
    for (x, y, r) in ((196, 30, 7), (140, 22, 5)):
        sparkle(burst, x, y, r, "#FFE66D")
    cv.over(burst)
    # tripod + barrel
    for (x0, x1) in ((60, 30), (60, 90)):
        P(cv, sd_capsule(X, Y, 60, 160, x1, 204, 4.5), BLACK, lw=2, depth=3)
    barrel = sd_box(X, Y, 84, 130, 50, 20, 10, ang=math.radians(-35))
    P(cv, barrel, "#FF4FD8", "#FFB8F1", "#8E1680", depth=10, spec=0.6)
    for t in (-26, 0, 26):
        cx, cy = 84 + t * math.cos(math.radians(-35)), 130 + t * math.sin(math.radians(-35))
        band = I(sd_box(X, Y, cx, cy, 4, 22, 2, ang=math.radians(-35)), barrel + 0.5)
        P(cv, band, BRASS, lw=1.6, depth=3)
    mouth = sd_ellipse(X, Y, mx, my, 8, 21, ang=math.radians(-35))
    P(cv, mouth, BRASS, lw=2.2, depth=4)
    P(cv, sd_circle(X, Y, 60, 158, 8), SILVER, lw=2, depth=4)
    return cv


# ============================================================== STADIUM
def item_stage():
    cv = Canvas(256, 210)
    X, Y = cv.X, cv.Y
    back = sd_rect(X, Y, 40, 40, 216, 150, 8)
    inset(cv, back, "#D9CCFF", depth=10, shadow=0.45, dark="#9B7BF0", light="#FFFFFF")
    st = opening(sd_star(X, Y, 128, 100, 42, 18), 3)
    glow(cv, st, "#FF4FD8", 14, 0.9, mode="over")
    P(cv, st, "#FF4FD8", "#FFB8F1", "#8E1680", depth=10)
    truss = U(sd_arc(X, Y, 128, 150, 112, math.radians(185), math.radians(355), 12),
              sd_rect(X, Y, 10, 140, 26, 170, 3), sd_rect(X, Y, 230, 140, 246, 170, 3))
    P(cv, truss, SILVER, depth=5, spec=0.6)
    for k in range(9):
        a = math.radians(190 + k * 20)
        x, y = 128 + 112 * math.cos(a), 150 + 112 * math.sin(a)
        glow(cv, sd_circle(X, Y, x, y, 4), ["#FF4FD8", "#3CF2FF", "#FFE66D"][k % 3], 7, 0.9, mode="over")
        P(cv, sd_circle(X, Y, x, y, 5), ["#FF4FD8", "#3CF2FF", "#FFE66D"][k % 3], lw=1.6, depth=3)
    for x in (30, 226):
        spk = sd_rect(X, Y, x - 24, 120, x + 24, 180, 5)
        P(cv, spk, BLACK, depth=6)
        for yy in (136, 162):
            P(cv, sd_circle(X, Y, x, yy, 10), PINKP, lw=2, depth=5)
    deck = sd_rect(X, Y, 20, 166, 236, 204, 6)
    P(cv, deck, ("#E4D6FF", "#B89CFF", "#8B6BF0", "#5A2FE0"), depth=8)
    for k in range(10):
        x = 32 + k * 21.5
        glow(cv, sd_rect(X, Y, x, 176, x + 12, 182, 2), PIECE_COLS[k % 6], 5, 0.9, mode="over")
        cv.fill(sd_rect(X, Y, x, 176, x + 12, 182, 2), lighten(PIECE_COLS[k % 6], 0.4))
    return cv


def item_screens():
    cv = Canvas(256, 180)
    X, Y = cv.X, cv.Y
    for x in (40, 216):
        P(cv, sd_rect(X, Y, x - 5, 120, x + 5, 176, 2), SILVER, lw=2, depth=3)
    frame = sd_rect(X, Y, 6, 8, 250, 136, 10)
    P(cv, frame, BLACK, depth=8)
    scr = sd_rect(X, Y, 16, 18, 240, 126, 5)
    w = cv.win(scr < 1)
    t = np.clip((cv.X[w] - 16) / 224, 0, 1)
    grad = ramp(t, [(0, "#6B4CE0"), (0.5, "#9B52FF"), (1, "#FF6FD8")])
    cv.paint(np.clip(0.5 - scr[w] * cv.ss, 0, 1), grad, 1.0, win=w)
    # equaliser + heart
    for k in range(14):
        x = 26 + k * 15.5
        h = 16 + 44 * abs(math.sin(k * 0.9 + 0.4))
        bar = sd_rect(X, Y, x, 118 - h, x + 10, 118, 2)
        cv.fill(bar, ["#3CF2FF", "#FFE66D", "#C6FF4D"][k % 3], 0.85)
    from ui import heart_sdf
    hd = opening(heart_sdf(X, Y, 128, 64, 1.4), 1)
    glow(cv, hd, "#FFFFFF", 8, 0.7, mode="over")
    P(cv, hd, "#FF4D6D", "#FFA3B5", "#A01838", lw=2, depth=8)
    px = ((np.floor(X / 3) + np.floor(Y / 3)) % 2).astype(np.float32)
    cv.paint(px * np.clip(0.5 - scr * cv.ss, 0, 1), C("#000000"), 0.08, "over")
    cv.fill(np.maximum(sd_rect(X, Y, 16, 18, 240, 50, 5), scr), WHITE, 0.12)
    return cv


HAIR = [("#FFE0B8", "#C9864A", "#A8683C", "#7A4520"), ("#FFD1E6", "#FF7EB6", "#F0508F", "#C22A6C"),
        ("#FFF3B0", "#F5C542", "#D9A21A", "#9C6E00"), ("#E3CCFF", "#9B6BFF", "#7B45E0", "#5A2FB0"),
        ("#C7FAFF", "#3CC8F0", "#1A9AD0", "#0B6E9C")]
SKIN_P = ("#FFF3E8", "#FFD9B8", "#F2B48A", "#C77A4A")


def _fan(cv, x, y, shirt, hair, stick, lean=0.0, style=0, s=1.0):
    """A concert-goer seen from behind: shoulders, head with hair, one arm up with a glowing stick."""
    X, Y = cv.X, cv.Y
    # raised arm from the shoulder, hand above the head, stick on top
    side = 1 if lean >= 0 else -1
    shx, shy = x + side * 17 * s, y + 20 * s
    hx, hy = x + side * 30 * s + lean * 10, y - 44 * s
    st_top = (hx + lean * 14 + side * 4, hy - 40 * s)
    stick_d = sd_capsule(X, Y, hx, hy - 4 * s, st_top[0], st_top[1], 5.2 * s)
    glow(cv, stick_d, stick, 14, 0.95, mode="over")
    P(cv, stick_d, stick, "#FFFFFF", darken(stick, 0.25), lw=2.0, depth=3, spec=0.2)
    cv.fill(np.maximum(sd_capsule(X, Y, hx, hy - 10 * s, st_top[0], st_top[1] + 6, 1.8 * s), stick_d + 2), WHITE, 0.9)
    P(cv, sd_capsule(X, Y, hx, hy - 6 * s, hx, hy + 6 * s, 4.6 * s), BLACK, lw=1.8, depth=2)
    arm = sd_polyline(X, Y, [(shx, shy), (shx + side * 10 * s, y - 8 * s), (hx, hy + 4 * s)]) - 7.5 * s
    P(cv, arm, shirt, depth=6, spec=0.2)
    P(cv, sd_circle(X, Y, hx, hy + 2 * s, 8.5 * s), SKIN_P, lw=2.2, depth=4)
    # body (shoulders) - fades out at the bottom of the canvas
    body = SU(sd_ellipse(X, Y, x, y + 58 * s, 34 * s, 50 * s), sd_capsule(X, Y, x - 18 * s, y + 22 * s,
                                                                         x + 18 * s, y + 22 * s, 13 * s), 8)
    P(cv, body, shirt, depth=14, spec=0.2)
    # neck + head from behind: mostly hair
    P(cv, sd_capsule(X, Y, x, y + 4 * s, x, y + 14 * s, 7 * s), SKIN_P, lw=2.0, depth=3)
    head = sd_circle(X, Y, x, y - 8 * s, 17 * s)
    P(cv, head, SKIN_P, lw=2.2, depth=8)
    if style == 0:        # short fluffy hair
        hr = SU(sd_circle(X, Y, x, y - 12 * s, 18 * s), sd_ellipse(X, Y, x, y - 2 * s, 17 * s, 11 * s), 5)
    elif style == 1:      # ponytail
        hr = SU(sd_circle(X, Y, x, y - 11 * s, 18 * s),
                sd_taper(X, Y, x + 4 * s, y - 20 * s, x - 14 * s, y + 18 * s, 9 * s, 5 * s), 6)
    elif style == 2:      # two buns
        hr = U(sd_circle(X, Y, x, y - 11 * s, 18 * s), sd_circle(X, Y, x - 16 * s, y - 26 * s, 9 * s),
               sd_circle(X, Y, x + 16 * s, y - 26 * s, 9 * s))
    else:                 # spiky
        pts = []
        for k in range(15):
            a = math.pi + k * math.pi / 14
            r = (22 if k % 2 == 0 else 16) * s
            pts.append((x + r * math.cos(a), y - 10 * s + r * math.sin(a)))
        hr = SU(opening(sd_poly(X, Y, pts + [(x + 17 * s, y), (x - 17 * s, y)]), 2),
                sd_circle(X, Y, x, y - 10 * s, 17 * s), 3)
    hr = np.maximum(hr, Y - (y + 4 * s))
    P(cv, hr, hair, depth=8, spec=0.3)
    cv.fill(np.maximum(sd_arc(X, Y, x - 4 * s, y - 12 * s, 10 * s, math.radians(200), math.radians(250), 3.0),
                       hr + 2), WHITE, 0.55)


def item_lightsticks():
    cv = Canvas(240, 236)
    back = cv.blank()
    sticks = ["#FF4FD8", "#3CF2FF", "#FFE66D", "#C6FF4D", "#FF4FD8"]
    shirts = ["#8E3DFF", "#3D8BFF", "#FF5C9A", "#22C58A", "#FF8C1A"]
    for k, (x, y, lean, st) in enumerate(((84, 132, -0.3, 1), (160, 128, 0.4, 2))):
        _fan(back, x, y, shirts[k + 3], HAIR[k + 3], sticks[k + 3], lean, st, 0.86)
    cv.over(back)
    for k, (x, y, lean, st) in enumerate(((52, 160, 0.2, 0), (122, 150, -0.3, 3), (190, 164, -0.2, 1))):
        _fan(cv, x, y, shirts[k], HAIR[k], sticks[k], lean, st, 1.0)
    # the crowd fades out toward the bottom (no hard edge), sticks stay bright
    k = smoothstep(234, 188, cv.Y)
    cv.rgb *= k[..., None]
    cv.a *= k
    return cv


def item_lasers():
    cv = Canvas(256, 208)
    X, Y = cv.X, cv.Y
    beams = cv.blank()
    cols = ["#C6FF4D", "#3CF2FF", "#FF4FD8", "#FFE66D", "#3CF2FF", "#C6FF4D", "#FF4FD8"]
    ox, oy = 128.0, 158.0
    for k in range(7):
        a = math.radians(-160 + k * 23.3)
        # beam length: stop well inside the canvas, then fade over the last 25 %
        L = 0.0
        while True:
            L += 2
            x, y = ox + L * math.cos(a), oy + L * math.sin(a)
            if not (10 < x < 246 and 10 < y < 198):
                break
        L -= 6
        ux, uy = math.cos(a), math.sin(a)
        along = (X - ox) * ux + (Y - oy) * uy
        fade = smoothstep(L, L * 0.75, along)
        lay = cv.blank()
        d = sd_capsule(X, Y, ox, oy, ox + L * ux, oy + L * uy, 2.2)
        lay.glow_from(np.clip(0.5 - d * cv.ss, 0, 1), 6, cols[k], 0.9, mode="over")
        lay.fill(d, lighten(cols[k], 0.5))
        lay.fill(d + 1.2, "#FFFFFF", 0.9)
        lay.rgb *= fade[..., None]
        lay.a *= fade
        beams.over(lay)
    cv.over(beams)
    box = sd_rect(X, Y, 84, 148, 172, 194, 8)
    P(cv, box, BLACK, depth=8)
    lens = sd_circle(X, Y, ox, oy, 12)
    glow(cv, lens, "#FFFFFF", 10, 0.9, mode="over")
    P(cv, lens, "#E0FFFF", "#FFFFFF", "#3CF2FF", lw=2.2, depth=6)
    for x in (96, 160):
        P(cv, sd_circle(X, Y, x, 178, 4), "#FF4FD8", lw=1.4, depth=2)
    return cv


def item_choir():
    cv = Canvas(240, 210)
    X, Y = cv.X, cv.Y
    robes = ["#8E3DFF", "#FF4FD8", "#3D8BFF"]
    for row, (y, xs, s) in enumerate(((96, (58, 120, 182), 0.9), (136, (30, 90, 150, 210), 1.0))):
        step = sd_rect(X, Y, 6 + row * 0, y + 40, 234, y + 70, 4) if False else None
        del step
    steps = [sd_rect(X, Y, 20, 134, 220, 164, 4), sd_rect(X, Y, 6, 172, 234, 206, 4)]
    singers = [((58, 96), 0.9), ((120, 96), 0.9), ((182, 96), 0.9), ((30, 136), 1.0), ((90, 136), 1.0),
               ((150, 136), 1.0), ((210, 136), 1.0)]
    P(cv, steps[0], ("#E3CFA8", "#FFF3DA", "#9A7A52"), depth=6)
    for k, ((x, y), s) in enumerate(singers[:3]):
        _singer(cv, x, y, s, robes[k % 3])
    P(cv, steps[1], ("#E3CFA8", "#FFF3DA", "#9A7A52"), depth=6)
    for k, ((x, y), s) in enumerate(singers[3:]):
        _singer(cv, x, y, s, robes[(k + 1) % 3])
    for (x, y) in ((30, 30), (212, 40)):
        n = note_sdf(X, Y, x - 20, y - 20, 0.26)
        P(cv, n, "#FFE66D", "#FFFBD8", "#E0A000", lw=1.8, depth=4)
    return cv


def _singer(cv, x, y, s, robe):
    X, Y = cv.X, cv.Y
    body = I(sd_ellipse(X, Y, x, y + 44 * s, 24 * s, 44 * s), Y - (y + 44 * s))
    P(cv, body, robe, depth=10 * s, spec=0.2)
    collar = I(sd_ellipse(X, Y, x, y + 4 * s, 16 * s, 10 * s), Y - (y + 4 * s))
    P(cv, collar, "#FFF6E5", "#FFFFFF", "#D9C4A0", lw=1.8, depth=3)
    head = sd_circle(X, Y, x, y - 12 * s, 15 * s)
    P(cv, head, "#FFD9B8", "#FFF3E8", "#D99A70", depth=8 * s, spec=0.3)
    cv.fill(sd_ellipse(X, Y, x, y - 5 * s, 4.5 * s, 5.5 * s), "#5A1238")
    for ex in (-6, 6):
        cv.fill(sd_arc(X, Y, x + ex * s, y - 14 * s, 3.5 * s, math.radians(200), math.radians(340), 1.8), INK)
    hair = I(sd_circle(X, Y, x, y - 14 * s, 16 * s), Y - (y - 18 * s))
    P(cv, hair, ("#E0B08A", "#A8683C", "#8A5028", "#5E3414"), lw=2, depth=5)


def item_fog():
    cv = Canvas(210, 180)
    X, Y = cv.X, cv.Y
    puffs = [(110, 70, 34), (150, 60, 30), (70, 64, 26), (184, 80, 22), (126, 36, 26), (40, 90, 18)]
    fog = None
    for (x, y, r) in puffs:
        d = sd_circle(X, Y, x, y, r)
        fog = d if fog is None else SU(fog, d, 8)
    P(cv, fog, "#F2ECFF", "#FFFFFF", "#B9ACE0", lw=2.2, depth=20, spec=0.0, grad=0.5)
    box = sd_rect(X, Y, 20, 116, 150, 172, 8)
    P(cv, box, BLACK, depth=8)
    for k in range(5):
        line(cv, [(34 + k * 10, 128), (34 + k * 10, 160)], 3, "#4632A8")
    noz = sd_rect(X, Y, 146, 126, 176, 148, 5)
    P(cv, noz, SILVER, lw=2.2, depth=4)
    for (x, c) in ((96, "#C6FF4D"), (116, "#FF4D6D")):
        P(cv, sd_circle(X, Y, x, 144, 5), c, lw=1.6, depth=3)
    return cv


def _dancer(cv, x, y, outfit, hair, flip=1, style=0):
    X, Y = cv.X, cv.Y
    skin = SKIN_P
    pants = ("#C9BCFF", "#7B6BEA", "#5A48C9", "#3B2A8F")
    # legs (thick, with sneakers)
    for (dx, ang) in ((-9, -0.32 * flip), (9, 0.28 * flip)):
        lx0, ly0 = x + dx, y + 36
        lx1, ly1 = lx0 + 50 * math.sin(ang), ly0 + 50 * math.cos(ang)
        P(cv, sd_taper(X, Y, lx0, ly0, lx1, ly1, 10, 8), pants, depth=5)
        shoe = sd_ellipse(X, Y, lx1 + 5 * flip * (1 if dx > 0 else -1), ly1 + 4, 13, 7.5)
        P(cv, shoe, ("#FFFFFF", "#FFFFFF", "#DCD3F5", "#7B6AAE"), lw=2.2, depth=3)
        cv.fill(np.maximum(np.abs(Y - (ly1 + 7)) - 1.4, shoe + 1.5), "#FF4FD8", 0.9)
    # arms from the shoulders: one up with an open hand, one out
    sh = y - 12
    a_up = sd_polyline(X, Y, [(x - 14 * flip, sh), (x - 30 * flip, sh - 22), (x - 28 * flip, sh - 52)]) - 7
    a_out = sd_polyline(X, Y, [(x + 14 * flip, sh + 2), (x + 38 * flip, sh + 12), (x + 56 * flip, sh - 4)]) - 7
    P(cv, U(a_up, a_out), outfit, depth=5, spec=0.3)
    for (hx, hy) in ((x - 28 * flip, sh - 58), (x + 60 * flip, sh - 8)):
        P(cv, sd_circle(X, Y, hx, hy, 8), skin, lw=2.2, depth=4)
    torso = SU(sd_taper(X, Y, x, y - 14, x, y + 38, 18, 15), sd_capsule(X, Y, x - 14, sh, x + 14, sh, 9), 6)
    P(cv, torso, outfit, depth=9, spec=0.4)
    cv.fill(np.maximum(sd_star(X, Y, x, y + 8, 9, 4), torso + 2), "#FFFFFF", 0.9)
    P(cv, sd_capsule(X, Y, x, y - 22, x, y - 14, 6), skin, lw=2, depth=3)
    hx, hy = x + 2 * flip, y - 38
    head = sd_circle(X, Y, hx, hy, 16)
    if style == 0:        # two bouncy pigtails
        for sd_ in (-1, 1):
            tail = sd_taper(X, Y, hx + sd_ * 14, hy - 8, hx + sd_ * 30, hy + 14, 8.5, 5)
            P(cv, tail, hair, depth=6, spec=0.3)
            P(cv, sd_circle(X, Y, hx + sd_ * 15, hy - 8, 4.5), "#FFE66D", lw=1.6, depth=2)
    else:                 # high ponytail
        tail = sd_taper(X, Y, hx - 6 * flip, hy - 16, hx - 30 * flip, hy + 10, 9, 4)
        P(cv, tail, hair, depth=6, spec=0.3)
    P(cv, head, skin, depth=8)
    fringe = SU(I(sd_circle(X, Y, hx, hy - 3, 18), Y - (hy - 6)), sd_ellipse(X, Y, hx - 10 * flip, hy - 4, 7, 9), 3)
    P(cv, fringe, hair, depth=6, spec=0.3)
    for ex in (-6, 6):
        cv.fill(sd_arc(X, Y, hx + ex, hy + 2, 3.8, math.radians(200), math.radians(340), 2.0), INK)
    m = I(sd_ellipse(X, Y, hx + 1 * flip, hy + 6, 6.5, 6), (hy + 6) - Y)     # round-bottom "D" smile
    cv.fill(m, "#8A2F4E")
    cv.fill(I(sd_ellipse(X, Y, hx + 1 * flip, hy + 12, 4, 3), m + 0.8), "#FF7E9E")
    for ex in (-9, 9):
        cv.fill(sd_ellipse(X, Y, hx + ex, hy + 6, 3.6, 2.4), "#FF8FAE", 0.7, soft=0.8)


def item_dancers():
    cv = Canvas(248, 232)
    _dancer(cv, 70, 120, ("#FFB8F1", "#FF4FD8", "#D12FB0", "#8E1680"), ("#C7FAFF", "#3CC8F0", "#1A9AD0", "#0B6E9C"),
            flip=1, style=0)
    _dancer(cv, 176, 124, ("#C7FAFF", "#3CF2FF", "#1AB8D8", "#0B7DA0"), ("#E3CCFF", "#9B6BFF", "#7B45E0", "#5A2FB0"),
            flip=-1, style=1)
    for (x, y, r) in ((124, 26, 8), (224, 36, 6), (22, 52, 6)):
        sparkle(cv, x, y, r, "#FFE66D")
    return cv


def item_fireworks():
    cv = Canvas(240, 240)
    X, Y = cv.X, cv.Y
    lay = cv.blank()
    for (cx, cy, R, col, n) in ((90, 92, 72, "#FF4FD8", 16), (176, 150, 52, "#3CF2FF", 12), (180, 56, 40, "#FFE66D", 10)):
        for k in range(n):
            a = 2 * math.pi * k / n
            x0, y0 = cx + R * 0.35 * math.cos(a), cy + R * 0.35 * math.sin(a)
            x1, y1 = cx + R * math.cos(a), cy + R * math.sin(a)
            d = sd_taper(X, Y, x0, y0, x1, y1, 1.2, 3.4)
            lay.fill(d, col)
            lay.fill(sd_circle(X, Y, x1, y1, 4.2), lighten(col, 0.6))
        lay.fill(sd_circle(X, Y, cx, cy, R * 0.18), lighten(col, 0.7), 0.9, soft=3)
    lay.glow_under(8, "#FFFFFF", 0.35)
    for (x, y, r) in ((40, 30, 7), (220, 210, 6), (30, 190, 5), (130, 200, 6)):
        sparkle(lay, x, y, r, "#FFF6C0")
    cv.over(lay)
    return cv


# ============================================================== GARAGE
def item_drum_kit():
    cv = Canvas(256, 230)
    X, Y = cv.X, cv.Y
    shell = ("#FF3B5C", "#FF8FA3", "#8A0A28")
    # cymbals + stands
    for (x, y, r, tilt) in ((34, 70, 30, 0.25), (222, 50, 34, -0.2)):
        line(cv, [(x, y), (x, 222)], 3.6, "#AEB9D3")
        P(cv, sd_ellipse(X, Y, x, y, r, 7, ang=tilt), BRASS, lw=2.2, depth=4, spec=0.8)
        P(cv, sd_circle(X, Y, x, y - 1, 3), SILVER, lw=1.2, depth=2)
    for x in (34, 222):
        P(cv, sd_polyline(X, Y, [(x - 16, 226), (x, 206), (x + 16, 226)]) - 2, SILVER, lw=1.4, depth=2)
    # toms
    for (x, y) in ((96, 76), (160, 76)):
        tom = sd_rect(X, Y, x - 28, y - 20, x + 28, y + 22, 8)
        P(cv, tom, shell, depth=10, spec=0.6)
        P(cv, sd_ellipse(X, Y, x, y - 20, 28, 7), "#FFF6E5", "#FFFFFF", "#C9B89A", lw=2, depth=3)
    # floor tom + snare
    ft = sd_rect(X, Y, 196, 118, 244, 196, 8)
    P(cv, ft, shell, depth=10, spec=0.6)
    P(cv, sd_ellipse(X, Y, 220, 118, 24, 6), "#FFF6E5", "#FFFFFF", "#C9B89A", lw=2, depth=3)
    sn = sd_rect(X, Y, 14, 128, 64, 160, 6)
    P(cv, sn, SILVER, depth=8, spec=0.8)
    P(cv, sd_ellipse(X, Y, 39, 128, 25, 6), "#FFF6E5", "#FFFFFF", "#C9B89A", lw=2, depth=3)
    # bass drum
    bd = sd_circle(X, Y, 128, 156, 66)
    P(cv, bd, shell, depth=12, spec=0.6)
    head = sd_circle(X, Y, 128, 156, 54)
    P(cv, head, "#FFF6E5", "#FFFFFF", "#D9C4A0", lw=2.4, depth=16, spec=0.2)
    st = opening(sd_star(X, Y, 128, 160, 34, 15), 3)
    P(cv, st, "#FFD60A", "#FFF2A6", "#C29B00", lw=2.2, depth=8)
    for k in range(8):
        a = 2 * math.pi * k / 8 + 0.2
        P(cv, sd_circle(X, Y, 128 + 60 * math.cos(a), 156 + 60 * math.sin(a), 4.2), SILVER, lw=1.4, depth=2)
    for x in (82, 174):
        P(cv, sd_capsule(X, Y, x, 210, x + (-18 if x < 128 else 18), 226, 3), SILVER, lw=1.4, depth=2)
    return cv


def item_amp():
    cv = Canvas(200, 240)
    X, Y = cv.X, cv.Y
    cab = sd_rect(X, Y, 10, 86, 190, 236, 10)
    P(cv, cab, ("#E3FFF6", "#7FE3C8", "#4FC4A6", "#2A8F76"), depth=10)
    grill = sd_rect(X, Y, 22, 98, 178, 224, 6)
    inset(cv, grill, "#FFF4E0", depth=6, shadow=0.4, dark="#E8C9A0", light="#FFFFFF")
    for (x, y) in ((61, 130), (139, 130), (61, 192), (139, 192)):
        cv.fill(np.maximum(sd_circle(X, Y, x, y, 28), grill + 3), "#FFD1E6", 0.9)
        cv.stroke(np.maximum(sd_circle(X, Y, x, y, 28), grill + 3), 2.6, "#F0508F", 0.9)
    wv = np.abs(((X + Y) % 5.0) - 2.5) - 0.6
    cv.fill(np.maximum(wv, grill + 3), "#E8C9A0", 0.35)
    head = sd_rect(X, Y, 14, 18, 186, 84, 8)
    P(cv, head, ("#E3FFF6", "#7FE3C8", "#4FC4A6", "#2A8F76"), depth=8)
    panel = sd_rect(X, Y, 24, 48, 176, 76, 4)
    P(cv, panel, BRASS, lw=2, depth=4, spec=0.7)
    for k in range(7):
        P(cv, sd_circle(X, Y, 40 + k * 20, 62, 6.5), CREAMP, lw=1.8, depth=3)
    txt = text_sdf(cv, "ROCK", FONT, 20, 100, 33, tracking=2)
    cv.fill(txt - 1.8, "#2A8F76")
    cv.fill(txt, "#FFFFFF")
    P(cv, sd_rect(X, Y, 80, 6, 120, 20, 5), BLACK, lw=2, depth=3)
    P(cv, sd_circle(X, Y, 166, 32, 4.5), "#FF3B5C", lw=1.6, depth=2)
    glow(cv, sd_circle(X, Y, 166, 32, 3), "#FF3B5C", 5, 0.7, mode="over")
    return cv


def item_bass_guitar():
    cv = Canvas(130, 256)
    lay = cv.blank()
    X, Y = lay.X, lay.Y
    body = SU(sd_circle(X, Y, 65, 214, 38), sd_ellipse(X, Y, 65, 174, 28, 26), 14)
    body = SU(body, sd_taper(X, Y, 44, 172, 36, 132, 13, 8), 10)
    body = SU(body, sd_taper(X, Y, 88, 176, 92, 146, 12, 8), 10)
    body = SUB(body, sd_ellipse(X, Y, 65, 142, 12, 16))
    body = opening(body, 2)
    P(lay, body, ("#2F9BFF", "#A6D4FF", "#0A58B8"), depth=16, spec=0.7)
    guard = I(opening(sd_poly(X, Y, [(52, 160), (40, 176), (38, 200), (50, 224), (78, 222), (76, 186), (74, 160)]), 5),
              body + 3)
    P(lay, guard, "#FFF6E5", "#FFFFFF", "#D9C4A0", lw=1.8, depth=3, spec=0.3)
    neck = sd_rect(X, Y, 58, 30, 72, 196, 3)
    P(lay, neck, ("#E8B36A", "#FFE2B0", "#A8672A"), lw=2.2, depth=4)
    for k in range(10):
        y = 50 + k * 14
        line(lay, [(59, y), (71, y)], 1.2, "#C9CCD8")
    head = opening(sd_poly(X, Y, [(56, 34), (74, 34), (80, 4), (58, 8)]), 3)
    P(lay, head, ("#2F9BFF", "#A6D4FF", "#0A58B8"), lw=2.2, depth=4)
    for k in range(4):
        side = -1 if k < 2 else 1
        y = 12 + (k % 2) * 12
        P(lay, sd_circle(X, Y, 66 + side * 16, y, 4.5), SILVER, lw=1.4, depth=2)
    P(lay, sd_rect(X, Y, 54, 170, 76, 180, 2), BLACK, lw=1.6, depth=2)
    P(lay, sd_rect(X, Y, 54, 212, 76, 220, 2), SILVER, lw=1.6, depth=2)
    for k in range(4):
        x = 61 + k * 2.7
        lay.fill(sd_capsule(X, Y, x, 34, x, 216, 0.5), "#F4F0E0", 0.9)
    for (x, y) in ((90, 222), (84, 196)):
        P(lay, sd_circle(X, Y, x, y, 4.5), SILVER, lw=1.4, depth=2)
    hl(lay, ((34, 222), (30, 196), (40, 178)), 3.5, 1.2, body + 3.5, alpha=0.6)
    # wall hanger: round plate with a padded yoke holding the neck under the headstock
    plate = sd_circle(X, Y, 65, 46, 10)
    P(lay, plate, CREAMP, lw=2, depth=4, mode="under")
    for sx in (-1, 1):
        P(lay, sd_capsule(X, Y, 65 + sx * 11, 36, 65 + sx * 11, 48, 3.6), PINKP, lw=1.6, depth=2)
    P(lay, sd_capsule(X, Y, 54, 48, 76, 48, 3.2), PINKP, lw=1.6, depth=2)
    cv.over(lay.transformed(-10, pivot=(65, 128)))
    return cv


def item_posters():
    cv = Canvas(240, 220)
    X, Y = cv.X, cv.Y
    posters = [((10, 20, 104, 150), -0.06, "#FF4FD8"), ((92, 8, 190, 128), 0.05, "#FFE66D"),
               ((128, 104, 230, 212), -0.04, "#3CF2FF"), ((24, 124, 124, 214), 0.04, "#C6FF4D")]
    for k, ((x0, y0, x1, y1), ang, col) in enumerate(posters):
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        d = sd_box(X, Y, cx, cy, (x1 - x0) / 2, (y1 - y0) / 2, 2, ang=ang)
        P(cv, d, col, lw=2.4, depth=5, spec=0.1, grad=0.3)
        if k == 0:
            pk = pick_sdf(cv, cx, cy + 6, s=0.34, ang=ang)
            P(cv, pk, "#8E3DFF", lw=2, depth=6)
            t = text_sdf(cv, "LIVE", FONT, 18, cx, y0 + 18)
            cv.fill(t, INK)
        elif k == 1:
            st = opening(sd_star(X, Y, cx, cy + 8, 30, 13), 2)
            P(cv, st, "#FF3B5C", lw=2, depth=6)
            t = text_sdf(cv, "ROCK", FONT, 20, cx, y0 + 18)
            cv.fill(t, INK)
        elif k == 2:
            for j in range(3):
                cv.fill(np.maximum(sd_ring(X, Y, cx, cy + 6, 12 + j * 11, 4), d + 5), INK, 0.85)
            t = text_sdf(cv, "TOUR", FONT, 16, cx, y0 + 16)
            cv.fill(t, INK)
        else:
            n = note_sdf(X, Y, cx - 30, cy - 34, 0.38)
            P(cv, n, "#FF8C1A", lw=2, depth=5)
        tape = sd_box(X, Y, cx, y0 + 2, 12, 5, 1, ang=0.3 * (-1) ** k)
        cv.fill(tape, "#FFF6DA", 0.85)
        cv.stroke(tape, 1.0, "#B8A070", 0.7)
    return cv


def item_keyboard():
    cv = Canvas(256, 178)
    X, Y = cv.X, cv.Y
    for (a, b) in (((40, 88), (200, 158)), ((216, 88), (56, 158))):
        P(cv, sd_capsule(X, Y, *a, *b, 5), SILVER, lw=2, depth=3)
    P(cv, sd_circle(X, Y, 128, 124, 7), BLACK, lw=2, depth=3)
    body = sd_rect(X, Y, 6, 30, 250, 96, 10)
    P(cv, body, ("#FFB3C6", "#FF5C7A", "#E0304F", "#A8123A"), depth=10)
    keys(cv, 18, 62, 238, 90, n=22)
    for k in range(6):
        P(cv, sd_circle(X, Y, 28 + k * 18, 45, 5.5), CREAMP, lw=1.6, depth=3)
    scr = sd_rect(X, Y, 142, 38, 196, 54, 3)
    inset(cv, scr, "#1AE0C0", depth=3, shadow=0.3, dark="#0A7A6A", light="#B8FFF0")
    for k in range(3):
        P(cv, sd_rect(X, Y, 206 + k * 12, 38, 214 + k * 12, 54, 2), ["#FF4FD8", "#FFE66D", "#3CF2FF"][k], lw=1.4,
          depth=2)
    return cv


def item_tambourine():
    cv = Canvas(150, 170)
    X, Y = cv.X, cv.Y
    P(cv, sd_circle(X, Y, 75, 12, 5), SILVER, lw=1.8, depth=3)
    line(cv, [(75, 14), (52, 42)], 2.4, "#6A3616")
    line(cv, [(75, 14), (98, 42)], 2.4, "#6A3616")
    for (a, col) in ((0.2, "#FF4FD8"), (-0.2, "#3CF2FF")):
        rb = sd_polyline(X, Y, bez((75, 160), (75 + a * 60, 170), (75 + a * 90, 150), n=10),
                         list(np.linspace(4, 2, 11)))
        P(cv, rb, col, lw=1.6, depth=2)
    frame = sd_circle(X, Y, 75, 96, 60)
    P(cv, frame, WOOD, depth=10)
    head = sd_circle(X, Y, 75, 96, 44)
    P(cv, head, "#FFF1D6", "#FFFFFF", "#D9B888", lw=2.4, depth=16, spec=0.2)
    st = opening(sd_star(X, Y, 75, 98, 20, 9), 2)
    cv.fill(st, "#FF8C1A", 0.9)
    for k in range(6):
        a = 2 * math.pi * k / 6 + 0.52
        jx, jy = 75 + 52 * math.cos(a), 96 + 52 * math.sin(a)
        P(cv, sd_ellipse(X, Y, jx, jy, 10, 7, ang=a + math.pi / 2), BRASS, lw=2, depth=4, spec=0.8)
        cv.fill(sd_circle(X, Y, jx, jy, 2), INK)
    return cv


def item_garage_door():
    """Roll-up garage shutter, half raised, painted with a bolt and stars (sits in the door opening)."""
    cv = Canvas(256, 150)
    X, Y = cv.X, cv.Y
    blue = ("#D6EEFF", "#7FC8FF", "#4FA6EE", "#2F7FD0")
    drum = sd_rect(X, Y, 0, 0, 256, 26, 8)
    P(cv, drum, PINKP, lw=2.4, depth=8)
    cv.fill(np.maximum(sd_rect(X, Y, 8, 6, 248, 10, 2), drum + 3), "#FFFFFF", 0.6)
    door = sd_rect(X, Y, 6, 22, 250, 140, 4)
    P(cv, door, blue, lw=2.6, depth=6, grad_dir=(0.0, 1.0))
    for k in range(7):
        y = 30 + k * 15.5
        cv.fill(np.maximum(np.abs(Y - y) - 1.4, door + 2), "#2F7FD0", 0.55)
        cv.fill(np.maximum(np.abs(Y - (y + 3)) - 1.0, door + 2), "#FFFFFF", 0.55)
    bolt = opening(sd_poly(X, Y, [(136, 30), (104, 84), (126, 84), (110, 136), (160, 72), (136, 72), (158, 30)]), 2)
    cv.fill(bolt - 3, "#FFFFFF")
    P(cv, bolt, ("#FFFBD6", "#FFDB1A", "#F5B800", "#C28A00"), lw=2.4, depth=6)
    for (x, y, r, c) in ((56, 70, 18, PINKP), (206, 96, 15, ("#E3CCFF", "#B78AFF", "#8B55F0", "#6230C2")),
                         (200, 44, 8, PINKP)):
        st = opening(sd_star(X, Y, x, y, r, r * 0.45), 1.5)
        cv.fill(st - 2.5, "#FFFFFF")
        P(cv, st, c, lw=2.0, depth=5)
    bar = sd_rect(X, Y, 4, 132, 252, 148, 5)
    P(cv, bar, SILVER, lw=2.2, depth=4, grad_dir=(0.0, 1.0))
    hnd = sd_rect(X, Y, 108, 136, 148, 144, 4)
    P(cv, hnd, PINKP, lw=1.8, depth=3)
    return cv


def item_strings():
    cv = Canvas(256, 100)
    X, Y = cv.X, cv.Y
    pts = bez((2, 10), (128, 60), (254, 10), n=40)
    line(cv, pts, 2.6, INK)
    cols = ["#FFE66D", "#FF8E72", "#FFE66D", "#FF4FD8", "#FFE66D", "#3CF2FF", "#FFE66D", "#C6FF4D"]
    for k in range(9):
        t = (k + 0.5) / 9
        x, y = pts[int(t * 40)]
        col = cols[k % len(cols)]
        P(cv, sd_rect(X, Y, x - 4, y, x + 4, y + 10, 1.5), BLACK, lw=1.6, depth=2)
        b = sd_ellipse(X, Y, x, y + 22, 9, 12)
        glow(cv, b, col, 10, 0.9, mode="over")
        P(cv, b, lighten(col, 0.55), "#FFFFFF", col, lw=2.0, depth=6, spec=0.6)
    return cv


def item_mic_stand():
    cv = Canvas(150, 256)
    X, Y = cv.X, cv.Y
    for (x1, y1) in ((30, 250), (120, 250), (75, 238)):
        P(cv, sd_capsule(X, Y, 75, 214, x1, y1, 4), BLACK, lw=2, depth=3)
    P(cv, sd_rect(X, Y, 70, 84, 80, 220, 3), SILVER, lw=2, depth=3, spec=0.8)
    P(cv, sd_rect(X, Y, 66, 150, 84, 162, 3), BLACK, lw=2, depth=3)
    blockers.draw_mic(cv=cv, cx=75, top=4, s=0.62)
    return cv


ITEM_FUNCS = {
    "turntable": item_turntable, "lamps": item_lamps, "piano": item_piano, "plants": item_plants,
    "cat": item_cat, "sign": item_sign,
    "stage_light": item_stage_light, "grand_piano": item_grand_piano, "double_bass": item_double_bass,
    "neon": item_neon, "sax": item_sax, "vibes": item_vibes, "trumpet": item_trumpet,
    "fountain": item_fountain, "garlands": item_garlands, "truck_stage": item_truck_stage, "tuba": item_tuba,
    "trumpets": item_trumpets, "clarinet": item_clarinet, "lanterns": item_lanterns, "confetti": item_confetti,
    "stage": item_stage, "screens": item_screens, "lightsticks": item_lightsticks, "lasers": item_lasers,
    "choir": item_choir, "fog": item_fog, "dancers": item_dancers, "fireworks": item_fireworks,
    "drum_kit": item_drum_kit, "amp": item_amp, "bass_guitar": item_bass_guitar, "posters": item_posters,
    "keyboard": item_keyboard, "tambourine": item_tambourine, "garage_door": item_garage_door,
    "strings": item_strings, "mic_stand": item_mic_stand,
}


# Items that stand on the floor get a soft contact shadow under their base (found from the drawing:
# the x-extent of the lowest few pixels), value = (extra half-width px, shadow alpha).
CONTACT = {
    "turntable": (10, 0.24), "piano": (10, 0.24), "plants": (8, 0.24), "cat": (6, 0.2),
    "grand_piano": (10, 0.24), "double_bass": (18, 0.24), "vibes": (10, 0.24), "sax": (16, 0.22),
    "trumpet": (8, 0.2), "fountain": (8, 0.22), "truck_stage": (8, 0.24), "tuba": (14, 0.24),
    "clarinet": (14, 0.22), "lanterns": (18, 0.22), "confetti": (10, 0.22), "stage": (8, 0.24),
    "screens": (10, 0.2), "choir": (6, 0.22), "fog": (8, 0.22), "drum_kit": (8, 0.24), "amp": (8, 0.25),
    "keyboard": (10, 0.24), "mic_stand": (16, 0.24), "dancers": (8, 0.22), "lasers": (8, 0.22),
}


def _contact(cv, extra, alpha, band=7.0):
    a = cv.a > 0.5
    rows = np.flatnonzero(a.any(1))
    ss = cv.ss
    ybot = (rows[-1] + 1) / ss
    lo = max(int((ybot - band) * ss), 0)
    cols = np.flatnonzero(a[lo:].any(0))
    x0, x1 = cols[0] / ss, (cols[-1] + 1) / ss
    rx = (x1 - x0) / 2 + extra
    ry = max(min(rx * 0.13, 12.0), 5.0)
    contact_shadow(cv, (x0 + x1) / 2, ybot - ry * 0.35, rx, ry, alpha=alpha, blur=10.0)


def _with_shadow(fn, name):
    def f():
        cv = fn()
        if name in CONTACT:
            cv = grow(cv, 16, 0, 16, 18)
            _contact(cv, *CONTACT[name])
        soft_shadow(cv, 0, 3, 3, "#5A3FA0", 0.22)
        return cv
    return f


ITEM_FUNCS = {k: _with_shadow(v, k) for k, v in ITEM_FUNCS.items()}
NO_TRIM = {"lamps", "garlands", "strings", "garage_door"}   # anchored to the scene: keep the canvas as drawn
