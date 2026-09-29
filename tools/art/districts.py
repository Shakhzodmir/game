"""District backgrounds (360x640, upscaled 2x by the engine) and scene layouts.

Each district has an evening scene (bg.png) and a concert-night variant
(bg_night.png). Item positions live in LAYOUT (720x1280 scene pixels, y down).
"""
import math

import numpy as np

from artkit import (C, Canvas, F32, INK, WHITE, bez, darken, gblur, lighten, mix, noise2, opening, ramp, rng,
                    sd_arc, sd_box, sd_capsule, sd_circle, sd_ellipse, sd_poly, sd_polyline, sd_rect, sd_ring,
                    sd_star, smoothstep, U, I, SUB, SU, vol, inset)

W, H = 360, 640
EVE_SKY = [(0.0, "#2B2D6E"), (0.38, "#7B4FA3"), (0.72, "#FF8E72"), (1.0, "#FFC89B")]
NIGHT_SKY = [(0.0, "#0D0F2B"), (1.0, "#1E1B4B")]
SPOTS = ["#FF4FD8", "#3CF2FF", "#FFE66D"]


def pick(night, eve, nig):
    return nig if night else eve


# --------------------------------------------------------------- helpers
def sky(cv, region, y0, y1, night, sun=(250, None), seed=1):
    cv.fill_grad(region, NIGHT_SKY if night else EVE_SKY, axis="y", p0=y0, p1=y1)
    X, Y = cv.X, cv.Y
    w = cv.win(region < 1)
    if w is None:
        return
    inside = np.clip(0.5 - region[w] * cv.ss, 0, 1)
    if night:
        g = rng(seed)
        k = np.zeros_like(inside)
        for _ in range(int(60 * (y1 - y0) / 300 + 20)):
            sx, sy = g.random() * W, y0 + g.random() * (y1 - y0) * 0.85
            r = 0.5 + g.random() * 0.9
            k = np.maximum(k, (1 - smoothstep(0, r, np.hypot(X[w] - sx, Y[w] - sy))) * (0.4 + 0.6 * g.random()))
        cv.paint(k * inside, WHITE, 1.0, win=w)
    else:
        sx = sun[0]
        sy = sun[1] if sun[1] is not None else y1 - 10
        r = np.hypot(X[w] - sx, Y[w] - sy)
        cv.paint(inside * np.exp(-(r / 70) ** 2), C("#FFE3B0"), 0.55, win=w)
        cv.paint(inside * (1 - smoothstep(18, 20, r)), C("#FFF1D6"), 0.9, win=w)


def moon(cv, x, y, r, clip=None):
    d = SUB(sd_circle(cv.X, cv.Y, x, y, r), sd_circle(cv.X, cv.Y, x + r * 0.45, y - r * 0.2, r * 0.85))
    if clip is not None:
        d = np.maximum(d, clip)
    cv.glow_from(np.clip(0.5 - sd_circle(cv.X, cv.Y, x, y, r) * cv.ss, 0, 1) * (1 if clip is None else np.clip(0.5 - clip * cv.ss, 0, 1)),
                 18, "#8C84FF", 0.35, mode="over")
    cv.fill(d, "#FFF4D6", 1.0, soft=0.5)


def skyline(cv, base_y, seed, color, hmin, hmax, night, clip=None, wmin=18, wmax=44, lit=0.0, win_col="#FFD27A",
            x0=-10, x1=W + 10):
    """Row of building silhouettes; lit>0 draws warm windows."""
    g = rng(seed)
    X, Y = cv.X, cv.Y
    x = x0
    shapes = None
    wins = []
    while x < x1:
        bw = wmin + g.random() * (wmax - wmin)
        bh = hmin + g.random() * (hmax - hmin)
        d = sd_rect(X, Y, x, base_y - bh, x + bw, base_y + 400, 1.5)
        roof = g.random()
        if roof < 0.25:
            d = U(d, sd_poly(X, Y, [(x - 2, base_y - bh), (x + bw + 2, base_y - bh), (x + bw / 2, base_y - bh - bw * 0.45)]))
        elif roof < 0.4:
            d = U(d, sd_rect(X, Y, x + bw * 0.6, base_y - bh - 14, x + bw * 0.6 + 4, base_y - bh, 0))
        shapes = d if shapes is None else np.minimum(shapes, d)
        if lit > 0:
            for wy in np.arange(base_y - bh + 8, base_y - 6, 10):
                for wx in np.arange(x + 5, x + bw - 7, 9):
                    if g.random() < lit:
                        wins.append((wx, wy))
        x += bw + g.random() * 3
    if clip is not None:
        shapes = np.maximum(shapes, clip)
    cv.fill(shapes, color, 1.0, soft=0.4)
    if wins:
        m = np.full_like(X, 1e3)
        for (wx, wy) in wins:
            m = np.minimum(m, sd_rect(X, Y, wx, wy, wx + 4, wy + 5, 0.8))
        m = np.maximum(m, shapes)
        if night:
            cv.glow_from(np.clip(0.5 - m * cv.ss, 0, 1), 4, win_col, 0.5, mode="over")
        cv.fill(m, win_col, 0.95 if night else 0.55)


