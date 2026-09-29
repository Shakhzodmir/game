"""Board pieces (160x160) and special pieces (192x192)."""
import math

import numpy as np

from artkit import (C, Canvas, F32, WHITE, bez, closing, darken, droplet, gblur, inset, lighten, mix,
                    opening, rng, sd_arc, sd_box, sd_capsule, sd_circle, sd_ellipse, sd_poly,
                    sd_polyline, sd_rect, sd_ring, sd_star, sd_taper, sdf_from_mask, smoothstep, SU,
                    SUB, U, I, vol)

# plan p.32: base, highlight, shadow+outline
PALETTE = {
    "red": ("#FF3B5C", "#FF8FA3", "#B80F35"),
    "orange": ("#FF8C1A", "#FFC380", "#B85A00"),
    "yellow": ("#FFD60A", "#FFF2A6", "#C29B00"),
    "green": ("#22D98A", "#9CF5CB", "#0B8F58"),
    "blue": ("#2F9BFF", "#A6D4FF", "#0A58B8"),
    "purple": ("#8E3DFF", "#C9A3FF", "#5A12C4"),
}
ORDER = ["red", "orange", "yellow", "green", "blue", "purple"]
OUTLINE = 3.0


def _body(cv, sil, pal, **kw):
    base, hi, sh = pal
    args = dict(light=hi, dark=sh, line=sh, lw=OUTLINE, grad=0.55, lift=0.6, shade=0.55, spec=0.45)
    args.update(kw)
    vol(cv, sil, base, **args)


def _finish(cv, drop_pts, drop_r, clip, dot=None):
    droplet(cv, drop_pts, drop_r, alpha=0.7, clip_sdf=clip)
    if dot is not None:
        x, y, r = dot
        cv.fill(np.maximum(sd_circle(cv.X, cv.Y, x, y, r), clip), WHITE, 0.7, soft=0.5)
    cv.shadow_under(0, 2, 0.8, "#000000", 0.2)


# ---------------------------------------------------------------- red: pick
def pick_sdf(cv, cx=80.0, cy=80.0, s=1.0, ang=0.0):
    """Guitar pick (rounded triangle with bulging sides), pointing down."""
    ca, sa = math.cos(ang), math.sin(ang)

    def P(x, y):
        x, y = x * s, y * s
        return (cx + x * ca - y * sa, cy + x * sa + y * ca)

    tl, tr, b = (-66, -52), (66, -52), (0, 76)
    pts = []
    pts += bez(P(*tl), P(0, -74), P(*tr), n=20)[:-1]
    pts += bez(P(*tr), P(50, 22), P(*b), n=20)[:-1]
    pts += bez(P(*b), P(-50, 22), P(*tl), n=20)[:-1]
    raw = sd_poly(cv.X, cv.Y, pts)
    return opening(raw, 17 * s, cv.ss)


def draw_red():
    cv = Canvas(160, 160)
    pal = PALETTE["red"]
    sil = pick_sdf(cv, 80, 80)
    _body(cv, sil, pal, depth=26)
    # engraved inner contour, like a moulded pick
    inner = sil + 17
    cv.stroke(inner, 2.2, darken(pal[0], 0.28), 0.55)
    cv.stroke(inner - 1.6, 1.4, lighten(pal[0], 0.5), 0.45)
    clip = sil + OUTLINE + 5
    _finish(cv, bez((30, 60), (38, 34), (70, 28), n=16), np.linspace(8.5, 3.0, 17), clip, dot=(26, 76, 3.8))
    return cv


