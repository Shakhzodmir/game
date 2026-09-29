"""Board tiles, FX particles, UI chrome (buttons, panels, ribbon) and 96px icons."""
import math

import numpy as np

from artkit import (C, Canvas, F32, INK, WHITE, bez, darken, droplet, gblur, inset, lighten, mix, opening,
                    closing, sd_arc, sd_box, sd_capsule, sd_circle, sd_ellipse, sd_poly, sd_polyline, sd_rect,
                    sd_ring, sd_star, sd_taper, smoothstep, SU, SUB, U, I, vol)
from pieces import note_sdf, PALETTE


# ==========================================================================
# board
# ==========================================================================
def draw_cell(color):
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    full = sd_rect(X, Y, -2, -2, 98, 98, 0)
    cv.fill(full, color, 0.85)
    # subtle rounded inner edge: soft inner shadow top-left, faint light bottom-right
    inner = sd_rect(X, Y, 3, 3, 93, 93, 14)
    w = cv.win(full < 1)
    s = inner[w]
    gy, gx = np.gradient(s)
    nrm = np.hypot(gx, gy) + 1e-6
    tl = np.clip((gx * -0.6 + gy * -0.8) / nrm, 0, 1)
    br = np.clip((gx * 0.6 + gy * 0.8) / nrm, 0, 1)
    edge = smoothstep(-6, 1.5, s)
    cv.paint(edge * (0.3 + 0.7 * tl), C("#0B0D22"), 0.35, "atop", w)
    cv.paint(smoothstep(-2.5, 0.5, s) * smoothstep(2.5, 0.0, s) * br, C("#8C92FF"), 0.18, "atop", w)
    return cv


def draw_board_frame():
    """96x96 nine-slice, 24px borders. Stroke outer edge at 10px, 3px wide."""
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    o, r = 10.0, 12.0
    frame = sd_rect(X, Y, o + 1.5, o + 1.5, 96 - o - 1.5, 96 - o - 1.5, r)
    ring = np.abs(frame) - 1.5
    cov = np.clip(0.5 - ring * cv.ss, 0, 1)
    # outer glow #FFB36B 25% (only outside the stroke)
    outside = smoothstep(-1.0, 0.5, frame)
    g = gblur(cov, 5 * cv.ss / 2)
    cv.paint(np.clip(g * 2.2, 0, 1) * outside, C("#FFB36B"), 0.25)
    halo = smoothstep(o + 1, 0, frame) * (frame > 0)
    cv.paint(halo, C("#FFB36B"), 0.25)
    # thin warm inner glow
    inner = smoothstep(-5, 0, frame) * (frame < 0)
    cv.paint(inner, C("#FFB36B"), 0.18)
    cv.paint(cov, C("#F4E3C3"), 1.0)
    return cv


# ==========================================================================
# fx (white / near white, tinted by the engine)
# ==========================================================================
def fx_spark():
    cv = Canvas(32, 32)
    X, Y = cv.X, cv.Y
    d = U(sd_ellipse(X, Y, 16, 16, 15, 2.6), sd_ellipse(X, Y, 16, 16, 2.6, 15))
    r = np.hypot(X - 16, Y - 16)
    cv.paint(np.clip(1 - r / 16, 0, 1) ** 2, WHITE, 0.6)
    cv.fill(d, WHITE, 1.0, soft=0.8)
    cv.fill(sd_circle(X, Y, 16, 16, 3.5), WHITE, 1, soft=1)
    return cv


def fx_glow_dot():
    cv = Canvas(64, 64)
    r = np.hypot(cv.X - 32, cv.Y - 32) / 32
    cv.paint(np.exp(-(r * 1.9) ** 2) * smoothstep(1.0, 0.8, r), WHITE, 1.0)
    return cv


def fx_ring():
    cv = Canvas(128, 128)
    d = sd_ring(cv.X, cv.Y, 64, 64, 58, 4)
    cv.fill(d, WHITE, 1.0, soft=1.2)
    return cv


def fx_shock():
    cv = Canvas(256, 256)
    r = np.hypot(cv.X - 128, cv.Y - 128)
    v = np.exp(-((r - 110) / 10) ** 2) + 0.45 * np.exp(-((r - 96) / 26) ** 2) * (r < 110)
    v *= smoothstep(127, 118, r)
    cv.paint(np.clip(v, 0, 1), WHITE, 1.0)
    return cv


def fx_bolt():
    cv = Canvas(256, 48)
    X, Y = cv.X, cv.Y
    along = smoothstep(0, 26, X) * smoothstep(256, 230, X)
    dy = np.abs(Y - 24)
    glow = np.exp(-(dy / 9) ** 2) * along
    core = np.exp(-(dy / 2.6) ** 2) * along
    cv.paint(np.clip(glow, 0, 1), C("#7DF9FF"), 0.9)
    cv.paint(np.clip(core * 1.3, 0, 1), WHITE, 1.0)
    return cv


def fx_ray():
    cv = Canvas(256, 16)
    X, Y = cv.X, cv.Y
    along = smoothstep(0, 14, X) * smoothstep(256, 200, X)
    v = np.exp(-((Y - 8) / 3.4) ** 2) * along
    cv.paint(np.clip(v * 1.2, 0, 1), WHITE, 1.0)
    return cv


def fx_flash():
    cv = Canvas(256, 256)
    r = np.hypot(cv.X - 128, cv.Y - 128) / 128
    v = np.clip(1 - r, 0, 1) ** 1.8
    cv.paint(v, WHITE, 1.0)
    return cv


