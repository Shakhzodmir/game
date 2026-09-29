"""Blockers and layers: record box, concrete, noise, balloons, dusty column,
wires, microphone cargo + its stand, dance floor tiles."""
import math

import numpy as np

from artkit import (C, Canvas, F32, INK, WHITE, bez, darken, droplet, gblur, inset, lighten, mix, noise2,
                    opening, rng, sd_arc, sd_box, sd_capsule, sd_circle, sd_ellipse, sd_poly, sd_polyline,
                    sd_rect, sd_ring, sd_taper, smoothstep, SU, SUB, U, I, vol, text_sdf)
from pieces import PALETTE, ORDER
import os

FONT_BLACK = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "fonts", "Rubik-Black.ttf")

CARD = ("#D9A066", "#F6CF96", "#9A6532")      # cardboard base / light / dark
CARD_LINE = "#5C3818"


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


def crack(cv, pts, width, seed, dark="#3A2414", light=None, amp=2.5, alpha=1.0, clip=None):
    p = jag(pts, amp, seed, step=4.0)
    radii = list(np.linspace(width, width * 0.25, len(p)))
    d = sd_polyline(cv.X, cv.Y, p, radii)
    if clip is not None:
        d = np.maximum(d, clip)
    if light is not None:
        dl = sd_polyline(cv.X, cv.Y, [(x + 1.2, y + 1.4) for x, y in p], radii)
        if clip is not None:
            dl = np.maximum(dl, clip)
        cv.fill(dl, light, 0.7 * alpha)
    cv.fill(d, dark, alpha)


# ------------------------------------------------------------ record box
def _record(cv, cx, cy, r, label, clip=None):
    X, Y = cv.X, cv.Y
    d = sd_circle(X, Y, cx, cy, r)
    if clip is not None:
        d = np.maximum(d, clip)
    vol(cv, d, "#2A2440", light="#5D5585", dark="#120F20", line="#0B0916", lw=2.2, depth=8, spec=0.5, grad=0.3)
    rr = np.hypot(X - cx, Y - cy)
    grooves = np.abs(((rr - r * 0.42) % 3.2) - 1.6) - 0.35
    g = np.maximum(grooves, np.maximum(rr - (r - 3.5), r * 0.42 - rr))
    if clip is not None:
        g = np.maximum(g, clip)
    cv.fill(g, "#4A4270", 0.55)
    lab = sd_circle(X, Y, cx, cy, r * 0.36)
    if clip is not None:
        lab = np.maximum(lab, clip)
    vol(cv, lab, label, line=darken(label, 0.5), lw=1.2, depth=4, spec=0.3)
    hole = sd_circle(X, Y, cx, cy, 2.2)
    if clip is not None:
        hole = np.maximum(hole, clip)
    cv.fill(hole, "#120F20", 1)
    # sheen streak
    sh = np.maximum(sd_arc(X, Y, cx, cy, r * 0.7, math.radians(200), math.radians(250), 3.0), d + 2)
    cv.fill(sh, WHITE, 0.35, soft=0.8)