# ------------------------------------------------------- orange: tambourine
def draw_orange():
    cv = Canvas(160, 160)
    base, hi, sh = PALETTE["orange"]
    X, Y = cv.X, cv.Y
    cx, cy, R = 80.0, 80.0, 58.0
    angles = [math.radians(-90 + 60 * k + 30) for k in range(6)]
    sil = sd_circle(X, Y, cx, cy, R)
    for a in angles:
        jx, jy = cx + 57 * math.cos(a), cy + 57 * math.sin(a)
        sil = SU(sil, sd_ellipse(X, Y, jx, jy, 13.5, 9.5, ang=a + math.pi / 2), 4.0)
    _body(cv, sil, (base, hi, sh), depth=15, spec=0.35)
    # drumhead
    head = sd_circle(X, Y, cx, cy, 37.0)
    inset(cv, head, "#FFDDB0", depth=8, shadow=0.6, hl=0.25, dark="#E08A32", light="#FFF6EA")
    cv.stroke(sd_circle(X, Y, cx, cy, 37.5), 2.4, sh, 0.9)
    cv.fill(opening(sd_star(X, Y, cx + 1, cy + 2, 17, 8), 1.6, cv.ss), "#FFB866", 0.9)
    # slots with pairs of jingles
    for a in angles:
        t = a + math.pi / 2
        sx, sy = cx + 48 * math.cos(a), cy + 48 * math.sin(a)
        slot = sd_box(X, Y, sx, sy, 12.5, 6.0, 4.0, ang=t)
        inset(cv, slot, "#5A2A00", depth=3, shadow=0.5)
        jx, jy = cx + 55 * math.cos(a), cy + 55 * math.sin(a)
        tx, ty = math.cos(t), math.sin(t)
        back = sd_ellipse(X, Y, jx + tx * 3.5, jy + ty * 3.5, 10.5, 7.2, ang=t)
        vol(cv, back, "#E0A640", light="#FFE9A8", dark="#8A5200", line=sh, lw=2.0, depth=5, spec=0.3)
        front = sd_ellipse(X, Y, jx - tx * 2.5, jy - ty * 2.5, 10.5, 7.2, ang=t)
        vol(cv, front, "#FFE08A", light="#FFFCEB", dark="#C9861C", line=sh, lw=2.0, depth=5, spec=0.8)
        cv.fill(sd_circle(X, Y, jx - tx * 2.5, jy - ty * 2.5, 2.3), sh, 0.9)
    clip = sil + OUTLINE + 4
    _finish(cv, bez((32, 70), (36, 44), (58, 30), n=16), np.linspace(8.0, 2.8, 17), clip, dot=(30, 86, 3.6))
    return cv


# ------------------------------------------------------ yellow: stage star
def draw_yellow():
    cv = Canvas(160, 160)
    base, hi, sh = PALETTE["yellow"]
    X, Y = cv.X, cv.Y
    cx, cy = 80.0, 86.0
    sil = opening(sd_star(X, Y, cx, cy, 82, 40), 11, cv.ss)
    _body(cv, sil, (base, hi, sh), depth=30, grad=0.5)
    # soft facets: ridges from the centre to each tip
    ang = np.arctan2(Y - cy, X - cx)
    rel = (ang + math.pi / 2) % (2 * math.pi / 5) - math.pi / 5    # -36..36 deg around each tip ray
    inside = np.clip(0.5 - (sil + OUTLINE + 1) * cv.ss, 0, 1)
    fall = smoothstep(0, 40, np.hypot(X - cx, Y - cy))
    # which side of the ridge faces the light (top-left)
    tip_dir = (np.round((ang + math.pi / 2) / (2 * math.pi / 5)) * (2 * math.pi / 5)) - math.pi / 2
    side = np.sign(rel)
    nxf = np.cos(tip_dir + side * math.pi / 2)
    nyf = np.sin(tip_dir + side * math.pi / 2)
    lit = -(nxf * 0.55 + nyf * 0.83)
    k = inside * (0.35 + 0.65 * fall)
    cv.paint(k * np.clip(lit, 0, 1), C(hi), 0.45, "over")
    cv.paint(k * np.clip(-lit, 0, 1), C(sh), 0.28, "over")
    clip = sil + OUTLINE + 4
    _finish(cv, bez((50, 70), (58, 52), (74, 38), n=16), np.linspace(7.5, 2.6, 17), clip, dot=(44, 84, 3.4))
    return cv