def fx_note():
    cv = Canvas(48, 48)
    s = 0.3
    d = note_sdf(cv.X, cv.Y, 24 - 80 * s + 1, 24 - 76 * s, s)
    cv.fill(d, WHITE, 1.0)
    return cv


def fx_confetti():
    cv = Canvas(16, 24)
    X, Y = cv.X, cv.Y
    d = sd_rect(X, Y, 2, 2, 14, 22, 2)
    col = mix(C("#FFFFFF"), C("#D9D9E6"), smoothstep(8, 16, X)[..., None] * 0.9)
    w = cv.win(d < 1)
    cv.paint(np.clip(0.5 - d[w] * cv.ss, 0, 1), col[w], 1.0, win=w)
    return cv


def fx_dust():
    cv = Canvas(64, 64)
    X, Y = cv.X, cv.Y
    v = np.zeros_like(X)
    for (x, y, r, a) in ((32, 36, 22, 1.0), (18, 34, 15, 0.85), (46, 32, 16, 0.85), (30, 20, 14, 0.75),
                         (46, 46, 12, 0.7), (16, 46, 11, 0.7)):
        v = np.maximum(v, a * smoothstep(r, r * 0.1, np.hypot(X - x, Y - y)))
    v *= smoothstep(32, 22, np.hypot(X - 32, Y - 32))
    cv.paint(np.clip(v, 0, 1), C("#FFFFFF"), 0.9)
    return cv


def fx_star():
    cv = Canvas(48, 48)
    X, Y = cv.X, cv.Y
    d = opening(sd_star(X, Y, 24, 25.5, 17, 7.5), 1.5, cv.ss)
    g = gblur(np.clip(0.5 - d * cv.ss, 0, 1), 4 * cv.ss / 2)
    cv.paint(np.clip(g * 1.2, 0, 1), WHITE, 0.6)
    cv.fill(d, WHITE, 1.0)
    return cv


FX_FUNCS = {"spark": fx_spark, "glow_dot": fx_glow_dot, "ring": fx_ring, "shock": fx_shock, "bolt": fx_bolt,
            "ray": fx_ray, "flash": fx_flash, "note": fx_note, "confetti": fx_confetti, "dust": fx_dust,
            "star_particle": fx_star}


# ==========================================================================
# UI chrome
# ==========================================================================
BUTTONS = {
    "green": ("#3BE37F", "#1FAF5A", "#0E6B35"),
    "blue": ("#3D8BFF", "#2463D1", "#173E8C"),
    "gold": ("#FFC83D", "#F29E0C", "#9C5A00"),
    "red": ("#FF4D6D", "#D92B4B", "#8C1028"),
}


def draw_button(kind):
    top, bot, line = BUTTONS[kind]
    cv = Canvas(128, 128)
    X, Y = cv.X, cv.Y
    outer = sd_rect(X, Y, 0.5, 0.5, 127.5, 127.5, 28)
    cv.fill(outer, line)
    lip = sd_rect(X, Y, 4.5, 4.5, 123.5, 123.5, 24)
    cv.fill(lip, darken(bot, 0.28))
    face = sd_rect(X, Y, 4.5, 4.5, 123.5, 115.5, 24)
    cv.fill_grad(face, [(0, lighten(top, 0.12)), (0.5, top), (1, bot)], axis="y", p0=6, p1=114)
    # bevel light on the upper rim, soft shade low
    rim = np.maximum(np.abs(face + 1.5) - 1.5, Y - 40)
    cv.fill(rim, WHITE, 0.35, soft=0.8)
    # glossy top
    gl = sd_rect(X, Y, 12, 9, 116, 52, 18)
    w = cv.win(gl < 1)
    fade = smoothstep(56, 10, Y[w])
    cv.paint(np.clip(0.5 - gl[w] * cv.ss, 0, 1) * fade, WHITE, 0.42, win=w)
    # tiny sparkle dots in the corner gloss
    cv.fill(sd_ellipse(X, Y, 24, 20, 6, 3.4, ang=-0.5), WHITE, 0.75, soft=0.6)
    return cv


def draw_panel():
    cv = Canvas(128, 128)
    X, Y = cv.X, cv.Y
    body = sd_rect(X, Y, 6, 5, 122, 119, 24)
    cv.fill_grad(body, [(0, "#FFFBF2"), (0.7, "#FFF6E5"), (1, "#F6E6C8")], axis="y", p0=5, p1=119)
    cv.stroke(body + 1.5, 3.0, "#E9D2A6", 1.0)
    cv.fill(np.maximum(np.abs(body + 4) - 1.2, Y - 30), WHITE, 0.7, soft=0.6)
    cv.shadow_under(0, 3, 3.0, "#1A1033", 0.3)
    return cv


def draw_panel_dark():
    cv = Canvas(128, 128)
    X, Y = cv.X, cv.Y
    body = sd_rect(X, Y, 4, 4, 124, 124, 24)
    cv.fill_grad(body, [(0, "#2A2660"), (0.35, "#1E1B4B"), (1, "#171442")], axis="y", p0=4, p1=124, alpha=0.9)
    cv.stroke(body + 1.5, 2.5, "#4A43A0", 0.9)
    cv.fill(np.maximum(np.abs(body + 4.5) - 1.0, Y - 28), "#8C84FF", 0.35, soft=0.6)
    return cv