def draw_record_box(hp):
    cv = Canvas(160, 160)
    X, Y = cv.X, cv.Y
    base, light, dark = CARD
    top = 72 if hp > 1 else 80
    front_pts = [(16, top), (144, top), (137, 148), (23, 148)]
    front = opening(sd_poly(X, Y, front_pts), 5, cv.ss)
    back = opening(sd_poly(X, Y, [(20, top - 10), (140, top - 10), (144, top + 6), (16, top + 6)]), 3, cv.ss)
    # back rim + inside of the box
    vol(cv, back, darken(base, 0.35), light=base, dark=darken(base, 0.6), line=CARD_LINE, lw=2.5, depth=4,
        spec=0.1)
    # records standing in the box
    recs = [(50, top - 12, 33, "#FF4FD8"), (111, top - 8, 31, "#3CF2FF"), (80, top - 20, 35, "#FFE66D")]
    if hp == 2:
        recs = [(50, top - 8, 33, "#FF4FD8"), (112, top - 4, 30, "#3CF2FF"), (82, top - 18, 35, "#FFE66D")]
    if hp == 1:
        recs = [(56, top - 6, 32, "#FF4FD8"), (104, top - 12, 34, "#FFE66D")]
    clip_top = Y - (top + 2)
    for (rx, ry, r, labc) in recs:
        _record(cv, rx, ry, r, labc, clip=clip_top)
    # flaps
    if hp >= 2:
        lf = opening(sd_poly(X, Y, [(16, top), (46, top), (34, top - 22), (6, top - 14)]), 2.5, cv.ss)
        vol(cv, lf, light, light="#FFE7BF", dark=base, line=CARD_LINE, lw=2.5, depth=5, spec=0.1, grad=0.4)
    if hp == 3:
        rf = opening(sd_poly(X, Y, [(114, top), (144, top), (154, top - 14), (126, top - 22)]), 2.5, cv.ss)
        vol(cv, rf, light, light="#FFE7BF", dark=base, line=CARD_LINE, lw=2.5, depth=5, spec=0.1, grad=0.4)
    # front face
    vol(cv, front, base, light=light, dark=dark, line=CARD_LINE, lw=3.0, depth=10, spec=0.12, grad=0.6,
        lift=0.5)
    # corrugation hint + tape
    cv.fill(np.maximum(sd_capsule(X, Y, 22, top + 7, 138, top + 7, 1.0), front + 4), darken(base, 0.25), 0.5)
    tape = I(sd_rect(X, Y, 68, top - 2, 92, top + 30, 2), front + 2.5)
    cv.fill(tape, "#F3DDB0", 0.85)
    cv.stroke(tape, 1.0, darken(base, 0.3), 0.5)
    # printed stamp: record + VINYL
    st_cx, st_cy = 80, top + 46 if hp > 1 else top + 42
    stamp = sd_ring(X, Y, 46, st_cy, 11, 3.0)
    stamp = U(stamp, sd_circle(X, Y, 46, st_cy, 3.2))
    txt = text_sdf(cv, "VINYL", FONT_BLACK, 17, 96, st_cy + 1)
    ink = "#8C3B2A"
    cv.fill(np.maximum(U(stamp, txt), front + 3), ink, 0.8)
    _ = st_cx
    if hp <= 2:
        # torn corner folded forward + dent + tears
        tear = sd_poly(X, Y, jag([(104, top), (140, top), (138, top + 34)], 1.6, 13, step=4) + [(122, top + 20)])
        tear = np.maximum(tear, front + 1.5)
        inset(cv, tear, "#3A2414", depth=5, shadow=0.7, hl=0.1)
        _record(cv, 124, top + 14, 16, "#3CF2FF", clip=tear + 1)
        flap = opening(sd_poly(X, Y, [(104, top), (122, top + 20), (138, top + 34), (126, top + 44), (100, top + 14)]),
                       1.5, cv.ss)
        vol(cv, flap, light, light="#FFE7BF", dark=base, line=CARD_LINE, lw=2.2, depth=5, spec=0.1, grad=0.5)
        crack(cv, [(30, top + 3), (44, top + 18), (40, top + 28)], 1.8, 11, dark="#4A2A12",
              light="#FFE2B0", clip=front + 2)
        cv.fill(np.maximum(sd_ellipse(X, Y, 116, 130, 18, 9, ang=-0.3), front + 3), dark, 0.35, soft=3)
    if hp == 1:
        hole_pts = []
        g = rng(5)
        for k in range(40):
            a = 2 * math.pi * k / 40
            r = 1 + 0.18 * (g.random() - 0.5)
            hole_pts.append((74 + 38 * r * math.cos(a), 118 + 22 * r * math.sin(a)))
        hole = sd_poly(X, Y, hole_pts)
        hole = np.maximum(hole, front + 3)
        inset(cv, hole, "#3A2414", depth=6, shadow=0.7, hl=0.1)
        _record(cv, 66, 130, 26, "#FF4FD8", clip=hole + 1)
        cv.stroke(hole - 0.6, 2.4, "#FFE2B0", 0.9)
        cv.stroke(hole + 0.8, 1.2, CARD_LINE, 0.8)
        crack(cv, [(24, top + 4), (40, top + 20), (36, top + 30)], 2.0, 21, dark="#4A2A12", light="#FFE2B0",
              clip=front + 2)
        # torn flap scrap hanging
        scrap = opening(sd_poly(X, Y, [(112, top), (142, top), (150, top + 26), (134, top + 20)]), 2, cv.ss)
        vol(cv, scrap, light, dark=base, line=CARD_LINE, lw=2.2, depth=4, spec=0.1)
    droplet(cv, bez((26, top + 30), (26, top + 14), (38, top + 9), n=8), np.linspace(3.2, 1.2, 9), alpha=0.45,
            clip_sdf=front + 5)
    cv.shadow_under(0, 2, 0.8, "#000000", 0.2)
    return cv


