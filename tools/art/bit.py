"""Bit - the mascot: a small fluffy creature with HUGE headphones (256x256 poses)."""
import math

import numpy as np

from artkit import (C, Canvas, INK, WHITE, bez, darken, droplet, lighten, mix, opening, rng, sd_arc, sd_box,
                    sd_capsule, sd_circle, sd_ellipse, sd_poly, sd_polyline, sd_rect, sd_ring, sd_star, sd_taper,
                    smoothstep, SU, SUB, U, I, vol, inset)
from pieces import note_sdf

FUR = ("#5ADCE3", "#CFFCFF", "#2B8FB8")       # base, light, shadow
MUZZLE = "#E6FFFD"
PHONES = ("#FF4FD8", "#FFB8F1", "#A0168A")
CAP = ("#FFE66D", "#FFFBD8", "#D9A21A")
CUSH = ("#3A2E6E", "#6E60B8", "#1C1540")
BLUSH = "#FF7AB8"
MOUTH = "#5A1238"
TONGUE = "#FF6F91"

CX, CY, R = 128.0, 148.0, 70.0


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


def fur_vol(cv, d, depth=None, **kw):
    args = dict(light=FUR[1], dark=FUR[2], line=INK, lw=3.2, spec=0.08, grad=0.5, lift=0.6, shade=0.55, rim=0.4)
    args.update(kw)
    vol(cv, d, FUR[0], depth=depth, **args)


def fur_strokes(cv, body, seed=5):
    g = rng(seed)
    X, Y = cv.X, cv.Y
    for _ in range(18):
        a = g.random() * 2 * math.pi
        rr = g.random() ** 0.6 * (R - 14)
        x, y = CX + rr * math.cos(a), CY + rr * math.sin(a)
        ang = a + (g.random() - 0.5) * 0.6
        L = 6 + g.random() * 6
        pts = bez((x, y), (x + math.cos(ang + 0.5) * L * 0.6, y + math.sin(ang + 0.5) * L * 0.6),
                  (x + math.cos(ang) * L, y + math.sin(ang) * L), n=6)
        d = np.maximum(sd_polyline(X, Y, pts, list(np.linspace(1.4, 0.4, len(pts)))), body + 6)
        lighter = y < CY + 10
        cv.fill(d, FUR[1] if lighter else FUR[2], 0.45 if lighter else 0.35)


def _arm(cv, side, ang_deg, length=27, hand_r=12.5):
    X, Y = cv.X, cv.Y
    sx, sy = CX + side * 56, CY + 26
    a = math.radians(ang_deg)
    ex, ey = sx + side * length * math.sin(a), sy + length * math.cos(a)
    arm = SU(sd_taper(X, Y, sx, sy, ex, ey, 13.5, 11), fluff(X, Y, ex, ey, hand_r, hand_r, n=5, amp=2.5, phase=a), 5)
    fur_vol(cv, arm, depth=9, lw=3.0)
    return ex, ey


def _arm_to(cv, side, tx, ty, hand_r=12.5):
    X, Y = cv.X, cv.Y
    sx, sy = CX + side * 56, CY + 26
    arm = SU(sd_taper(X, Y, sx, sy, tx, ty, 13.5, 11), fluff(X, Y, tx, ty, hand_r, hand_r, n=5, amp=2.5), 5)
    fur_vol(cv, arm, depth=9, lw=3.0)


