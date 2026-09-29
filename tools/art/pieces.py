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


SHADOW_ALPHA = 0.5      # gives a visible peak of ~32 % just below the piece (spec: 30-35 %)


def _finish(cv, cy=CENTER[1], box=FILL):
    out = fit(cv, box, CENTER[0], cy)
    soft_shadow(out, 0, 2.6, 2.4, PIECE_SHADOW, SHADOW_ALPHA)
    return out


def _poly_sdf(cv, path, scale, ox, oy):
    pts = svg_path(path, scale, ox, oy, n=24)[0]
    return sd_poly(cv.X, cv.Y, pts)


# ---------------------------------------------------------------- red: pick
PICK_PATH = "M20 37 C13 31 5 19 6 11 C7 5 13 3 20 3 C27 3 33 5 34 11 C35 19 27 31 20 37 Z"


def pick_sdf(cv, cx=80.0, cy=80.0, s=1.0, ang=0.0):
    k = 3.95 * s
    pts = svg_path(PICK_PATH, k, cx - 20 * k, cy - 20 * k, n=24)[0]
    if ang:
        ca, sa = math.cos(ang), math.sin(ang)
        pts = [(cx + (x - cx) * ca - (y - cy) * sa, cy + (x - cx) * sa + (y - cy) * ca) for x, y in pts]
    return opening(sd_poly(cv.X, cv.Y, pts), 7 * s, cv.ss)


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
def note_sdf(X, Y, ox=0.0, oy=0.0, s=1.0, bold=False):
    """Eighth note. bold=True is the chunky board-piece version (thicker stem, bigger head, wider flag)."""
    def p(x, y):
        return ox + x * s, oy + y * s
    if bold:
        hx, hy = p(56, 112)
        head = sd_ellipse(X, Y, hx, hy, 46 * s, 35 * s, ang=math.radians(-24))
        stem = sd_capsule(X, Y, *p(86, 104), *p(86, 26), 15.5 * s)
        fl = bez(p(86, 20), p(108, 48), p(154, 50), p(132, 110), n=28)
        flag = sd_polyline(X, Y, fl, list(np.linspace(23, 8.5, len(fl)) * s))
        d = SU(head, stem, 9 * s)
        return SU(d, flag, 12 * s)
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
    sil = note_sdf(X, Y, 0, -2, bold=True)
    candy(cv, sil, PIECES["green"], lw=OUTLINE, depth=22, lift=0.55, shade=0.4)
    clip = sil + OUTLINE + 2
    gloss_drop(cv, 40, 100, 13, 7, math.radians(-30), clip, alpha=0.85)
    gloss_drop(cv, 27, 116, 3.4, 3.0, 0, clip, alpha=0.8)
    stem_hl = sd_capsule(X, Y, 80, 34, 80, 82, 3.0)
    cv.fill(np.maximum(stem_hl, clip), WHITE, 0.7, soft=0.6)
    fl_hl = sd_polyline(X, Y, bez((94, 26), (108, 44), (130, 50), n=12), list(np.linspace(4.0, 1.4, 13)))
    cv.fill(np.maximum(fl_hl, clip), WHITE, 0.7, soft=0.6)
    return _finish(cv, box=141)     # optical sizing: the sparse note reads smaller


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
    return _finish(cv, box=126)


# -------------------------------------------------- purple: headphones
def phones_sdf(X, Y, cx=80.0, cy=80.0, s=1.0):
    band = sd_arc(X, Y, cx, cy + 6 * s, 47 * s, math.radians(180), math.radians(360), 27 * s)
    lc = sd_box(X, Y, cx - 46 * s, cy + 27 * s, 27 * s, 37 * s, 21 * s)
    rc = sd_box(X, Y, cx + 46 * s, cy + 27 * s, 27 * s, 37 * s, 21 * s)
    return SU(SU(band, lc, 5 * s), rc, 5 * s), band, lc, rc