def beam(cv, x0, y0, x1, y1, w0, w1, color, alpha, clip=None):
    X, Y = cv.X, cv.Y
    dx, dy = x1 - x0, y1 - y0
    L = math.hypot(dx, dy)
    ux, uy = dx / L, dy / L
    px, py = X - x0, Y - y0
    along = px * ux + py * uy
    across = np.abs(-px * uy + py * ux)
    t = np.clip(along / L, 0, 1)
    half = w0 + (w1 - w0) * t
    v = smoothstep(half, half * 0.2, across) * (along > 0) * (1 - t * 0.7) * smoothstep(0, 30, along)
    if clip is not None:
        v = v * np.clip(0.5 - clip * cv.ss, 0, 1)
    cv.paint(np.clip(v, 0, 1), C(color), alpha, "add")


def bricks(cv, region, bw, bh, ca, cb, mortar, alpha=1.0, seed=3):
    X, Y = cv.X, cv.Y
    w = cv.win(region < 1)
    if w is None:
        return
    x, y = X[w], Y[w]
    row = np.floor(y / bh)
    xo = x + (row % 2) * bw / 2
    col = np.floor(xo / bw)
    lx = xo - col * bw
    ly = y - row * bh
    h = ((row * 73 + col * 31 + seed) % 7) / 6.0
    colr = mix(C(ca), C(cb), h)
    m = np.minimum(np.minimum(lx, bw - lx), np.minimum(ly, bh - ly))
    colr = mix(colr, C(mortar), smoothstep(1.2, 0.4, m))
    colr = mix(colr, lighten(ca, 0.3), smoothstep(2.2, 1.2, ly) * (ly < bh / 2) * 0.35)
    cv.paint(np.clip(0.5 - region[w] * cv.ss, 0, 1), colr, alpha, win=w)


def planks(cv, region, vx, vy, n, ca, cb, seam, alpha=1.0):
    """Perspective wooden floor converging to (vx, vy)."""
    X, Y = cv.X, cv.Y
    w = cv.win(region < 1)
    if w is None:
        return
    x, y = X[w], Y[w]
    u = (x - vx) / np.maximum(y - vy, 1) * n
    fu = u - np.floor(u)
    v = 60.0 / np.maximum(y - vy, 1)
    idx = np.floor(u)
    fv = (v * 8 + (idx % 3) * 0.33) % 1.0
    h = (idx * 37 % 5) / 4.0
    colr = mix(C(ca), C(cb), h * 0.6 + smoothstep(vy, H, y) * 0.0)
    colr = mix(colr, C(seam), smoothstep(0.06, 0.0, np.minimum(fu, 1 - fu)) * 0.8)
    colr = mix(colr, C(seam), smoothstep(0.03, 0.0, np.minimum(fv, 1 - fv)) * 0.6)
    cv.paint(np.clip(0.5 - region[w] * cv.ss, 0, 1), colr, alpha, win=w)


def cobbles(cv, region, vx, vy, ca, cb, gap, alpha=1.0):
    X, Y = cv.X, cv.Y
    w = cv.win(region < 1)
    if w is None:
        return
    x, y = X[w], Y[w]
    dy = np.maximum(y - vy, 1)
    v = 900.0 / dy
    row = np.floor(v)
    u = (x - vx) / dy * 9 + (row % 2) * 0.5
    col = np.floor(u)
    fu, fv = u - col, v - row
    h = ((row * 13 + col * 7) % 5) / 4.0
    colr = mix(C(ca), C(cb), h)
    e = np.minimum(np.minimum(fu, 1 - fu) * 1.6, np.minimum(fv, 1 - fv))
    colr = mix(colr, C(gap), smoothstep(0.12, 0.02, e))
    colr = mix(colr, lighten(ca, 0.25), smoothstep(0.3, 0.12, fv) * (fv < 0.5) * 0.25)
    cv.paint(np.clip(0.5 - region[w] * cv.ss, 0, 1), colr, alpha, win=w)