# ------------------------------------------------------ green: eighth note
def note_sdf(X, Y, ox=0.0, oy=0.0, s=1.0):
    def p(x, y):
        return ox + x * s, oy + y * s
    hx, hy = p(58, 114)
    head = sd_ellipse(X, Y, hx, hy, 33 * s, 25 * s, ang=math.radians(-24))
    sx0, sy0 = p(83, 108)
    sx1, sy1 = p(83, 18)
    stem = sd_capsule(X, Y, sx0, sy0, sx1, sy1, 8.5 * s)
    fl = bez(p(84, 20), p(98, 48), p(140, 52), p(124, 104), n=24)
    flag = sd_polyline(X, Y, fl, list(np.linspace(11.5, 4.0, len(fl)) * s))
    d = SU(head, stem, 6 * s)
    d = SU(d, flag, 7 * s)
    return d


def draw_green():
    cv = Canvas(160, 160)
    base, hi, sh = PALETTE["green"]
    sil = note_sdf(cv.X, cv.Y, 2, 0)
    _body(cv, sil, (base, hi, sh), depth=20)
    clip = sil + OUTLINE + 3
    _finish(cv, bez((38, 112), (40, 98), (56, 92), n=12), np.linspace(6.5, 2.4, 13), clip,
            dot=(88, 40, 3.0))
    return cv


# -------------------------------------------------------- blue: cassette
def draw_blue():
    cv = Canvas(160, 160)
    base, hi, sh = PALETTE["blue"]
    X, Y = cv.X, cv.Y
    cx, cy = 80.0, 80.0
    sil = sd_box(X, Y, cx, cy, 67, 50, 15)
    _body(cv, sil, (base, hi, sh), depth=14, grad=0.55)
    # label
    lab = sd_rect(X, Y, 25, 42, 135, 96, 9)
    inset(cv, lab, "#EAF5FF", depth=3, shadow=0.35, hl=0.2, dark=hi)
    cv.fill(sd_rect(X, Y, 25, 42, 135, 52, 0) + 0 * X, "#FFD60A", 0.0)  # (kept flat, no stripe)
    stripe = I(lab + 0, sd_rect(X, Y, 20, 46, 140, 53, 0))
    cv.fill(stripe, "#FF4FD8", 0.85)
    cv.fill(sd_capsule(X, Y, 36, 90, 124, 90, 0.9), hi, 0.9)
    # tape window with two reels
    win = sd_rect(X, Y, 44, 60, 116, 84, 10)
    inset(cv, win, "#16244F", depth=5, shadow=0.7, hl=0.25, light="#3E5FA8")
    cv.fill(sd_rect(X, Y, 64, 64, 96, 80, 4), "#6B4A3A", 0.9)       # tape between reels
    for rx in (58.0, 102.0):
        reel = sd_circle(X, Y, rx, 72, 10.5)
        vol(cv, reel, "#F4F8FF", light="#FFFFFF", dark="#9FB7DA", line="#0A2A66", lw=1.8, depth=6, spec=0.3)
        hub = sd_circle(X, Y, rx, 72, 5.0)
        for k in range(6):
            a = k * math.pi / 3
            hub = SUB(hub, sd_circle(X, Y, rx + 5.2 * math.cos(a), 72 + 5.2 * math.sin(a), 1.6))
        cv.fill(hub, "#0A2A66", 0.95)
        cv.fill(sd_circle(X, Y, rx, 72, 2.0), "#F4F8FF", 1)
    # bottom trapezoid
    trap = opening(sd_poly(X, Y, [(46, 104), (114, 104), (124, 128), (36, 128)]), 3, cv.ss)
    vol(cv, trap, darken(base, 0.12), light=base, dark=sh, line=sh, lw=1.8, depth=5, spec=0.15, grad=0.3)
    for hx in (62, 98):
        inset(cv, sd_circle(X, Y, hx, 117, 4.2), "#0B2F6E", depth=2, shadow=0.5)
    for (sx, sy) in ((24, 38), (136, 38), (24, 122), (136, 122)):
        inset(cv, sd_circle(X, Y, sx, sy, 3.0), sh, depth=2, shadow=0.4)
    clip = sil + OUTLINE + 3
    _finish(cv, bez((22, 58), (22, 40), (40, 34), n=12), np.linspace(5.5, 2.2, 13), clip, dot=(60, 36, 2.6))
    return cv


