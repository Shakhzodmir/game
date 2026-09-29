"""Bit - the mascot: a round fluffy ginger-cream critter in HUGE purple headphones (256x256 poses).

Palette (art-direction v2): fur #FFC98B with #E0873A outline, headphones #7B4FFF, pink cups
#FF4D8D with white rims and yellow lights, blush. Same construction in every pose.
"""
import math

import numpy as np

from artkit import (C, Canvas, WHITE, bez, candy, gloss_drop, mix, opening, rim_gloss, rng, sd_arc, sd_box,
                    sd_capsule, sd_circle, sd_ellipse, sd_poly, sd_polyline, sd_rect, sd_ring, sd_star, sd_taper,
                    smoothstep, soft_shadow, sparkle4, SU, SUB, U, I, inset)
from palette import BIT_FUR, BIT_LINE, BIT_PHONES, BIT_CUPS, BIT_LIGHTS, PIECES, PIECE_SHADOW
from pieces import note_sdf

FUR = ("#FFEBD2", BIT_FUR, "#F6A95E", BIT_LINE)
BELLY = ("#FFFFFF", "#FFF1DE", "#FFD9AE", BIT_LINE)
BAND = ("#C2A8FF", BIT_PHONES, "#5A2FE0", "#4320B8")
CUP = ("#FFB3D1", BIT_CUPS, "#E0306F", "#B3124F")
LIGHT = ("#FFFBD6", BIT_LIGHTS, "#F5B800", "#C28A00")
EYE = "#2B2345"
MOUTH = "#8A2F4E"
TONGUE = "#FF7E9E"
BLUSH = "#FF8FAE"

CX, CY, R = 128.0, 150.0, 68.0


def fluff(X, Y, cx, cy, rx, ry, n=20, amp=6.0, phase=0.0, p=1.6, seed=None):
    """Fluffy ellipse: soft irregular tufts around the rim (deterministic)."""
    g = rng(seed if seed is not None else int(rx * 7 + n))
    cen = [2 * math.pi * j / n + phase + (g.random() - 0.5) * 0.25 for j in range(n)]
    amps = [amp * (0.65 + 0.7 * g.random()) for _ in range(n)]
    half = math.pi / n * 1.25
    pts = []
    for k in range(240):
        t = 2 * math.pi * k / 240
        bump = 0.0
        for c, a in zip(cen, amps):
            dd = (t - c + math.pi) % (2 * math.pi) - math.pi
            if abs(dd) < half:
                bump = max(bump, a * math.cos(dd / half * math.pi / 2) ** p)
        bump *= 0.85 + 0.3 * max(math.sin(t), 0)
        pts.append((cx + (rx + bump) * math.cos(t), cy + (ry + bump) * math.sin(t)))
    return opening(sd_poly(X, Y, pts), 1.5)


def fur(cv, d, depth=None, lw=3.2, **kw):
    args = dict(lift=0.5, shade=0.35, rim=0.45)
    args.update(kw)
    candy(cv, d, FUR, lw=lw, depth=depth, **args)


def fur_strokes(cv, body, seed=5):
    g = rng(seed)
    X, Y = cv.X, cv.Y
    for _ in range(16):
        a = g.random() * 2 * math.pi
        rr = g.random() ** 0.6 * (R - 16)
        x, y = CX + rr * math.cos(a), CY + rr * math.sin(a)
        ang = a + (g.random() - 0.5) * 0.6
        L = 6 + g.random() * 6
        pts = bez((x, y), (x + math.cos(ang + 0.5) * L * 0.6, y + math.sin(ang + 0.5) * L * 0.6),
                  (x + math.cos(ang) * L, y + math.sin(ang) * L), n=6)
        d = np.maximum(sd_polyline(X, Y, pts, list(np.linspace(1.4, 0.4, len(pts)))), body + 7)
        lighter = y < CY + 6
        cv.fill(d, "#FFF4E6" if lighter else "#F2A45C", 0.6 if lighter else 0.35)


def _hand(cv, hx, hy, r=12.5, phase=0.0):
    X, Y = cv.X, cv.Y
    return fluff(X, Y, hx, hy, r, r, n=5, amp=2.5, phase=phase)


def _arm(cv, side, ang_deg, length=27, hand_r=12.5):
    X, Y = cv.X, cv.Y
    sx, sy = CX + side * 54, CY + 24
    a = math.radians(ang_deg)
    ex, ey = sx + side * length * math.sin(a), sy + length * math.cos(a)
    arm = SU(sd_taper(X, Y, sx, sy, ex, ey, 13.5, 11), _hand(cv, ex, ey, hand_r, a), 5)
    fur(cv, arm, depth=9, lw=3.0)
    return ex, ey