# -------------------------------------------------------------- concrete
CONC = ("#C9A882", "#EAD6B6", "#8A6A4E")
CONC_LINE = "#4E3A2A"


def draw_concrete(hp):
    cv = Canvas(160, 160)
    X, Y = cv.X, cv.Y
    base, light, dark = CONC
    body = sd_rect(X, Y, 16, 34, 144, 148, 16)
    if hp == 1:
        chunk = sd_poly(X, Y, [(112, 20), (150, 20), (150, 78), (138, 64), (128, 56), (122, 40)])
        body = SUB(body, chunk)
        body = opening(body, 2.5, cv.ss)
    vol(cv, body, base, light=light, dark=dark, line=CONC_LINE, lw=3.0, depth=14, spec=0.12, grad=0.55,
        lift=0.55)
    # top slab
    slab = I(sd_rect(X, Y, 16, 34, 144, 62, 14), body)
    vol(cv, slab, lighten(base, 0.25), light="#FFF1DA", dark=base, line=CONC_LINE, lw=2.4, depth=8, spec=0.15,
        grad=0.4)
    # pores / aggregate speckles
    g = rng(40 + hp)
    for _ in range(46):
        px, py = 22 + g.random() * 116, 66 + g.random() * 76
        r = 0.9 + g.random() * 1.8
        d = np.maximum(sd_circle(X, Y, px, py, r), body + 5)
        if g.random() < 0.6:
            inset(cv, d, darken(base, 0.3), depth=1.2, shadow=0.5)
        else:
            cv.fill(d, light, 0.6)
    # hazard band
    band = I(sd_rect(X, Y, 16, 104, 144, 122, 0), body + 3)
    stripes = ((X + Y) % 18.0) < 9.0
    col = np.where(stripes[..., None], C("#FFD23F"), C("#2B2345"))
    w = cv.win(band < 2)
    cv.paint(np.clip(0.5 - band[w] * cv.ss, 0, 1), col[w], 0.9, win=w)
    cv.stroke(band, 1.2, CONC_LINE, 0.6)
    # bolts
    for bx in (32, 128):
        if hp == 1 and bx == 128:
            continue
        vol(cv, sd_circle(X, Y, bx, 48, 4.5), "#B9BDCB", light="#FFFFFF", dark="#6A6F85", line="#3A3F55",
            lw=1.2, depth=3, spec=0.6)
    if hp == 1:
        crack(cv, [(118, 60), (100, 78), (106, 96), (86, 118), (92, 140)], 3.0, 3, dark="#3E2C1E",
              light="#FFF1DA", clip=body + 2)
        crack(cv, [(100, 78), (72, 86), (60, 80)], 2.2, 4, dark="#3E2C1E", light="#FFF1DA", clip=body + 2)
        crack(cv, [(30, 64), (44, 86), (38, 100)], 1.8, 5, dark="#3E2C1E", light="#FFF1DA", clip=body + 2)
        for (px, py, r) in ((146, 142, 5), (134, 150, 3.5)):
            vol(cv, sd_circle(X, Y, px, py, r), base, light=light, dark=dark, line=CONC_LINE, lw=1.4, depth=3)
    else:
        crack(cv, [(128, 70), (118, 82), (122, 90)], 1.4, 7, dark="#5A4430", light="#FFF1DA", clip=body + 2)
    droplet(cv, bez((24, 90), (22, 72), (34, 66), n=8), np.linspace(3.2, 1.2, 9), alpha=0.4, clip_sdf=body + 5)
    cv.shadow_under(0, 2, 0.8, "#000000", 0.2)
    return cv


