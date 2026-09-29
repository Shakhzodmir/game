"""GLOW wordmark (640x320): neon glow + stage-light gradient, Rubik Black."""
import math
import os

import numpy as np

from artkit import (C, Canvas, INK, WHITE, gblur, ramp, sd_ellipse, sd_poly, sdf_from_mask, smoothstep, text_mask,
                    U, opening, sd_star, shift, vol)

FONT = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "fonts", "Rubik-Black.ttf")


def _beam(cv, x0, y0, x1, y1, w0, w1, color, alpha):
    X, Y = cv.X, cv.Y
    dx, dy = x1 - x0, y1 - y0
    L = math.hypot(dx, dy)
    ux, uy = dx / L, dy / L
    px, py = X - x0, Y - y0
    along = px * ux + py * uy
    across = np.abs(-px * uy + py * ux)
    t = np.clip(along / L, 0, 1)
    half = w0 + (w1 - w0) * t
    v = smoothstep(half, half * 0.35, across) * (along > 0) * (1 - t) ** 0.8 * smoothstep(0, 40, along)
    cv.paint(np.clip(v, 0, 1), C(color), alpha, "over")


def draw_logo():
    cv = Canvas(640, 320)
    X, Y = cv.X, cv.Y
    ss = cv.ss
    # stage beams behind the word
    _beam(cv, 40, -30, 330, 330, 8, 120, "#3CF2FF", 0.30)
    _beam(cv, 600, -30, 310, 330, 8, 120, "#FF4FD8", 0.30)
    _beam(cv, 320, -60, 320, 330, 6, 90, "#FFE66D", 0.22)

    mask = text_mask(cv, "GLOW", FONT, 196, 320, 158, tracking=4)
    sd = sdf_from_mask(mask > 0.5, ss)
    ys = np.flatnonzero((mask > 0.5).any(1))
    top, bot = ys[0] / ss, ys[-1] / ss

    # neon glow (magenta core, cyan halo)
    core = np.clip(0.5 - (sd - 8) * ss, 0, 1)
    cv.glow_from(core, 34, "#3CF2FF", 0.55, mode="over", gain=1.2)
    cv.glow_from(core, 16, "#FF4FD8", 0.85, mode="over", gain=1.5)
    # extrusion (depth)
    ext = sdf_from_mask(shift((mask > 0.5).astype(np.float32), 0, 12 * ss) > 0.5, ss)
    cv.fill(np.minimum(ext, sd) - 8, INK)
    cv.fill_grad(ext - 1, [(0, "#8E3DFF"), (1, "#3A1680")], axis="y", p0=top, p1=bot + 12)
    # outline
    cv.fill(sd - 7, INK)
    # face gradient: warm stage light from above
    stops = [(0.0, "#FFFBE0"), (0.28, "#FFE66D"), (0.62, "#FF8E72"), (1.0, "#FF4FD8")]
    cv.fill_grad(sd, stops, axis="y", p0=top, p1=bot)
    # bevel: light rim on top-left edges, inner shade low
    w = cv.win(sd < 1)
    s = sd[w]
    gy, gx = np.gradient(s)
    nrm = np.hypot(gx, gy) + 1e-6
    up = np.clip((-gx * 0.5 - gy * 0.86) / nrm, 0, 1)
    dn = np.clip((gx * 0.3 + gy * 0.95) / nrm, 0, 1)
    edge = smoothstep(-6, -0.5, s) * (s < 0)
    cv.paint(edge * up, WHITE, 0.75, "over", w)
    cv.paint(edge * dn, C("#B0169A"), 0.45, "over", w)
    # glossy band across the upper half
    band = np.maximum(sd + 5, Y - (top + (bot - top) * 0.42))
    wb = cv.win(band < 1)
    fade = smoothstep(top + (bot - top) * 0.45, top, Y[wb])
    cv.paint(np.clip(0.5 - band[wb] * ss, 0, 1) * (0.35 + 0.65 * fade), WHITE, 0.35, win=wb)
    # sparkles
    for (x, y, r) in ((92, 64, 18), (566, 250, 14), (470, 58, 10), (180, 262, 9)):
        d = opening(sd_star(X, Y, x, y, r, r * 0.3, n=4, rot=-math.pi / 2), 0.5)
        cv.glow_from(np.clip(0.5 - d * ss, 0, 1), 6, "#FFFFFF", 0.6, mode="over")
        cv.fill(d, WHITE, 1.0)
    return cv