def draw_purple():
    cv = Canvas(160, 160)
    light, base, shadow, line = PIECES["purple"]
    X, Y = cv.X, cv.Y
    # cushions peek out on the inner side of the cups (behind)
    for sgn in (-1, 1):
        cush = sd_box(X, Y, 80 + sgn * 24, 108, 9, 28, 9)
        candy(cv, cush, ("#FFFFFF", "#F0E4FF", "#C8A8FF", line), lw=2.4, depth=5, rim=0.2)
    sil, band, lc, rc = phones_sdf(X, Y)
    candy(cv, sil, PIECES["purple"], lw=OUTLINE, depth=14, lift=0.6, shade=0.35)
    # caps on the cups
    for sgn in (-1, 1):
        cxp = 80 + sgn * 48
        cap = sd_ellipse(X, Y, cxp, 109, 17, 25)
        candy(cv, cap, ("#F3E8FF", "#C79BFF", "#9B52FF", line), lw=2.2, depth=9, rim=0.4, lift=0.6)
        cv.fill(sd_ellipse(X, Y, cxp - 4, 99, 4.2, 6.2, -0.3), WHITE, 0.9, soft=0.5)
    clip = sil + OUTLINE + 2
    rim_gloss(cv, band, 80, 86, -135, 28, OUTLINE + 2.0, 8.5, alpha=0.8)
    rim_gloss(cv, band, 80, 86, -60, 14, OUTLINE + 2.0, 5.0, alpha=0.45)
    gloss_drop(cv, 21, 92, 3.8, 8, 0, clip, alpha=0.85)
    return _finish(cv, box=140)


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
    """Horizontal riff: a lightning bolt through a guitar pick ("molniya-mediator"), pale cyan fill with a
    3 px #1FA8E6 outline so it reads on white cells without relying on the glow."""
    cv = Canvas(192, 192)
    X, Y = cv.X, cv.Y
    cx, cy = 96.0, 96.0
    # speed streaks behind
    streaks = cv.blank()
    for (oy, x0, x1, r) in ((-44, 10, 56, 3.4), (46, 14, 62, 3.2), (-62, 30, 64, 2.4), (62, 34, 70, 2.2)):
        for sgn in (-1, 1):
            a, b = cx + sgn * (96 - x0), cx + sgn * (96 - x1)
            d = sd_taper(X, Y, b, cy + oy * 0.55 * sgn, a, cy + oy * 0.55 * sgn, r, 0.6)
            streaks.fill(d, "#5CD9FF", 0.9)
            streaks.fill(d + 1.4, "#FFFFFF", 0.8)
    cv.over(streaks)
    bolt = bolt_sdf(X, Y, cx, cy, 1.08)
    pk = pick_sdf(cv, cx, cy + 2, s=0.5)
    sil = SU(bolt, pk, 4)
    _glow(cv, sil - 3, 22, RIFF_GLOW, 0.85, mode="over", gain=1.2)
    candy(cv, sil, ("#F2FEFF", "#B8F3FF", "#6FDDFF", RIFF_LINE), lw=3.0, depth=12, lift=0.45, shade=0.45,
          rim=0.35, stops=(0.0, 0.45, 1.0))
    # pick medallion: white face with a cyan ring, the bolt's core crosses it
    inner = pk + 5.5
    candy(cv, inner, ("#FFFFFF", "#FFFFFF", "#D6F8FF", "#6FDDFF"), lw=1.6, depth=6, rim=0.2)
    core = sd_polyline(X, Y, [(cx - 72, cy + 4), (cx - 20, cy - 12), (cx - 2, cy + 2), (cx + 20, cy - 12),
                              (cx + 72, cy - 4)])
    cv.fill(np.maximum(core - 2.2, sil + 6.5), "#E8FCFF", 0.95, soft=0.8)
    zz = sd_polyline(X, Y, [(cx - 8, cy - 10), (cx + 3, cy - 1), (cx - 4, cy + 2), (cx + 7, cy + 12)]) - 2.6
    cv.fill(zz - 1.4, "#FFFFFF", 1.0)
    cv.fill(zz, RIFF_LINE, 1.0)
    clip = sil + 5.0
    gloss_drop(cv, cx - 46, cy - 6, 12, 3.4, math.radians(-30), clip, alpha=0.95)
    gloss_drop(cv, cx + 36, cy - 17, 7, 2.4, math.radians(-30), clip, alpha=0.85)
    gloss_drop(cv, cx - 8, cy - 13, 4, 1.8, math.radians(-20), inner + 2, alpha=0.9)
    sparkle4(cv, cx + 60, cy - 42, 12, WHITE, glow=6, glow_color=RIFF_GLOW)
    sparkle4(cv, cx - 62, cy + 40, 9, WHITE, glow=5, glow_color=RIFF_GLOW)
    soft_shadow(cv, 0, 3, 3, PIECE_SHADOW, 0.3)
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
    # legs + three-toed feet: they start inside the body so they read as attached
    for lx, lean in ((cx - 10, -2.0), (cx + 12, 2.0)):
        leg = sd_capsule(X, Y, lx, cy + 34, lx + lean, cy + 56, 3.0)
        toes = U(*[sd_capsule(X, Y, lx + lean, cy + 56, lx + lean + dx, cy + 60 + abs(dx) * 0.1, 2.4)
                   for dx in (-7.5, 0.5, 8.5)])
        foot = U(leg, toes)
        lay.fill(foot - 2.4, WHITE)
        candy(lay, foot, ("#FFE7A0", "#FFA928", "#F08A00", "#C26400"), lw=1.4, depth=2.5, rim=0.2)
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


