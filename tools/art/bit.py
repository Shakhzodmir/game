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
    for _ in range(9):
        a = g.random() * 2 * math.pi
        rr = (0.55 + 0.45 * g.random()) * (R - 14)
        x, y = CX + rr * math.cos(a), CY + rr * math.sin(a)
        ang = a + (g.random() - 0.5) * 0.6
        L = 6 + g.random() * 6
        pts = bez((x, y), (x + math.cos(ang + 0.5) * L * 0.6, y + math.sin(ang + 0.5) * L * 0.6),
                  (x + math.cos(ang) * L, y + math.sin(ang) * L), n=6)
        d = np.maximum(sd_polyline(X, Y, pts, list(np.linspace(1.4, 0.4, len(pts)))), body + 7)
        lighter = y < CY + 6
        cv.fill(d, "#FFF4E6" if lighter else "#F2A45C", 0.45 if lighter else 0.25)


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
        # round-bottom "D" smile: flat (slightly smiling) top edge, full round bottom, tongue
        top = my - 5
        m = I(sd_ellipse(X, Y, mx, top, 16, 17), top - Y - 0.02 * (X - mx) ** 2)
        m = opening(m, 2.5)
        cv.fill(m, MOUTH)
        cv.fill(I(sd_ellipse(X, Y, mx + 1, top + 14, 9.5, 6.5), m + 1.2), TONGUE)
        if kind == "grin":
            cv.fill(I(sd_rect(X, Y, mx - 14, top - 2, mx + 14, top + 4.5, 0), m + 1.4), WHITE)
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


def _ears(cv, droop=0.0):
    """Small rounded ears peeking out above the cups (behind the head and the headband)."""
    X, Y = cv.X, cv.Y
    for side in (-1, 1):
        bx, by = CX + side * 58, CY - 40 + droop
        tx, ty = CX + side * 92, CY - 74 + droop
        ear = opening(sd_poly(X, Y, [(bx - side * 16, by - 10), (tx, ty), (bx + side * 16, by + 8)]), 6)
        fur(cv, ear, depth=7, lw=3.0)
        inner = opening(sd_poly(X, Y, [(bx - side * 6, by - 6), (tx - side * 5, ty + 8), (bx + side * 9, by + 3)]), 3)
        cv.fill(inner, "#FFB3C6", 0.85)


def _body(cv):
    X, Y = cv.X, cv.Y
    body = fluff(X, Y, CX, CY, R - 1, R - 3, n=17, amp=4.5, p=1.1, seed=11)
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
    """Fluffy three-lobed fur tuft on top of the head."""
    X, Y = cv.X, cv.Y
    y0 = CY - 60 + droop
    lobes = [sd_ellipse(X, Y, CX - 15, y0 - 7, 11, 13, ang=math.radians(-30)),
             sd_ellipse(X, Y, CX + 1, y0 - 15, 12, 16, ang=math.radians(4)),
             sd_ellipse(X, Y, CX + 16, y0 - 6, 10, 12, ang=math.radians(32))]
    h = SU(SU(lobes[0], lobes[1], 5), lobes[2], 5)
    h = SU(h, sd_ellipse(X, Y, CX, y0 + 6, 22, 9), 6)
    fur(cv, h, depth=9, lw=3.0)
    for (a, b) in (((CX - 8, y0 - 6), (CX - 4, y0 + 2)), ((CX + 8, y0 - 6), (CX + 5, y0 + 2))):
        cv.fill(np.maximum(sd_capsule(X, Y, *a, *b, 1.2), h + 3.5), "#F2A45C", 0.5)
    cv.fill(np.maximum(sd_ellipse(X, Y, CX - 3, y0 - 20, 4, 2.4, ang=-0.4), h + 2), "#FFF4E6", 0.8, soft=0.6)


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


DECK_C = (160.0, 206.0)      # platter centre of the DJ deck (scratch pose)


def _deck(cv):
    X, Y = cv.X, cv.Y
    px, py = DECK_C
    base = sd_rect(X, Y, 78, 196, 236, 236, 11)
    candy(cv, base, ("#E4D6FF", "#B89CFF", "#8B6BF0", "#5A2FE0"), lw=3.0, depth=9, rim=0.4)
    led = sd_capsule(X, Y, 92, 228, 222, 228, 1.6)
    cv.fill(led, "#3CE0FF", 1)
    plat = sd_ellipse(X, Y, px, py, 46, 14.5)
    candy(cv, plat, ("#FFB3D6", "#FF7EB6", "#F0508F", "#C22A6C"), lw=2.4, depth=5, rim=0.3)
    rr = np.hypot((X - px) / 46, (Y - py) / 14.5)
    gro = np.maximum(np.abs(((rr * 8) % 1.0) - 0.5) - 0.18, np.maximum(plat + 3, 0.38 - rr))
    cv.fill(gro * 3, "#FFD1E6", 0.6)
    cv.fill(sd_ellipse(X, Y, px, py, 14.5, 4.8), "#FFDB1A")
    cv.fill(sd_ellipse(X, Y, px, py, 2.2, 1.1), "#C22A6C")
    cv.fill(np.maximum(sd_arc(X, Y, px, py, 34, math.radians(200), math.radians(250), 2.6), plat + 3), WHITE, 0.6)
    for kx, pal in ((98, LIGHT), (114, ("#C7FAFF", "#3CE0FF", "#12A9E0", "#0B7DB8"))):
        candy(cv, sd_circle(X, Y, kx, 216, 4.8), pal, lw=1.5, depth=3)