def vignette(cv, strength=0.35, color="#140F2E"):
    r = np.hypot((cv.X - W / 2) / (W * 0.62), (cv.Y - H * 0.45) / (H * 0.62))
    cv.paint(smoothstep(0.7, 1.25, r), C(color), strength)


def warm_haze(cv, night):
    """Soft painterly light: big low-frequency colour variation."""
    n = noise2(cv.a.shape, 90 * cv.ss, seed=17, octaves=2)
    cv.paint(n * 0.5, C(pick(night, "#FFB36B", "#8C84FF")), pick(night, 0.10, 0.08))


def window_view(cv, rect, night, seed, arch=False):
    """A window showing the evening/night city."""
    x0, y0, x1, y1 = rect
    X, Y = cv.X, cv.Y
    frame = sd_rect(X, Y, x0 - 8, y0 - 8, x1 + 8, y1 + 8, 6)
    glass = sd_rect(X, Y, x0, y0, x1, y1, 3)
    if arch:
        r = (x1 - x0) / 2
        cx = (x0 + x1) / 2
        frame = U(frame, sd_circle(X, Y, cx, y0, r + 8))
        glass = U(glass, sd_circle(X, Y, cx, y0, r))
        top = y0 - r
    else:
        top = y0
    vol(cv, frame, pick(night, "#6B3F2E", "#3A2233"), light=pick(night, "#A8674E", "#6A4460"),
        dark=pick(night, "#34160F", "#150A14"), line="#1A0F1A", lw=2, depth=5, spec=0.2)
    sky(cv, glass, top, y1, night, sun=((x0 + x1) / 2 + 20, y1 - 26), seed=seed)
    if night:
        moon(cv, x0 + (x1 - x0) * 0.72, top + (y1 - top) * 0.25, 9, clip=glass)
    skyline(cv, y1 + 2, seed, pick(night, "#5A3A78", "#16143A"), 20, 60, night, clip=glass, lit=0.35,
            x0=x0 - 10, x1=x1 + 10)
    skyline(cv, y1 + 2, seed + 1, pick(night, "#3A2458", "#0E0C28"), 10, 34, night, clip=glass, lit=0.3,
            wmin=12, wmax=26, x0=x0 - 10, x1=x1 + 10)
    # muntins
    mx = (x0 + x1) / 2
    my = (top + y1) / 2 + 10
    bars = U(np.maximum(np.abs(X - mx) - 2.2, glass), np.maximum(np.abs(Y - my) - 2.2, glass))
    cv.fill(np.maximum(bars, glass), pick(night, "#6B3F2E", "#3A2233"), 1.0)
    # glass sheen
    sheen = np.maximum(np.abs((X - x0) - (Y - top) * 0.6 - (x1 - x0) * 0.2) - 6, glass)
    cv.fill(sheen, "#FFFFFF", 0.08, soft=3)
    return glass


def spotlights(cv, night, sources, clip=None):
    """Concert beams (night only)."""
    if not night:
        return
    for (x0, y0, x1, y1, w1, col) in sources:
        beam(cv, x0, y0, x1, y1, 4, w1, col, 0.32, clip=clip)