# -------------------------------------------------- purple: headphones
def phones_sdf(X, Y, cx=80.0, cy=78.0, s=1.0):
    band = sd_arc(X, Y, cx, cy, 50 * s, math.radians(192), math.radians(348), 17 * s)
    lc = sd_box(X, Y, cx - 49 * s, cy + 24 * s, 19 * s, 31 * s, 14 * s)
    rc = sd_box(X, Y, cx + 49 * s, cy + 24 * s, 19 * s, 31 * s, 14 * s)
    return SU(SU(band, lc, 5 * s), rc, 5 * s), band, lc, rc


def draw_purple():
    cv = Canvas(160, 160)
    base, hi, sh = PALETTE["purple"]
    X, Y = cv.X, cv.Y
    sil, band, lc, rc = phones_sdf(X, Y)
    _body(cv, sil, (base, hi, sh), depth=14, grad=0.45)
    # padded strip under the band
    pad = sd_arc(X, Y, 80, 78, 45.5, math.radians(212), math.radians(328), 5.5)
    vol(cv, pad, "#6A22D8", light="#A77BFF", dark=sh, line=sh, lw=1.2, depth=3, spec=0.2, grad=0.2)
    # cushions on the inner side of the cups + round caps
    for sgn in (-1, 1):
        cxp = 80 + sgn * 49
        cush = sd_box(X, Y, cxp - sgn * 12, 102, 7, 26, 7)
        vol(cv, cush, "#3F1590", light="#7A45E0", dark="#22074F", line=sh, lw=1.2, depth=4, spec=0.25)
        cap = sd_circle(X, Y, cxp + sgn * 3, 103, 12)
        vol(cv, cap, hi, light="#EFE4FF", dark=base, line=sh, lw=2.0, depth=7, spec=0.55, grad=0.5)
        cv.fill(sd_circle(X, Y, cxp + sgn * 3, 103, 4.2), sh, 0.45, soft=0.8)
    clip = sil + OUTLINE + 3
    _finish(cv, bez((36, 58), (42, 40), (62, 30), n=14), np.linspace(5.8, 2.2, 15), clip, dot=(24, 88, 2.8))
    return cv


PIECE_FUNCS = {"red": draw_red, "orange": draw_orange, "yellow": draw_yellow,
               "green": draw_green, "blue": draw_blue, "purple": draw_purple}