def draw_bit(pose):
    P = dict(lean=0.0, sx=1.0, sy=1.0, dy=0.0, arms=(20, 20), feet=(0.0, 0.0), eyes="open", mouth="smile",
             brows=None, droop=0.0, look=(0.0, 0.0), ears=False, deck=False)
    P.update(POSES[pose] if isinstance(pose, str) else pose)
    lay = Canvas(256, 256)
    droop = P["droop"]
    if not P["deck"]:
        _feet(lay, P["feet"])
    _ears(lay, droop)
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
        _arm_to(lay, 1, DECK_C[0] + 14, DECK_C[1] - 6)
    else:
        _arm(lay, -1, P["arms"][0])
        _arm(lay, 1, P["arms"][1])
    out = lay.transformed(P["lean"], pivot=(128, 236), sx=P["sx"] * 0.93, sy=P["sy"] * 0.93, dy=P["dy"] + 2)
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
        arc = sd_arc(X, Y, 158, 204, 56 + k * 8, math.radians(-48), math.radians(-4), 3.0)
        cv.fill(arc - 1.6, "#FFFFFF", 0.9 - 0.25 * k)
        cv.fill(arc, "#3CE0FF", 0.95 - 0.25 * k)
    _note(cv, 222, 138, 0.2, PIECES["yellow"], ang=14)
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


# ------------------------------------------------------------------ flipbook frames
# The animations of client/anim.lua (content/animations.json): `bit/<anim>_<n>.png`, 256x256, every frame stands on
# the same ground line. The producer's art (docs/art-brief-chatgpt.md, group A1) replaces these under the same names
# (tools/art/install_ready.py); anything not replaced stays this procedural drawing.
def _zzz(cv, x, y, s, a=1.0):
    X, Y = cv.X, cv.Y
    for k in range(2):
        zx, zy, z = x + k * 22 * s, y - k * 26 * s, (11 - 2 * k) * s
        pts = [(zx - z, zy - z), (zx + z, zy - z), (zx - z, zy + z), (zx + z, zy + z)]
        cv.fill(sd_polyline(X, Y, pts) - 3.6 * s, "#FFFFFF", a)
        cv.fill(sd_polyline(X, Y, pts) - 2.2 * s, "#7B4FFF", a)


def _extras_notepad(k):
    def f(cv):
        X, Y = cv.X, cv.Y
        pad = lambda: sd_rect(X, Y, 150, 176, 236, 238, 6)
        cv.fill(pad() - 3, "#B3A0E8")
        cv.fill(pad(), "#FFFDF4")
        for ly in (194, 207, 220):
            cv.fill(sd_capsule(X, Y, 160, ly, 160 + 52 - (k % 3) * 6, ly, 1.3), "#C9B8F4")
        x = 168 + (k % 3) * 14
        y = 190 + (k % 2) * 9
        cv.fill(sd_capsule(X, Y, x, y, x + 34, y - 44, 3.6) - 1.5, "#FFFFFF")
        cv.fill(sd_capsule(X, Y, x, y, x + 34, y - 44, 3.6), "#FFD23F")
        cv.fill(sd_circle(X, Y, x, y, 3.4), "#3B2A8F")
        if k % 2:
            _note(cv, 210, 172 - 10 * (k % 3), 0.14, PIECES["blue"], ang=8)
    return f


def _extras_listen(k):
    def f(cv):
        _note(cv, 42 + 4 * (k % 2), 70 - 8 * (k % 4), 0.18, PIECES["pink" if "pink" in PIECES else "red"], ang=-10)
        _note(cv, 218 - 4 * (k % 2), 52 + 8 * (k % 3), 0.2, PIECES["green"], ang=10)
        if k % 2 == 0:
            _sparkle(cv, 224, 110, 8, "#3CE0FF")
    return f


def _extras_sleepy(k):
    def f(cv):
        if k >= 1:
            _zzz(cv, 190, 70 - 4 * k, 0.7 + 0.12 * k, 1.0 if k < 3 else 0.8)
    return f


def _extras_surprised(k):
    def f(cv):
        X, Y = cv.X, cv.Y
        if k >= 1:
            for a in (-35, 0, 35):
                ar = math.radians(a - 90)
                cv.fill(sd_capsule(X, Y, 128 + 76 * math.cos(ar), 150 + 82 * math.sin(ar),
                                   128 + 96 * math.cos(ar), 150 + 104 * math.sin(ar), 3.2), "#FFDB1A")
    return f