def draw_ribbon():
    cv = Canvas(320, 80)
    X, Y = cv.X, cv.Y
    band_c, tail_c, fold_c, line = "#7B4FA3", "#5E3585", "#3E2160", "#2B1545"
    # tails (behind), with V notches
    for sgn in (-1, 1):
        xo = 160 + sgn * 160
        xi = 160 + sgn * 104
        pts = [(xi, 22), (xo - sgn * 2, 22), (xo - sgn * 18, 46), (xo - sgn * 2, 70), (xi, 70)]
        tail = opening(sd_poly(X, Y, pts), 2, cv.ss)
        vol(cv, tail, tail_c, light="#8E62BA", dark="#3A1D5A", line=line, lw=3, depth=8, spec=0.2, grad=0.4)
        fold = sd_poly(X, Y, [(160 + sgn * 126, 58), (160 + sgn * 126, 70), (160 + sgn * 104, 58)])
        cv.fill(fold, fold_c)
        cv.stroke(fold, 2.2, line)
    band = sd_rect(X, Y, 34, 8, 286, 58, 8)
    vol(cv, band, band_c, light="#B48BDB", dark="#4A2670", line=line, lw=3, depth=12, spec=0.3, grad=0.4,
        grad_dir=(0.0, 1.0))
    gl = I(sd_rect(X, Y, 40, 12, 280, 30, 6), band + 3)
    w = cv.win(gl < 1)
    cv.paint(np.clip(0.5 - gl[w] * cv.ss, 0, 1) * smoothstep(34, 12, Y[w]), WHITE, 0.35, win=w)
    # stitched edges
    for yy in (15, 51):
        dash = np.maximum(np.abs(Y - yy) - 0.8, np.abs((X % 10) - 5) - 2.6)
        cv.fill(np.maximum(dash, band + 6), "#C9A8EA", 0.5)
    cv.shadow_under(0, 3, 1.5, "#000000", 0.25)
    return cv


# ==========================================================================
# icons (96x96)
# ==========================================================================
GLYPH = dict(base="#FFFFFF", light="#FFFFFF", dark="#C7BFEA", line=INK)
GOLD = ("#FFC83D", "#FFF0B0", "#B86E00", "#7A4300")


def glyph(cv, d, lw=3.0, depth=None, **kw):
    vol(cv, d, GLYPH["base"], light=GLYPH["light"], dark=GLYPH["dark"], line=GLYPH["line"], lw=lw,
        depth=depth, spec=0.0, grad=0.7, lift=0.4, shade=0.6, **kw)


def obj(cv, d, base, light=None, dark=None, line=None, lw=3.0, depth=None, spec=0.45, **kw):
    dark = dark if dark is not None else darken(base, 0.45)
    line = line if line is not None else darken(dark, 0.35)
    vol(cv, d, base, light=light, dark=dark, line=line, lw=lw, depth=depth, spec=spec, **kw)


def finish(cv, alpha=0.25):
    cv.shadow_under(0, 2, 0.8, "#000000", alpha)
    return cv


def hl(cv, pts, r0, r1, clip, alpha=0.7):
    droplet(cv, bez(*pts, n=12), np.linspace(r0, r1, 13), alpha=alpha, clip_sdf=clip)


def heart_sdf(X, Y, cx, cy, s):
    pts = []
    for k in range(120):
        t = 2 * math.pi * k / 120
        x = 16 * math.sin(t) ** 3
        y = -(13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t))
        pts.append((cx + x * s, cy + y * s))
    return sd_poly(X, Y, pts)


def beamed_notes(X, Y, ox, oy, s=1.0):
    h1 = sd_ellipse(X, Y, ox + 22 * s, oy + 66 * s, 13 * s, 10 * s, ang=math.radians(-22))
    h2 = sd_ellipse(X, Y, ox + 60 * s, oy + 58 * s, 13 * s, 10 * s, ang=math.radians(-22))
    s1 = sd_capsule(X, Y, ox + 32 * s, oy + 64 * s, ox + 32 * s, oy + 22 * s, 4.5 * s)
    s2 = sd_capsule(X, Y, ox + 70 * s, oy + 56 * s, ox + 70 * s, oy + 12 * s, 4.5 * s)
    beam = sd_poly(X, Y, [(ox + 27 * s, oy + 16 * s), (ox + 75 * s, oy + 4 * s), (ox + 75 * s, oy + 18 * s),
                          (ox + 27 * s, oy + 30 * s)])
    d = U(SU(h1, s1, 3 * s), SU(h2, s2, 3 * s))
    return opening(U(d, beam), 1.5)


def speaker_sdf(X, Y, ox=0.0):
    box = sd_rect(X, Y, 14 + ox, 36, 32 + ox, 60, 4)
    cone = opening(sd_poly(X, Y, [(26 + ox, 36), (50 + ox, 16), (50 + ox, 80), (26 + ox, 60)]), 3)
    return U(box, cone)


def icon_coin():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    d = sd_circle(X, Y, 48, 48, 40)
    obj(cv, d, GOLD[0], GOLD[1], GOLD[2], GOLD[3], depth=14, spec=0.6)
    inner = sd_circle(X, Y, 48, 48, 29)
    inset(cv, inner, "#FFB521", depth=5, shadow=0.5, hl=0.5, dark="#C27400", light="#FFF0B0")
    n = note_sdf(X, Y, 48 - 80 * 0.36 + 2, 48 - 76 * 0.36 - 2, 0.36)
    obj(cv, n, "#FFE27A", "#FFF8D6", "#C27400", "#8A4E00", lw=2.0, depth=5, spec=0.5)
    hl(cv, ((16, 50), (16, 26), (36, 14)), 5, 1.8, d + 5)
    return finish(cv)