def _eyes(cv, kind, look=(0.0, 0.0)):
    X, Y = cv.X, cv.Y
    lx, rx_, ey = CX - 25, CX + 25, CY - 8
    for side, ex in ((-1, lx), (1, rx_)):
        k = kind
        if kind == "wink":
            k = "open" if side < 0 else "happy"
        if k in ("open", "sad"):
            e = sd_ellipse(X, Y, ex + look[0], ey + look[1], 11.5, 15.5)
            cv.fill(e, "#1A1433")
            cv.fill(sd_circle(X, Y, ex + look[0] - 3.5, ey + look[1] - 6, 5.2), WHITE, 1, soft=0.3)
            cv.fill(sd_circle(X, Y, ex + look[0] + 4, ey + look[1] + 6, 2.4), WHITE, 0.9, soft=0.3)
            if k == "sad":
                lid = I(sd_ellipse(X, Y, ex, ey, 13.5, 17.5), sd_poly(X, Y, [(ex - 16, ey - 20), (ex + 16, ey - 20),
                                                                            (ex + 16, ey - 8 + side * 5),
                                                                            (ex - 16, ey - 8 - side * 5)]))
                fur_vol(cv, lid, depth=4, lw=0)
                cv.stroke(np.maximum(sd_polyline(X, Y, [(ex - 13, ey - 8 - side * 5), (ex + 13, ey - 8 + side * 5)]),
                                     sd_ellipse(X, Y, ex, ey, 13, 17)), 3.0, INK)
        elif k == "happy":
            arc = sd_arc(X, Y, ex, ey + 6, 11, math.radians(200), math.radians(340), 5.0)
            cv.fill(arc, "#1A1433")
        elif k == "squeeze":
            pts = [(ex - side * 10, ey - 10), (ex + side * 8, ey), (ex - side * 10, ey + 10)]
            cv.fill(sd_polyline(X, Y, pts) - 2.8, "#1A1433")


def _mouth(cv, kind):
    X, Y = cv.X, cv.Y
    mx, my = CX, CY + 20
    if kind == "smile":
        cv.fill(sd_arc(X, Y, mx, my - 8, 12, math.radians(30), math.radians(150), 4.2), "#1A1433")
    elif kind in ("open", "grin"):
        m = I(sd_ellipse(X, Y, mx, my, 16, 15), Y - (my - 3))
        m = opening(m, 2)
        cv.fill(m, MOUTH)
        cv.fill(I(sd_ellipse(X, Y, mx, my + 11, 10, 7), m + 1), TONGUE)
        if kind == "grin":
            cv.fill(I(sd_rect(X, Y, mx - 14, my - 4, mx + 14, my + 2, 0), m + 1.5), WHITE)
        cv.stroke(m, 3.0, "#1A1433")
    elif kind == "o":
        m = sd_ellipse(X, Y, mx, my + 2, 7.5, 9.5)
        cv.fill(m, MOUTH)
        cv.fill(I(sd_ellipse(X, Y, mx, my + 7, 5, 4), m + 1), TONGUE)
        cv.stroke(m, 3.0, "#1A1433")
    elif kind == "wavy":
        pts = [(mx - 14 + i, my + 2 + 3.0 * math.sin(i / 28 * 2 * math.pi * 1.5)) for i in range(0, 29, 2)]
        cv.fill(sd_polyline(X, Y, pts) - 2.2, "#1A1433")
    elif kind == "frown":
        cv.fill(sd_arc(X, Y, mx, my + 12, 11, math.radians(215), math.radians(325), 4.0), "#1A1433")


def _brows(cv, kind):
    X, Y = cv.X, cv.Y
    for side in (-1, 1):
        ex = CX + side * 25
        if kind == "worried":
            a = (ex - side * 10, CY - 30), (ex + side * 8, CY - 36)
        else:   # sad
            a = (ex - side * 10, CY - 34), (ex + side * 8, CY - 30)
        a = ((a[0][0], a[0][1]), (a[1][0], a[1][1]))
        cv.fill(sd_capsule(X, Y, a[0][0], a[0][1], a[1][0], a[1][1], 2.6), "#1A1433")


def _headphones_band(cv, droop=0.0):
    X, Y = cv.X, cv.Y
    band = sd_arc(X, Y, CX, CY + droop, 86, math.radians(203), math.radians(337), 17)
    vol(cv, band, PHONES[0], light=PHONES[1], dark=PHONES[2], line=INK, lw=3.2, depth=8, spec=0.6)
    pad = sd_arc(X, Y, CX, CY + droop, 80, math.radians(232), math.radians(308), 7)
    vol(cv, pad, CUSH[0], light=CUSH[1], dark=CUSH[2], line=INK, lw=2.0, depth=3, spec=0.3)


