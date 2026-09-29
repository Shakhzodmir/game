"""Board pieces (160x160) and special pieces (192x192) - bright candy style (art-direction v2)."""
import math

import numpy as np

from artkit import (C, Canvas, F32, WHITE, bez, candy, closing, fit, gblur, gloss_drop, inset, mix, opening,
                    rim_gloss, rng, sd_arc, sd_box, sd_capsule, sd_circle, sd_ellipse, sd_poly, sd_polyline,
                    sd_rect, sd_ring, sd_star, sd_taper, smoothstep, soft_shadow, sparkle4, svg_path, SU, SUB, U,
                    I)
from palette import (PIECES, ORDER, PIECE_SHADOW, RIFF_GLOW, RIFF_LINE, SUB_TOP, SUB_BOT, SUB_CONE, SUB_ACCENT,
                     BIRD_A, BIRD_B, BIRD_WING, BIRD_BEAK, DISCO_HI, DISCO_LO)

PALETTE = PIECES
OUTLINE = 3.0
FILL = 134          # 84 % of 160
CENTER = (80.0, 78.5)


def _finish(cv, cy=CENTER[1]):
    out = fit(cv, FILL, CENTER[0], cy)
    soft_shadow(out, 0, 2.6, 2.4, PIECE_SHADOW, 0.34)
    return out


def _poly_sdf(cv, path, scale, ox, oy):
    pts = svg_path(path, scale, ox, oy, n=24)[0]
    return sd_poly(cv.X, cv.Y, pts)


# ---------------------------------------------------------------- red: pick
PICK_PATH = "M20 37 C13 31 5 19 6 11 C7 5 13 3 20 3 C27 3 33 5 34 11 C35 19 27 31 20 37 Z"


def pick_sdf(cv, cx=80.0, cy=80.0, s=1.0):
    k = 3.95 * s
    raw = _poly_sdf(cv, PICK_PATH, k, cx - 20 * k, cy - 20 * k)
    return opening(raw, 7 * s, cv.ss)


def draw_red():
    cv = Canvas(160, 160)
    pal = PIECES["red"]
    X, Y = cv.X, cv.Y
    sil = pick_sdf(cv, 80, 80)
    candy(cv, sil, pal, lw=OUTLINE, depth=30, lift=0.55, shade=0.4)
    # moulded inner ridge
    ridge = sil + 15
    cv.stroke(ridge + 1.2, 2.0, "#E0183F", 0.35, soft=0.6)
    cv.stroke(ridge - 1.0, 1.8, "#FFC2D2", 0.55, soft=0.6)
    # tiny embossed star
    st = opening(sd_star(X, Y, 80, 70, 13, 6), 1.8, cv.ss)
    cv.fill(st + 0.8, "#E0183F", 0.25, soft=0.8)
    cv.fill(st, "#FF7A98", 0.9, soft=0.4)
    cv.fill(np.maximum(st, sd_circle(X, Y, 76, 66, 7)), "#FFB3C6", 0.8, soft=0.8)
    clip = sil + OUTLINE + 2
    rim_gloss(cv, sil, 80, 64, -140, 58, OUTLINE + 3.5, 9, alpha=0.8)
    gloss_drop(cv, 50, 44, 13, 7.5, math.radians(-38), clip, alpha=0.85)
    gloss_drop(cv, 38, 64, 3.6, 3.2, 0, clip, alpha=0.8)
    rim_gloss(cv, sil, 80, 80, 40, 40, OUTLINE + 2, 3.5, alpha=0.35)
    return _finish(cv)