def _star_shape(X, Y):
    return opening(sd_star(X, Y, 48, 52, 47, 22), 6, 4)


def icon_star():
    cv = Canvas(96, 96)
    d = _star_shape(cv.X, cv.Y)
    obj(cv, d, "#FFD23F", "#FFF4B0", "#E08A00", "#8A4E00", depth=20, spec=0.6)
    hl(cv, ((30, 44), (34, 32), (44, 26)), 4.5, 1.6, d + 5)
    return finish(cv)


def icon_star_empty():
    cv = Canvas(96, 96)
    d = _star_shape(cv.X, cv.Y)
    inset(cv, d, "#1E1B4B", depth=8, shadow=0.6, hl=0.4, dark="#0C0A24", light="#4E47A0", alpha=0.75)
    cv.stroke(d + 1.4, 2.8, "#6B63B5", 1.0)
    return cv


def icon_heart():
    cv = Canvas(96, 96)
    d = opening(heart_sdf(cv.X, cv.Y, 48, 50, 2.55), 2)
    obj(cv, d, "#FF4D6D", "#FFA3B5", "#C0183A", "#7A0A22", depth=22, spec=0.6)
    hl(cv, ((20, 44), (20, 26), (36, 18)), 5.5, 2.0, d + 5)
    return finish(cv)


def icon_heart_infinite():
    cv = icon_heart_base()
    X, Y = cv.X, cv.Y
    pts = []
    for k in range(97):
        t = 2 * math.pi * k / 96
        den = 1 + math.sin(t) ** 2
        pts.append((48 + 25 * math.cos(t) / den, 52 + 25 * math.sin(t) * math.cos(t) / den))
    d = sd_polyline(X, Y, pts) - 4.2
    cv.fill(d - 2.2, "#7A0A22", 1)
    glyph(cv, d, lw=0.0, depth=3)
    return finish(cv)


def icon_heart_base():
    cv = Canvas(96, 96)
    d = opening(heart_sdf(cv.X, cv.Y, 48, 50, 2.55), 2)
    obj(cv, d, "#FF4D6D", "#FFA3B5", "#C0183A", "#7A0A22", depth=22, spec=0.6)
    hl(cv, ((20, 40), (20, 26), (34, 18)), 4.5, 1.6, d + 5)
    return cv


def icon_pause():
    cv = Canvas(96, 96)
    d = U(sd_rect(cv.X, cv.Y, 22, 16, 42, 80, 8), sd_rect(cv.X, cv.Y, 54, 16, 74, 80, 8))
    glyph(cv, d, depth=8)
    return finish(cv)


def icon_settings():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    d = sd_circle(X, Y, 48, 48, 28)
    for k in range(8):
        a = k * math.pi / 4
        d = SU(d, sd_box(X, Y, 48 + 32 * math.cos(a), 48 + 32 * math.sin(a), 9, 8, 3, ang=a), 3)
    d = SUB(d, sd_circle(X, Y, 48, 48, 11))
    glyph(cv, d, depth=9)
    return finish(cv)


def icon_close():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    d = U(sd_capsule(X, Y, 24, 24, 72, 72, 11), sd_capsule(X, Y, 72, 24, 24, 72, 11))
    glyph(cv, d, depth=8)
    return finish(cv)


def icon_check():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    d = sd_polyline(X, Y, [(18, 50), (38, 70), (78, 26)]) - 11
    obj(cv, d, "#3BE37F", "#B8FFD3", "#1FAF5A", "#0E6B35", depth=8, spec=0.5)
    return finish(cv)


def icon_lock():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    sh = U(sd_arc(X, Y, 48, 38, 19, math.pi, 2 * math.pi, 10), sd_capsule(X, Y, 29, 38, 29, 52, 5),
           sd_capsule(X, Y, 67, 38, 67, 52, 5))
    obj(cv, sh, "#D5DAE6", "#FFFFFF", "#7C8399", "#2F3448", depth=5, spec=0.7)
    body = sd_rect(X, Y, 16, 44, 80, 88, 12)
    obj(cv, body, GOLD[0], GOLD[1], GOLD[2], GOLD[3], depth=12, spec=0.6)
    kh = U(sd_circle(X, Y, 48, 61, 7), sd_poly(X, Y, [(44, 63), (52, 63), (55, 78), (41, 78)]))
    inset(cv, kh, "#5A3100", depth=3, shadow=0.6)
    hl(cv, ((22, 70), (22, 54), (32, 49)), 3.5, 1.4, body + 4)
    return finish(cv)


