"""GLOW wordmark (640x320): Rubik Black, rainbow-candy gradient, white outline, soft glow."""
import math
import os

import numpy as np

from artkit import (C, Canvas, F32, LIGHT, WHITE, gblur, mix, ramp, sd_ellipse, sdf_from_mask, shift, smoothstep,
                    sparkle4, text_mask, _t)
from palette import PIECES, ORDER

FONT = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "fonts", "Rubik-Black.ttf")


def _rainbow(t, which=1):
    return ramp(t, [(i / 5, PIECES[k][which]) for i, k in enumerate(ORDER)])


def draw_logo():
    cv = Canvas(640, 320)
    X, Y = cv.X, cv.Y
    ss = cv.ss
    mask = text_mask(cv, "GLOW", FONT, 188, 320, 150, tracking=6)
    m = mask > 0.5
    sd = sdf_from_mask(m, ss)
    ys = np.flatnonzero(m.any(1))
    xs = np.flatnonzero(m.any(0))
    top, bot = ys[0] / ss, ys[-1] / ss
    left, right = xs[0] / ss, xs[-1] / ss
    depth = 12
    ext_m = shift(m.astype(F32), 0, depth * ss) > 0.5
    ext = sdf_from_mask(ext_m | m, ss)
    # soft rainbow glow behind everything
    tx = np.clip((X - left) / (right - left), 0, 1)
    glow = gblur(np.clip(0.5 - (ext - 16) * ss, 0, 1), 16 * ss / 2)
    cv.paint(np.clip(glow * 1.2, 0, 1), _rainbow(tx, 0), 0.75)
    # white sticker outline around face + extrusion
    cv.fill(ext - 11, "#FFFFFF", 1.0)
    cv.fill(ext - 11.5, "#E9DDFF", 0.0)
    # extrusion (candy side): darker rainbow
    side = sdf_from_mask(ext_m & ~m, ss)
    w = cv.win(ext < 1)
    ecol = mix(_rainbow(tx[w], 2), C("#4B1FB0"), 0.25)
    cv.paint(np.clip(0.5 - ext[w] * ss, 0, 1), ecol, 1.0, win=w)
    _ = side
    # face
    w = cv.win(sd < 1)
    s = sd[w]
    Xw, Yw = X[w], Y[w]
    txw = np.clip((Xw - left) / (right - left), 0, 1)
    ty = np.clip((Yw - top) / (bot - top), 0, 1)
    base = _rainbow(txw, 1)
    lite = _rainbow(txw, 0)
    dark = _rainbow(txw, 2)
    line = _rainbow(txw, 3)
    col = mix(base, lite, smoothstep(0.55, 0.0, ty) * 0.85)
    col = mix(col, dark, smoothstep(0.55, 1.0, ty) * 0.7)
    # bevel
    d = np.maximum(-(s + 3.5), 0)
    t = np.clip(d / 9.0, 0, 1)
    h = 1 - (1 - t) ** 2
    gy, gx = np.gradient(h)
    k = 9.0 * ss
    nx, ny = -gx * k, -gy * k
    nl = np.sqrt(nx * nx + ny * ny + 1)
    nx, ny, nz = nx / nl, ny / nl, 1 / nl
    lam = nx * LIGHT[0] + ny * LIGHT[1] + nz * LIGHT[2] - LIGHT[2]
    col = mix(col, mix(lite, WHITE, 0.5), np.clip(lam * 2.4, 0, 1) * 0.8)
    col = mix(col, dark, np.clip(-lam * 1.8, 0, 1) * 0.5)
    rr = np.clip(nx * 0.4 + ny * 0.9, 0, 1) * (1 - t) ** 1.5
    col = mix(col, lite, np.clip(rr * 2, 0, 1) * 0.5)
    col = mix(line, col, np.clip(0.5 - (s + 3.5) * ss, 0, 1))
    cv.paint(np.clip(0.5 - s * ss, 0, 1), col, 1.0, win=w)
    # glossy band across the upper half of the letters
    band = np.maximum(sd + 8, Y - (top + (bot - top) * 0.40))
    wb = cv.win(band < 1)
    fade = smoothstep(top + (bot - top) * 0.42, top + 4, Y[wb])
    cv.paint(np.clip(0.5 - band[wb] * ss, 0, 1) * (0.25 + 0.75 * fade), WHITE, 0.45, win=wb)
    # sparkles
    for (x, y, r, c) in ((96, 62, 20, "#FFFFFF"), (560, 238, 15, "#FFFFFF"), (486, 52, 11, "#FFFFFF"),
                         (170, 250, 9, "#FFFFFF")):
        sparkle4(cv, x, y, r, C(c), glow=6, glow_color="#FFF3A6")
    cv.shadow_under(0, 6, 6, "#7B4FFF", 0.3)
    return cv