# ------------------------------------------------------- orange: tambourine
def draw_orange():
    cv = Canvas(160, 160)
    light, base, shadow, line = PIECES["orange"]
    X, Y = cv.X, cv.Y
    cx, cy, R = 80.0, 80.0, 55.0
    angles = [math.radians(-90 + 72 * k) for k in range(5)]
    angles = [math.radians(a) for a in (-90, -18, 54, 126, 198)]
    sil = sd_circle(X, Y, cx, cy, R)
    # jingle pairs sitting in slots on the rim
    for a in angles:
        jx, jy = cx + (R + 1) * math.cos(a), cy + (R + 1) * math.sin(a)
        sil = SU(sil, sd_ellipse(X, Y, jx, jy, 15, 11.5, ang=a + math.pi / 2), 5)
    candy(cv, sil, PIECES["orange"], lw=OUTLINE, depth=16, lift=0.55, shade=0.35)
    # drumhead
    head = sd_circle(X, Y, cx, cy, 37.5)
    cv.fill(head - 3.0, line, 0.9)
    inset(cv, head, "#FFE9C9", depth=9, shadow=0.55, hl=0.3, dark="#FFB45E", light="#FFFFFF")
    # printed star on the skin
    st = opening(sd_star(X, Y, cx, cy + 2, 21, 10), 2.6, cv.ss)
    cv.fill(st, "#FFC479", 0.85)
    cv.fill(np.maximum(st, sd_circle(X, Y, cx - 6, cy - 6, 10)), "#FFDDB0", 0.8, soft=1.0)
    # jingles: pairs of little golden cymbals in slots
    for a in angles:
        t = a + math.pi / 2
        tx, ty = math.cos(t), math.sin(t)
        jx, jy = cx + (R + 1) * math.cos(a), cy + (R + 1) * math.sin(a)
        slot = sd_box(X, Y, jx, jy, 12.5, 6.5, 5.0, ang=t)
        cv.fill(slot, "#B04E00", 0.9)
        for off, pal in ((3.4, ("#FFF4C2", "#FFD65A", "#E8A11C", line)),
                         (-2.6, ("#FFFFFF", "#FFE88A", "#F2B230", line))):
            d = sd_ellipse(X, Y, jx + tx * off, jy + ty * off, 10.8, 8.6, ang=t)
            candy(cv, d, pal, lw=1.9, depth=5, rim=0.35, lift=0.6)
            cv.stroke(sd_ellipse(X, Y, jx + tx * off, jy + ty * off, 5.2, 4.0, ang=t), 1.3, "#E39A2A", 0.55)
        cv.fill(sd_ellipse(X, Y, jx - tx * 5.2 - 1.2, jy - ty * 2.6 - 2.4, 3.0, 1.5, ang=t), WHITE, 0.95, soft=0.4)
    clip = sil + OUTLINE + 2
    rim_gloss(cv, sd_circle(X, Y, cx, cy, R), cx, cy, -135, 40, OUTLINE + 2.5, 7.5, alpha=0.8)
    gloss_drop(cv, 64, 64, 9, 5, math.radians(-40), head + 3, alpha=0.85)
    return _finish(cv)


# ------------------------------------------------------ yellow: stage star
def draw_yellow():
    cv = Canvas(160, 160)
    light, base, shadow, line = PIECES["yellow"]
    X, Y = cv.X, cv.Y
    cx, cy = 80.0, 86.0
    sil = opening(sd_star(X, Y, cx, cy, 80, 40), 11, cv.ss)
    candy(cv, sil, PIECES["yellow"], lw=OUTLINE, depth=30, lift=0.5, shade=0.35, stops=(0.0, 0.5, 1.0))
    # soft facets: a ridge from the centre to every tip
    ang = np.arctan2(Y - cy, X - cx)
    step = 2 * math.pi / 5
    tip_dir = np.round((ang + math.pi / 2) / step) * step - math.pi / 2
    rel = (ang - tip_dir + math.pi) % (2 * math.pi) - math.pi
    side = np.sign(rel)
    nxf = np.cos(tip_dir + side * math.pi / 2)
    nyf = np.sin(tip_dir + side * math.pi / 2)
    lit = -(nxf * 0.55 + nyf * 0.83)
    inside = np.clip(0.5 - (sil + OUTLINE + 1.5) * cv.ss, 0, 1)
    fall = smoothstep(2, 30, np.hypot(X - cx, Y - cy))
    k = inside * (0.25 + 0.75 * fall)
    cv.paint(k * np.clip(lit, 0, 1), C("#FFFBD6"), 0.6, "over")
    cv.paint(k * np.clip(-lit, 0, 1), C("#F2A900"), 0.30, "over")
    clip = sil + OUTLINE + 2.5
    gloss_drop(cv, 62, 62, 10, 5.5, math.radians(-36), clip, alpha=0.85)
    gloss_drop(cv, 44, 82, 3.4, 3.0, 0, clip, alpha=0.8)
    rim_gloss(cv, sil, cx, cy, -162, 12, OUTLINE + 2.5, 4.5, alpha=0.6)
    rim_gloss(cv, sil, cx, cy, -108, 10, OUTLINE + 2.5, 4.5, alpha=0.6)
    return _finish(cv)