def icon_shop():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    handle = U(sd_arc(X, Y, 36, 36, 12, math.pi, 2 * math.pi, 6), sd_arc(X, Y, 60, 36, 12, math.pi, 2 * math.pi, 6))
    obj(cv, handle, "#FFC83D", "#FFF0B0", "#B86E00", "#7A4300", depth=3, spec=0.6)
    bag = opening(sd_poly(X, Y, [(18, 34), (78, 34), (84, 88), (12, 88)]), 7)
    obj(cv, bag, "#FF4FD8", "#FFB3F0", "#B0169A", "#6A0A5C", depth=16, spec=0.4)
    band = I(sd_rect(X, Y, 10, 34, 86, 46, 0), bag + 3)
    cv.fill(band, "#FF8AE6", 0.8)
    st = opening(sd_star(X, Y, 48, 66, 16, 7.5), 1.5)
    obj(cv, st, "#FFE66D", "#FFFBD8", "#D98A00", "#7A4300", lw=2.0, depth=5, spec=0.5)
    hl(cv, ((20, 72), (20, 52), (28, 42)), 3.5, 1.2, bag + 4)
    return finish(cv)


def icon_city():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    bl = [((10, 40, 36, 88), "#5A4FCF"), ((56, 48, 86, 88), "#8E3DFF"), ((30, 14, 64, 88), "#3D8BFF")]
    for (x0, y0, x1, y1), col in bl:
        d = sd_rect(X, Y, x0, y0, x1, y1, 5)
        obj(cv, d, col, depth=8, spec=0.3, line=INK)
        for wy in range(int(y0) + 9, int(y1) - 8, 11):
            for wx in np.arange(x0 + 7, x1 - 6, 9.0):
                wd = sd_rect(X, Y, wx, wy, wx + 5, wy + 6, 1.2)
                lit = ((int(wx) * 7 + wy * 3) % 5) != 0
                cv.fill(wd, "#FFE66D" if lit else darken(col, 0.4), 1)
    cv.fill(sd_rect(X, Y, 6, 84, 90, 90, 3), INK)
    flag = sd_poly(X, Y, [(47, 2), (60, 6), (47, 11)])
    cv.fill(sd_capsule(X, Y, 47, 3, 47, 15, 1.4), INK)
    obj(cv, flag, "#FF4FD8", lw=1.5, depth=2)
    return finish(cv)


def icon_jukebox():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    body = U(sd_rect(X, Y, 18, 36, 78, 90, 8), sd_circle(X, Y, 48, 38, 30))
    body = I(body, Y - 90.5)
    obj(cv, body, "#FF4D6D", "#FFA3B5", "#B0183A", "#5A0A1E", depth=14, spec=0.4)
    arch = sd_arc(X, Y, 48, 40, 22, math.pi * 1.0, math.pi * 2.0, 6)
    t = np.clip((np.arctan2(Y - 40, X - 48) + math.pi) / math.pi, 0, 1)
    from artkit import ramp
    rb = ramp(t, [(0, "#FFE66D"), (0.33, "#3CF2FF"), (0.66, "#FF4FD8"), (1, "#FFE66D")])
    w = cv.win(arch < 1)
    cv.paint(np.clip(0.5 - arch[w] * cv.ss, 0, 1), rb[w], 1, win=w)
    cv.stroke(arch, 1.2, "#5A0A1E", 0.8)
    win = sd_circle(X, Y, 48, 42, 13)
    inset(cv, win, "#2B2345", depth=4, shadow=0.6, light="#6A5E9A")
    cv.fill(sd_ring(X, Y, 48, 42, 8, 1.2), "#6A5E9A", 0.9)
    cv.fill(sd_circle(X, Y, 48, 42, 3.2), "#FFE66D")
    gr = sd_rect(X, Y, 28, 60, 68, 82, 5)
    inset(cv, gr, "#5A0A1E", depth=3, shadow=0.5)
    slats = np.maximum(np.abs(((X - 28) % 6.0) - 3) - 1.1, gr + 2)
    cv.fill(slats, "#FFB02E", 0.9)
    hl(cv, ((24, 56), (22, 34), (36, 16)), 4, 1.4, body + 4)
    return finish(cv)


def icon_team():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    for (cx, s, col) in ((24, 0.8, "#8E3DFF"), (72, 0.8, "#22D98A"), (48, 1.0, "#3D8BFF")):
        by = 88
        body = I(sd_ellipse(X, Y, cx, by, 22 * s, 26 * s), Y - by)
        head = sd_circle(X, Y, cx, by - 36 * s, 13.5 * s)
        obj(cv, body, col, depth=10 * s, spec=0.3, line=INK)
        obj(cv, head, "#FFD9B8", "#FFF3E8", "#D99A70", INK, depth=8 * s, spec=0.4)
    return finish(cv)


def icon_chart():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    for (x0, y0, col) in ((12, 58, "#FF4FD8"), (36, 40, "#FFC83D"), (60, 22, "#3CF2FF")):
        d = sd_rect(X, Y, x0, y0, x0 + 22, 86, 5)
        obj(cv, d, col, depth=8, spec=0.4, line=INK)
    st = opening(sd_star(X, Y, 71, 12, 11, 5), 1)
    obj(cv, st, "#FFE66D", lw=2, depth=4, line=INK)
    cv.fill(sd_rect(X, Y, 6, 84, 90, 90, 3), INK)
    return finish(cv)


def icon_play():
    cv = Canvas(96, 96)
    d = opening(sd_poly(cv.X, cv.Y, [(26, 14), (82, 48), (26, 82)]), 8)
    glyph(cv, d, depth=10)
    return finish(cv)


def icon_retry():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    a0, a1 = math.radians(-50), math.radians(215)
    arc = sd_arc(X, Y, 48, 52, 26, a0, a1, 12)
    ex, ey = 48 + 26 * math.cos(a0), 52 + 26 * math.sin(a0)
    head = opening(sd_poly(X, Y, [(ex - 20, ey - 8), (ex + 14, ey - 14), (ex + 6, ey + 20)]), 2)
    glyph(cv, U(arc, head), depth=7)
    return finish(cv)