# ==========================================================================
# specials (192x192, glow allowed)
# ==========================================================================
def draw_riff():
    cv = Canvas(192, 192)
    X, Y = cv.X, cv.Y
    cx, cy = 96.0, 96.0
    cyan = C("#7DF9FF")
    # double-ended comet trail
    trail = cv.blank()
    for sgn in (-1, 1):
        pts = [(cx + sgn * 14, cy), (cx + sgn * 94, cy)]
        d = sd_taper(X, Y, *pts[0], *pts[1], 26, 3)
        fade = np.clip(1 - np.abs(X - cx) / 96.0, 0, 1) ** 1.3
        trail.paint(np.clip(0.5 - d * cv.ss, 0, 1) * fade, cyan, 0.75)
        d2 = sd_taper(X, Y, *pts[0], *pts[1], 11, 1.2)
        trail.paint(np.clip(0.5 - d2 * cv.ss, 0, 1) * fade ** 0.7, WHITE, 0.95)
        for off, ln in ((-15, 56), (15, 48), (-26, 30), (26, 26)):
            x0 = cx + sgn * 30
            x1 = cx + sgn * (30 + ln)
            ds = sd_capsule(X, Y, x0, cy + off, x1, cy + off * 1.1, 1.8)
            f2 = np.clip(1 - np.abs(X - x0) / ln, 0, 1)
            trail.paint(np.clip(0.5 - ds * cv.ss, 0, 1) * f2, cyan, 0.8)
    trail.glow_under(10, "#7DF9FF", 0.6)
    cv.over(trail)
    # glowing halo
    halo = gblur(np.clip(0.5 - sd_circle(X, Y, cx, cy, 46) * cv.ss, 0, 1), 18 * cv.ss / 2)
    cv.paint(np.clip(halo * 1.6, 0, 1), cyan, 0.7, "over")
    # the pick with a lightning bolt, white-hot core
    sil = pick_sdf(cv, cx, cy + 3, s=0.64)
    vol(cv, sil, "#CFFCFF", light="#FFFFFF", dark="#29B6D9", line="#1592B8", lw=2.6, depth=16, spec=0.6,
        grad=0.45)
    bolt = [(cx + 6, cy - 36), (cx - 15, cy + 4), (cx + 1, cy + 4), (cx - 7, cy + 36),
            (cx + 17, cy - 6), (cx + 1, cy - 6), (cx + 11, cy - 36)]
    bd = opening(sd_poly(X, Y, bolt), 1.2, cv.ss)
    glow = gblur(np.clip(0.5 - bd * cv.ss, 0, 1), 5 * cv.ss / 2)
    cv.paint(np.clip(glow * 1.5, 0, 1), cyan, 0.9)
    vol(cv, bd, "#FFFFFF", light="#FFFFFF", dark="#9BEFFF", line="#1592B8", lw=1.8, depth=4, spec=0.0,
        grad=0.4)
    droplet(cv, bez((cx - 32, cy - 12), (cx - 28, cy - 26), (cx - 12, cy - 30), n=10), np.linspace(4.2, 1.5, 11),
            alpha=0.8, clip_sdf=sil + 5)
    return cv


def draw_sub():
    cv = Canvas(192, 192)
    X, Y = cv.X, cv.Y
    body = sd_box(X, Y, 96, 98, 70, 76, 20)
    vol(cv, body, "#2B2D6E", light="#5A5DB8", dark="#141538", line="#0B0B26", lw=3.5, depth=18, spec=0.4,
        grad=0.5)
    # front panel bevel
    inset(cv, sd_box(X, Y, 96, 98, 60, 66, 14), "#23255C", depth=6, shadow=0.6, hl=0.35, light="#4B4EA6")
    # tweeter
    tw = sd_circle(X, Y, 96, 52, 12)
    vol(cv, tw, "#3A3C86", light="#7C80E6", dark="#16173F", line="#0B0B26", lw=2.2, depth=6, spec=0.5)
    cv.fill(sd_circle(X, Y, 96, 52, 6.0), "#FF4FD8", 1.0)
    cv.fill(sd_circle(X, Y, 94, 50, 2.2), WHITE, 0.8, soft=0.4)
    # woofer: yellow beat-ring, surround, cone, dust cap
    cx, cy = 96.0, 114.0
    ring = sd_ring(X, Y, cx, cy, 44, 4.5)
    glow = gblur(np.clip(0.5 - ring * cv.ss, 0, 1), 6 * cv.ss / 2)
    cv.paint(np.clip(glow * 1.3, 0, 1), C("#FFE66D"), 0.8)
    vol(cv, ring, "#FFE66D", light="#FFFBD8", dark="#C9A92A", line="#6E5A00", lw=1.0, depth=2.5, spec=0.5)
    sur = sd_circle(X, Y, cx, cy, 40)
    vol(cv, sur, "#7A1C6E", light="#C23AA8", dark="#3A0A38", line="#0B0B26", lw=2.5, depth=8, spec=0.35)
    cone = sd_circle(X, Y, cx, cy, 31)
    r = np.hypot(X - cx, Y - cy)
    inset(cv, cone, "#FF4FD8", depth=10, shadow=0.55, hl=0.3, dark="#9A1A86", light="#FFB3F0")
    rings = np.abs(((r - 12) % 7.0) - 3.5) - 0.6
    cv.fill(np.maximum(rings, np.maximum(cone + 2, 13 - r)), "#C72FB0", 0.35)
    cap = sd_circle(X, Y, cx, cy, 13)
    vol(cv, cap, "#FF7AE3", light="#FFE1F8", dark="#B32199", line="#7A0F68", lw=1.6, depth=9, spec=0.7)
    cv.fill(sd_ellipse(X, Y, cx - 4.5, cy - 5, 4.2, 2.6, ang=-0.7), WHITE, 0.85, soft=0.5)
    for (sx, sy) in ((42, 40), (150, 40), (42, 160), (150, 160)):
        vol(cv, sd_circle(X, Y, sx, sy, 5.0), "#FFE66D", light="#FFFBD8", dark="#B48E10", line="#5A4800",
            lw=1.2, depth=3, spec=0.6)
    droplet(cv, bez((34, 80), (32, 50), (50, 32), n=12), np.linspace(4.2, 1.6, 13), alpha=0.55,
            clip_sdf=body + 5)
    cv.glow_under(12, "#FF4FD8", 0.55)
    return cv