def _cup(cv, side, droop=0.0):
    X, Y = cv.X, cv.Y
    cx, cy = CX + side * 84, CY + 4 + droop
    cush = sd_ellipse(X, Y, cx - side * 17, cy, 13, 33)
    vol(cv, cush, CUSH[0], light=CUSH[1], dark=CUSH[2], line=INK, lw=3.0, depth=8, spec=0.3)
    shell = sd_ellipse(X, Y, cx, cy, 27, 40)
    vol(cv, shell, PHONES[0], light=PHONES[1], dark=PHONES[2], line=INK, lw=3.4, depth=16, spec=0.6)
    cap = sd_ellipse(X, Y, cx + side * 4, cy, 16, 26)
    vol(cv, cap, CAP[0], light=CAP[1], dark=CAP[2], line=INK, lw=2.6, depth=8, spec=0.7)
    st = opening(sd_star(X, Y, cx + side * 4, cy + 1, 10, 4.6), 1)
    cv.fill(st, "#FF4FD8", 0.95)
    droplet(cv, bez((cx - 16, cy + 6), (cx - 16, cy - 20), (cx - 4, cy - 32), n=10), np.linspace(3.6, 1.3, 11),
            alpha=0.7, clip_sdf=shell + 4)


def _feet(cv, lift=(0.0, 0.0)):
    X, Y = cv.X, cv.Y
    for side, lf in zip((-1, 1), lift):
        fx, fy = CX + side * 25, 223 - lf
        f = sd_ellipse(X, Y, fx, fy, 20, 12, ang=side * math.radians(8 if lf else 0) * -1)
        fur_vol(cv, f, depth=8, lw=3.0, grad=0.7)
        for k in (-1, 1):
            cv.fill(np.maximum(sd_capsule(X, Y, fx + k * 6, fy + 5, fx + k * 6, fy + 10, 0.9), f + 3), INK, 0.7)


def _body(cv):
    X, Y = cv.X, cv.Y
    body = fluff(X, Y, CX, CY, R - 2, R - 4, n=19, amp=6.5, p=0.9, seed=11)
    smooth = sd_ellipse(X, Y, CX, CY, R + 2, R)
    fur_vol(cv, body, depth=58, lw=3.4, shade_sdf=smooth)
    fur_strokes(cv, body)
    muzzle = I(sd_ellipse(X, Y, CX, CY + 21, 23, 16), body + 6)
    vol(cv, muzzle, MUZZLE, light="#FFFFFF", dark="#9FE3EA", depth=16, spec=0.0, grad=0.4, lift=0.5, shade=0.35)
    # blush
    for side in (-1, 1):
        cv.fill(sd_ellipse(X, Y, CX + side * 40, CY + 14, 9, 5.5), BLUSH, 0.55, soft=1.8)
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
    fur_vol(cv, h, depth=8, lw=3.0)


# ------------------------------------------------------------------ extras
def _note(cv, x, y, s, col, ang=0.0):
    lay = cv.blank()
    d = note_sdf(lay.X, lay.Y, x - 80 * s, y - 76 * s, s)
    vol(lay, d, col, line=INK, lw=2.4, depth=6, spec=0.5)
    if ang:
        lay = lay.transformed(ang, pivot=(x, y))
    cv.over(lay)


def _sparkle(cv, x, y, sz, col="#FFFFFF"):
    X, Y = cv.X, cv.Y
    d = opening(sd_star(X, Y, x, y, sz, sz * 0.32, n=4, rot=-math.pi / 2), 0.6)
    cv.fill(d - 1.8, INK, 0.9)
    cv.fill(d, col, 1.0)


def _drop(cv, x, y, s, col="#8FE6FF"):
    X, Y = cv.X, cv.Y
    d = SU(sd_circle(X, Y, x, y + 4 * s, 6 * s), sd_poly(X, Y, [(x, y - 9 * s), (x + 4 * s, y + 2 * s),
                                                              (x - 4 * s, y + 2 * s)]), 2 * s)
    vol(cv, d, col, light="#FFFFFF", dark="#3A9AD9", line=INK, lw=2.2, depth=4, spec=0.7)