def _arm_to(cv, side, tx, ty, hand_r=12.5):
    X, Y = cv.X, cv.Y
    sx, sy = CX + side * 54, CY + 24
    arm = SU(sd_taper(X, Y, sx, sy, tx, ty, 13.5, 11), _hand(cv, tx, ty, hand_r), 5)
    fur(cv, arm, depth=9, lw=3.0)


def _eyes(cv, kind, look=(0.0, 0.0)):
    X, Y = cv.X, cv.Y
    lx, rx_, ey = CX - 24, CX + 24, CY - 8
    for side, ex in ((-1, lx), (1, rx_)):
        k = kind
        if kind == "wink":
            k = "open" if side < 0 else "happy"
        if k in ("open", "sad"):
            ox, oy = ex + look[0], ey + look[1]
            e = sd_ellipse(X, Y, ox, oy, 11, 14.5)
            cv.fill(e, EYE)
            # soft purple iris glow at the bottom
            cv.fill(np.maximum(sd_ellipse(X, Y, ox, oy + 6, 8, 6), e + 1.5), "#6A4FD8", 0.8, soft=2)
            cv.fill(sd_circle(X, Y, ox - 3.5, oy - 5.5, 5.0), WHITE, 1, soft=0.3)
            cv.fill(sd_circle(X, Y, ox + 4, oy + 5, 2.3), WHITE, 0.95, soft=0.3)
            if k == "sad":
                lid = I(sd_ellipse(X, Y, ex, ey, 13.5, 17), sd_poly(X, Y, [(ex - 16, ey - 20), (ex + 16, ey - 20),
                                                                          (ex + 16, ey - 7 + side * 5),
                                                                          (ex - 16, ey - 7 - side * 5)]))
                fur(cv, lid, depth=4, lw=0)
                cv.fill(np.maximum(sd_polyline(X, Y, [(ex - 13, ey - 7 - side * 5), (ex + 13, ey - 7 + side * 5)])
                                   - 1.6, sd_ellipse(X, Y, ex, ey, 13, 16.5)), EYE)
        elif k == "happy":
            arc = sd_arc(X, Y, ex, ey + 6, 10.5, math.radians(200), math.radians(340), 5.2)
            cv.fill(arc, EYE)
        elif k == "squeeze":
            pts = [(ex - side * 10, ey - 10), (ex + side * 8, ey), (ex - side * 10, ey + 10)]
            cv.fill(sd_polyline(X, Y, pts) - 2.8, EYE)


def _mouth(cv, kind):
    X, Y = cv.X, cv.Y
    mx, my = CX, CY + 20
    if kind == "smile":
        cv.fill(sd_arc(X, Y, mx, my - 8, 11, math.radians(30), math.radians(150), 4.2), EYE)
    elif kind in ("open", "grin"):
        m = I(sd_ellipse(X, Y, mx, my, 15, 14), Y - (my - 3))
        m = opening(m, 2)
        cv.fill(m, MOUTH)
        cv.fill(I(sd_ellipse(X, Y, mx, my + 10, 9.5, 6.5), m + 1), TONGUE)
        if kind == "grin":
            cv.fill(I(sd_rect(X, Y, mx - 13, my - 4, mx + 13, my + 1.5, 0), m + 1.5), WHITE)
        cv.stroke(m, 2.6, EYE)
    elif kind == "o":
        m = sd_ellipse(X, Y, mx, my + 2, 7.5, 9)
        cv.fill(m, MOUTH)
        cv.fill(I(sd_ellipse(X, Y, mx, my + 7, 5, 4), m + 1), TONGUE)
        cv.stroke(m, 2.6, EYE)
    elif kind == "wavy":
        pts = [(mx - 14 + i, my + 2 + 3.0 * math.sin(i / 28 * 2 * math.pi * 1.5)) for i in range(0, 29, 2)]
        cv.fill(sd_polyline(X, Y, pts) - 2.2, EYE)
    elif kind == "frown":
        cv.fill(sd_arc(X, Y, mx, my + 12, 10, math.radians(215), math.radians(325), 4.0), EYE)