# ---------------------------------------------------------------- noise
def draw_noise():
    cv = Canvas(160, 160)
    X, Y = cv.X, cv.Y
    ss = cv.ss
    g = rng(99)
    # wobbly blob outline
    pts = []
    for k in range(72):
        a = 2 * math.pi * k / 72
        r = 1 + 0.035 * math.sin(5 * a + 1.3) + 0.025 * math.sin(9 * a) + 0.02 * (g.random() - 0.5)
        sq = 1 / max(abs(math.cos(a)), abs(math.sin(a))) ** 0.55
        pts.append((80 + 60 * r * sq * math.cos(a), 80 + 60 * r * sq * math.sin(a)))
    blob = opening(sd_poly(X, Y, pts), 10, ss)
    # static texture on output-pixel grain
    grain1 = np.repeat(np.repeat(g.random((160, 160)).astype(F32), ss, 0), ss, 1)
    grain2 = np.repeat(np.repeat(g.random((80, 80)).astype(F32), 2 * ss, 0), 2 * ss, 1)
    v = 0.55 * grain1 + 0.45 * grain2
    scan = ((np.floor(Y / 2.0) % 2) == 0).astype(F32)
    v = v * (0.82 + 0.18 * scan)
    # glitch bands
    for (y0, h, sh) in ((38, 5, 0.25), (92, 3, 0.35), (118, 6, -0.2)):
        band = (Y >= y0) & (Y < y0 + h)
        v = np.where(band, np.clip(v + sh, 0, 1), v)
    basec = C("#8A8FA3")
    col = mix(mix(basec, C("#3F4254"), 0.75), mix(basec, WHITE, 0.6), v[..., None])
    # soft vignette inside
    d = np.maximum(-blob, 0)
    col = mix(col, C("#4A4E62"), (1 - smoothstep(0, 16, d)) * 0.45)
    col = mix(col, C("#C9CCD8"), smoothstep(10, 60, d) * 0.12)
    cv.paint(np.clip(0.5 - blob * ss, 0, 1), col, 1.0)
    cv.stroke(blob + 1.5, 3.0, "#3A3D4E", 1.0)
    # glassy highlight like an old CRT
    droplet(cv, bez((30, 70), (30, 40), (56, 28), n=10), np.linspace(5, 1.8, 11), alpha=0.35, clip_sdf=blob + 6)
    cv.shadow_under(0, 2, 0.8, "#000000", 0.2)
    return cv


# -------------------------------------------------------------- balloon
def draw_balloon(color):
    base, hi, sh = PALETTE[color]
    cv = Canvas(160, 160)
    X, Y = cv.X, cv.Y
    # string first (behind knot)
    s_pts = bez((80, 118), (70, 132), (92, 140), (82, 152), n=20)
    cv.fill(sd_polyline(X, Y, s_pts) - 1.6, sh, 1)
    cv.fill(sd_polyline(X, Y, s_pts) - 0.7, hi, 0.9)
    body = sd_ellipse(X, Y, 80, 64, 50, 56)
    body = SU(body, sd_ellipse(X, Y, 80, 110, 12, 8), 10)
    vol(cv, body, base, light=hi, dark=sh, line=sh, lw=3.0, depth=34, spec=0.55, grad=0.55, lift=0.6)
    knot = opening(sd_poly(X, Y, [(72, 124), (88, 124), (84, 114), (76, 114)]), 1.5, cv.ss)
    vol(cv, knot, base, light=hi, dark=sh, line=sh, lw=2.2, depth=3, spec=0.3)
    droplet(cv, bez((42, 66), (42, 36), (66, 22), n=14), np.linspace(8.5, 2.8, 15), alpha=0.7, clip_sdf=body + 6)
    cv.fill(sd_circle(X, Y, 44, 82, 3.8), WHITE, 0.7, soft=0.5)
    cv.shadow_under(0, 2, 0.8, "#000000", 0.2)
    return cv


# ------------------------------------------------------ dusty column 2x2
COL_BODY = ("#3A2F5E", "#6B5DA6", "#1C1535")