# --------------------------------------------------------------- CAFE
def bg_cafe(night):
    cv = Canvas(W, H, bg="#000000")
    X, Y = cv.X, cv.Y
    wall = sd_rect(X, Y, -5, 88, W + 5, 452, 0)
    cv.fill_grad(wall, [(0, pick(night, "#7A4A70", "#2E2250")), (1, pick(night, "#9A5E74", "#3A2A5A"))], axis="y",
                 p0=88, p1=452)
    stripes = np.maximum(np.abs((X % 24.0) - 12) - 5, wall)
    cv.fill(stripes, pick(night, "#B8768A", "#4A3A78"), 0.18)
    # wainscot
    wain = sd_rect(X, Y, -5, 360, W + 5, 452, 0)
    cv.fill_grad(wain, [(0, pick(night, "#6B3A36", "#2A1A30")), (1, pick(night, "#50282A", "#1E1226"))], axis="y")
    for k in range(9):
        x = 6 + k * 40
        p = sd_rect(X, Y, x, 372, x + 32, 440, 3)
        cv.stroke(p, 1.6, pick(night, "#8A4E46", "#3E2A48"), 0.8)
    cv.fill(sd_rect(X, Y, -5, 356, W + 5, 364, 1), pick(night, "#8A4E46", "#3E2A48"))
    # ceiling + beam
    ceil = sd_rect(X, Y, -5, -5, W + 5, 90, 0)
    cv.fill_grad(ceil, [(0, pick(night, "#2A1826", "#0C0818")), (1, pick(night, "#4A2A36", "#1A1228"))], axis="y")
    cv.fill(sd_rect(X, Y, -5, 80, W + 5, 92, 0), pick(night, "#5A3428", "#24162A"))
    # window + sill
    glass = window_view(cv, (160, 150, 330, 328), night, seed=11)
    sill = sd_rect(X, Y, 146, 330, 344, 342, 2)
    vol(cv, sill, pick(night, "#8A5A40", "#3E2A40"), light=pick(night, "#C98A60", "#6A4A70"),
        dark=pick(night, "#4A2A1A", "#1A1024"), line="#1A0F1A", lw=1.5, depth=3, spec=0.2)
    # chalk menu board on the left wall (behind nothing)
    board = sd_rect(X, Y, 26, 196, 120, 300, 4)
    vol(cv, board, pick(night, "#6B3F2E", "#2E1E30"), line="#1A0F1A", lw=1.5, depth=3, spec=0.1)
    inset(cv, sd_rect(X, Y, 32, 202, 114, 294, 2), pick(night, "#2E3A34", "#1A2226"), depth=3, shadow=0.4)
    for k in range(5):
        cv.fill(sd_capsule(X, Y, 42, 222 + k * 14, 42 + 30 + (k * 17) % 30, 222 + k * 14, 1.1), "#E8F0EA", 0.55)
    # floor
    floor = sd_rect(X, Y, -5, 452, W + 5, H + 5, 0)
    planks(cv, floor, 180, 300, 5.5, pick(night, "#A8663E", "#4A2E44"), pick(night, "#8A4E30", "#3A2238"),
           pick(night, "#4A2416", "#1A0E1C"))
    cv.fill(sd_rect(X, Y, -5, 448, W + 5, 456, 0), pick(night, "#3A1E14", "#140A14"))
    rug = sd_ellipse(X, Y, 190, 560, 150, 40)
    cv.fill(rug, pick(night, "#C24A5A", "#5A2A6A"), 0.85, soft=1)
    cv.stroke(sd_ellipse(X, Y, 190, 560, 136, 32), 3, pick(night, "#FFC89B", "#FF4FD8"), 0.5)
    if not night:
        # warm sunset light through the window
        patch = sd_poly(X, Y, [(160, 456), (330, 456), (300, 620), (80, 620)])
        cv.fill(patch, "#FFC89B", 0.16, soft=12)
        cv.glow_from(np.clip(0.5 - glass * cv.ss, 0, 1), 30, "#FFB36B", 0.3, mode="over")
    else:
        # small concert corner: fairy lights + beams
        for k in range(14):
            x = 10 + k * 25
            y = 100 + 8 * math.sin(k * 0.9)
            cv.glow_from(np.clip(0.5 - sd_circle(X, Y, x, y, 2) * cv.ss, 0, 1), 5, SPOTS[k % 3], 0.8, mode="over")
            cv.fill(sd_circle(X, Y, x, y, 2.2), lighten(SPOTS[k % 3], 0.5))
        spotlights(cv, night, [(20, 90, 200, 640, 90, SPOTS[0]), (340, 90, 160, 640, 90, SPOTS[1]),
                               (180, 90, 190, 640, 70, SPOTS[2])])
    warm_haze(cv, night)
    vignette(cv, 0.35)
    return cv


