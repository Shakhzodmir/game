"""Level background and district scenes, rendered at 720x1280 (drawn in 360x640 units, BG_OUT = 2).

Bright daytime scenes (art-direction v2): pastel walls and buildings with white windows, the
level-sky gradient, soft light. The town screen covers the top (stats bar, district ribbon) and the
bottom (task card, level button, navigation) of every scene, so each scene is composed around the free
band SAFE = y 236..786 (scene px): walls and windows above, the floor line at ~y 600-650 and the items'
bases on the floor inside the band.

bg_concert is the same scene re-lit for the final concert, not a tint: sky and walls in the spec
gradient #3B2A8F -> #6B4CE0, buildings and props in their own hues but more saturated, lit windows
#FFE66D, 3-5 neon spotlight cones (#FF4FD8, #3CF2FF, #FFE66D) added as light, with their pools and
reflections on the floor.
Item positions live in LAYOUT (720x1280 scene pixels, y down, centre of the item image).
"""
import math

import numpy as np

from artkit import (C, Canvas, F32, WHITE, bez, candy, gblur, inset, mix, noise2, opening, ramp, raw, rng,
                    sd_arc, sd_box, sd_capsule, sd_circle, sd_ellipse, sd_poly, sd_polyline, sd_rect, shift,
                    smoothstep, sparkle4, U, I)
from palette import SKY, TOWN, CONCERT, SPOTS

W, H = 360, 640          # drawing units; the image is rendered at BG_OUT x (720x1280)
BG_OUT = 2
SUN_COL = "#FFF6BE"
SHADOW_PINK = "#D66E8C"
ROOFS = ["#FF7EB6", "#C18CFF", "#FF8E72", "#FF9EC7"]     # gable roofs: pink / lilac / coral, never olive


# ==========================================================================
# day / concert mode
# ==========================================================================
class _Mode:
    concert = False


MODE = _Mode()
LAVENDER_LO, LAVENDER_HI = C("#7A68E8"), C("#D6CBFF")
NIGHT_TINT = C("#3B2A8F")


def night(col):
    """Concert re-light of an object colour: same hue, more saturated, slightly deeper; whites and greys
    become lavender (they catch the violet ambient light) - never grey, never black."""
    c = np.asarray(col, F32)
    mx = c.max(-1, keepdims=True)
    mn = c.min(-1, keepdims=True)
    s = (mx - mn) / np.maximum(mx, 1e-4)
    s2 = np.clip(s * 1.35 + 0.2, 0, 1)
    v2 = mx * 0.9
    hue = v2 * (1 - s2 * (mx - c) / np.maximum(mx - mn, 1e-4))
    grey = LAVENDER_LO + (LAVENDER_HI - LAVENDER_LO) * mx
    k = smoothstep(0.06, 0.2, s)
    out = grey + (hue - grey) * k
    return (out + (NIGHT_TINT - out) * 0.1).astype(F32)


def new_canvas():
    cv = Canvas(W, H, out=BG_OUT)
    if MODE.concert:
        cv.cmap = night
    return cv


def window_col():
    return "#FFE66D" if MODE.concert else "#FFFFFF"


def lit_window(cv, d, alpha=1.0):
    """A window: white by day; lit #FFE66D with a warm glow at the concert."""
    if MODE.concert:
        with raw(cv):
            cv.glow_from(np.clip(0.5 - d * cv.ss, 0, 1), 5, "#FFD23F", 0.55, mode="over")
            cv.fill(d, "#FFE66D", alpha)
            cv.fill(d + 1.6, "#FFF6C2", 0.6 * alpha)
    else:
        cv.fill(d, "#FFFFFF", alpha)


# ==========================================================================
# helpers
# ==========================================================================
def full(cv):
    return sd_rect(cv.X, cv.Y, -8, -8, W + 8, H + 8, 0)


def rect(cv, x0, y0, x1, y1, r=0.0):
    return sd_rect(cv.X, cv.Y, x0, y0, x1, y1, r)


def wall(cv, region, stops, y0, y1):
    """A wall: pastel gradient by day, the concert gradient at night."""
    if MODE.concert:
        with raw(cv):
            cv.fill_grad(region, [(0, CONCERT[0][1]), (1, CONCERT[1][1])], axis="y", p0=y0 - 60, p1=y1 + 40)
    else:
        cv.fill_grad(region, stops, axis="y", p0=y0, p1=y1)


def sky(cv, region, y0, y1, sun=None, clouds=(), stops=None):
    X, Y = cv.X, cv.Y
    if MODE.concert:
        with raw(cv):
            cv.fill_grad(region, [(0, CONCERT[0][1]), (1, CONCERT[1][1])], axis="y", p0=y0 - 40, p1=y1 + 60)
            w = cv.win(region < 1)
            inside = np.clip(0.5 - region[w] * cv.ss, 0, 1)
            g = rng(int(y0 * 7 + y1 * 3 + 11))
            xs0, xs1 = float(X[w].min()), float(X[w].max())
            ys0, ys1 = float(Y[w].min()), float(Y[w].max())
            n = int((xs1 - xs0) * (ys1 - ys0) / 900) + 4
            stars = np.full(X[w].shape, 1e3, F32)
            for _ in range(n):
                sx, sy = xs0 + g.random() * (xs1 - xs0), ys0 + g.random() * (ys1 - ys0)
                stars = np.minimum(stars, np.hypot(X[w] - sx, Y[w] - sy) - (0.5 + g.random() * 0.8))
            cv.paint(inside * np.clip(0.5 - stars * cv.ss, 0, 1), C("#FFF6D6"), 0.85, win=w)
            for (cx, by, s, a) in clouds:
                d = np.maximum(sd_cloud(X, Y, cx, by, s), region)
                cv.fill(d, "#8E78F0", a * 0.35, soft=2 * s + 1)
        return
    cv.fill_grad(region, stops or SKY, axis="y", p0=y0, p1=y1)
    w = cv.win(region < 1)
    inside = np.clip(0.5 - region[w] * cv.ss, 0, 1)
    if sun is not None:
        sx, sy, sr = sun
        r = np.hypot(X[w] - sx, Y[w] - sy)
        cv.paint(inside * np.exp(-(r / (sr * 3.2)) ** 2), C("#FFF2B0"), 0.75, win=w)
        cv.paint(inside * (1 - smoothstep(sr - 1.2, sr + 0.8, r)), C(SUN_COL), 1.0, win=w)
        cv.paint(inside * np.exp(-(r / (sr * 1.4)) ** 2), C("#FFFFFF"), 0.35, win=w)
    for (cx, by, s, a) in clouds:
        d = np.maximum(sd_cloud(X, Y, cx, by, s), region)
        cv.fill(d + 1.0, "#DCEFFF", a * 0.7, soft=1.5 * s + 0.8)
        cv.fill(d, "#FFFFFF", a, soft=1.2 * s + 0.5)