def icon_home():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    roof = opening(sd_poly(X, Y, [(48, 10), (90, 48), (6, 48)]), 5)
    body = sd_rect(X, Y, 20, 40, 76, 86, 6)
    chim = sd_rect(X, Y, 64, 16, 76, 38, 3)
    d = U(roof, body, chim)
    glyph(cv, d, depth=8)
    door = sd_rect(X, Y, 40, 58, 56, 86, 5)
    inset(cv, door, "#8E86C9", depth=3, shadow=0.5, alpha=0.9)
    return finish(cv)


def icon_music(on=True):
    cv = Canvas(96, 96)
    d = beamed_notes(cv.X, cv.Y, 6, 10, 1.0)
    glyph(cv, d, depth=7)
    if not on:
        _slash(cv)
    return finish(cv)


def _slash(cv):
    X, Y = cv.X, cv.Y
    sl = sd_capsule(X, Y, 16, 16, 80, 80, 6)
    cv.fill(sl - 3, INK)
    obj(cv, sl, "#FF4D6D", "#FFA3B5", "#C0183A", "#7A0A22", lw=0, depth=4, spec=0.4)


def icon_sound(on=True):
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    d = speaker_sdf(X, Y, 2)
    if on:
        for r, w in ((17, 9.5), (32, 9.5)):
            d = U(d, sd_arc(X, Y, 54, 48, r, math.radians(-50), math.radians(50), w))
        glyph(cv, d, depth=7)
    else:
        glyph(cv, d, depth=7)
        x = U(sd_capsule(X, Y, 62, 36, 84, 60, 5), sd_capsule(X, Y, 84, 36, 62, 60, 5))
        cv.fill(x - 3, INK)
        obj(cv, x, "#FF4D6D", "#FFA3B5", "#C0183A", "#7A0A22", lw=0, depth=4, spec=0.4)
    return finish(cv)


def icon_haptics():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    phone = sd_rect(X, Y, 30, 12, 66, 84, 9)
    glyph(cv, phone, depth=8)
    inset(cv, sd_rect(X, Y, 36, 22, 60, 70, 3), "#3D8BFF", depth=3, shadow=0.4)
    cv.fill(sd_circle(X, Y, 48, 77, 3), "#C7BFEA")
    for sgn in (-1, 1):
        zz = [(48 + sgn * 26, 28 + k * 10) if k % 2 == 0 else (48 + sgn * 33, 28 + k * 10) for k in range(5)]
        z = sd_polyline(X, Y, zz) - 3.2
        glyph(cv, z, lw=2.2, depth=2)
    return finish(cv)


def icon_hand():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    cuff = sd_rect(X, Y, 34, 76, 72, 94, 5)
    palm = sd_rect(X, Y, 32, 42, 74, 80, 12)
    index = sd_capsule(X, Y, 42, 50, 42, 10, 8)
    thumb = sd_capsule(X, Y, 34, 62, 22, 50, 7)
    fingers = [sd_capsule(X, Y, 50 + 9 * k, 46, 50 + 9 * k, 56, 6.5) for k in range(3)]
    hand = U(SU(palm, index, 4), SU(palm, thumb, 4), *fingers)
    lay = cv.blank()
    vol(lay, cuff, "#3D8BFF", light="#A6D4FF", dark="#173E8C", line=INK, lw=3, depth=6, spec=0.4)
    vol(lay, hand, "#FFFFFF", light="#FFFFFF", dark="#CFC6EE", line=INK, lw=3, depth=12, spec=0.2, grad=0.6)
    for k in range(3):
        lay.stroke(np.maximum(sd_capsule(X, Y, 45.5 + 9 * k, 50, 45.5 + 9 * k, 60, 0.1), hand + 3), 2.2, INK, 0.9)
    droplet(lay, bez((38, 40), (38, 26), (40, 16), n=8), np.linspace(2.8, 1.2, 9), alpha=0.8, clip_sdf=index + 4)
    rot = lay.transformed(-24, pivot=(48, 52), sx=0.92, sy=0.92, dx=4, dy=-2)
    cv.over(rot)
    return finish(cv)


def icon_stick():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    burst = opening(sd_star(X, Y, 74, 24, 18, 9, n=8), 1)
    obj(cv, burst, "#FFE66D", "#FFFBD8", "#E0A000", INK, lw=2.2, depth=5)
    st = sd_taper(X, Y, 12, 86, 62, 34, 10, 5.5)
    obj(cv, st, "#E8B36A", "#FFE2B0", "#A8672A", "#5A3010", depth=8, spec=0.5)
    tip = sd_ellipse(X, Y, 66, 30, 9, 7, ang=-0.8)
    obj(cv, tip, "#F4CD8E", "#FFF4E0", "#A8672A", "#5A3010", lw=2.6, depth=5, spec=0.6)
    grip = I(st, sd_capsule(X, Y, 12, 86, 28, 69, 13))
    obj(cv, grip, "#FF4D6D", "#FFA3B5", "#C0183A", "#7A0A22", lw=0, depth=5, spec=0.4)
    for t in (0.3, 0.55):
        gx, gy = 12 + (28 - 12) * t, 86 + (69 - 86) * t
        cv.fill(np.maximum(sd_capsule(X, Y, gx - 8, gy - 8, gx + 8, gy + 8, 0.8), grip + 1.5), "#7A0A22", 0.7)
    hl(cv, ((22, 70), (36, 56), (52, 40)), 2.6, 1.2, st + 3.5, alpha=0.6)
    return finish(cv)