def _brows(cv, kind):
    X, Y = cv.X, cv.Y
    for side in (-1, 1):
        ex = CX + side * 24
        if kind == "worried":
            a = (ex - side * 10, CY - 30), (ex + side * 8, CY - 36)
        else:
            a = (ex - side * 10, CY - 34), (ex + side * 8, CY - 30)
        cv.fill(sd_capsule(X, Y, a[0][0], a[0][1], a[1][0], a[1][1], 2.6), "#C0652A")


def _headphones_band(cv, droop=0.0):
    X, Y = cv.X, cv.Y
    band = sd_arc(X, Y, CX, CY + droop, 86, math.radians(203), math.radians(337), 18)
    candy(cv, band, BAND, lw=3.0, depth=8, lift=0.6, rim=0.4, grad_dir=(0.6, 1.0))
    rim_gloss(cv, sd_circle(X, Y, CX, CY + droop, 95), CX, CY + droop, -120, 24, 3.2, 5, alpha=0.8)
    # little yellow lights along the band
    for a in (235, 255, 270, 285, 305):
        ar = math.radians(a)
        lx, ly = CX + 86 * math.cos(ar), CY + droop + 86 * math.sin(ar)
        cv.fill(sd_circle(X, Y, lx, ly, 4.2), LIGHT[1])
        cv.fill(sd_circle(X, Y, lx - 1.2, ly - 1.2, 1.5), WHITE, 0.95)


def _cup(cv, side, droop=0.0):
    X, Y = cv.X, cv.Y
    cx, cy = CX + side * 84, CY + 4 + droop
    cush = sd_ellipse(X, Y, cx - side * 17, cy, 13, 33)
    candy(cv, cush, ("#EFE6FF", "#C9B2FF", "#9D7CF5", "#5A2FE0"), lw=2.6, depth=8, rim=0.3)
    shell = sd_ellipse(X, Y, cx, cy, 27, 40)
    cv.fill(shell - 4.0, "#FFFFFF")                          # white rim as in the mockup
    candy(cv, shell, CUP, lw=2.6, depth=16, lift=0.6, rim=0.45)
    cap = sd_ellipse(X, Y, cx + side * 3, cy, 15, 25)
    candy(cv, cap, ("#FFE0EC", "#FF8FBE", "#FF5C9A", "#B3124F"), lw=2.0, depth=8, rim=0.4)
    lt = sd_circle(X, Y, cx + side * 3, cy, 8.5)
    cv.glow_from(np.clip(0.5 - lt * cv.ss, 0, 1), 6, "#FFF6A0", 0.8, mode="over")
    candy(cv, lt, LIGHT, lw=1.6, depth=5, rim=0.3)
    cv.fill(sd_circle(X, Y, cx + side * 3 - 2.5, cy - 3, 2.4), WHITE, 0.95)
    gloss_drop(cv, cx - 10, cy - 22, 4.5, 9, math.radians(-25), shell + 4, alpha=0.85)


def _feet(cv, lift=(0.0, 0.0)):
    X, Y = cv.X, cv.Y
    for side, lf in zip((-1, 1), lift):
        fx, fy = CX + side * 26, 222 - lf
        f = sd_ellipse(X, Y, fx, fy, 20, 12.5, ang=side * math.radians(-8 if lf else 0))
        fur(cv, f, depth=8, lw=3.0)
        cv.fill(sd_ellipse(X, Y, fx, fy + 3, 9, 5), "#FFB3C6", 0.8)
        for k in (-1, 1):
            cv.fill(sd_circle(X, Y, fx + k * 9, fy - 3, 3), "#FFB3C6", 0.8)


def _body(cv):
    X, Y = cv.X, cv.Y
    body = fluff(X, Y, CX, CY, R - 2, R - 4, n=19, amp=6.5, p=0.9, seed=11)
    smooth = sd_ellipse(X, Y, CX, CY, R + 2, R)
    fur(cv, body, depth=58, lw=3.4, shade_sdf=smooth)
    fur_strokes(cv, body)
    belly = I(sd_ellipse(X, Y, CX, CY + 24, 34, 26), body + 6)
    cv.fill(belly, BELLY[1], 0.95, soft=2.5)
    muzzle = I(sd_ellipse(X, Y, CX, CY + 20, 22, 15), body + 6)
    cv.fill(muzzle, "#FFFFFF", 0.7, soft=2.0)
    for side in (-1, 1):
        cv.fill(sd_ellipse(X, Y, CX + side * 40, CY + 12, 10, 6), BLUSH, 0.75, soft=2.0)
        cv.fill(sd_circle(X, Y, CX + side * 40 - 3, CY + 10, 1.6), WHITE, 0.8)
    rim_gloss(cv, sd_ellipse(X, Y, CX, CY, R + 2, R), CX, CY, -130, 32, 5, 7, alpha=0.55)
    return body