# --------------------------------------------------------------- JAZZ
def bg_jazz(night):
    cv = Canvas(W, H, bg="#000000")
    X, Y = cv.X, cv.Y
    wall = sd_rect(X, Y, -5, -5, W + 5, 380, 0)
    bricks(cv, wall, 24, 11, pick(night, "#8A3A3E", "#3E1C34"), pick(night, "#6E2A34", "#2E1428"),
           pick(night, "#3A1620", "#12081A"))
    cv.fill_grad(wall, [(0, "#000000"), (1, "#000000")], alpha=0.0)
    # warm wall lights (sconces)
    for x in (40, 320):
        cv.glow_from(np.clip(0.5 - sd_circle(X, Y, x, 190, 6) * cv.ss, 0, 1), 40, pick(night, "#FFB36B", "#FF4FD8"),
                     0.5, mode="over")
        vol(cv, sd_ellipse(X, Y, x, 196, 10, 6), "#FFC23D", light="#FFF0B0", dark="#B86E00", line="#1A0F1A", lw=1.2,
            depth=3)
    # arched window
    glass = window_view(cv, (228, 120, 318, 250), night, seed=21, arch=True)
    # curtains
    for sgn in (-1, 1):
        x_in = W / 2 + sgn * 150
        edge = [(x_in, 30), (x_in + sgn * 8, 150), (x_in - sgn * 4, 260), (x_in + sgn * 10, 390)]
        pts = [(W / 2 + sgn * 200, 20)] + edge + [(W / 2 + sgn * 200, 390)]
        cur = sd_poly(X, Y, pts)
        w = cv.win(cur < 1)
        folds = 0.5 + 0.5 * np.cos((X[w] - x_in) * 0.35)
        col = mix(C(pick(night, "#B01E48", "#5A0F3A")), C(pick(night, "#6A0A2A", "#2A0620")), folds[..., None] * 0.7)
        cv.paint(np.clip(0.5 - cur[w] * cv.ss, 0, 1), col, 1.0, win=w)
    val = sd_rect(X, Y, -5, -5, W + 5, 40, 0)
    cv.fill_grad(val, [(0, pick(night, "#6A0A2A", "#2A0620")), (1, pick(night, "#B01E48", "#5A0F3A"))], axis="y")
    for k in range(12):
        cv.fill(sd_circle(X, Y, 15 + k * 30, 40, 15), pick(night, "#8A1238", "#3E0A2C"), 1.0)
    cv.fill(sd_rect(X, Y, -5, 34, W + 5, 40, 0), "#FFC23D", 0.8)
    # stage
    stage_top = sd_poly(X, Y, [(-5, 350), (W + 5, 350), (W + 5, 384), (-5, 384)])
    planks(cv, stage_top, 180, 200, 7, pick(night, "#9A5A34", "#4A2A3E"), pick(night, "#7A4226", "#3A1E30"),
           pick(night, "#3A1A10", "#140A14"))
    front = sd_rect(X, Y, -5, 384, W + 5, 404, 0)
    cv.fill_grad(front, [(0, pick(night, "#4A2418", "#1E1020")), (1, pick(night, "#2E140E", "#120A14"))], axis="y")
    for k in range(18):
        x = 10 + k * 20
        cv.glow_from(np.clip(0.5 - sd_circle(X, Y, x, 394, 1.6) * cv.ss, 0, 1), 4, "#FFE66D", 0.7, mode="over")
        cv.fill(sd_circle(X, Y, x, 394, 1.8), "#FFF3B0")
    # club floor (checker)
    floor = sd_rect(X, Y, -5, 404, W + 5, H + 5, 0)
    w = cv.win(floor < 1)
    dy = np.maximum(Y[w] - 250, 1)
    u = (X[w] - 180) / dy * 5
    v = 600.0 / dy
    chk = ((np.floor(u) + np.floor(v)) % 2)
    col = mix(C(pick(night, "#3A2438", "#1A1228")), C(pick(night, "#E8D8C0", "#4A3E66")), chk[..., None] * 0.9)
    cv.paint(np.clip(0.5 - floor[w] * cv.ss, 0, 1), col, 1.0, win=w)
    # bar counter on the left
    bar = sd_rect(X, Y, -10, 430, 120, 486, 4)
    vol(cv, bar, pick(night, "#6B3A2E", "#2E1A28"), light=pick(night, "#A8674E", "#5A3A50"),
        dark=pick(night, "#34160F", "#12080E"), line="#12080E", lw=1.5, depth=6, spec=0.3)
    cv.fill(sd_rect(X, Y, -10, 426, 126, 434, 2), pick(night, "#C98A60", "#5A3A70"))
    # warm stage light pool / night beams
    if not night:
        cv.fill(sd_ellipse(X, Y, 180, 366, 150, 26), "#FFC89B", 0.25, soft=16)
    spotlights(cv, night, [(60, 40, 120, 380, 60, SPOTS[0]), (300, 40, 240, 380, 60, SPOTS[1]),
                           (180, 40, 180, 380, 50, SPOTS[2])])
    warm_haze(cv, night)
    vignette(cv, 0.4)
    del glass
    return cv