def _frames():
    F = {}
    F["idle_breathe"] = [dict(arms=(18, 18), sx=sx, sy=sy, dy=dy) for sx, sy, dy in
                         ((1.0, 1.0, 0), (1.015, 0.985, 0), (1.03, 0.97, 1), (1.015, 0.985, 0))]
    F["idle_look"] = [dict(arms=(18, 18), look=lk, eyes=ey) for lk, ey in
                      (((-4, 0), "open"), ((0, 0), "open"), ((4, 0), "open"), ((0, 0), "happy"))]
    F["dance_a"] = [dict(lean=l, sx=sx, sy=sy, arms=a, feet=f, eyes=e, mouth="open", extras=[_extras_dance_a]) for
                    l, sx, sy, a, f, e in
                    ((-9, 1.04, 0.97, (150, 40), (0, 12), "happy"), (-4, 1.0, 1.0, (120, 70), (4, 4), "happy"),
                     (0, 0.98, 1.03, (60, 60), (0, 0), "open"), (5, 1.0, 1.0, (40, 120), (4, 4), "happy"),
                     (9, 1.04, 0.97, (40, 150), (12, 0), "happy"), (0, 1.0, 1.0, (90, 90), (0, 0), "open"))]
    F["dance_b"] = [dict(lean=l, sx=sx, sy=sy, dy=dy, arms=a, feet=f, eyes="open", mouth="o", look=(3, -2),
                         extras=[_extras_dance_b]) for l, sx, sy, dy, a, f in
                    ((9, 0.97, 1.03, 0, (45, 155), (12, 0)), (4, 1.0, 1.0, -6, (80, 130), (6, 6)),
                     (0, 0.96, 1.04, -12, (150, 150), (10, 10)), (-4, 1.0, 1.0, -6, (130, 80), (6, 6)),
                     (-9, 1.03, 0.97, 0, (155, 45), (0, 12)), (0, 1.0, 1.0, 0, (100, 100), (0, 0)))]
    F["cheer"] = [dict(sx=sx, sy=sy, dy=dy, arms=a, feet=f, eyes="happy", mouth="grin", extras=[_extras_happy] if
                       dy < -4 else []) for sx, sy, dy, a, f in
                  ((1.06, 0.92, 4, (40, 40), (0, 0)), (0.99, 1.03, -4, (120, 120), (6, 6)),
                   (0.97, 1.05, -14, (165, 165), (12, 12)), (0.97, 1.05, -16, (170, 170), (12, 12)),
                   (1.0, 1.0, -6, (130, 130), (8, 8)), (1.05, 0.94, 3, (50, 50), (0, 0)))]
    F["surprised"] = [dict(sx=sx, sy=sy, dy=dy, arms=a, feet=f, eyes="open", mouth=m, brows="worried" if k else None,
                           extras=[_extras_surprised(k)]) for k, (sx, sy, dy, a, f, m) in
                      enumerate(((1.0, 1.0, 0, (18, 18), (0, 0), "smile"), (0.96, 1.05, -10, (110, 110), (8, 8), "o"),
                                 (0.94, 1.07, -14, (140, 140), (10, 10), "o"), (1.0, 1.0, -3, (80, 80), (3, 3), "o")))]
    F["sleepy"] = [dict(sx=sx, sy=sy, arms=(8, 8), eyes=e, mouth=m, droop=dr, look=(0, 2), extras=[_extras_sleepy(k)])
                   for k, (sx, sy, e, m, dr) in enumerate(((1.0, 1.0, "sad", "smile", 1), (1.02, 0.98, "squeeze", "smile", 3),
                                                           (1.03, 0.96, "happy", "smile", 5), (1.02, 0.98, "happy", "o", 4)))]
    F["write"] = [dict(arms=(18, 60 + 4 * (k % 3)), eyes="open", mouth="smile", look=(2, 4), lean=2 + k % 2,
                       extras=[_extras_notepad(k)]) for k in range(6)]
    F["listen"] = [dict(ears=True, lean=l, sx=sx, sy=sy, eyes="happy", mouth="smile", extras=[_extras_listen(k)])
                   for k, (l, sx, sy) in enumerate(((-5, 1.0, 1.0), (0, 1.02, 0.98), (5, 1.0, 1.0), (0, 1.02, 0.98)))]
    F["wave"] = [dict(arms=(18, a), eyes="happy" if k % 2 else "open", mouth="grin" if k % 2 else "smile") for k, a in
                 enumerate((110, 150, 175, 150))]
    return F


FRAMES = _frames()
FRAME_ANIMS = ["idle_breathe", "idle_look", "dance_a", "dance_b", "cheer", "surprised", "sleepy", "write", "listen",
               "wave"]


def frame_names():
    """Image paths (relative to assets/images) of every flipbook frame."""
    return ["bit/%s_%d.png" % (a, i + 1) for a in FRAME_ANIMS for i in range(len(FRAMES[a]))]


def draw_frame(anim, n):
    return draw_bit(FRAMES[anim][n - 1])