def bird_parts(X, Y, cx=96.0, cy=100.0, s=1.0):
    body = sd_ellipse(X, Y, cx, cy + 4 * s, 56 * s, 50 * s)
    head = sd_circle(X, Y, cx + 16 * s, cy - 24 * s, 38 * s)
    b = SU(body, head, 14 * s)
    tail = opening(sd_poly(X, Y, [(cx - 40 * s, cy - 2 * s), (cx - 88 * s, cy - 40 * s), (cx - 80 * s, cy - 14 * s),
                                  (cx - 90 * s, cy + 4 * s), (cx - 40 * s, cy + 26 * s)]), 4 * s)
    return SU(b, tail, 8 * s), body, head, tail


def draw_bird():
    cv = Canvas(192, 192)
    X, Y = cv.X, cv.Y
    cx, cy = 100.0, 102.0
    s = 0.92
    lime = C("#C6FF4D")
    sil, body, head, tail = bird_parts(X, Y, cx, cy, s)
    # tail feathers (separate lighter tips)
    vol(cv, sil, "#2B2D6E", light="#5B5FC4", dark="#121338", line="#0A0A24", lw=3.2, depth=24, spec=0.35,
        grad=0.45, lift=0.7)
    for k, (dy, ln) in enumerate(((-30, 0.98), (-12, 1.0), (4, 0.9))):
        fx0, fy0 = cx - 42 * s, cy + (dy * 0.3) * s
        fx1, fy1 = cx - 84 * s * ln, cy + (dy - 8) * s
        f = sd_taper(X, Y, fx0, fy0, fx1, fy1, 7 * s, 4 * s)
        cv.fill(np.maximum(f, sil + 3.2), "#3D40A0", 0.9)
        cv.stroke(np.maximum(f, sil + 3.2), 1.4, "#0A0A24", 0.6)
    # belly
    belly = I(sd_ellipse(X, Y, cx + 12 * s, cy + 22 * s, 36 * s, 28 * s), sil + 4)
    vol(cv, belly, "#6C70E0", light="#B7BAFF", dark="#3A3DA0", depth=14, spec=0.2, grad=0.35, lift=0.6)
    # wing
    wpts = bez((cx - 18 * s, cy - 8 * s), (cx - 50 * s, cy + 6 * s), (cx - 40 * s, cy + 40 * s),
               (cx + 4 * s, cy + 30 * s), n=18)
    wing = opening(sd_poly(X, Y, wpts + [(cx + 10 * s, cy + 6 * s)]), 5 * s)
    vol(cv, wing, "#3B3EA2", light="#8286F0", dark="#1B1C58", line="#0A0A24", lw=2.4, depth=10, spec=0.4)
    for k in range(3):
        fe = sd_arc(X, Y, cx - 6 * s, cy + 6 * s, (12 + 9 * k) * s, math.radians(95), math.radians(150), 2.4)
        cv.fill(np.maximum(fe, wing + 2.5), lime, 0.55)
    cv.stroke(wing + 1.0, 1.6, lime, 0.35)
    # beak
    hx, hy = cx + 16 * s, cy - 24 * s
    beak = opening(sd_poly(X, Y, [(hx + 30 * s, hy - 8 * s), (hx + 58 * s, hy + 2 * s), (hx + 30 * s, hy + 12 * s)]),
                   2.5)
    vol(cv, beak, "#FFB02E", light="#FFE7A0", dark="#C66A00", line="#0A0A24", lw=2.4, depth=6, spec=0.5)
    # eye
    ex, ey = hx + 12 * s, hy - 6 * s
    cv.fill(sd_ellipse(X, Y, ex, ey, 11 * s, 12.5 * s), "#FFFFFF", 1)
    cv.stroke(sd_ellipse(X, Y, ex, ey, 11 * s, 12.5 * s), 2.2, "#0A0A24", 1)
    cv.fill(sd_ellipse(X, Y, ex + 2.5 * s, ey + 1.5 * s, 7 * s, 8.5 * s), "#141238", 1)
    cv.fill(sd_circle(X, Y, ex + 0.5 * s, ey - 2.5 * s, 3 * s), WHITE, 1, soft=0.3)
    cv.fill(sd_circle(X, Y, ex + 5 * s, ey + 4 * s, 1.4 * s), WHITE, 0.9, soft=0.3)
    # cheek + crest
    cv.fill(sd_ellipse(X, Y, ex - 4 * s, ey + 18 * s, 7 * s, 4.5 * s), "#FF7AC8", 0.55, soft=1.5)
    crest = U(sd_taper(X, Y, hx - 6 * s, hy - 34 * s, hx - 18 * s, hy - 58 * s, 6 * s, 2.2 * s),
              sd_taper(X, Y, hx + 2 * s, hy - 34 * s, hx + 4 * s, hy - 60 * s, 6 * s, 2.4 * s))
    vol(cv, crest, "#C6FF4D", light="#F2FFD0", dark="#6FA800", line="#0A0A24", lw=2.0, depth=4, spec=0.4)
    # legs
    for lx in (cx - 4 * s, cx + 16 * s):
        leg = sd_capsule(X, Y, lx, cy + 50 * s, lx + 2 * s, cy + 62 * s, 3.2 * s)
        cv.fill(leg, "#FFB02E", 1, mode="under")
    droplet(cv, bez((hx - 24 * s, hy - 4 * s), (hx - 20 * s, hy - 24 * s), (hx - 2 * s, hy - 30 * s), n=10),
            np.linspace(4.4, 1.6, 11), alpha=0.55, clip_sdf=sil + 5)
    # lime rim light + glow
    rim = np.clip(0.5 - (sil + 3.4) * cv.ss, 0, 1) * np.clip(0.5 + (sil + 6.5) * cv.ss, 0, 1)
    cv.paint(rim, lime, 0.55, "atop")
    cv.glow_under(14, "#C6FF4D", 0.6)
    return cv