def _column_base(cv, on):
    X, Y = cv.X, cv.Y
    body = sd_rect(X, Y, 26, 20, 294, 306, 26)
    vol(cv, body, COL_BODY[0], light=COL_BODY[1], dark=COL_BODY[2], line="#0D0A1C", lw=4.0, depth=22,
        spec=0.35, grad=0.5)
    panel = sd_rect(X, Y, 44, 38, 276, 288, 18)
    inset(cv, panel, "#2A2248", depth=8, shadow=0.6, hl=0.3, light="#5A4C92")
    # horn tweeter
    horn = sd_rect(X, Y, 104, 52, 216, 96, 14)
    vol(cv, horn, "#241C40", light="#55498A", dark="#100C20", line="#0D0A1C", lw=3.0, depth=8, spec=0.3)
    throat = sd_rect(X, Y, 128, 64, 192, 84, 10)
    inset(cv, throat, "#FF4FD8" if on else "#1A1430", depth=5, shadow=0.6, hl=0.4,
          light="#FFD1F5" if on else "#3A3060")
    # woofer
    cx, cy = 160.0, 196.0
    sur = sd_circle(X, Y, cx, cy, 84)
    vol(cv, sur, "#1E1834", light="#4C4180", dark="#0C0918", line="#0D0A1C", lw=3.5, depth=12, spec=0.35)
    ring = sd_ring(X, Y, cx, cy, 78, 5)
    vol(cv, ring, "#FFE66D" if on else "#9E8A48", light="#FFFBD8", dark="#8A7020", line="#3A2E00", lw=1.2,
        depth=2.5, spec=0.5)
    cone = sd_circle(X, Y, cx, cy, 70)
    if on:
        inset(cv, cone, "#FF4FD8", depth=22, shadow=0.55, hl=0.35, dark="#8E1680", light="#FFC4F3")
    else:
        inset(cv, cone, "#6A4A7E", depth=22, shadow=0.55, hl=0.25, dark="#2E1F40", light="#9C84B0")
    r = np.hypot(X - cx, Y - cy)
    rings = np.abs(((r - 26) % 13.0) - 6.5) - 1.0
    cv.fill(np.maximum(rings, np.maximum(cone + 3, 27 - r)), "#000000", 0.18)
    cap = sd_circle(X, Y, cx, cy, 26)
    vol(cv, cap, "#FF7AE3" if on else "#8A6A9E", light="#FFE1F8" if on else "#C9B6D6",
        dark="#B32199" if on else "#4A355E", line="#1A0F28", lw=2.4, depth=16, spec=0.7)
    # metal corners + handle
    for (qx, qy, sx, sy) in ((26, 20, 1, 1), (294, 20, -1, 1), (26, 306, 1, -1), (294, 306, -1, -1)):
        cpts = [(qx, qy), (qx + sx * 40, qy), (qx + sx * 40, qy + sy * 12), (qx + sx * 12, qy + sy * 12),
                (qx + sx * 12, qy + sy * 40), (qx, qy + sy * 40)]
        cd = I(opening(sd_poly(X, Y, cpts), 3, cv.ss), body + 0.5)
        vol(cv, cd, "#C9CCD8", light="#FFFFFF", dark="#6E7390", line="#2A2D40", lw=2.0, depth=5, spec=0.8)
        vol(cv, sd_circle(X, Y, qx + sx * 20, qy + sy * 20 - sy * 12 + sy * 6, 3.2), "#8A8FA8",
            light="#FFFFFF", dark="#50556E", line="#2A2D40", lw=1.0, depth=2)
    droplet(cv, bez((38, 150), (36, 80), (70, 34), n=18), np.linspace(7, 2.4, 19), alpha=0.35, clip_sdf=body + 8)
    return body, (cx, cy)