# ------------------------------------------------------ green: eighth note
def note_sdf(X, Y, ox=0.0, oy=0.0, s=1.0):
    def p(x, y):
        return ox + x * s, oy + y * s
    hx, hy = p(58, 116)
    head = sd_ellipse(X, Y, hx, hy, 34 * s, 25 * s, ang=math.radians(-24))
    sx0, sy0 = p(84, 110)
    sx1, sy1 = p(84, 22)
    stem = sd_capsule(X, Y, sx0, sy0, sx1, sy1, 9.5 * s)
    fl = bez(p(84, 18), p(100, 44), p(142, 50), p(126, 104), n=28)
    flag = sd_polyline(X, Y, fl, list(np.linspace(13, 4.5, len(fl)) * s))
    d = SU(head, stem, 6 * s)
    d = SU(d, flag, 8 * s)
    return d


def draw_green():
    cv = Canvas(160, 160)
    X, Y = cv.X, cv.Y
    sil = note_sdf(X, Y, 0, -2)
    candy(cv, sil, PIECES["green"], lw=OUTLINE, depth=18, lift=0.55, shade=0.4)
    clip = sil + OUTLINE + 2
    gloss_drop(cv, 44, 104, 11, 6, math.radians(-30), clip, alpha=0.85)
    gloss_drop(cv, 33, 118, 3.0, 2.6, 0, clip, alpha=0.8)
    stem_hl = sd_capsule(X, Y, 81, 34, 81, 84, 2.4)
    cv.fill(np.maximum(stem_hl, clip), WHITE, 0.7, soft=0.6)
    fl_hl = sd_polyline(X, Y, bez((92, 26), (104, 44), (124, 50), n=12), list(np.linspace(3.2, 1.2, 13)))
    cv.fill(np.maximum(fl_hl, clip), WHITE, 0.7, soft=0.6)
    return _finish(cv)


# -------------------------------------------------------- blue: cassette
def draw_blue():
    cv = Canvas(160, 160)
    light, base, shadow, line = PIECES["blue"]
    X, Y = cv.X, cv.Y
    cx, cy = 80.0, 80.0
    sil = sd_box(X, Y, cx, cy, 67, 49, 16)
    candy(cv, sil, PIECES["blue"], lw=OUTLINE, depth=12, lift=0.5, shade=0.35)
    # label with a candy stripe
    lab = sd_rect(X, Y, 25, 42, 135, 98, 10)
    inset(cv, lab, "#F2F9FF", depth=4, shadow=0.35, hl=0.2, dark="#9FD0FF", light="#FFFFFF")
    stripe = I(lab + 0.5, sd_rect(X, Y, 20, 45, 140, 54, 0))
    cv.fill(stripe, "#FF7EB6", 0.95)
    stripe2 = I(lab + 0.5, sd_rect(X, Y, 20, 54, 140, 58, 0))
    cv.fill(stripe2, "#FFDB1A", 0.95)
    cv.stroke(lab, 2.0, line, 0.9)
    # tape window with reels
    win = sd_rect(X, Y, 42, 62, 118, 88, 11)
    inset(cv, win, "#CFE8FF", depth=5, shadow=0.5, hl=0.2, dark="#5DAAF5", light="#FFFFFF")
    cv.fill(sd_rect(X, Y, 62, 69, 98, 83, 3), "#7FB9FF", 0.9)
    for rx in (58.0, 102.0):
        reel = sd_circle(X, Y, rx, 75, 10.5)
        candy(cv, reel, ("#FFFFFF", "#FFFFFF", "#CFE3FA", line), lw=2.0, depth=5, rim=0.1)
        hub = sd_circle(X, Y, rx, 75, 5.2)
        for k in range(6):
            a = k * math.pi / 3 + 0.3
            hub = SUB(hub, sd_circle(X, Y, rx + 5.4 * math.cos(a), 75 + 5.4 * math.sin(a), 1.7))
        cv.fill(hub, shadow, 1.0)
        cv.fill(sd_circle(X, Y, rx, 75, 1.9), WHITE, 1)
    cv.stroke(win, 2.0, line, 0.9)
    # bottom trapezoid
    trap = opening(sd_poly(X, Y, [(46, 106), (114, 106), (122, 128), (38, 128)]), 3, cv.ss)
    candy(cv, trap, ("#8CCBFF", "#3A9BFA", "#1C73E0", line), lw=2.0, depth=5, rim=0.3)
    for hx in (62, 98):
        cv.fill(sd_circle(X, Y, hx, 118, 4.2), line, 0.95)
    for (sx, sy) in ((25, 36), (135, 36), (25, 122), (135, 122)):
        cv.fill(sd_circle(X, Y, sx, sy, 3.0), "#FFFFFF", 0.9)
        cv.fill(sd_circle(X, Y, sx, sy, 3.0) + 0.0, line, 0.0)
        cv.stroke(sd_circle(X, Y, sx, sy, 3.0), 1.2, line, 0.9)
    clip = sil + OUTLINE + 2
    rim_gloss(cv, sil, cx, cy, -150, 40, OUTLINE + 2.0, 6, alpha=0.75)
    gloss_drop(cv, 42, 38, 9, 3.8, math.radians(-12), clip, alpha=0.85)
    return _finish(cv)