def _spotlight(cv, vertical):
    X, Y = cv.X, cv.Y
    lay = cv.blank()
    beam = sd_ellipse(X, Y, 48, 48, 46, 17)
    lay.fill(beam, "#FFF3A8", 0.55, soft=9)
    for sgn in (-1, 1):
        head = opening(sd_poly(X, Y, [(48 + sgn * 46, 48), (48 + sgn * 30, 30), (48 + sgn * 30, 66)]), 2)
        shaft = sd_rect(X, Y, min(48, 48 + sgn * 34), 42, max(48, 48 + sgn * 34), 54, 3)
        vol(lay, U(head, shaft), "#FFE66D", light="#FFFBD8", dark="#D98A00", line=INK, lw=2.6, depth=5, spec=0.5)
    body = sd_circle(X, Y, 48, 48, 20)
    vol(lay, body, "#3A3560", light="#7A72B8", dark="#18142E", line=INK, lw=3, depth=8, spec=0.5)
    lens = sd_circle(X, Y, 48, 48, 12)
    vol(lay, lens, "#FFF6C0", light="#FFFFFF", dark="#FFC83D", line="#8A5A00", lw=1.6, depth=7, spec=0.8)
    if vertical:
        lay = lay.transformed(90, pivot=(48, 48))
    cv.over(lay)


def icon_row_light():
    cv = Canvas(96, 96)
    _spotlight(cv, False)
    return finish(cv)


def icon_col_light():
    cv = Canvas(96, 96)
    _spotlight(cv, True)
    return finish(cv)


def _arrow_stroke(pts, w, head):
    return pts, w, head


def icon_remix():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    for (p, col) in ((bez((10, 74), (46, 74), (46, 24), (74, 24), n=20), "#3CF2FF"),
                     (bez((10, 24), (46, 24), (46, 74), (74, 74), n=20), "#FF4FD8")):
        ex, ey = p[-1]
        stroke = sd_polyline(X, Y, p[:-2]) - 6
        head = opening(sd_poly(X, Y, [(ex - 12, ey - 15), (ex + 16, ey), (ex - 12, ey + 15)]), 2)
        d = U(stroke, head)
        obj(cv, d, col, lw=2.8, depth=5, spec=0.5, line=INK)
    return finish(cv)


def icon_plus():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    c = sd_circle(X, Y, 48, 48, 40)
    obj(cv, c, "#3BE37F", "#B8FFD3", "#1FAF5A", "#0E6B35", depth=14, spec=0.5)
    p = U(sd_rect(X, Y, 40, 22, 56, 74, 5), sd_rect(X, Y, 22, 40, 74, 56, 5))
    glyph(cv, p, lw=2.4, depth=5)
    hl(cv, ((16, 46), (18, 28), (32, 16)), 3.6, 1.3, c + 4)
    return finish(cv)


WOOD = ("#C2743E", "#F0A86A", "#6E3614", "#3E1A06")


def _chest_body(cv):
    X, Y = cv.X, cv.Y
    body = sd_rect(X, Y, 10, 46, 86, 88, 7)
    obj(cv, body, WOOD[0], WOOD[1], WOOD[2], WOOD[3], depth=10, spec=0.2)
    for x0 in (20, 68):
        band = I(sd_rect(X, Y, x0, 44, x0 + 8, 90, 1), body + 0.5)
        obj(cv, band, GOLD[0], GOLD[1], GOLD[2], GOLD[3], lw=1.8, depth=3, spec=0.6)
    return body


def icon_chest_closed():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    _chest_body(cv)
    lid = U(sd_rect(X, Y, 10, 26, 86, 50, 6), I(sd_ellipse(X, Y, 48, 30, 38, 18), Y - 30))
    obj(cv, lid, WOOD[0], WOOD[1], WOOD[2], WOOD[3], depth=10, spec=0.3)
    for x0 in (20, 68):
        band = I(sd_rect(X, Y, x0, 8, x0 + 8, 50, 1), lid + 0.5)
        obj(cv, band, GOLD[0], GOLD[1], GOLD[2], GOLD[3], lw=1.8, depth=3, spec=0.6)
    plate = sd_rect(X, Y, 38, 40, 58, 62, 4)
    obj(cv, plate, GOLD[0], GOLD[1], GOLD[2], GOLD[3], lw=2.2, depth=5, spec=0.7)
    inset(cv, U(sd_circle(X, Y, 48, 49, 3.2), sd_rect(X, Y, 46.6, 49, 49.4, 56, 1)), "#5A3100", depth=2)
    hl(cv, ((16, 40), (18, 28), (30, 20)), 3.4, 1.2, lid + 4)
    return finish(cv)