def draw_column(stage):
    """stage 3 = most dust, 1 = least; 0 = switched on."""
    cv = Canvas(320, 320)
    X, Y = cv.X, cv.Y
    on = stage == 0
    body, (cx, cy) = _column_base(cv, on)
    if not on:
        amount = {3: 0.9, 2: 0.6, 1: 0.32}[stage]
        n = noise2(cv.a.shape, 40 * cv.ss, seed=300, octaves=4)
        n2 = noise2(cv.a.shape, 3 * cv.ss, seed=301, octaves=2)
        # dust settles on top surfaces and edges more
        topness = smoothstep(200, 20, Y) * 0.35
        edge = smoothstep(26, 0, -body) * 0.25
        field = n * 0.8 + topness + edge
        thr = np.quantile(field[cv.a > 0.5], 1 - amount * 0.85)
        dust = smoothstep(thr - 0.22, thr + 0.18, field) * np.clip(cv.a, 0, 1)
        dust = dust * (0.55 + 0.25 * amount) * (0.75 + 0.25 * n2)
        dcol = mix(C("#D9CAB0"), C("#F4EBDB"), n2[..., None])
        cv.paint(dust, dcol, 1.0, "atop")
        # grainy specks
        g = rng(302)
        grain = np.repeat(np.repeat(g.random((320, 320)).astype(F32), cv.ss, 0), cv.ss, 1)
        cv.paint((dust > 0.25) * (grain > 0.93), C("#FFF8EA"), 0.3, "atop")
        cv.paint((dust > 0.25) * (grain < 0.06), C("#8C7A5E"), 0.35, "atop")
        # lumpy dust layer on the top edge
        g2 = rng(303 + stage)
        lumps = None
        n_l = {3: 14, 2: 9, 1: 3}[stage]
        for k in range(n_l):
            lx = 40 + (240 * (k + 0.5) / n_l) + (g2.random() - 0.5) * 12
            lr = (4 + 2.5 * stage) + g2.random() * (3 + 3 * stage)
            dl = sd_ellipse(X, Y, lx, 22, lr * 1.6, lr * 0.75)
            lumps = dl if lumps is None else SU(lumps, dl, 6)
        lumps = np.maximum(lumps, Y - 27)
        vol(cv, lumps, "#E2D3B8", light="#FFF8EA", dark="#A89574", line="#8A7658", lw=1.2, depth=4, spec=0.0,
            grad=0.4)
        # cobwebs
        webs = {3: [(34, 28, 1, 1), (286, 298, -1, -1)], 2: [(286, 28, -1, 1)], 1: []}[stage]
        for (wx, wy, sx, sy) in webs:
            spokes = []
            for k in range(5):
                a = math.radians(4 + k * 20.5)
                spokes.append(sd_capsule(X, Y, wx, wy, wx + sx * 64 * math.cos(a), wy + sy * 64 * math.sin(a), 0.7))
            web = U(*spokes)
            for rr in (18, 32, 46, 60):
                arc_pts = []
                for k in range(5):
                    a = math.radians(4 + k * 20.5)
                    rw = rr * (1 - 0.08 * (k % 2))
                    arc_pts.append((wx + sx * rw * math.cos(a), wy + sy * rw * math.sin(a)))
                sag = []
                for i in range(len(arc_pts) - 1):
                    (ax, ay), (bx, by) = arc_pts[i], arc_pts[i + 1]
                    mx, my = (ax + bx) / 2, (ay + by) / 2
                    mx -= sx * 3
                    my -= sy * 3
                    sag += bez((ax, ay), (mx, my), (bx, by), n=6)
                web = np.minimum(web, sd_polyline(X, Y, sag) - 0.7)
            cv.fill(web, "#F4ECDD", 0.85)
    else:
        # switched on: glowing cone, LED strip, sound arcs
        glow = gblur(np.clip(0.5 - sd_circle(X, Y, cx, cy, 70) * cv.ss, 0, 1), 12 * cv.ss / 2)
        cv.paint(np.clip(glow, 0, 1) * np.clip(cv.a, 0, 1), C("#FF9CEB"), 0.35, "atop")
        led = sd_capsule(X, Y, 64, 292, 256, 292, 3.2)
        cv.fill(led, "#3CF2FF", 1)
        cv.glow_from(np.clip(0.5 - led * cv.ss, 0, 1), 8, "#3CF2FF", 0.8, mode="over")
        for k in range(3):
            arc = sd_arc(X, Y, cx, cy, 104 + k * 16, math.radians(-38), math.radians(38), 6 - k)
            cv.fill(arc, "#FFE66D", 0.9 - 0.25 * k)
            arc2 = sd_arc(X, Y, cx, cy, 104 + k * 16, math.radians(142), math.radians(218), 6 - k)
            cv.fill(arc2, "#FFE66D", 0.9 - 0.25 * k)
        cv.glow_under(18, "#FF4FD8", 0.7)
    cv.shadow_under(0, 3, 1.2, "#000000", 0.22)
    return cv


# ------------------------------------------------------------- wires
def _cable(cv, pts, color, r=5.0, line="#140F24"):
    d = sd_polyline(cv.X, cv.Y, pts) - r
    vol(cv, d, color, line=line, lw=1.6, depth=r * 0.95, bulge=1.2, spec=0.7, spec_pow=20, grad=0.2,
        lift=0.6, shade=0.6)
    return d


def _plug(cv, x, y, ang, body="#FFC83D"):
    X, Y = cv.X, cv.Y
    ca, sa = math.cos(ang), math.sin(ang)
    b = sd_box(X, Y, x, y, 9, 5.8, 3, ang=ang)
    vol(cv, b, "#2B2345", light="#6A5E9A", dark="#120E22", line="#0B0816", lw=1.6, depth=4, spec=0.5)
    tipx, tipy = x + ca * 14, y + sa * 14
    t = sd_capsule(X, Y, x + ca * 8, y + sa * 8, tipx, tipy, 2.6)
    vol(cv, t, body, light="#FFF3C0", dark="#9C5A00", line="#5A3500", lw=1.2, depth=2.5, spec=0.8)