def _hash(a, b, salt):
    """Deterministic per-facet hash in [0, 1)."""
    v = np.sin(a * 12.9898 + b * 78.233 + salt * 37.719) * 43758.5453
    return v - np.floor(v)


def draw_disco():
    """Mirror ball: latitude/longitude facets with foreshortening, each facet a flat mirror shaded by its
    own normal, facets in all six piece colours, a big white highlight top-left and an even glow."""
    cv = Canvas(192, 192)
    X, Y = cv.X, cv.Y
    cx, cy, R = 96.0, 99.0, 70.0
    x = (X - cx) / R
    y = (Y - cy) / R
    rr = x * x + y * y
    z = np.sqrt(np.clip(1 - rr, 0, 1))
    # view -> ball space: tilt the north pole toward the viewer, then spin around the axis
    tilt, spin = math.radians(24), math.radians(9)
    yt = y * math.cos(tilt) - z * math.sin(tilt)
    zt = y * math.sin(tilt) + z * math.cos(tilt)
    xs = x * math.cos(spin) + zt * math.sin(spin)
    zs = -x * math.sin(spin) + zt * math.cos(spin)
    lat = np.arcsin(np.clip(-yt, -1, 1))
    lon = np.arctan2(xs, zs)
    nrow = 11
    dlat = math.pi / nrow
    row = np.clip(np.floor((lat + math.pi / 2) / dlat), 0, nrow - 1)
    rowc = (row + 0.5) * dlat - math.pi / 2
    ncol = np.maximum(np.round(2 * nrow * np.cos(rowc)), 3)
    dlon = 2 * math.pi / ncol
    col = np.floor((lon + math.pi) / dlon)
    lonc = (col + 0.5) * dlon - math.pi
    # facet normal (ball space -> view space)
    fxs = np.cos(rowc) * np.sin(lonc)
    fyt = -np.sin(rowc)
    fzs = np.cos(rowc) * np.cos(lonc)
    fx = fxs * math.cos(spin) - fzs * math.sin(spin)
    fzt = fxs * math.sin(spin) + fzs * math.cos(spin)
    fy = fyt * math.cos(tilt) + fzt * math.sin(tilt)
    fz = -fyt * math.sin(tilt) + fzt * math.cos(tilt)
    L = np.array([-0.55, -0.7, 0.75], np.float32)
    L /= np.linalg.norm(L)
    lam = np.clip(fx * L[0] + fy * L[1] + fz * L[2], 0, 1)
    h1 = _hash(row, col, 1.0)
    h2 = _hash(row, col, 2.0)
    # silver mirror facets: environment = bright sky top-left, lavender floor bottom-right
    env = np.clip(0.5 - fy * 0.45 - fx * 0.25, 0, 1)
    base = mix(mix(C(DISCO_LO), C("#8C96BC"), 0.3), C(DISCO_HI),
               np.clip(env * 0.65 + lam * 0.55 + (h1 - 0.5) * 0.5, 0, 1))     # spec: #FFFFFF -> #B7C2DC
    base = mix(base, C("#FFFFFF"), np.clip((h2 > 0.86) * lam * 1.4, 0, 1))          # flashing facets
    base = mix(base, C("#FFB8EE"), np.clip(fy * 0.8 + fx * 0.4, 0, 1) * 0.35)      # pink bounce light
    base = mix(base, C("#9FEFFF"), np.clip(-fx * 0.9, 0, 1) * np.clip(fy + 0.3, 0, 1) * 0.35)
    # coloured facets: all six piece colours, evenly spread
    tints = np.stack([C(PIECES[k][1]) for k in ORDER])
    lights = np.stack([C(PIECES[k][0]) for k in ORDER])
    tinted = h1 < 0.3
    tidx = (np.floor(h2 * 6)).astype(int) % 6
    tcol = tints[tidx] + (lights[tidx] - tints[tidx]) * np.clip(lam * 1.1, 0, 1)[..., None]
    tcol = mix(tcol, C("#FFFFFF"), np.clip((lam - 0.75) * 2.5, 0, 1) * 0.6)
    colr = np.where(tinted[..., None], tcol, base)
    # grout between the facets (thin, lavender grey); thinner toward the rim where facets foreshorten
    fr = (lat + math.pi / 2) / dlat - row
    fc = (lon + math.pi) / dlon - col
    gw = 0.075
    gr = np.minimum(np.minimum(fr, 1 - fr), np.minimum(fc, 1 - fc) * np.clip(ncol / (2 * nrow), 0.4, 1))
    colr = mix(colr, C("#8C96BC"), smoothstep(gw, gw * 0.3, gr) * 0.85)
    # sphere shading: darker rim, soft terminator bottom-right
    rim = smoothstep(0.72, 1.0, np.sqrt(rr))
    colr = mix(colr, C("#7A84B4"), rim * 0.35)
    colr = mix(colr, C("#7078B8"), np.clip((x * 0.5 + y * 0.8) - 0.4, 0, 1) * 0.25)
    ball = sd_circle(X, Y, cx, cy, R)
    # even glow behind: white core fading to lavender-pink
    glow = cv.blank()
    gg = gblur(np.clip(0.5 - (ball - 2) * cv.ss, 0, 1), 12 * cv.ss / 2)
    glow.paint(np.clip(gg * 1.5, 0, 1), C("#F4E8FF"), 0.9)
    gg2 = gblur(np.clip(0.5 - (ball - 8) * cv.ss, 0, 1), 18 * cv.ss / 2)
    glow.paint(np.clip(gg2 * 1.3, 0, 1), C("#E3B8FF"), 0.45, mode="under")
    w = cv.win(ball < 1)
    cv.paint(np.clip(0.5 - ball[w] * cv.ss, 0, 1), colr[w], 1.0, win=w)
    cv.stroke(ball + 1.3, 2.6, "#6E78A6", 1.0)
    # big highlight top-left: soft bloom + bright core + star
    hx, hy = cx - 28, cy - 30
    bloom = np.exp(-((X - hx) ** 2 + (Y - hy) ** 2) / (2 * 19.0 ** 2))
    wb = cv.win(ball < 1)
    cv.paint(np.clip(bloom[wb] * 1.25, 0, 1) * np.clip(0.5 - (ball[wb] + 2) * cv.ss, 0, 1), WHITE, 0.9, win=wb)
    gloss_drop(cv, hx - 5, hy - 5, 17, 10, math.radians(-40), ball + 5, alpha=0.75)
    cv.fill(sd_circle(X, Y, hx, hy, 7), WHITE, 0.95, soft=4)
    sparkle4(cv, hx + 1, hy + 1, 21, WHITE, glow=7, glow_color="#FFFFFF", thin=0.22)
    rim_gloss(cv, ball, cx, cy, -135, 40, 3.5, 5, alpha=0.6)
    # cap + loop on top
    capd = sd_box(X, Y, cx, cy - R - 2, 10, 5.5, 2.2)
    candy(cv, capd, ("#FFFFFF", "#E3E9F7", "#B7C2DC", "#6E78A6"), lw=1.8, depth=3, mode="over")
    loop = sd_ring(X, Y, cx, cy - R - 11.5, 5.5, 3.2)
    cv.fill(loop, "#6E78A6")
    cv.under(glow)
    for (sx, sy, sz, c) in ((156, 50, 14, "#FFDB1A"), (36, 150, 9, "#FFFFFF"), (160, 142, 8, "#FFFFFF")):
        sparkle4(cv, sx, sy, sz, C(c), glow=5, glow_color="#FFFFFF")
    soft_shadow(cv, 0, 3, 3, PIECE_SHADOW, 0.25)
    return cv


SPECIAL_FUNCS = {"riff": draw_riff, "sub": draw_sub, "bird": draw_bird, "disco": draw_disco}