# -------------------------------------------------- purple: headphones
def phones_sdf(X, Y, cx=80.0, cy=80.0, s=1.0):
    band = sd_arc(X, Y, cx, cy + 6 * s, 48 * s, math.radians(180), math.radians(360), 17 * s)
    lc = sd_box(X, Y, cx - 48 * s, cy + 26 * s, 19 * s, 29 * s, 16 * s)
    rc = sd_box(X, Y, cx + 48 * s, cy + 26 * s, 19 * s, 29 * s, 16 * s)
    return SU(SU(band, lc, 4 * s), rc, 4 * s), band, lc, rc


def draw_purple():
    cv = Canvas(160, 160)
    light, base, shadow, line = PIECES["purple"]
    X, Y = cv.X, cv.Y
    # cushions peek out on the inner side of the cups (behind)
    for sgn in (-1, 1):
        cush = sd_box(X, Y, 80 + sgn * 31, 106, 8, 25, 8)
        candy(cv, cush, ("#FFFFFF", "#F0E4FF", "#C8A8FF", line), lw=2.4, depth=5, rim=0.2)
    sil, band, lc, rc = phones_sdf(X, Y)
    candy(cv, sil, PIECES["purple"], lw=OUTLINE, depth=11, lift=0.6, shade=0.35)
    # caps on the cups
    for sgn in (-1, 1):
        cxp = 80 + sgn * 49
        cap = sd_ellipse(X, Y, cxp, 107, 12.5, 18)
        candy(cv, cap, ("#F3E8FF", "#C79BFF", "#9B52FF", line), lw=2.0, depth=8, rim=0.4, lift=0.6)
        cv.fill(sd_ellipse(X, Y, cxp - 3, 99, 3.6, 5.2, -0.3), WHITE, 0.9, soft=0.5)
    clip = sil + OUTLINE + 2
    rim_gloss(cv, band, 80, 86, -135, 28, OUTLINE + 1.5, 6.5, alpha=0.8)
    rim_gloss(cv, band, 80, 86, -60, 14, OUTLINE + 1.5, 4.0, alpha=0.45)
    gloss_drop(cv, 26, 88, 3.2, 6.5, 0, clip, alpha=0.85)
    return _finish(cv)


PIECE_FUNCS = {"red": draw_red, "orange": draw_orange, "yellow": draw_yellow,
               "green": draw_green, "blue": draw_blue, "purple": draw_purple}


# ==========================================================================
# specials (192x192, glow allowed)
# ==========================================================================
def _glow(cv, sdf, radius, color, alpha, gain=1.4, mode="under"):
    cv.glow_from(np.clip(0.5 - sdf * cv.ss, 0, 1), radius, color, alpha, mode=mode, gain=gain)


def bolt_sdf(X, Y, cx, cy, s=1.0):
    """Horizontal lightning pick: a pointed double bolt spanning the width."""
    P = [(-80, 4), (-22, -30), (-17, -8), (26, -36), (20, -10), (80, -4), (22, 30), (17, 8), (-26, 36), (-20, 10)]
    pts = [(cx + x * s, cy + y * s) for x, y in P]
    return opening(sd_poly(X, Y, pts), 3.5 * s)