def draw_wires(hp):
    cv = Canvas(160, 160)
    if hp == 2:
        a = bez((-6, 40), (40, 6), (120, 4), (166, 38), n=30)
        _cable(cv, a, "#2B2345", r=5.5)
        b = bez((34, 166), (4, 120), (8, 60), (30, -6), n=30)
        _cable(cv, b, "#FF4FD8", r=4.8, line="#6A0F5C")
        c = bez((-6, 128), (60, 170), (130, 150), (166, 104), n=30)
        _cable(cv, c, "#FFD23F", r=4.8, line="#6E5200")
        d = bez((150, -6), (164, 50), (150, 110), (126, 166), n=30)
        _cable(cv, d, "#2B2345", r=5.0)
        # zip ties
        for (x, y, ang) in ((24, 24, 0.8), (136, 136, 0.8)):
            z = sd_box(cv.X, cv.Y, x, y, 3.2, 10, 1.5, ang=ang)
            vol(cv, z, "#F4F4F8", line="#6A6F85", lw=1.0, depth=2, spec=0.4)
        _plug(cv, 126, 20, math.radians(160))
        _plug(cv, 20, 138, math.radians(-40), body="#C9CCD8")
    else:
        a = bez((-6, 30), (50, 0), (130, 0), (166, 44), n=30)
        _cable(cv, a, "#2B2345", r=5.5)
        c = bez((-6, 132), (50, 168), (120, 160), (140, 118), n=30)
        _cable(cv, c, "#FF4FD8", r=4.8, line="#6A0F5C")
        _plug(cv, 146, 104, math.radians(-70))
    cv.shadow_under(0, 2, 0.8, "#000000", 0.25)
    return cv


# ----------------------------------------------------------- microphone
SILVER = ("#D5DAE6", "#FFFFFF", "#7C8399")
GOLD = ("#FFC83D", "#FFF0B0", "#9C5A00")


def draw_mic(size=160, cx=80.0, top=10.0, cv=None, s=1.0):
    """Vintage 'capsule' microphone: chrome slatted head, gold yoke and body."""
    cv = cv or Canvas(size, size)
    X, Y = cv.X, cv.Y
    hy = top + 46 * s
    # body + stub below the yoke
    stub = sd_taper(X, Y, cx, hy + 50 * s, cx, top + 138 * s, 13 * s, 9 * s)
    vol(cv, stub, GOLD[0], light=GOLD[1], dark=GOLD[2], line="#5A3500", lw=2.6, depth=8 * s, spec=0.8, grad=0.4)
    for yy in (top + 112 * s, top + 124 * s):
        cv.stroke(np.maximum(np.abs(Y - yy) - 0.1, stub + 2.5), 2.2, GOLD[2], 0.7)
    # yoke (U holding the head)
    yoke = sd_arc(X, Y, cx, hy + 6 * s, 44 * s, math.radians(18), math.radians(162), 9 * s)
    vol(cv, yoke, GOLD[0], light=GOLD[1], dark=GOLD[2], line="#5A3500", lw=2.4, depth=5 * s, spec=0.9)
    knob = sd_box(X, Y, cx, hy + 50 * s, 12 * s, 7 * s, 4 * s)
    vol(cv, knob, GOLD[0], light=GOLD[1], dark=GOLD[2], line="#5A3500", lw=2.0, depth=4 * s, spec=0.9)
    # capsule head
    head = sd_box(X, Y, cx, hy, 36 * s, 44 * s, 30 * s)
    vol(cv, head, SILVER[0], light=SILVER[1], dark=SILVER[2], line="#2F3448", lw=3.0, depth=20 * s, spec=0.7,
        grad=0.5)
    # horizontal chrome slats
    slat = np.abs(((Y - hy) % (7.0 * s)) - 3.5 * s) - 1.1 * s
    slat = np.maximum(slat, head + 6 * s)
    cv.fill(slat, "#4A5068", 0.75)
    # gold centre spine + badge
    spine = I(sd_box(X, Y, cx, hy, 5.5 * s, 44 * s, 0), head + 2.5)
    vol(cv, spine, GOLD[0], light=GOLD[1], dark=GOLD[2], line="#5A3500", lw=1.4, depth=3, spec=0.8, grad=0.5)
    badge = sd_circle(X, Y, cx, hy + 4 * s, 9 * s)
    vol(cv, badge, "#FF4FD8", light="#FFD1F5", dark="#8E1680", line="#5A3500", lw=2.2, depth=5 * s, spec=0.9)
    droplet(cv, bez((cx - 26 * s, hy + 14 * s), (cx - 28 * s, hy - 18 * s), (cx - 12 * s, hy - 36 * s), n=12),
            np.linspace(5.5 * s, 2.0 * s, 13), alpha=0.75, clip_sdf=head + 4)
    return cv