def _deck(cv):
    X, Y = cv.X, cv.Y
    base = sd_rect(X, Y, 70, 206, 250, 250, 10)
    vol(cv, base, "#3A2E6E", light="#7A6CC8", dark="#1A1238", line=INK, lw=3.2, depth=10, spec=0.4)
    cv.fill(sd_capsule(X, Y, 84, 240, 236, 240, 1.4), "#3CF2FF", 0.9)
    plat = sd_ellipse(X, Y, 172, 214, 54, 17)
    vol(cv, plat, "#2A2440", light="#5D5585", dark="#120F20", line=INK, lw=3, depth=6, spec=0.6)
    rr = np.hypot((X - 172) / 54, (Y - 214) / 17)
    gro = np.maximum(np.abs(((rr * 9) % 1.0) - 0.5) - 0.18, np.maximum(plat + 3, 0.38 - rr))
    cv.fill(gro * 3, "#4A4270", 0.6)
    cv.fill(sd_ellipse(X, Y, 172, 214, 18, 6), "#FF4FD8")
    cv.fill(sd_ellipse(X, Y, 172, 214, 2.5, 1.2), INK)
    # knobs + fader
    for kx in (92, 108):
        vol(cv, sd_circle(X, Y, kx, 226, 5), CAP[0], light=CAP[1], dark=CAP[2], line=INK, lw=1.6, depth=3)


def draw_bit(pose):
    P = dict(lean=0.0, sx=1.0, sy=1.0, dy=0.0, arms=(20, 20), feet=(0.0, 0.0), eyes="open", mouth="smile",
             brows=None, droop=0.0, look=(0.0, 0.0), ears=False, deck=False)
    P.update(POSES[pose])
    lay = Canvas(256, 256)
    X, Y = lay.X, lay.Y
    droop = P["droop"]
    if not P["deck"]:
        _feet(lay, P["feet"])
    # arms behind the body when pointing down/out
    body = _body(lay)
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
        _arm_to(lay, -1, CX - 80, CY - 6 + droop)
        _arm_to(lay, 1, CX + 80, CY - 6 + droop)
    elif P["deck"]:
        _arm_to(lay, -1, CX - 78, CY - 18)
        _arm_to(lay, 1, 186, 204)
    else:
        _arm(lay, -1, P["arms"][0])
        _arm(lay, 1, P["arms"][1])
    del body
    # pose transform (lean + squash about the feet)
    out = lay.transformed(P["lean"], pivot=(128, 238), sx=P["sx"], sy=P["sy"], dy=P["dy"])
    for fn in P.get("extras", []):
        fn(out)
    out.shadow_under(0, 3, 1.5, "#000000", 0.18)
    return out


def _extras_dance_a(cv):
    _note(cv, 38, 58, 0.26, "#FFE66D", ang=-12)
    _note(cv, 222, 40, 0.2, "#3CF2FF", ang=10)
    _sparkle(cv, 214, 92, 9)


def _extras_dance_b(cv):
    _note(cv, 222, 54, 0.26, "#FF8E72", ang=12)
    _note(cv, 36, 34, 0.2, "#C6FF4D", ang=-8)
    _sparkle(cv, 44, 96, 9)


def _extras_happy(cv):
    for (x, y, s, c) in ((30, 60, 12, "#FFE66D"), (226, 50, 14, "#FFE66D"), (40, 128, 8, "#FFFFFF"),
                         (224, 118, 9, "#FFFFFF"), (128, 12, 8, "#3CF2FF")):
        _sparkle(cv, x, y, s, c)


def _extras_worried(cv):
    _drop(cv, 196, 60, 1.2)
    X, Y = cv.X, cv.Y
    for k in range(3):
        a = math.radians(-60 + k * 30)
        cv.fill(sd_capsule(X, Y, 56 + 22 * math.cos(a + math.pi), 60 + 22 * math.sin(a + math.pi),
                           56 + 34 * math.cos(a + math.pi), 60 + 34 * math.sin(a + math.pi), 2.6), INK)


def _extras_scratch(cv):
    X, Y = cv.X, cv.Y
    for k in range(3):
        arc = sd_arc(X, Y, 172, 214, 66 + k * 9, math.radians(-40), math.radians(10), 3.2)
        cv.fill(arc, "#3CF2FF", 0.9 - 0.25 * k)
    _note(cv, 230, 150, 0.2, "#FFE66D", ang=14)
    _sparkle(cv, 30, 70, 9, "#FF4FD8")


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