def draw_riff():
    cv = Canvas(192, 192)
    X, Y = cv.X, cv.Y
    cx, cy = 96.0, 96.0
    # speed streaks behind
    streaks = cv.blank()
    for (oy, x0, x1, r) in ((-44, 8, 58, 3.4), (46, 14, 66, 3.2), (-60, 30, 66, 2.4), (62, 36, 72, 2.2)):
        for sgn in (-1, 1):
            a, b = cx + sgn * (96 - x0), cx + sgn * (96 - x1)
            d = sd_taper(X, Y, b, cy + oy * 0.55 * sgn, a, cy + oy * 0.55 * sgn, r, 0.6)
            streaks.fill(d, "#8FF0FF", 0.9)
            streaks.fill(d + 1.4, "#FFFFFF", 0.8)
    cv.over(streaks)
    sil = bolt_sdf(X, Y, cx, cy, 1.1)
    _glow(cv, sil - 3, 24, RIFF_GLOW, 0.95, mode="over", gain=1.3)
    _glow(cv, sil, 9, "#9FF4FF", 0.9, mode="over", gain=1.6)
    candy(cv, sil, ("#FFFFFF", "#F4FEFF", "#8FE6FF", RIFF_LINE), lw=3.4, depth=12, lift=0.35, shade=0.55, rim=0.3,
          stops=(0.0, 0.5, 1.0))
    # hot cyan core seam
    core = sd_polyline(X, Y, [(cx - 70, cy + 3), (cx - 20, cy - 14), (cx + 20, cy - 13), (cx + 70, cy - 3)])
    cv.fill(np.maximum(core - 1.6, sil + 7), "#BFF6FF", 0.9, soft=1.2)
    clip = sil + 5.5
    gloss_drop(cv, cx - 42, cy - 8, 13, 3.6, math.radians(-30), clip, alpha=0.95)
    gloss_drop(cv, cx + 30, cy - 18, 8, 2.6, math.radians(-30), clip, alpha=0.8)
    sparkle4(cv, cx + 58, cy - 40, 12, WHITE, glow=6, glow_color=RIFF_GLOW)
    sparkle4(cv, cx - 60, cy + 38, 9, WHITE, glow=5, glow_color=RIFF_GLOW)
    soft_shadow(cv, 0, 3, 3, PIECE_SHADOW, 0.25)
    return cv


def draw_sub():
    cv = Canvas(192, 192)
    X, Y = cv.X, cv.Y
    cx = 96.0
    body = sd_box(X, Y, cx, 96, 56, 76, 20)
    # white trim (kant) = outer rim; the cabinet is inset
    _glow(cv, body - 2, 18, "#FF6FD8", 0.85, gain=1.5)
    cv.fill(body, "#FFFFFF")
    cv.stroke(body, 2.4, "#C7B8FF", 1.0)
    cab = sd_box(X, Y, cx, 96, 49, 69, 15)
    candy(cv, cab, ("#9C90FF", SUB_TOP, SUB_BOT, "#3A2BB8"), lw=2.2, depth=14, grad_dir=(0.3, 1.0),
          lift=0.4, shade=0.35)
    # tweeter (accent yellow)
    tw = sd_circle(X, Y, cx, 50, 14)
    candy(cv, tw, ("#FFFFFF", "#F1EDFF", "#B9B0F5", "#3A2BB8"), lw=2.0, depth=6, rim=0.2)
    t2 = sd_circle(X, Y, cx, 50, 8.5)
    candy(cv, t2, ("#FFF7B0", SUB_ACCENT, "#F5B800", "#C28A00"), lw=1.6, depth=5, rim=0.3)
    cv.fill(sd_ellipse(X, Y, cx - 3, 47, 3.0, 1.8, -0.6), WHITE, 0.9, soft=0.3)
    # woofer
    wy = 116.0
    sur = sd_circle(X, Y, cx, wy, 38)
    candy(cv, sur, ("#FFFFFF", "#F4F0FF", "#C9BEFF", "#3A2BB8"), lw=2.2, depth=6, rim=0.2)
    cone = sd_circle(X, Y, cx, wy, 30)
    inset(cv, cone, SUB_CONE, depth=12, shadow=0.55, hl=0.35, dark="#C2279F", light="#FFC7F0")
    r = np.hypot(X - cx, Y - wy)
    rings = np.abs(((r - 12) % 6.5) - 3.25) - 0.55
    cv.fill(np.maximum(rings, np.maximum(cone + 3, 13 - r)), "#FF9BE5", 0.55)
    cap = sd_circle(X, Y, cx, wy, 12)
    candy(cv, cap, ("#FFFFFF", "#FFFFFF", "#FFC7F0", "#C2279F"), lw=1.8, depth=8, rim=0.2)
    cv.fill(sd_circle(X, Y, cx, wy, 5), SUB_CONE, 1.0)
    cv.fill(sd_ellipse(X, Y, cx - 3.5, wy - 4, 3.2, 2, -0.6), WHITE, 0.9, soft=0.3)
    # accent screws
    for (sx, sy) in ((60, 38), (132, 38), (60, 156), (132, 156)):
        candy(cv, sd_circle(X, Y, sx, sy, 4.2), ("#FFF7B0", SUB_ACCENT, "#F5B800", "#C28A00"), lw=1.2, depth=3,
              rim=0.2)
    # bass waves
    for sgn in (-1, 1):
        for k in range(2):
            arc = sd_arc(X, Y, cx, wy, 70 + k * 12, math.radians(-28 if sgn > 0 else 152),
                         math.radians(28 if sgn > 0 else 208), 4.2 - k)
            cv.fill(arc, "#FF6FD8", 0.9 - 0.3 * k)
            cv.fill(arc + 1.4, WHITE, 0.7 - 0.2 * k)
    clip = cab + 4
    gloss_drop(cv, 64, 50, 6, 18, math.radians(8), clip, alpha=0.6)
    rim_gloss(cv, body, cx, 96, -125, 30, 1.2, 3.5, alpha=0.9)
    soft_shadow(cv, 0, 3, 3, PIECE_SHADOW, 0.3)
    return cv