def icon_chest_open():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    # glow + rays
    rays = cv.blank()
    for k in range(7):
        a = math.radians(-90 + (k - 3) * 22)
        rays.fill(sd_poly(X, Y, [(48, 50), (48 + 60 * math.cos(a - 0.12), 50 + 60 * math.sin(a - 0.12)),
                                 (48 + 60 * math.cos(a + 0.12), 50 + 60 * math.sin(a + 0.12))]), "#FFF6C8", 0.5,
                  soft=3)
    rays.paint(smoothstep(50, 10, np.hypot(X - 48, Y - 50)), C("#FFFFFF"), 1.0, "atop")
    cv.over(rays)
    lid = opening(sd_poly(X, Y, [(12, 34), (84, 34), (78, 14), (18, 14)]), 5)
    obj(cv, lid, darken(WOOD[0], 0.25), WOOD[0], WOOD[2], WOOD[3], depth=8, spec=0.2)
    inner = sd_rect(X, Y, 14, 38, 82, 52, 4)
    cv.fill(inner, "#FFE66D", 1)
    cv.glow_from(np.clip(0.5 - inner * cv.ss, 0, 1), 8, "#FFE66D", 0.7, mode="over")
    for (x, y) in ((30, 44), (44, 40), (58, 44), (68, 40), (38, 48)):
        obj(cv, sd_ellipse(X, Y, x, y, 7, 5), GOLD[0], GOLD[1], GOLD[2], GOLD[3], lw=1.6, depth=3, spec=0.7)
    _chest_body(cv)
    plate = sd_rect(X, Y, 38, 46, 58, 62, 4)
    obj(cv, plate, GOLD[0], GOLD[1], GOLD[2], GOLD[3], lw=2.2, depth=5, spec=0.7)
    return finish(cv)


def icon_note(on=True):
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    s = 0.58
    d = note_sdf(X, Y, 48 - 80 * s + 4, 48 - 76 * s + 2, s)
    if on:
        lay = cv.blank()
        for k, (sx, sy) in enumerate(((14, 72), (22, 58), (12, 44))):
            lay.fill(sd_capsule(X, Y, sx, sy, sx + 16, sy - 6, 2.4 - k * 0.4), "#FF4FD8", 0.8)
        obj(lay, d, "#FFE66D", "#FFFBD8", "#E08A00", "#7A4300", depth=10, spec=0.6)
        hl(lay, ((32, 70), (32, 60), (40, 56)), 3.2, 1.2, d + 4)
        lay.glow_under(9, "#FF4FD8", 0.8)
        for (sx, sy, sz) in ((76, 18, 8), (82, 70, 5)):
            spk = U(sd_ellipse(X, Y, sx, sy, sz, sz * 0.18), sd_ellipse(X, Y, sx, sy, sz * 0.18, sz))
            lay.fill(spk, "#FFFFFF", 1, soft=0.5)
        cv.over(lay)
        return cv
    obj(cv, d, "#4A4470", "#6E6898", "#2E2A4E", "#1A1733", depth=10, spec=0.1, lift=0.3)
    return finish(cv, 0.15)


def icon_arrow():
    cv = Canvas(96, 96)
    d = opening(sd_poly(cv.X, cv.Y, [(10, 38), (48, 38), (48, 16), (88, 48), (48, 80), (48, 58), (10, 58)]), 5)
    glyph(cv, d, depth=8)
    return finish(cv)


def icon_gift():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    for sgn in (-1, 1):
        loop = sd_ellipse(X, Y, 48 + sgn * 14, 24, 14, 9, ang=sgn * -0.45)
        loop = SUB(loop, sd_ellipse(X, Y, 48 + sgn * 14, 24, 6, 3, ang=sgn * -0.45))
        obj(cv, loop, GOLD[0], GOLD[1], GOLD[2], GOLD[3], lw=2.4, depth=4, spec=0.6)
    box = sd_rect(X, Y, 16, 46, 80, 88, 5)
    obj(cv, box, "#8E3DFF", "#C9A3FF", "#5A12C4", "#2E0870", depth=10, spec=0.3)
    lid = sd_rect(X, Y, 10, 32, 86, 50, 5)
    obj(cv, lid, "#9E55FF", "#D6B8FF", "#5A12C4", "#2E0870", depth=7, spec=0.4)
    rib = I(sd_rect(X, Y, 41, 30, 55, 90, 0), U(box, lid) + 0.5)
    obj(cv, rib, GOLD[0], GOLD[1], GOLD[2], GOLD[3], lw=2.0, depth=4, spec=0.6)
    obj(cv, sd_circle(X, Y, 48, 30, 6), GOLD[0], GOLD[1], GOLD[2], GOLD[3], lw=2.0, depth=4, spec=0.7)
    return finish(cv)


ICON_FUNCS = {
    "coin": icon_coin, "star": icon_star, "star_empty": icon_star_empty, "heart": icon_heart,
    "heart_infinite": icon_heart_infinite, "pause": icon_pause, "settings": icon_settings,
    "close": icon_close, "check": icon_check, "lock": icon_lock, "shop": icon_shop, "city": icon_city,
    "jukebox": icon_jukebox, "team": icon_team, "chart": icon_chart, "play": icon_play,
    "retry": icon_retry, "home": icon_home, "music_on": lambda: icon_music(True),
    "music_off": lambda: icon_music(False), "sound_on": lambda: icon_sound(True),
    "sound_off": lambda: icon_sound(False), "haptics": icon_haptics, "hand": icon_hand,
    "stick": icon_stick, "row_light": icon_row_light, "col_light": icon_col_light, "remix": icon_remix,
    "plus": icon_plus, "chest_closed": icon_chest_closed, "chest_open": icon_chest_open,
    "note_on": lambda: icon_note(True), "note_off": lambda: icon_note(False), "arrow": icon_arrow,
    "gift": icon_gift,
}