def _hair(cv, droop=0.0):
    X, Y = cv.X, cv.Y
    y0 = CY - 58 + droop
    curls = [bez((CX - 10, y0), (CX - 20, y0 - 22), (CX - 34, y0 - 26), n=12),
             bez((CX, y0 - 2), (CX - 2, y0 - 34), (CX + 16, y0 - 44), n=12),
             bez((CX + 10, y0), (CX + 22, y0 - 18), (CX + 34, y0 - 16), n=12)]
    h = None
    for c, r0 in zip(curls, (10, 12, 9)):
        d = sd_polyline(X, Y, c, list(np.linspace(r0, 2.5, len(c))))
        h = d if h is None else SU(h, d, 3)
    fur(cv, h, depth=8, lw=3.0)


# ------------------------------------------------------------------ extras
def _note(cv, x, y, s, pal, ang=0.0):
    lay = cv.blank()
    d = note_sdf(lay.X, lay.Y, x - 84 * s, y - 70 * s, s)
    lay.fill(d - 3.0, "#FFFFFF")
    candy(lay, d, pal, lw=2.4, depth=6, rim=0.35)
    if ang:
        lay = lay.transformed(ang, pivot=(x, y))
    cv.over(lay)


def _sparkle(cv, x, y, sz, col="#FFFFFF"):
    X, Y = cv.X, cv.Y
    d = opening(sd_star(X, Y, x, y, sz, sz * 0.32, n=4, rot=-math.pi / 2), 0.6)
    cv.fill(d - 2.2, "#FFFFFF", 1.0)
    cv.fill(d, col, 1.0)


def _drop(cv, x, y, s, col="#8FE6FF"):
    X, Y = cv.X, cv.Y
    d = SU(sd_circle(X, Y, x, y + 4 * s, 6 * s), sd_poly(X, Y, [(x, y - 9 * s), (x + 4 * s, y + 2 * s),
                                                              (x - 4 * s, y + 2 * s)]), 2 * s)
    cv.fill(d - 2.0, "#FFFFFF")
    candy(cv, d, ("#FFFFFF", col, "#3AA4FF", "#1775E8"), lw=2.0, depth=4, rim=0.3)


def _deck(cv):
    X, Y = cv.X, cv.Y
    base = sd_rect(X, Y, 66, 204, 252, 252, 12)
    candy(cv, base, ("#E4D6FF", "#B89CFF", "#8B6BF0", "#5A2FE0"), lw=3.0, depth=10, rim=0.4)
    led = sd_capsule(X, Y, 82, 243, 238, 243, 1.8)
    cv.fill(led, "#3CE0FF", 1)
    plat = sd_ellipse(X, Y, 172, 216, 54, 17)
    candy(cv, plat, ("#FFB3D6", "#FF7EB6", "#F0508F", "#C22A6C"), lw=2.6, depth=6, rim=0.3)
    rr = np.hypot((X - 172) / 54, (Y - 216) / 17)
    gro = np.maximum(np.abs(((rr * 9) % 1.0) - 0.5) - 0.18, np.maximum(plat + 3, 0.38 - rr))
    cv.fill(gro * 3, "#FFD1E6", 0.6)
    cv.fill(sd_ellipse(X, Y, 172, 216, 17, 5.6), "#FFDB1A")
    cv.fill(sd_ellipse(X, Y, 172, 216, 2.5, 1.2), "#C22A6C")
    cv.fill(np.maximum(sd_arc(X, Y, 172, 216, 40, math.radians(200), math.radians(250), 3), plat + 3), WHITE, 0.6)
    for kx, pal in ((90, LIGHT), (108, ("#C7FAFF", "#3CE0FF", "#12A9E0", "#0B7DB8"))):
        candy(cv, sd_circle(X, Y, kx, 226, 5.5), pal, lw=1.6, depth=3)