def draw_bird():
    cv = Canvas(192, 192)
    X, Y = cv.X, cv.Y
    s = 1.0
    cx, cy = 100.0, 104.0
    lay = cv.blank()
    # tail feathers
    tail = None
    for (ang, L, w) in ((-28, 58, 13), (-10, 64, 14), (8, 54, 12)):
        a = math.radians(180 + ang)
        tx, ty = cx - 30 + L * math.cos(a), cy + 4 + L * math.sin(a) * 0.8
        d = sd_taper(X, Y, cx - 26, cy + 6, tx, ty, 10, w * 0.62)
        tail = d if tail is None else SU(tail, d, 3)
    body = sd_ellipse(X, Y, cx - 2, cy + 8, 48, 40, ang=math.radians(-12))
    head = sd_circle(X, Y, cx + 32, cy - 26, 30)
    sil = SU(SU(body, head, 16), tail, 8)
    # white outline (drawn as a slightly grown white sticker edge)
    lay.fill(sil - 4.0, "#FFFFFF")
    candy(lay, sil, (BIRD_A, "#48D6F8", BIRD_B, "#1488C9"), lw=2.2, depth=26, lift=0.5, shade=0.35)
    # tail tips lighter
    for (ang, L, w) in ((-28, 58, 13), (-10, 64, 14), (8, 54, 12)):
        a = math.radians(180 + ang)
        tx, ty = cx - 30 + L * math.cos(a), cy + 4 + L * math.sin(a) * 0.8
        ln = sd_capsule(X, Y, cx - 30 + (L - 38) * math.cos(a), cy + 4 + (L - 38) * math.sin(a) * 0.8, tx, ty, 1.2)
        lay.fill(np.maximum(ln, sil + 5), "#1488C9", 0.45)
    # belly
    belly = I(sd_ellipse(X, Y, cx + 16, cy + 22, 32, 22, ang=math.radians(-20)), sil + 4)
    lay.fill(belly, "#DDFBFF", 0.85, soft=3)
    # wing
    wpts = bez((cx - 20, cy - 4), (cx - 52, cy + 8), (cx - 40, cy + 44), (cx + 8, cy + 30), n=22)
    wing = opening(sd_poly(X, Y, wpts + [(cx + 14, cy + 4)]), 5)
    candy(lay, wing, ("#E9FFB3", BIRD_WING, "#7FD400", "#5E9E00"), lw=2.2, depth=10, lift=0.5, shade=0.3)
    for k in range(3):
        fe = sd_arc(X, Y, cx - 2, cy + 10, (14 + 9 * k), math.radians(110), math.radians(160), 2.6)
        lay.fill(np.maximum(fe, wing + 3), "#7FD400", 0.7)
    # beak
    hx, hy = cx + 32, cy - 26
    beak = opening(sd_poly(X, Y, [(hx + 22, hy - 7), (hx + 46, hy + 3), (hx + 22, hy + 13)]), 2.5)
    candy(lay, beak, ("#FFE7A0", BIRD_BEAK, "#F08A00", "#C26400"), lw=2.0, depth=5, rim=0.3)
    # eye
    ex, ey = hx + 8, hy - 5
    lay.fill(sd_ellipse(X, Y, ex, ey, 8.5, 10), "#2B2345")
    lay.fill(sd_circle(X, Y, ex - 2.2, ey - 3.5, 3.2), WHITE, 1)
    lay.fill(sd_circle(X, Y, ex + 2.6, ey + 3.6, 1.4), WHITE, 0.9)
    # cheek + crest
    lay.fill(sd_ellipse(X, Y, ex - 2, ey + 15, 7, 4.2), "#FF7EB6", 0.6, soft=1.5)
    crest = U(sd_taper(X, Y, hx - 6, hy - 22, hx - 16, hy - 38, 5.5, 3.0),
              sd_taper(X, Y, hx + 2, hy - 24, hx + 4, hy - 40, 5.5, 3.2))
    crest_all = SU(crest, sil, 1)
    _ = crest_all
    lay.fill(crest - 3.5, "#FFFFFF", mode="under")
    candy(lay, crest, (BIRD_A, "#48D6F8", BIRD_B, "#1488C9"), lw=2.0, depth=4, rim=0.2)
    # legs
    for lx in (cx - 8, cx + 12):
        leg = sd_capsule(X, Y, lx, cy + 44, lx + 1, cy + 54, 2.6)
        toe = sd_capsule(X, Y, lx - 4, cy + 55, lx + 6, cy + 55, 2.4)
        lay.fill(U(leg, toe), "#F08A00", 1, mode="under")
        lay.fill(U(leg, toe) - 2.2, WHITE, mode="under")
    clip = sil + 5
    gloss_drop(lay, hx - 12, hy - 14, 9, 5, math.radians(-40), clip, alpha=0.85)
    gloss_drop(lay, cx - 30, cy - 12, 9, 4, math.radians(-25), clip, alpha=0.7)
    lay = fit(lay, 150, 96, 98)
    lay.glow_under(16, BIRD_WING, 0.8, grow=4)
    cv.over(lay)
    sparkle4(cv, 160, 44, 10, WHITE, glow=6, glow_color="#B6FF3B")
    sparkle4(cv, 34, 150, 7, WHITE, glow=4, glow_color="#7EF0FF")
    soft_shadow(cv, 0, 3, 3, PIECE_SHADOW, 0.3)
    return cv