# --------------------------------------------------------------- SQUARE
def _house_row(cv, night, base_y, xs, seed):
    X, Y = cv.X, cv.Y
    g = rng(seed)
    cols = [("#E07A5F", "#5A2A48"), ("#F2CC8F", "#4A3A5E"), ("#81B29A", "#2A3A4E"), ("#C98BB9", "#4A2A5A"),
            ("#7FA7D9", "#2A3060")]
    for i, (x0, x1, h) in enumerate(xs):
        eve, nig = cols[(i + seed) % len(cols)]
        body = sd_rect(X, Y, x0, base_y - h, x1, base_y + 10, 1)
        c0 = mix(C(pick(night, eve, nig)), C(pick(night, "#7B4FA3", "#0D0F2B")), 0.35)
        cv.fill(body, c0)
        roof = sd_poly(X, Y, [(x0 - 4, base_y - h), (x1 + 4, base_y - h), ((x0 + x1) / 2, base_y - h - (x1 - x0) * 0.35)])
        cv.fill(roof, pick(night, "#6A2E3E", "#1A1030"))
        for wy in np.arange(base_y - h + 12, base_y - 12, 22):
            for wx in np.arange(x0 + 8, x1 - 12, 16):
                wd = sd_rect(X, Y, wx, wy, wx + 8, wy + 12, 3)
                lit = g.random() < pick(night, 0.35, 0.75)
                if lit and night:
                    cv.glow_from(np.clip(0.5 - wd * cv.ss, 0, 1), 5, "#FFD27A", 0.5, mode="over")
                cv.fill(wd, "#FFD27A" if lit else darken(c0, 0.35), 0.95 if lit else 0.9)


def bg_square(night):
    cv = Canvas(W, H, bg="#000000")
    X, Y = cv.X, cv.Y
    skyr = sd_rect(X, Y, -5, -5, W + 5, 330, 0)
    sky(cv, skyr, 0, 330, night, sun=(200, 300), seed=31)
    if night:
        moon(cv, 280, 70, 16)
    skyline(cv, 330, 32, pick(night, "#6A4A8E", "#1A1840"), 40, 110, night, lit=0.25)
    _house_row(cv, night, 340, [(-10, 44, 150), (44, 96, 190), (96, 130, 120)], 3)
    _house_row(cv, night, 340, [(236, 272, 130), (272, 318, 200), (318, 372, 160)], 5)
    ground = sd_rect(X, Y, -5, 336, W + 5, H + 5, 0)
    cobbles(cv, ground, 180, 250, pick(night, "#C99A7A", "#4A3A5E"), pick(night, "#B08066", "#3A2E50"),
            pick(night, "#6A4A48", "#1A1430"))
    ring = sd_ring(X, Y, 180, 440, 0, 0)
    del ring
    plaza = sd_ellipse(X, Y, 180, 440, 150, 44)
    cv.stroke(plaza, 5, pick(night, "#E8C8A8", "#6A5A86"), 0.7)
    cv.fill(sd_ellipse(X, Y, 180, 440, 138, 38), pick(night, "#D8B090", "#54466E"), 0.35)
    if not night:
        cv.fill(sd_ellipse(X, Y, 200, 330, 200, 60), "#FFC89B", 0.2, soft=30)
    spotlights(cv, night, [(10, 640, 120, 0, 60, SPOTS[0]), (350, 640, 240, 0, 60, SPOTS[1]),
                           (180, 640, 180, 60, 50, SPOTS[2])])
    warm_haze(cv, night)
    vignette(cv, 0.3)
    return cv