def draw_bit(pose):
    P = dict(lean=0.0, sx=1.0, sy=1.0, dy=0.0, arms=(20, 20), feet=(0.0, 0.0), eyes="open", mouth="smile",
             brows=None, droop=0.0, look=(0.0, 0.0), ears=False, deck=False)
    P.update(POSES[pose])
    lay = Canvas(256, 256)
    droop = P["droop"]
    if not P["deck"]:
        _feet(lay, P["feet"])
    _body(lay)
    _eyes(lay, P["eyes"], P["look"])
    _mouth(lay, P["mouth"])
    if P["brows"]:
        _brows(lay, P["brows"])
    _headphones_band(lay, droop)
    _hair(lay, droop)
    _cup(lay, -1, droop)
    _cup(lay, 1, droop)
    if P["deck"]:
        _deck(lay)
    if P["ears"]:
        _arm_to(lay, -1, CX - 82, CY - 8 + droop)
        _arm_to(lay, 1, CX + 82, CY - 8 + droop)
    elif P["deck"]:
        _arm_to(lay, -1, CX - 80, CY - 20)
        _arm_to(lay, 1, 184, 206)
    else:
        _arm(lay, -1, P["arms"][0])
        _arm(lay, 1, P["arms"][1])
    out = lay.transformed(P["lean"], pivot=(128, 236), sx=P["sx"] * 0.97, sy=P["sy"] * 0.97, dy=P["dy"] + 2)
    for fn in P.get("extras", []):
        fn(out)
    soft_shadow(out, 0, 3, 3, PIECE_SHADOW, 0.3)
    return out


def _extras_dance_a(cv):
    _note(cv, 40, 58, 0.26, PIECES["yellow"], ang=-12)
    _note(cv, 222, 40, 0.2, PIECES["blue"], ang=10)
    _sparkle(cv, 214, 92, 9, "#FFDB1A")


def _extras_dance_b(cv):
    _note(cv, 220, 56, 0.26, PIECES["red"], ang=12)
    _note(cv, 36, 36, 0.2, PIECES["green"], ang=-8)
    _sparkle(cv, 44, 98, 9, "#3CE0FF")


def _extras_happy(cv):
    for (x, y, s, c) in ((30, 60, 12, "#FFDB1A"), (226, 50, 14, "#FF5C9A"), (40, 128, 8, "#3CE0FF"),
                         (224, 118, 9, "#FFDB1A"), (128, 14, 8, "#9B52FF")):
        _sparkle(cv, x, y, s, c)


def _extras_worried(cv):
    _drop(cv, 198, 58, 1.2)
    X, Y = cv.X, cv.Y
    for k in range(3):
        a = math.radians(-60 + k * 30)
        cv.fill(sd_capsule(X, Y, 56 + 22 * math.cos(a + math.pi), 58 + 22 * math.sin(a + math.pi),
                           56 + 34 * math.cos(a + math.pi), 58 + 34 * math.sin(a + math.pi), 3.0), "#9B52FF")


def _extras_scratch(cv):
    X, Y = cv.X, cv.Y
    for k in range(3):
        arc = sd_arc(X, Y, 172, 214, 68 + k * 9, math.radians(-42), math.radians(8), 3.4)
        cv.fill(arc - 1.6, "#FFFFFF", 0.9 - 0.25 * k)
        cv.fill(arc, "#3CE0FF", 0.95 - 0.25 * k)
    _note(cv, 228, 150, 0.2, PIECES["yellow"], ang=14)
    _sparkle(cv, 30, 70, 9, "#FF5C9A")


def _extras_sad(cv):
    _drop(cv, CX - 36, CY + 16, 0.9)


POSES = {
    "idle": dict(arms=(18, 18)),
    "dance_a": dict(lean=-9, sx=1.04, sy=0.97, arms=(150, 40), feet=(0, 12), eyes="happy", mouth="open",
                    extras=[_extras_dance_a]),
    "dance_b": dict(lean=9, sx=0.97, sy=1.03, arms=(45, 155), feet=(12, 0), eyes="open", mouth="o",
                    look=(3, -2), extras=[_extras_dance_b]),
    "happy": dict(sy=1.02, dy=-8, arms=(160, 160), feet=(8, 8), eyes="happy", mouth="grin",
                  extras=[_extras_happy]),
    "worried": dict(sx=1.02, sy=0.97, ears=True, eyes="squeeze", mouth="wavy", brows="worried",
                    extras=[_extras_worried]),
    "scratch": dict(lean=-4, deck=True, eyes="wink", mouth="grin", extras=[_extras_scratch]),
    "sad": dict(sx=1.03, sy=0.95, arms=(8, 8), eyes="sad", mouth="frown", brows="sad", droop=5, look=(0, 3),
                extras=[_extras_sad]),
}
POSE_ORDER = ["idle", "dance_a", "dance_b", "happy", "worried", "scratch", "sad"]