def sd_cloud(X, Y, cx, base_y, s=1.0):
    from ui import cloud_sdf
    return cloud_sdf(X, Y, cx, base_y, s)


def town(cv, base_y, specs, clip=None, win_alpha=1.0, shade=True):
    """Pastel buildings with white windows (like the approved mockup).
    specs: (x0, x1, height, colour, roof) with roof in 'flat', 'round', 'arch', 'gable'."""
    X, Y = cv.X, cv.Y
    for i, (x0, x1, h, col, roof) in enumerate(specs):
        top = base_y - h
        wdt = x1 - x0
        if roof == "round":
            d = rect(cv, x0, top, x1, base_y + 40, wdt / 2)
        elif roof == "arch":
            d = rect(cv, x0, top, x1, base_y + 40, min(18, wdt / 2))
        else:
            d = rect(cv, x0, top, x1, base_y + 40, 5 if roof == "flat" else 3)
        if clip is not None:
            d = np.maximum(d, clip)
        c = C(col)
        cv.fill_grad(d, [(0, mix(c, WHITE, 0.18)), (1, c)], axis="y", p0=top - 10, p1=base_y)
        if shade:
            # soft shade on the right side of each building
            sh = np.maximum(d, (x0 + x1) / 2 + wdt * 0.28 - X)
            cv.fill(sh, mix(c, C("#7B4FFF"), 0.15), 0.35, soft=4)
        if roof == "gable":
            rf = opening(sd_poly(X, Y, [(x0 - 4, top + 3), (x1 + 4, top + 3), ((x0 + x1) / 2, top - wdt * 0.44)]), 2.0)
            if clip is not None:
                rf = np.maximum(rf, clip)
            cv.fill(rf, ROOFS[i % len(ROOFS)], 1.0)
            cv.fill(np.maximum(rf + 1.5, top - 2 - Y), "#FFFFFF", 0.35)
        # windows
        nx = max(int((wdt - 8) // 14), 1)
        gap = (wdt - nx * 8) / (nx + 1)
        rows = max(int((h - 16) // 20), 1)
        for r in range(rows):
            wy = top + 12 + r * 20 + (8 if roof in ("round", "arch") else 0)
            if wy + 10 > base_y - 4:
                continue
            for k in range(nx):
                wx = x0 + gap + k * (8 + gap)
                wd = rect(cv, wx, wy, wx + 8, wy + 10, 2.5 if roof != "round" else 4)
                if clip is not None:
                    wd = np.maximum(wd, clip)
                lit_window(cv, wd, win_alpha)


def beam(cv, x0, y0, x1, y1, w0, w1, color, alpha, clip=None, mode="add", fade=0.6):
    X, Y = cv.X, cv.Y
    dx, dy = x1 - x0, y1 - y0
    L = math.hypot(dx, dy)
    ux, uy = dx / L, dy / L
    px, py = X - x0, Y - y0
    along = px * ux + py * uy
    across = np.abs(-px * uy + py * ux)
    t = np.clip(along / L, 0, 1)
    half = w0 + (w1 - w0) * t
    v = smoothstep(half, half * 0.15, across) * (along > 0) * (1 - t * fade) * smoothstep(0, 24, along)
    v = v * (along < L)
    if clip is not None:
        v = v * np.clip(0.5 - clip * cv.ss, 0, 1)
    cv.paint(np.clip(v, 0, 1), C(color), alpha, mode)


def planks(cv, region, vx, vy, n, ca, cb, seam, alpha=1.0):
    """Perspective wooden floor converging to (vx, vy)."""
    X, Y = cv.X, cv.Y
    w = cv.win(region < 1)
    x, y = X[w], Y[w]
    u = (x - vx) / np.maximum(y - vy, 1) * n
    fu = u - np.floor(u)
    v = 60.0 / np.maximum(y - vy, 1)
    idx = np.floor(u)
    fv = (v * 8 + (idx % 3) * 0.33) % 1.0
    h = (idx * 37 % 5) / 4.0
    colr = mix(C(ca), C(cb), h * 0.5)
    colr = mix(colr, C(seam), smoothstep(0.06, 0.0, np.minimum(fu, 1 - fu)) * 0.7)
    colr = mix(colr, C(seam), smoothstep(0.03, 0.0, np.minimum(fv, 1 - fv)) * 0.5)
    colr = mix(colr, WHITE, smoothstep(0.16, 0.05, fu) * (fu < 0.5) * 0.18)
    cv.paint(np.clip(0.5 - region[w] * cv.ss, 0, 1), colr, alpha, win=w)


def tiles(cv, region, vx, vy, ca, cb, n=7, rows=900.0, alpha=1.0, seam=None):
    """Perspective checkerboard floor."""
    X, Y = cv.X, cv.Y
    w = cv.win(region < 1)
    x, y = X[w], Y[w]
    dy = np.maximum(y - vy, 1)
    v = rows / dy
    u = (x - vx) / dy * n
    chk = ((np.floor(u) + np.floor(v)) % 2)[..., None]
    colr = C(ca) * (1 - chk) + C(cb) * chk
    if seam is not None:
        fu, fv = u - np.floor(u), v - np.floor(v)
        e = np.minimum(np.minimum(fu, 1 - fu), np.minimum(fv, 1 - fv) * 0.6)
        colr = mix(colr, C(seam), smoothstep(0.05, 0.0, e) * 0.6)
    cv.paint(np.clip(0.5 - region[w] * cv.ss, 0, 1), colr, alpha, win=w)


def cobbles(cv, region, vx, vy, ca, cb, gap, alpha=1.0):
    X, Y = cv.X, cv.Y
    w = cv.win(region < 1)
    x, y = X[w], Y[w]
    dy = np.maximum(y - vy, 1)
    v = 700.0 / dy
    row = np.floor(v)
    u = (x - vx) / dy * 10 + (row % 2) * 0.5
    col = np.floor(u)
    fu, fv = u - col, v - row
    h = ((row * 13 + col * 7) % 5) / 4.0
    colr = mix(C(ca), C(cb), h)
    e = np.minimum(np.minimum(fu, 1 - fu) * 1.6, np.minimum(fv, 1 - fv))
    colr = mix(colr, C(gap), smoothstep(0.12, 0.03, e))
    colr = mix(colr, WHITE, smoothstep(0.35, 0.12, fv) * (fv < 0.5) * 0.3)
    cv.paint(np.clip(0.5 - region[w] * cv.ss, 0, 1), colr, alpha, win=w)


def polka(cv, region, step, r, color="#FFFFFF", alpha=0.5, offset=0.0):
    X, Y = cv.X, cv.Y
    w = cv.win(region < 1)
    x, y = X[w] + offset, Y[w]
    row = np.floor(y / step)
    xo = x + (row % 2) * step / 2
    dx = (xo % step) - step / 2
    dyy = (y % step) - step / 2
    d = np.hypot(dx, dyy) - r
    d = np.maximum(d, region[w])
    cv.paint(np.clip(0.5 - d * cv.ss, 0, 1), C(color), alpha, win=w)


def soft_shadow_of(cv, sdf, dy=4.0, blur=6.0, color=SHADOW_PINK, alpha=0.3):
    m = np.clip(0.5 - sdf * cv.ss, 0, 1)
    m = shift(gblur(m, blur * cv.ss / 2), 0, dy * cv.ss)
    cv.paint(np.clip(m, 0, 1), C(color), alpha)


def light_pool(cv, cx, cy, rx, ry, color="#FFFFFF", alpha=0.35, mode="over"):
    r = np.hypot((cv.X - cx) / rx, (cv.Y - cy) / ry)
    cv.paint(np.exp(-r * r * 2.2), C(color), alpha, mode)


def ambient(cv, seed=17, color="#FFD6E8", alpha=0.10):
    n = noise2(cv.a.shape, 90 * cv.ss, seed=seed, octaves=2)
    cv.paint(n, C(color), alpha)


def string_lights(cv, pts, cols, r=2.6, every=3):
    X, Y = cv.X, cv.Y
    cv.fill(sd_polyline(X, Y, pts) - 0.8, "#FFFFFF", 0.9)
    for i in range(1, len(pts) - 1, every):
        x, y = pts[i]
        c = cols[(i // every) % len(cols)]
        cv.glow_from(np.clip(0.5 - sd_circle(X, Y, x, y + 3, r) * cv.ss, 0, 1), 5, c, 0.7, mode="over")
        cv.fill(sd_circle(X, Y, x, y + 3, r), mix(C(c), WHITE, 0.45))


def floor_shade(cv, y0, color=SHADOW_PINK, alpha=0.2, depth=18):
    """Soft contact shade where the floor meets the wall."""
    Y = cv.Y
    cv.paint(smoothstep(y0 + depth, y0, Y) * (Y > y0), C(color), alpha)


# anchors of items that hang or are mounted (item canvas px) - the backgrounds draw their cords / hooks
def _item_pt(district, item, ax, ay, iw, ih):
    x, y, s = LAYOUT[district][item]
    return (x + (ax - iw / 2) * s) / BG_OUT, (y + (ay - ih / 2) * s) / BG_OUT


def _cords(cv, district, item, anchors, iw, ih, top=-4.0, color="#9D7BC9", r=0.9):
    """Cords from the ceiling (or `top`) down to anchor points of an item image."""
    for (ax, ay) in anchors:
        sx, sy = _item_pt(district, item, ax, ay, iw, ih)
        cv.fill(sd_capsule(cv.X, cv.Y, sx, top, sx, sy + 1.5, r), color, 1.0)


def _hooks(cv, district, item, anchors, iw, ih, color="#FF7EB6"):
    for (ax, ay) in anchors:
        sx, sy = _item_pt(district, item, ax, ay, iw, ih)
        cv.fill(sd_circle(cv.X, cv.Y, sx, sy, 3.2), color)
        cv.fill(sd_circle(cv.X, cv.Y, sx - 0.8, sy - 0.8, 1.2), "#FFFFFF", 0.9)


# ==========================================================================
# level background
# ==========================================================================
def bg_level():
    cv = new_canvas()
    X, Y = cv.X, cv.Y
    f = full(cv)
    sky(cv, f, 0, H, sun=(286, 62, 22),
        clouds=[(58, 128, 0.42, 0.9), (300, 190, 0.34, 0.8), (110, 330, 0.28, 0.55), (310, 420, 0.3, 0.5)])
    # sun rays
    for k in range(9):
        a = math.radians(100 + k * 16)
        beam(cv, 286, 62, 286 + 520 * math.cos(a), 62 + 520 * math.sin(a), 4, 46, "#FFFFFF", 0.07, mode="over")
    # distant pastel town + hills at the bottom
    hill = sd_ellipse(X, Y, 90, 690, 220, 110)
    hill = U(hill, sd_ellipse(X, Y, 320, 700, 200, 120))
    cv.fill(hill, "#BFF0D0", 0.9)
    town(cv, 602, [(-6, 34, 58, TOWN[0], "flat"), (30, 62, 84, TOWN[1], "round"), (58, 98, 50, TOWN[2], "gable"),
                   (96, 124, 70, TOWN[3], "flat"), (122, 172, 46, TOWN[4], "arch"), (170, 198, 92, TOWN[0], "round"),
                   (196, 240, 58, TOWN[2], "flat"), (238, 266, 76, TOWN[1], "gable"), (264, 310, 52, TOWN[3], "arch"),
                   (308, 336, 88, TOWN[4], "round"), (334, 368, 60, TOWN[0], "flat")], win_alpha=0.9)
    cv.fill(rect(cv, -8, 598, W + 8, H + 8), "#FFE9C4")
    cv.fill(rect(cv, -8, 596, W + 8, 602), "#FFFFFF", 0.8)
    # a whisper of haze so the board area stays calm
    cv.paint(np.exp(-((Y - 330) / 190) ** 2) * 0.12, C("#FFFFFF"), 1.0)
    return cv


# ==========================================================================
# districts (drawing units: 360x640 = scene / 2; free band y 118..393)
# ==========================================================================
FLOOR_Y = {"cafe": 322, "jazz": 282, "square": 300, "stadium": 318, "garage": 304}


def bg_cafe():
    cv = new_canvas()
    X, Y = cv.X, cv.Y
    fy = FLOOR_Y["cafe"]
    wl = rect(cv, -8, -8, W + 8, fy)
    wall(cv, wl, [(0, "#FFD3E6"), (0.6, "#FFE1D6"), (1, "#FFE9CC")], 0, fy)
    polka(cv, wl, 17, 2.4, "#FFFFFF", 0.55)
    cv.fill(rect(cv, -8, -8, W + 8, 12), "#FFFFFF", 0.9)
    cv.fill(rect(cv, -8, 12, W + 8, 16), "#FFC2D8", 0.8)
    # big window with a sunny street
    frame = rect(cv, 20, 40, 340, 230, 22)
    soft_shadow_of(cv, frame, 6, 10, SHADOW_PINK, 0.3)
    cv.fill(frame, "#FFFFFF")
    glass = rect(cv, 30, 50, 330, 220, 15)
    sky(cv, glass, 50, 220, sun=(258, 96, 20), clouds=[(96, 104, 0.3, 1.0), (300, 136, 0.2, 0.9)],
        stops=[(0, "#43BFFF"), (0.55, "#8BE0FF"), (1, "#D8F7FF")])
    town(cv, 222, [(26, 64, 66, TOWN[0], "flat"), (60, 92, 90, TOWN[1], "round"), (88, 130, 56, TOWN[2], "gable"),
                   (126, 156, 80, TOWN[3], "flat"), (152, 212, 62, TOWN[4], "round"), (208, 242, 86, TOWN[0], "arch"),
                   (238, 288, 52, TOWN[2], "gable"), (284, 334, 74, TOWN[1], "flat")], clip=glass)
    sheen = np.maximum(np.abs((X - 30) - (Y - 50) * 0.7 - 120) - 10, glass)
    cv.fill(sheen, "#FFFFFF", 0.18, soft=4)
    sheen2 = np.maximum(np.abs((X - 30) - (Y - 50) * 0.7 - 150) - 4, glass)
    cv.fill(sheen2, "#FFFFFF", 0.14, soft=2)
    # striped awning over the window
    val = rect(cv, 12, 26, 348, 56, 10)
    scal = None
    for k in range(12):
        c_ = sd_circle(X, Y, 12 + 14 + k * 28, 54, 14)
        scal = c_ if scal is None else U(scal, c_)
    val = np.maximum(U(val, np.maximum(scal, Y - 70)), 26 - Y)
    soft_shadow_of(cv, val, 4, 6, SHADOW_PINK, 0.25)
    stripes = ((np.floor((X - 12) / 28)) % 2)[..., None]
    col = C("#FF7EB6") * (1 - stripes) + C("#FFFFFF") * stripes
    w = cv.win(val < 1)
    cv.paint(np.clip(0.5 - val[w] * cv.ss, 0, 1), col[w], 1.0, win=w)
    cv.fill(np.maximum(val, Y - 34), "#FFFFFF", 0.35)
    cv.stroke(val, 1.6, "#F0508F", 0.9)
    # sill (the cat sits here)
    sill = rect(cv, 10, 226, 350, 238, 6)
    soft_shadow_of(cv, sill, 5, 5, SHADOW_PINK, 0.3)
    candy(cv, sill, ("#FFFFFF", "#FFFFFF", "#FFE1EC", "#F2B8CF"), lw=1.2, depth=4, rim=0.2)
    # wainscot
    wain = rect(cv, -8, 272, W + 8, fy)
    cv.fill_grad(wain, [(0, "#FFC6DA"), (1, "#FFB5CD")], axis="y", p0=272, p1=fy)
    for k in range(9):
        x = 6 + k * 42
        cv.stroke(rect(cv, x, 282, x + 34, fy - 8, 5), 2.0, "#FFFFFF", 0.7)
    cv.fill(rect(cv, -8, 268, W + 8, 274, 3), "#FFFFFF")
    # floor
    floor = rect(cv, -8, fy, W + 8, H + 8)
    planks(cv, floor, 180, 190, 5, "#FFD2A6", "#FFC08A", "#E89A5C")
    cv.fill(rect(cv, -8, fy - 4, W + 8, fy + 4, 2), "#FFFFFF")
    floor_shade(cv, fy + 4)
    pool = sd_poly(X, Y, [(40, fy + 6), (320, fy + 6), (360, fy + 110), (0, fy + 110)])
    cv.fill(pool, "#FFFFFF", 0.22, soft=18)
    rug = sd_ellipse(X, Y, 184, 384, 112, 17)
    soft_shadow_of(cv, rug, 2, 3, "#C9784A", 0.25)
    cv.fill(rug, "#9FE6C8")
    cv.stroke(sd_ellipse(X, Y, 184, 384, 97, 13), 3, "#FFFFFF", 0.8)
    cv.stroke(sd_ellipse(X, Y, 184, 384, 80, 9), 2, "#FFFFFF", 0.6)
    # ceiling cords for the lamps, little hooks for the sign
    _cords(cv, "cafe", "lamps", [(48, 0), (116, 0), (180, 0)], 220, 256)
    _hooks(cv, "cafe", "sign", [(70, 0), (186, 0)], 256, 160)
    ambient(cv, 17, "#FFFFFF", 0.08)
    return cv


def bg_jazz():
    cv = new_canvas()
    X, Y = cv.X, cv.Y
    fy = FLOOR_Y["jazz"]
    wl = rect(cv, -8, -8, W + 8, fy)
    wall(cv, wl, [(0, "#9BE8DA"), (1, "#D4FAF1")], 0, fy)
    # art-deco sunburst behind the stage
    cx, cy = 180.0, fy
    ang = np.arctan2(Y - cy, X - cx)
    rays = (np.floor((ang + math.pi) / (math.pi / 14)) % 2)
    r = np.hypot(X - cx, Y - cy)
    burst = np.maximum(r - 230, wl)
    w = cv.win(burst < 1)
    cv.paint(np.clip(0.5 - burst[w] * cv.ss, 0, 1) * rays[w], C("#E9FFF9"), 0.8, win=w)
    for rr in (110, 165, 220):
        cv.fill(np.maximum(np.abs(r - rr) - 1.6, wl), "#FFD86B", 0.9)
    # pilasters
    for x in (58, 302):
        pil = rect(cv, x - 12, 48, x + 12, fy, 3)
        soft_shadow_of(cv, pil, 0, 5, "#3FA38E", 0.2)
        candy(cv, pil, ("#FFFFFF", "#FFF4DC", "#F2DDB0", "#E0B04A"), lw=1.6, depth=6, rim=0.2, grad_dir=(1.0, 0.0))
        for k in range(3):
            cv.fill(rect(cv, x - 4 + k * 4 - 1, 62, x - 4 + k * 4 + 1, fy - 12, 1), "#FFD86B", 0.7)
    # curtains
    for sgn in (-1, 1):
        x0 = 0 if sgn < 0 else W
        s_ = -sgn
        pts = [(x0 - s_ * 8, -8), (x0 + s_ * 58, -8)] + bez((x0 + s_ * 58, -8), (x0 + s_ * 38, 120),
                                                          (x0 + s_ * 16, 210), (x0 + s_ * 34, fy + 6), n=24) + \
            [(x0 - s_ * 8, fy + 6)]
        cur = sd_poly(X, Y, pts)
        soft_shadow_of(cv, cur, 0, 8, "#3FA38E", 0.3)
        folds = 0.5 + 0.5 * np.sin((X - x0) * sgn / 7.0)
        w = cv.win(cur < 1)
        colc = mix(C("#FF5C9A"), C("#FF9CC6"), folds[w] ** 2)
        colc = mix(colc, C("#E0306F"), (1 - folds[w]) ** 3 * 0.6)
        cv.paint(np.clip(0.5 - cur[w] * cv.ss, 0, 1), colc, 1.0, win=w)
        tie = sd_box(X, Y, x0 - sgn * 8, 214, 11, 4.2, 4.2, ang=sgn * -0.2)
        candy(cv, tie, ("#FFF6C2", "#FFD23F", "#F5A300", "#B86E00"), lw=1.4, depth=3)
    # valance with gold trim
    val = rect(cv, -8, -8, W + 8, 30)
    scal = None
    for k in range(9):
        c_ = sd_circle(X, Y, k * 45, 26, 22)
        scal = c_ if scal is None else U(scal, c_)
    val = U(val, np.maximum(scal, Y - 50))
    soft_shadow_of(cv, val, 5, 6, "#3FA38E", 0.3)
    cv.fill_grad(val, [(0, "#FF9CC6"), (1, "#FF5C9A")], axis="y", p0=0, p1=48)
    cv.stroke(val + 2, 2.4, "#FFD23F", 1.0)
    # stage: plank floor, gold front edge with bulbs
    stage = rect(cv, -8, fy, W + 8, 400)
    cv.fill_grad(stage, [(0, "#FFD9A8"), (1, "#FFC48A")], axis="y", p0=fy, p1=400)
    planks(cv, rect(cv, -8, fy, W + 8, 396), 180, 150, 7, "#FFDDB2", "#FFCC96", "#EFA566", alpha=0.9)
    floor_shade(cv, fy, "#C9784A", 0.18, 14)
    edge = rect(cv, -8, 394, W + 8, 410, 3)
    candy(cv, edge, ("#FFF6C2", "#FFD23F", "#F5A300", "#B86E00"), lw=1.4, depth=4, rim=0.3, grad_dir=(0, 1))
    for k in range(10):
        bx = 18 + k * 36
        cv.glow_from(np.clip(0.5 - sd_circle(X, Y, bx, 402, 2.6) * cv.ss, 0, 1), 4, "#FFFFFF", 0.8, mode="over")
        cv.fill(sd_circle(X, Y, bx, 402, 2.6), "#FFFFFF")
    # front floor: pastel checker (under the task card and the level button)
    floor = rect(cv, -8, 410, W + 8, H + 8)
    tiles(cv, floor, 180, 300, "#FFF3E6", "#FFCFE0", n=6, rows=1500)
    cv.paint(smoothstep(428, 410, Y) * (Y > 410), C("#D66E8C"), 0.25)
    for (x, c) in ((110, "#FFFFFF"), (262, "#FFF6BE")):
        light_pool(cv, x, 330, 76, 20, c, 0.4)
    # cables that hold the lighting truss
    _cords(cv, "jazz", "stage_light", [(14, 18), (206, 18)], 220, 240, color="#5E6378", r=1.1)
    ambient(cv, 21, "#FFFFFF", 0.06)
    return cv


def bg_square():
    cv = new_canvas()
    X, Y = cv.X, cv.Y
    fy = FLOOR_Y["square"]
    f = full(cv)
    sky(cv, f, 0, fy, sun=(66, 44, 18), clouds=[(250, 56, 0.3, 1.0), (96, 118, 0.22, 0.8)])
    # back row of houses
    town(cv, fy, [(-8, 50, 150, TOWN[3], "gable"), (48, 104, 116, TOWN[1], "flat"), (102, 150, 146, TOWN[4], "round"),
                  (148, 214, 124, TOWN[0], "arch"), (212, 258, 156, TOWN[2], "gable"), (256, 314, 118, TOWN[1], "round"),
                  (312, 368, 146, TOWN[3], "flat")])
    # shop awnings along the row
    for (x0, x1, c) in ((52, 100, "#FF7EB6"), (152, 210, "#3AA4FF"), (260, 310, "#2BE38F")):
        aw = opening(sd_poly(X, Y, [(x0 - 4, fy - 38), (x1 + 4, fy - 38), (x1 + 8, fy - 24), (x0 - 8, fy - 24)]), 1.5)
        stripes = ((np.floor((X - x0) / 8)) % 2)[..., None]
        colr = C(c) * (1 - stripes) + WHITE * stripes
        w = cv.win(aw < 1)
        cv.paint(np.clip(0.5 - aw[w] * cv.ss, 0, 1), colr[w], 1.0, win=w)
        cv.fill(rect(cv, x0 + 6, fy - 22, x1 - 6, fy, 3), "#FFFFFF", 0.95)
        lit_window(cv, rect(cv, x0 + 10, fy - 18, x1 - 10, fy, 2), 0.9)
        cv.fill(rect(cv, x0 + 10, fy - 18, x1 - 10, fy, 2), mix(C(c), WHITE, 0.6), 0.6)
    # side houses framing the square (garland hooks come from the layout)
    for sgn in (-1, 1):
        x0 = -10 if sgn < 0 else 306
        x1 = 54 if sgn < 0 else 370
        house = rect(cv, x0, 60, x1, 400, 6)
        soft_shadow_of(cv, house, 0, 8, "#7B4FFF", 0.2)
        c = C(TOWN[0] if sgn < 0 else TOWN[4])
        cv.fill_grad(house, [(0, mix(c, WHITE, 0.2)), (1, c)], axis="y", p0=60, p1=400)
        roof = opening(sd_poly(X, Y, [(x0 - 6, 64), (x1 + 6, 64), ((x0 + x1) / 2, 22)]), 2)
        cv.fill(roof, ROOFS[0] if sgn < 0 else ROOFS[1])
        for r in range(5):
            for k in range(2):
                wx = x0 + 14 + k * 24 if sgn < 0 else x0 + 12 + k * 24
                wy = 84 + r * 56
                lit_window(cv, rect(cv, wx, wy, wx + 14, wy + 22, 7))
                cv.fill(rect(cv, wx - 3, wy + 22, wx + 17, wy + 26, 2), mix(c, WHITE, 0.5))
                cv.fill(sd_ellipse(X, Y, wx + 7, wy + 25, 9, 3.5), "#8BE39A")
    _hooks(cv, "square", "garlands", [(2, 10), (298, 10)], 300, 96)
    # a nail and a ribbon loop for the crossed trumpets on the facade
    tx, ty = _item_pt("square", "trumpets", 120, 0, 208, 166)
    cv.fill(sd_polyline(X, Y, [(tx - 12, ty + 12), (tx, ty - 6), (tx + 12, ty + 12)]) - 1.0, "#FF4D6D", 1.0)
    cv.fill(sd_circle(X, Y, tx, ty - 6, 2.6), "#FFD23F")
    # plaza
    plaza = rect(cv, -8, fy, W + 8, H + 8)
    cobbles(cv, plaza, 180, 210, "#FFE8D6", "#FFDCC8", "#F3BFA6")
    floor_shade(cv, fy, "#D66E8C", 0.2, 16)
    cv.stroke(sd_ellipse(X, Y, 180, 372, 140, 30), 5, "#FFFFFF", 0.7)
    cv.stroke(sd_ellipse(X, Y, 180, 372, 160, 38), 2, "#FFFFFF", 0.5)
    # round trees in pots at the sides (behind the items)
    for (x, y) in ((22, 330), (338, 330)):
        tr = U(sd_circle(X, Y, x, y - 40, 24), sd_circle(X, Y, x - 16, y - 24, 16), sd_circle(X, Y, x + 16, y - 24, 16))
        soft_shadow_of(cv, tr, 4, 5, "#3FA38E", 0.25)
        candy(cv, tr, ("#D8FFE8", "#6FE0A0", "#3BBF7A", "#2A9A60"), lw=2, depth=10, rim=0.4)
        pot = rect(cv, x - 12, y - 8, x + 12, y + 12, 4)
        candy(cv, pot, ("#FFE1EE", "#FF9CC6", "#F0508F", "#C22A6C"), lw=1.6, depth=4)
    ambient(cv, 23, "#FFFFFF", 0.08)
    return cv


def bg_stadium():
    cv = new_canvas()
    X, Y = cv.X, cv.Y
    fy = FLOOR_Y["stadium"]
    f = full(cv)
    sky(cv, f, 0, 200, sun=(300, 44, 18), clouds=[(70, 50, 0.3, 1.0), (240, 96, 0.2, 0.8)])
    # stands: curved tiers
    for k, (y0, c) in enumerate(((100, "#FF9EC7"), (136, "#7FC8FF"), (172, "#FFD36E"), (208, "#C9A7FF"),
                                  (244, "#8BE39A"), (280, "#FF9EC7"))):
        tier = sd_ellipse(X, Y, 180, y0 + 330, 420, 330)
        tier = np.maximum(tier, -sd_ellipse(X, Y, 180, y0 + 366, 420, 330))
        cc = C(c)
        cv.fill(tier, mix(cc, WHITE, 0.1))
        cv.fill(np.maximum(tier, -(tier + 3.0)), mix(cc, C("#7B4FFF"), 0.18), 0.55)
        cv.fill(np.maximum(tier + 3.0, -(tier + 5.0)), "#FFFFFF", 0.6)
    # tiny crowd dots in the stands
    g = rng(51)
    crowd = np.full(X.shape, 1e3, F32)
    for _ in range(170):
        x = g.random() * W
        y = 110 + g.random() * 200
        crowd = np.minimum(crowd, sd_circle(X, Y, x, y, 2.1))
    cv.fill(np.maximum(crowd, Y - fy + 10), "#FFFFFF", 0.6)
    # roof truss
    roof = sd_arc(X, Y, 180, 470, 420, math.radians(220), math.radians(320), 10)
    candy(cv, roof, ("#FFFFFF", "#F4F0FF", "#CFC4F0", "#9D8FD0"), lw=1.6, depth=4, rim=0.2)
    for k in range(7):
        a = math.radians(226 + k * 15)
        x, y = 180 + 420 * math.cos(a), 470 + 420 * math.sin(a)
        cv.fill(sd_capsule(X, Y, x, y, x, y + 26, 2), "#FFFFFF", 0.9)
        lit_window(cv, sd_circle(X, Y, x, y + 28, 4))
    # field
    field = sd_ellipse(X, Y, 180, fy + 380, 380, 380)
    cv.fill(field, "#8BE39A")
    stripes = ((np.floor((Y - fy) / 22)) % 2) * 1.0
    cv.fill(np.maximum(field, -0.5 + 0 * X) + (1 - stripes) * 100, "#A8F0B6", 0.9)
    cv.stroke(sd_ellipse(X, Y, 180, fy + 380, 350, 350), 3, "#FFFFFF", 0.8)
    cv.stroke(sd_circle(X, Y, 180, 520, 60), 3, "#FFFFFF", 0.7)
    cv.paint(smoothstep(fy + 20, fy, Y) * (field < 0) * 1.0, C("#3FA38E"), 0.2)
    # light towers
    for sgn in (-1, 1):
        x = 180 + sgn * 162
        cv.fill(sd_capsule(X, Y, x, 60, x, 150, 3), "#FFFFFF")
        panel = rect(cv, x - 18, 40, x + 18, 66, 5)
        candy(cv, panel, ("#FFFFFF", "#F4F0FF", "#CFC4F0", "#9D8FD0"), lw=1.4, depth=4)
        for k in range(3):
            for j in range(2):
                lit_window(cv, sd_circle(X, Y, x - 10 + k * 10, 48 + j * 10, 3.2))
    ambient(cv, 29, "#FFFFFF", 0.07)
    return cv


def bg_garage():
    cv = new_canvas()
    X, Y = cv.X, cv.Y
    fy = FLOOR_Y["garage"]
    wl = rect(cv, -8, -8, W + 8, fy)
    wall(cv, wl, [(0, "#CDEBFF"), (1, "#E8F7FF")], 0, fy)
    # painted brick texture (soft)
    bw, bh = 24, 12
    row = np.floor(Y / bh)
    xo = X + (row % 2) * bw / 2
    lx = xo % bw
    ly = Y % bh
    m = np.minimum(np.minimum(lx, bw - lx), np.minimum(ly, bh - ly))
    cv.paint(smoothstep(1.2, 0.3, m) * (wl < 0), C("#FFFFFF"), 0.55)
    # colourful stripe right across the wall, over the door frame
    for k, c in enumerate(("#FF7EB6", "#FFD23F", "#3AA4FF")):
        cv.fill(rect(cv, -8, 118 + k * 7, W + 8, 123 + k * 7), c, 0.9)
    # open garage door: sunny street view
    op = rect(cv, 204, 148, 332, fy, 4)
    frame = rect(cv, 196, 140, 340, fy + 2, 8)
    soft_shadow_of(cv, frame, 4, 8, "#3A7FC9", 0.25)
    candy(cv, frame, ("#FFE1EE", "#FF9CC6", "#F0508F", "#C22A6C"), lw=1.6, depth=5, rim=0.3)
    sky(cv, op, 148, fy - 40, sun=(296, 176, 14), clouds=[(246, 186, 0.16, 1.0)],
        stops=[(0, "#43BFFF"), (0.6, "#8BE0FF"), (1, "#D8F7FF")])
    town(cv, fy - 36, [(198, 230, 66, TOWN[1], "gable"), (228, 264, 90, TOWN[0], "round"),
                       (262, 300, 60, TOWN[2], "flat"), (298, 338, 80, TOWN[4], "arch")], clip=op)
    street = np.maximum(rect(cv, 190, fy - 36, 346, fy + 4), op)
    cv.fill(street, "#FFE3C4")
    cv.fill(np.maximum(rect(cv, 190, fy - 36, 346, fy - 31), op), "#FFFFFF", 0.9)
    tree = np.maximum(U(sd_circle(X, Y, 222, fy - 60, 15), sd_circle(X, Y, 236, fy - 70, 13)), op)
    cv.fill(tree, "#6FE0A0")
    for x in (200, 336):
        cv.fill(rect(cv, x - 3, 142, x + 3, fy, 1.5), "#FFFFFF", 0.8)
    # ceiling beam with nails for the bulb string
    beam_ = rect(cv, -8, -8, W + 8, 20)
    candy(cv, beam_, ("#FFFFFF", "#FFF4E0", "#F2D7B0", "#C28A4E"), lw=1.4, depth=6, rim=0.2, grad_dir=(0, 1))
    _hooks(cv, "garage", "strings", [(2, 10), (254, 10)], 256, 100)
    # floor
    floor = rect(cv, -8, fy, W + 8, H + 8)
    tiles(cv, floor, 180, 220, "#FFF1DE", "#FFE6CC", n=5, rows=1300, seam="#F2CFA6")
    cv.fill(rect(cv, -8, fy - 4, W + 8, fy + 4, 2), "#FFFFFF")
    floor_shade(cv, fy + 4, "#C9784A", 0.18, 18)
    # rug under the drum kit
    rcx, rcy = 150, fy + 72
    rug = sd_ellipse(X, Y, rcx, rcy, 112, 22)
    soft_shadow_of(cv, rug, 2, 3, "#C9784A", 0.25)
    t = np.clip((np.arctan2(Y - rcy, (X - rcx) * 0.22) + math.pi) / (2 * math.pi), 0, 1)
    rb = ramp((t * 6) % 1.0, [(0, "#FF9EC7"), (0.5, "#FFD36E"), (1, "#FF9EC7")])
    w = cv.win(rug < 1)
    cv.paint(np.clip(0.5 - rug[w] * cv.ss, 0, 1), rb[w], 1.0, win=w)
    cv.stroke(sd_ellipse(X, Y, rcx, rcy, 97, 17), 3, "#FFFFFF", 0.8)
    pool = sd_poly(X, Y, [(204, fy + 4), (332, fy + 4), (360, fy + 96), (178, fy + 96)])
    cv.fill(pool, "#FFFFFF", 0.3, soft=14)
    ambient(cv, 31, "#FFFFFF", 0.07)
    return cv


BG_FUNCS = {"cafe": bg_cafe, "jazz": bg_jazz, "square": bg_square, "stadium": bg_stadium, "garage": bg_garage}


# ==========================================================================
# concert re-light
# ==========================================================================
# spotlight cones: (x at the top, x on the floor, colour index); pools land on the floor line + depth
CONCERT_CONES = {
    "cafe": [(40, 96, 0), (150, 176, 1), (250, 206, 2), (330, 292, 0)],
    "jazz": [(70, 104, 1), (180, 180, 2), (290, 262, 0), (130, 150, 0)],
    "square": [(0, 96, 0), (120, 158, 2), (240, 214, 1), (360, 280, 0)],
    "stadium": [(18, 110, 1), (130, 160, 0), (230, 200, 2), (342, 262, 1), (180, 180, 0)],
    "garage": [(30, 92, 0), (160, 160, 1), (260, 236, 2), (350, 300, 1)],
}


def concert(district):
    MODE.concert = True
    try:
        cv = BG_FUNCS[district]()
    finally:
        MODE.concert = False
    X, Y = cv.X, cv.Y
    fy = FLOOR_Y[district]
    with raw(cv):
        # a gentle darkening toward the top so the neon reads, nothing near black; the floor keeps its own
        # hue but sinks toward the concert violet so the spotlight pools pop
        cv.paint(smoothstep(fy, 0, Y) * 0.25, C(CONCERT[0][1]), 0.5)
        cv.paint(smoothstep(fy - 2, fy + 10, Y), C(CONCERT[1][1]), 0.32)
        # spotlight cones (added as light) + their pools and reflections on the floor
        for (x0, x1, ci) in CONCERT_CONES[district]:
            col = SPOTS[ci]
            ye = fy + 64
            beam(cv, x0, -12, x1, ye, 4, 44, col, 0.30, fade=0.35)
            beam(cv, x0, -12, x1, ye, 1.5, 14, "#FFFFFF", 0.12, fade=0.5)
            light_pool(cv, x1, ye, 58, 13, col, 0.55, mode="add")
            light_pool(cv, x1, ye, 26, 6, "#FFFFFF", 0.35, mode="add")
            refl = np.exp(-((X - x1) / 10) ** 2) * smoothstep(ye, ye + 12, Y) * smoothstep(ye + 150, ye + 20, Y)
            cv.paint(np.clip(refl, 0, 1) * (Y > fy), C(col), 0.35, mode="add")
            cv.glow_from(np.clip(0.5 - sd_circle(X, Y, x0, 4, 9) * cv.ss, 0, 1), 12, col, 0.9, mode="add")
        # bokeh + confetti sparkles above the floor
        g = rng(sum(ord(ch) * (i + 1) for i, ch in enumerate(district)) + 5)
        for _ in range(26):
            x, y = g.random() * W, 20 + g.random() * (fy - 40)
            r = 2 + g.random() * 5
            c = SPOTS[int(g.random() * 3)]
            cv.fill(sd_circle(X, Y, x, y, r), c, 0.2 + 0.2 * g.random(), soft=r * 0.6)
        for _ in range(12):
            x, y = g.random() * W, 20 + g.random() * (fy - 30)
            sparkle4(cv, x, y, 3 + g.random() * 4, WHITE, 0.9)
        # neon string along the top
        pts = []
        for i in range(3):
            pts += bez((i * 120 - 1, 6), (i * 120 + 60, 26), (i * 120 + 121, 6), n=18)[:-1]
        pts.append((W + 1, 6))
        string_lights(cv, pts, SPOTS, r=2.4, every=3)
        # floor glow
        cv.paint(smoothstep(fy, H, Y) * 0.6, C("#FF6FD8"), 0.18)
    return cv


# ==========================================================================
# scene layout (720x1280 scene px, centre of the item image, scale)
# ==========================================================================
LAYOUT = {
    "cafe": {
        "lamps": (360, 348, 0.66), "cat": (574, 418, 0.66), "sign": (360, 540, 0.56),
        "piano": (160, 690, 0.72), "turntable": (370, 712, 0.66), "plants": (578, 694, 0.72),
    },
    "jazz": {
        "stage_light": (382, 330, 0.7), "neon": (160, 322, 0.6), "grand_piano": (240, 586, 0.74),
        "double_bass": (578, 560, 0.7), "vibes": (160, 722, 0.6), "sax": (376, 712, 0.5),
        "trumpet": (568, 738, 0.56),
    },
    "square": {
        "garlands": (360, 322, 1.7), "lanterns": (106, 540, 0.66), "truck_stage": (380, 520, 0.66),
        "tuba": (600, 580, 0.56), "trumpets": (596, 432, 0.46), "fountain": (330, 700, 0.66),
        "confetti": (130, 712, 0.52), "clarinet": (560, 716, 0.46),
    },
    "stadium": {
        "fireworks": (142, 330, 0.62), "lasers": (578, 326, 0.6), "screens": (360, 330, 0.6),
        "choir": (140, 540, 0.62), "dancers": (580, 540, 0.62), "stage": (360, 560, 0.72),
        "fog": (150, 718, 0.6), "lightsticks": (560, 710, 0.64),
    },
    "garage": {
        "strings": (228, 302, 1.3), "posters": (112, 430, 0.5), "tambourine": (334, 420, 0.44),
        "garage_door": (536, 372, 1.0), "bass_guitar": (232, 470, 0.56), "drum_kit": (300, 660, 0.7),
        "amp": (112, 640, 0.56), "keyboard": (500, 730, 0.52), "mic_stand": (636, 690, 0.46),
    },
}