# --------------------------------------------------------------- STADIUM
def bg_stadium(night):
    cv = Canvas(W, H, bg="#000000")
    X, Y = cv.X, cv.Y
    skyr = sd_rect(X, Y, -5, -5, W + 5, 300, 0)
    sky(cv, skyr, 0, 300, night, sun=(170, 250), seed=41)
    if night:
        moon(cv, 70, 60, 14)
    # stadium bowl
    bowl = U(sd_ellipse(X, Y, 180, 330, 260, 130), sd_rect(X, Y, -5, 330, W + 5, 420, 0))
    bowl = np.maximum(bowl, 200 - Y)
    cv.fill_grad(bowl, [(0, pick(night, "#4A2E6E", "#16123A")), (1, pick(night, "#2E1E4E", "#0E0C28"))], axis="y",
                 p0=200, p1=420)
    # crowd rows
    w = cv.win(bowl < 1)
    g = rng(42)
    rows = np.floor((Y[w] - 200) / 9)
    xx = X[w] + (rows % 2) * 4
    head = np.hypot((xx % 8) - 4, ((Y[w] - 200) % 9) - 4.5)
    hcol = (np.floor(xx / 8) * 7 + rows * 3) % 6
    cols = np.stack([C(c) for c in ("#FF4FD8", "#3CF2FF", "#FFE66D", "#C6FF4D", "#FF8E72", "#8C84FF")])
    cc = cols[hcol.astype(int)]
    dots = (1 - smoothstep(1.6, 2.6, head)) * np.clip(0.5 - bowl[w] * cv.ss, 0, 1) * (Y[w] > 212)
    base = mix(C(pick(night, "#6A4A8E", "#2A2458")), cc, pick(night, 0.25, 0.8))
    cv.paint(dots, base, pick(night, 0.55, 0.85), win=w)
    del g
    # rim of the stands
    rim = np.abs(sd_ellipse(X, Y, 180, 330, 260, 130)) - 2.5
    cv.fill(np.maximum(rim, 205 - Y), pick(night, "#8C84FF", "#3CF2FF"), 0.8)
    # light towers
    for x in (26, 334):
        cv.fill(sd_rect(X, Y, x - 3, 120, x + 3, 330, 1), pick(night, "#3A2E5E", "#14102E"))
        panel = sd_rect(X, Y, x - 20, 96, x + 20, 124, 3)
        cv.fill(panel, pick(night, "#4A3E7E", "#1E1846"))
        for k in range(8):
            lx = x - 15 + (k % 4) * 10
            ly = 104 + (k // 4) * 10
            d = sd_circle(X, Y, lx, ly, 3)
            cv.glow_from(np.clip(0.5 - d * cv.ss, 0, 1), 6, "#FFF6C0", pick(night, 0.4, 0.9), mode="over")
            cv.fill(d, "#FFF6C0")
    # field / stage floor
    floor = sd_rect(X, Y, -5, 416, W + 5, H + 5, 0)
    cv.fill_grad(floor, [(0, pick(night, "#3A2A5E", "#141032")), (1, pick(night, "#241A40", "#0C0A20"))], axis="y")
    grid = np.maximum(np.minimum(np.abs(((X - 180) / np.maximum(Y - 300, 1) * 8) % 1 - 0.5) - 0.47,
                                 np.abs((600 / np.maximum(Y - 300, 1)) % 1 - 0.5) - 0.46) * 10, floor)
    cv.fill(grid, pick(night, "#8C84FF", "#3CF2FF"), 0.18)
    cv.fill(sd_rect(X, Y, -5, 412, W + 5, 418, 0), pick(night, "#FF8E72", "#FF4FD8"), 0.7)
    spotlights(cv, night, [(26, 110, 170, 640, 70, SPOTS[0]), (334, 110, 190, 640, 70, SPOTS[1]),
                           (180, 420, 60, 0, 40, SPOTS[2]), (180, 420, 300, 0, 40, SPOTS[0])])
    if not night:
        cv.fill(sd_ellipse(X, Y, 170, 260, 220, 50), "#FFC89B", 0.18, soft=30)
    warm_haze(cv, night)
    vignette(cv, 0.3)
    return cv


# --------------------------------------------------------------- GARAGE
def bg_garage(night):
    cv = Canvas(W, H, bg="#000000")
    X, Y = cv.X, cv.Y
    wall = sd_rect(X, Y, -5, 90, W + 5, 470, 0)
    bricks(cv, wall, 26, 12, pick(night, "#A85A44", "#4A2A3E"), pick(night, "#8E4A3A", "#3A2032"),
           pick(night, "#5A2E26", "#1A0E1A"))
    ceil = sd_rect(X, Y, -5, -5, W + 5, 92, 0)
    cv.fill_grad(ceil, [(0, pick(night, "#2E1E2A", "#0C0818")), (1, pick(night, "#4A3040", "#1A1228"))], axis="y")
    for k in range(5):
        x = 20 + k * 80
        cv.fill(sd_rect(X, Y, x, 70, x + 10, 92, 0), pick(night, "#5A3A38", "#24162A"))
    cv.fill(sd_rect(X, Y, -5, 84, W + 5, 94, 0), pick(night, "#5A3A38", "#24162A"))
    # window (top right, above the door)
    glass = window_view(cv, (40, 116, 150, 186), night, seed=51)
    # pegboard
    peg = sd_rect(X, Y, 150, 250, 214, 330, 3)
    vol(cv, peg, pick(night, "#C9A070", "#4A3A4E"), line="#1A0F1A", lw=1.2, depth=3, spec=0.1)
    holes = np.maximum(np.hypot((X % 8) - 4, (Y % 8) - 4) - 0.9, peg + 2)
    cv.fill(holes, "#3A2418", 0.6)
    for (x0, y0, x1, y1) in ((162, 262, 162, 300), (176, 264, 186, 296), (198, 262, 198, 292)):
        cv.fill(sd_capsule(X, Y, x0, y0, x1, y1, 2.2), pick(night, "#6A6F85", "#3A3E55"))
    # floor
    floor = sd_rect(X, Y, -5, 470, W + 5, H + 5, 0)
    cv.fill_grad(floor, [(0, pick(night, "#8A7478", "#2E2640")), (1, pick(night, "#6A5660", "#1E1830"))], axis="y")
    n = noise2(cv.a.shape, 30 * cv.ss, seed=52, octaves=3)
    w = cv.win(floor < 1)
    cv.paint(n[w] * np.clip(0.5 - floor[w] * cv.ss, 0, 1), C(pick(night, "#5A4650", "#14102A")), 0.25, win=w)
    for k in range(4):
        x = 30 + k * 100
        cv.fill(sd_polyline(X, Y, [(x, 470), (x - 60 + k * 30, 640)]) - 0.8, pick(night, "#5A4650", "#14102A"), 0.6)
    cv.fill(sd_ellipse(X, Y, 230, 560, 40, 9), pick(night, "#4A3A48", "#100C20"), 0.5, soft=3)
    cv.fill(sd_rect(X, Y, -5, 466, W + 5, 472, 0), pick(night, "#4A2A22", "#140A14"))
    # rug under the drums
    rug = sd_ellipse(X, Y, 170, 420, 120, 24)
    del rug
    if not night:
        patch = sd_poly(X, Y, [(40, 472), (150, 472), (120, 600), (0, 600)])
        cv.fill(patch, "#FFC89B", 0.12, soft=12)
        cv.glow_from(np.clip(0.5 - glass * cv.ss, 0, 1), 26, "#FFB36B", 0.3, mode="over")
    spotlights(cv, night, [(20, 94, 180, 640, 80, SPOTS[0]), (340, 94, 160, 640, 80, SPOTS[1]),
                           (180, 94, 190, 640, 60, SPOTS[2])])
    warm_haze(cv, night)
    vignette(cv, 0.35)
    return cv


BG_FUNCS = {"cafe": bg_cafe, "jazz": bg_jazz, "square": bg_square, "stadium": bg_stadium, "garage": bg_garage}

# Scene composition (720x1280, y down). Centers refer to the (trimmed) item image.
LAYOUT = {
    "cafe": {
        "sign": (184, 262, 0.86), "lamps": (410, 292, 0.86), "cat": (572, 604, 0.78),
        "piano": (190, 772, 0.94), "plants": (382, 856, 0.8), "turntable": (560, 850, 0.84),
    },
    "jazz": {
        "stage_light": (344, 290, 0.9), "neon": (170, 420, 0.84), "grand_piano": (222, 652, 1.0),
        "double_bass": (566, 634, 0.94), "vibes": (178, 890, 0.8), "sax": (400, 866, 0.72),
        "trumpet": (566, 908, 0.7),
    },
    "square": {
        "garlands": (360, 262, 1.8), "lanterns": (140, 480, 0.84), "truck_stage": (400, 520, 0.98),
        "tuba": (138, 728, 0.78), "trumpets": (560, 724, 0.78), "fountain": (362, 812, 0.98),
        "confetti": (156, 918, 0.74), "clarinet": (590, 906, 0.7),
    },
    "stadium": {
        "fireworks": (186, 290, 0.9), "lasers": (528, 300, 0.88), "screens": (360, 482, 0.94),
        "choir": (150, 598, 0.7), "dancers": (570, 598, 0.74), "stage": (362, 722, 0.94),
        "fog": (162, 884, 0.78), "lightsticks": (540, 884, 0.84),
    },
    "garage": {
        "strings": (360, 256, 1.8), "posters": (176, 430, 0.8), "tambourine": (352, 424, 0.68),
        "garage_door": (534, 482, 0.94), "bass_guitar": (112, 704, 0.8), "drum_kit": (326, 726, 0.94),
        "amp": (570, 712, 0.78), "keyboard": (206, 904, 0.8), "mic_stand": (596, 906, 0.7),
    },
}