def draw_mic_cargo():
    cv = draw_mic()
    cv.shadow_under(0, 2, 0.8, "#000000", 0.2)
    return cv


def draw_mic_stand():
    cv = Canvas(160, 96)
    X, Y = cv.X, cv.Y
    # glow pool
    pool = sd_ellipse(X, Y, 80, 80, 60, 12)
    cv.fill(pool, "#FFE66D", 0.35, soft=10)
    # pole + base
    pole = sd_capsule(X, Y, 80, 44, 80, 84, 5)
    vol(cv, pole, SILVER[0], light=SILVER[1], dark=SILVER[2], line="#2B2345", lw=2.0, depth=4, spec=0.8)
    base = sd_ellipse(X, Y, 80, 86, 34, 7)
    vol(cv, base, "#2B2345", light="#6D6199", dark="#120E22", line="#0B0816", lw=2.0, depth=5, spec=0.5)
    # clip (cradle) waiting for the mic
    cradle = sd_arc(X, Y, 80, 16, 26, math.radians(20), math.radians(160), 9)
    vol(cv, cradle, GOLD[0], light=GOLD[1], dark=GOLD[2], line="#5A3500", lw=2.4, depth=4.5, spec=0.9)
    knob = sd_box(X, Y, 80, 44, 9, 5, 3)
    vol(cv, knob, GOLD[0], light=GOLD[1], dark=GOLD[2], line="#5A3500", lw=1.8, depth=3, spec=0.8)
    # down chevrons inside the cradle
    for k, yy in enumerate((6, 20)):
        ch = sd_polyline(X, Y, [(68, yy), (80, yy + 9), (92, yy)]) - 3.2
        cv.fill(ch, "#FFFFFF", 0.95 - 0.35 * k)
    cv.glow_under(8, "#FFE66D", 0.55)
    return cv


# ------------------------------------------------------- dance floor tiles
def draw_floor(kind):
    """kind: 2 (double border), 1 (single border), 'lit'."""
    lit = kind == "lit"
    cv = Canvas(160, 160, bg="#1A1535")
    X, Y = cv.X, cv.Y
    tile = sd_rect(X, Y, 3, 3, 157, 157, 12)
    if not lit:
        vol(cv, tile, "#2A2350", light="#4A3F86", dark="#18122E", line="#120D26", lw=1.5, depth=10, spec=0.15,
            grad=0.4, lift=0.45)
        for k, inset_px in enumerate((14, 24) if kind == 2 else (16,)):
            b = sd_rect(X, Y, inset_px, inset_px, 160 - inset_px, 160 - inset_px, 10 - k * 3)
            cv.stroke(b, 3.0, "#16102C", 0.9)
            cv.stroke(b + 1.6, 1.4, "#5B4FA6", 0.8)
        # faint reflections
        refl = np.maximum(np.abs((X - Y) * 0.7071 + 20) - 7, tile + 4)
        cv.fill(refl, "#FFFFFF", 0.05, soft=4)
    else:
        vol(cv, tile, "#FFE9A8", light="#FFFFFF", dark="#F2B84B", line="#B87A18", lw=1.5, depth=14, spec=0.3,
            grad=0.35, lift=0.6)
        # colour sheen across the tile (piece colours)
        t = ((X + Y) / 320.0) * 1.4 - 0.2
        cols = [PALETTE[k][1] for k in ("red", "orange", "yellow", "green", "blue", "purple")]
        stops = [(i / 5, c) for i, c in enumerate(cols)]
        from artkit import ramp
        sheen = ramp(np.clip(t, 0, 1), stops)
        w = cv.win(tile < 1)
        cv.paint(np.clip(0.5 - (tile[w] + 2) * cv.ss, 0, 1), sheen[w], 0.38, win=w)
        core = sd_rect(X, Y, 20, 20, 140, 140, 16)
        cv.fill(core, "#FFFFFF", 0.55, soft=16)
        b = sd_rect(X, Y, 16, 16, 144, 144, 10)
        cv.stroke(b, 2.2, "#FFFFFF", 0.8)
        # sparkles
        for (sx, sy, sz) in ((40, 36, 10), (120, 118, 8), (116, 44, 5)):
            d = U(sd_ellipse(X, Y, sx, sy, sz, sz * 0.16), sd_ellipse(X, Y, sx, sy, sz * 0.16, sz))
            cv.fill(d, "#FFFFFF", 0.95, soft=0.5)
    return cv