def draw_disco():
    cv = Canvas(192, 192)
    X, Y = cv.X, cv.Y
    cx, cy, R = 96.0, 98.0, 76.0
    g = rng(71)
    x = (X - cx) / R
    y = (Y - cy) / R
    rr = x * x + y * y
    inside = rr < 1
    z = np.sqrt(np.clip(1 - rr, 0, 1))
    # tilt the ball a bit so the facet rows curve nicely
    tilt = math.radians(18)
    yt = y * math.cos(tilt) - z * math.sin(tilt)
    zt = y * math.sin(tilt) + z * math.cos(tilt)
    lat = np.arcsin(np.clip(-yt, -1, 1))            # -pi/2..pi/2
    lon = np.arctan2(x, zt)
    nrow = 14
    dlat = math.pi / nrow
    row = np.floor((lat + math.pi / 2) / dlat)
    rowc = (row + 0.5) * dlat - math.pi / 2
    ncol = np.maximum(np.round(28 * np.cos(rowc)), 4)
    dlon = 2 * math.pi / ncol
    col = np.floor((lon + math.pi) / dlon)
    # facet-centre normal -> flat shading
    lonc = (col + 0.5) * dlon - math.pi
    fx = np.cos(rowc) * np.sin(lonc)
    fyt = -np.sin(rowc)
    fzt = np.cos(rowc) * np.cos(lonc)
    fy = fyt * math.cos(tilt) + fzt * math.sin(tilt)
    fz = -fyt * math.sin(tilt) + fzt * math.cos(tilt)
    Lx, Ly, Lz = -0.5, -0.7, 0.9
    ln = math.sqrt(Lx * Lx + Ly * Ly + Lz * Lz)
    lam = np.clip((fx * Lx + fy * Ly + fz * Lz) / ln, 0, 1)
    # reflection of a dark stage with coloured lights
    rz = 2 * fz * fz - 1
    ry = 2 * fz * fy
    env = np.clip(0.35 + 0.55 * (-ry) * 0.6 + 0.25 * rz, 0, 1)
    hsh = (row * 37 + col * 11) % 97
    tints = [C(PALETTE[k][0]) for k in ORDER]
    jit = ((hsh * 53) % 17) / 16.0
    br = np.clip(0.42 + env * 0.3 + lam * 0.45 + (jit - 0.5) * 0.45, 0, 1)
    base = mix(C("#6A7096"), C("#F4F6FB"), br)
    colr = base.copy()
    tinted = (((hsh * 7) % 5) == 0) & inside
    tidx = (hsh % 6).astype(int)
    tcols = np.stack(tints)[tidx]
    colr = np.where(tinted[..., None], mix(tcols, lighten(tcols, 0.55), br * 0.9), colr)
    hot = (((hsh * 13) % 23) == 0) & (lam > 0.55)
    colr = np.where(hot[..., None], mix(colr, WHITE, 0.8), colr)
    spec = (lam ** 18) * 1.2
    colr = colr + (1 - colr) * np.clip(spec, 0, 1)[..., None]
    # grout lines
    fr = (lat + math.pi / 2) / dlat - row
    fc = (lon + math.pi) / dlon - col
    edge_w = 0.07
    gr = np.minimum(np.minimum(fr, 1 - fr), np.minimum(fc, 1 - fc))
    groutk = smoothstep(edge_w, edge_w * 0.3, gr) * (z > 0.05)
    colr = mix(colr, C("#343A66"), groutk * 0.7)
    # limb darkening
    colr = mix(colr, C("#2B2D6E"), smoothstep(0.6, 1.0, np.sqrt(rr)) * 0.35)
    ball = sd_circle(X, Y, cx, cy, R)
    cv.paint(np.clip(0.5 - ball * cv.ss, 0, 1), colr, 1.0)
    cv.stroke(ball + 1.5, 3.0, "#3A3F66", 1.0)
    # sparkles
    for (sx, sy, sz) in ((58, 60, 16), (130, 124, 9), (76, 136, 7), (140, 60, 8)):
        d = U(sd_ellipse(X, Y, sx, sy, sz, sz * 0.14), sd_ellipse(X, Y, sx, sy, sz * 0.14, sz))
        cv.fill(d, WHITE, 0.95, soft=0.6)
        cv.fill(sd_circle(X, Y, sx, sy, sz * 0.22), WHITE, 1, soft=0.8)
    droplet(cv, bez((44, 92), (46, 60), (72, 42), n=14), np.linspace(6.5, 2.2, 15), alpha=0.55,
            clip_sdf=ball + 6)
    # rainbow glow
    glow = cv.blank()
    ang = np.arctan2(Y - cy, X - cx)
    t = (ang + math.pi) / (2 * math.pi) * 6
    idx = np.floor(t).astype(int) % 6
    fr2 = (t - np.floor(t))[..., None]
    cols = np.stack([C(PALETTE[k][0]) for k in ORDER])
    rainbow = cols[idx] * (1 - fr2) + cols[(idx + 1) % 6] * fr2
    gg = gblur(np.clip(0.5 - (ball - 2) * cv.ss, 0, 1), 12 * cv.ss / 2)
    glow.paint(np.clip(gg * 1.5, 0, 1), rainbow, 0.75)
    cv.under(glow)
    _ = g
    return cv


SPECIAL_FUNCS = {"riff": draw_riff, "sub": draw_sub, "bird": draw_bird, "disco": draw_disco}