def draw_disco():
    cv = Canvas(192, 192)
    X, Y = cv.X, cv.Y
    cx, cy, R = 96.0, 98.0, 72.0
    x = (X - cx) / R
    y = (Y - cy) / R
    rr = x * x + y * y
    inside = rr < 1
    z = np.sqrt(np.clip(1 - rr, 0, 1))
    tilt = math.radians(16)
    yt = y * math.cos(tilt) - z * math.sin(tilt)
    zt = y * math.sin(tilt) + z * math.cos(tilt)
    lat = np.arcsin(np.clip(-yt, -1, 1))
    lon = np.arctan2(x, zt)
    nrow = 12
    dlat = math.pi / nrow
    row = np.floor((lat + math.pi / 2) / dlat)
    rowc = (row + 0.5) * dlat - math.pi / 2
    ncol = np.maximum(np.round(24 * np.cos(rowc)), 4)
    dlon = 2 * math.pi / ncol
    col = np.floor((lon + math.pi) / dlon)
    lonc = (col + 0.5) * dlon - math.pi
    fx = np.cos(rowc) * np.sin(lonc)
    fyt = -np.sin(rowc)
    fzt = np.cos(rowc) * np.cos(lonc)
    fy = fyt * math.cos(tilt) + fzt * math.sin(tilt)
    fz = -fyt * math.sin(tilt) + fzt * math.cos(tilt)
    Lx, Ly, Lz = -0.5, -0.7, 0.9
    ln = math.sqrt(Lx * Lx + Ly * Ly + Lz * Lz)
    lam = np.clip((fx * Lx + fy * Ly + fz * Lz) / ln, 0, 1)
    # base: radial gradient white -> #B7C2DC, facet jitter
    rad = np.clip(np.hypot(x + 0.35, y + 0.4) / 1.5, 0, 1)
    basec = mix(C(DISCO_HI), C("#E3E9F7"), smoothstep(0, 0.6, rad))
    basec = mix(basec, C(DISCO_LO), smoothstep(0.55, 1.0, rad))
    hsh = (row * 37 + col * 11) % 97
    jit = ((hsh * 53) % 17) / 16.0 - 0.5
    colr = mix(basec, C("#9AA7C7"), np.clip(-jit * 0.5, 0, 1)[..., None] * 1.0)
    colr = mix(colr, WHITE, np.clip(jit * 0.8 + lam * 0.35, 0, 1))
    # coloured facets (the six piece colours)
    tints = np.stack([C(PIECES[k][1]) for k in ORDER])
    tinted = (((hsh * 7) % 4) == 0) & inside
    tidx = (hsh % 6).astype(int)
    tc = tints[tidx]
    tc = mix(tc, WHITE, np.clip(lam * 0.5 + jit * 0.3, 0, 0.6))
    colr = np.where(tinted[..., None], tc, colr)
    spec = (lam ** 16) * 1.1
    colr = colr + (1 - colr) * np.clip(spec, 0, 1)[..., None]
    # grout
    fr = (lat + math.pi / 2) / dlat - row
    fc = (lon + math.pi) / dlon - col
    gr = np.minimum(np.minimum(fr, 1 - fr), np.minimum(fc, 1 - fc))
    groutk = smoothstep(0.075, 0.02, gr) * (z > 0.05)
    colr = mix(colr, C("#A9B3CE"), groutk * 0.8)
    colr = mix(colr, C("#8E98B8"), smoothstep(0.75, 1.0, np.sqrt(rr)) * 0.35)
    ball = sd_circle(X, Y, cx, cy, R)
    # rainbow glow behind
    ang = np.arctan2(Y - cy, X - cx)
    tt = (ang + math.pi) / (2 * math.pi) * 6
    idx = np.floor(tt).astype(int) % 6
    fr2 = (tt - np.floor(tt))[..., None]
    rainbow = tints[idx] * (1 - fr2) + tints[(idx + 1) % 6] * fr2
    glow = cv.blank()
    gg = gblur(np.clip(0.5 - (ball - 3) * cv.ss, 0, 1), 11 * cv.ss / 2)
    glow.paint(np.clip(gg * 1.6, 0, 1), rainbow, 0.8)
    cv.paint(np.clip(0.5 - ball * cv.ss, 0, 1), colr, 1.0)
    cv.stroke(ball + 1.3, 2.6, "#8E98B8", 1.0)
    # cap + loop on top
    capd = sd_box(X, Y, cx, cy - R - 2, 9, 5, 2)
    candy(cv, capd, ("#FFFFFF", "#E3E9F7", "#B7C2DC", "#8E98B8"), lw=1.8, depth=3, mode="over")
    loop = sd_ring(X, Y, cx, cy - R - 11, 5.5, 3.0)
    cv.fill(loop, "#8E98B8")
    rim_gloss(cv, ball, cx, cy, -135, 34, 4, 7, alpha=0.7)
    gloss_drop(cv, 64, 64, 13, 7, math.radians(-40), ball + 4, alpha=0.75)
    cv.under(glow)
    for (sx, sy, sz, c) in ((150, 44, 15, "#FFDB1A"), (42, 150, 9, "#FFFFFF"), (158, 132, 8, "#FFFFFF")):
        sparkle4(cv, sx, sy, sz, C(c), glow=5, glow_color="#FFFFFF")
    soft_shadow(cv, 0, 3, 3, PIECE_SHADOW, 0.25)
    return cv


SPECIAL_FUNCS = {"riff": draw_riff, "sub": draw_sub, "bird": draw_bird, "disco": draw_disco}
