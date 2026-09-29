"""Board tiles, FX particles, UI chrome (buttons, panels, ribbon, badge, bunting) and 96px icons
in the bright candy style of docs/design/art-direction.md."""
import math

import numpy as np

from artkit import (C, Canvas, F32, WHITE, bez, candy, fit, gblur, gloss_drop, inset, mix, noise2, opening,
                    closing, ramp, rim_gloss, rng, sd_arc, sd_box, sd_capsule, sd_circle, sd_ellipse, sd_poly,
                    sd_polyline, sd_rect, sd_ring, sd_star, sd_taper, smoothstep, soft_shadow, sparkle4, SU, SUB,
                    U, I)
from palette import (PIECES, ORDER, BUTTONS, CELL_A, CELL_B, FRAME_GLOW, FRAME_SHADOW, PANEL_LINE, PINK_BADGE,
                     PIECE_SHADOW)
from pieces import note_sdf

# ==========================================================================
# board
# ==========================================================================
def draw_cell(color, alpha=0.95):
    cv = Canvas(96, 96)
    cv.fill(sd_rect(cv.X, cv.Y, -2, -2, 98, 98, 0), color, alpha)
    return cv


FRAME_INNER = 14      # px from the texture edge to the inside of the white frame line


def draw_board_frame():
    """96x96 nine-slice (24px borders): soft blue shadow, lavender glow ring, 4px white frame,
    white 60 % backing inside."""
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    white_out = sd_rect(X, Y, 10, 10, 86, 86, 18)          # outer edge of the white line
    inner = sd_rect(X, Y, FRAME_INNER, FRAME_INNER, 96 - FRAME_INNER, 96 - FRAME_INNER, 14)
    lav = sd_rect(X, Y, 6, 6, 90, 90, 22)
    # soft shadow (blue) below
    sh = gblur(np.clip(0.5 - (lav - 0.0) * cv.ss, 0, 1), 3.5 * cv.ss)
    from artkit import shift
    sh = shift(sh, 0, 3.5 * cv.ss)
    cv.paint(np.clip(sh, 0, 1), np.array(FRAME_SHADOW, F32), 0.30)
    # lavender glow ring (outside the white line)
    ring = np.maximum(lav, -white_out)
    cv.fill(ring, np.array(FRAME_GLOW, F32), 0.25)
    cv.paint(np.clip(gblur(np.clip(0.5 - lav * cv.ss, 0, 1), 1.5 * cv.ss), 0, 1) * (lav > 0), np.array(FRAME_GLOW, F32),
             0.12)
    # white line + backing
    cv.fill(np.maximum(white_out, -inner), "#FFFFFF", 1.0)
    cv.fill(inner, "#FFFFFF", 0.60)
    # faint inner lavender edge on the backing for depth
    cv.fill(np.maximum(inner, -(inner + 3)), "#E6DAFF", 0.35)
    return cv


# ==========================================================================
# fx (white / near white, tinted by the engine)
# ==========================================================================
def fx_spark():
    cv = Canvas(32, 32)
    X, Y = cv.X, cv.Y
    d = U(sd_ellipse(X, Y, 16, 16, 15, 2.4), sd_ellipse(X, Y, 16, 16, 2.4, 15))
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
    r = np.hypot(cv.X - 64, cv.Y - 64)
    cv.paint(np.exp(-((r - 56) / 6) ** 2) * 0.5, WHITE, 1.0)
    cv.fill(sd_ring(cv.X, cv.Y, 64, 64, 56, 5), WHITE, 1.0, soft=1.0)
    return cv


def fx_shock():
    cv = Canvas(256, 256)
    r = np.hypot(cv.X - 128, cv.Y - 128)
    v = np.exp(-((r - 110) / 9) ** 2) + 0.45 * np.exp(-((r - 94) / 24) ** 2) * (r < 110)
    v *= smoothstep(127, 118, r)
    cv.paint(np.clip(v, 0, 1), WHITE, 1.0)
    return cv


def fx_bolt():
    cv = Canvas(256, 48)
    X, Y = cv.X, cv.Y
    along = smoothstep(0, 26, X) * smoothstep(256, 230, X)
    g = rng(12)
    # slightly jagged core
    pts = [(x, 24 + (g.random() - 0.5) * 9 if 0 < x < 256 else 24) for x in range(0, 257, 16)]
    core_d = sd_polyline(X, Y, pts)
    glow = np.exp(-(np.abs(Y - 24) / 10) ** 2) * along
    core = np.exp(-(core_d / 2.2) ** 2) * along
    cv.paint(np.clip(glow, 0, 1), C("#EFFCFF"), 0.75)
    cv.paint(np.clip(core * 1.4, 0, 1), WHITE, 1.0)
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
    s = 0.27
    d = note_sdf(cv.X, cv.Y, 24 - 84 * s, 24 - 70 * s, s)
    cv.glow_from(np.clip(0.5 - d * cv.ss, 0, 1), 3, "#FFFFFF", 0.5, mode="over")
    cv.fill(d, WHITE, 1.0)
    return cv


def fx_confetti():
    cv = Canvas(16, 24)
    X, Y = cv.X, cv.Y
    d = sd_rect(X, Y, 2, 2, 14, 22, 2.5)
    col = mix(C("#FFFFFF"), C("#E4E4EE"), smoothstep(6, 16, X)[..., None])
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
    d = opening(sd_star(X, Y, 24, 25.5, 18, 8.5), 2.2, cv.ss)
    cv.glow_from(np.clip(0.5 - d * cv.ss, 0, 1), 5, "#FFFFFF", 0.6, mode="over")
    cv.fill(d, WHITE, 1.0)
    return cv


def fx_cloud():
    cv = Canvas(256, 128)
    X, Y = cv.X, cv.Y
    d = cloud_sdf(X, Y, 126, 112, 0.84)
    cv.fill(d, "#FFFFFF", 1.0, soft=2.5)
    # gentle underside tint (still near white) so a tinted cloud keeps volume
    w = cv.win(d < 3)
    under = smoothstep(80, 118, Y[w])
    cv.paint(np.clip(0.5 - (d[w] + 2) * cv.ss, 0, 1) * under, C("#E9EEF8"), 0.9, win=w)
    return cv


def cloud_sdf(X, Y, cx, base_y, s=1.0, seed=0):
    puffs = [(-78, -18, 30), (-40, -40, 40), (6, -52, 48), (52, -34, 38), (86, -16, 28), (-8, -14, 40)]
    d = None
    for (x, y, r) in puffs:
        c = sd_circle(X, Y, cx + x * s, base_y + y * s, r * s)
        d = c if d is None else SU(d, c, 10 * s)
    flat = sd_rect(X, Y, cx - 104 * s, base_y - 30 * s, cx + 112 * s, base_y + 10 * s, 20 * s)
    d = SU(d, flat, 8 * s)
    return np.maximum(d, Y - base_y - 6 * s)


FX_FUNCS = {"spark": fx_spark, "glow_dot": fx_glow_dot, "ring": fx_ring, "shock": fx_shock, "bolt": fx_bolt,
            "ray": fx_ray, "flash": fx_flash, "note": fx_note, "confetti": fx_confetti, "dust": fx_dust,
            "star_particle": fx_star, "cloud": fx_cloud}


# ==========================================================================
# UI chrome
# ==========================================================================
SHELF = 10          # px of darker "shelf" under a button face


def draw_button(kind):
    top, bot, shelf = BUTTONS[kind]
    cv = Canvas(128, 128)
    X, Y = cv.X, cv.Y
    outer = sd_rect(X, Y, 1, 1, 127, 127, 28)
    cv.fill(outer, shelf)
    face = sd_rect(X, Y, 1, 1, 127, 127 - SHELF, 28)
    cv.fill_grad(face, [(0, top), (1, bot)], axis="y", p0=4, p1=127 - SHELF)
    # white top highlight (inner lip) + glossy band
    lip = np.maximum(np.abs(face + 2.2) - 2.2, Y - 30)
    w = cv.win(lip < 1)
    cv.paint(np.clip(0.5 - lip[w] * cv.ss, 0, 1) * smoothstep(30, 6, Y[w]), WHITE, 0.55, win=w)
    gl = sd_rect(X, Y, 12, 8, 116, 50, 18)
    w = cv.win(gl < 1)
    cv.paint(np.clip(0.5 - gl[w] * cv.ss, 0, 1) * smoothstep(54, 10, Y[w]), WHITE, 0.30, win=w)
    # soft darker band at the bottom of the face
    lo = np.maximum(face, 100 - Y)
    w = cv.win(lo < 1)
    cv.paint(np.clip(0.5 - lo[w] * cv.ss, 0, 1) * smoothstep(100, 117, Y[w]), C(shelf), 0.25, win=w)
    cv.fill(sd_ellipse(X, Y, 26, 20, 7, 3.6, ang=-0.45), WHITE, 0.8, soft=0.6)
    return cv


def _panel(fill, line, shadow_col):
    cv = Canvas(128, 128)
    X, Y = cv.X, cv.Y
    body = sd_rect(X, Y, 12, 8, 116, 112, 24)
    cv.fill(body, fill)
    cv.stroke(body + 1.5, 3.0, line, 1.0)
    cv.fill(np.maximum(np.abs(body + 4.5) - 1.0, Y - 30), WHITE, 0.8, soft=0.6)
    cv.shadow_under(0, 5, 5, shadow_col, 0.28)
    return cv


def draw_panel():
    return _panel("#FFFFFF", PANEL_LINE, "#2F80ED")


def draw_panel_tint():
    return _panel("#FFF6E5", "#FFE3B8", "#E08A3A")


def draw_ribbon():
    cv = Canvas(320, 80)
    X, Y = cv.X, cv.Y
    line = "#5B17C9"
    for sgn in (-1, 1):
        xo = 160 + sgn * 158
        xi = 160 + sgn * 104
        pts = [(xi, 24), (xo, 24), (xo - sgn * 16, 46), (xo, 68), (xi, 68)]
        tail = opening(sd_poly(X, Y, pts), 2, cv.ss)
        candy(cv, tail, ("#C9A1FF", "#9B5CFF", "#7433E0", line), lw=2.6, depth=8, rim=0.3, grad_dir=(0, 1))
        fold = sd_poly(X, Y, [(160 + sgn * 126, 58), (160 + sgn * 126, 70), (160 + sgn * 104, 58)])
        cv.fill(fold, "#4A10A8")
    band = sd_rect(X, Y, 34, 8, 286, 60, 12)
    candy(cv, band, ("#D8B8FF", "#A66BFF", "#8B45FF", line), lw=2.8, depth=12, lift=0.5, rim=0.4, grad_dir=(0, 1),
          stops=(0.0, 0.45, 1.0))
    gl = I(sd_rect(X, Y, 42, 12, 278, 30, 7), band + 3)
    w = cv.win(gl < 1)
    cv.paint(np.clip(0.5 - gl[w] * cv.ss, 0, 1) * smoothstep(34, 12, Y[w]), WHITE, 0.45, win=w)
    for yy in (15, 53):
        dash = np.maximum(np.abs(Y - yy) - 0.9, np.abs((X % 11) - 5.5) - 2.8)
        cv.fill(np.maximum(dash, band + 5), "#F1E6FF", 0.75)
    for sx in (52, 268):
        sparkle4(cv, sx, 34, 7, WHITE, 0.9)
    soft_shadow(cv, 0, 3, 3, PIECE_SHADOW, 0.3)
    return cv


def draw_moves_badge():
    cv = Canvas(192, 192)
    X, Y = cv.X, cv.Y
    body = sd_rect(X, Y, 14, 10, 178, 174, 48)
    cv.shadow_under(0, 0, 0, "#000000", 0)
    cv.fill_grad(body, PINK_BADGE, axis=(0.35, 1.0))
    ring = sd_rect(X, Y, 14, 10, 178, 174, 48)
    cv.stroke(ring + 2.5, 5.0, "#FFFFFF", 0.6)
    gl = I(sd_rect(X, Y, 26, 20, 166, 84, 36), body + 8)
    w = cv.win(gl < 1)
    cv.paint(np.clip(0.5 - gl[w] * cv.ss, 0, 1) * smoothstep(86, 20, Y[w]), WHITE, 0.3, win=w)
    cv.fill(sd_ellipse(X, Y, 44, 34, 11, 5.5, ang=-0.6), WHITE, 0.85, soft=0.8)
    lo = np.maximum(body + 2, 140 - Y)
    w = cv.win(lo < 1)
    cv.paint(np.clip(0.5 - lo[w] * cv.ss, 0, 1) * smoothstep(140, 172, Y[w]), C("#D21E5E"), 0.35, win=w)
    cv.shadow_under(0, 7, 7, "#F0306F", 0.35)
    return cv


def draw_bunting():
    cv = Canvas(720, 64)
    X, Y = cv.X, cv.Y
    swags = 4
    span = 720 / swags
    cols = [PIECES[k] for k in ("red", "yellow", "green", "blue", "purple", "orange")]
    string_pts = []
    for i in range(swags):
        x0 = i * span
        string_pts += bez((x0 - 1, 5), (x0 + span / 2, 26), (x0 + span + 1, 5), n=32)[:-1]
    string_pts.append((721, 5))

    def sy(x):
        i = min(int(x // span), swags - 1)
        t = (x - i * span) / span
        return 5 + 2 * t * (1 - t) * 21 * 2 * 0.5 * 2 * 0.5 * 2
    k = 0
    lay = cv.blank()
    for i in range(swags):
        for j in range(4):
            fx = i * span + span * (j + 0.5) / 4
            t = (fx - i * span) / span
            y0 = 5 + 4 * t * (1 - t) * 21 * 0.5 * 2 - 0.5
            y0 = (1 - t) ** 2 * 5 + 2 * (1 - t) * t * 26 + t * t * 5
            slope = 2 * (1 - t) * (26 - 5) - 2 * t * (26 - 5)
            ang = math.atan2(slope / span, 1.0)
            w_, h_ = 15, 34
            ca, sa = math.cos(ang), math.sin(ang)

            def R(px, py):
                return (fx + px * ca - py * sa, y0 + px * sa + py * ca)
            flag = opening(sd_poly(X, Y, [R(-w_, 0), R(w_, 0), R(0, h_)]), 2.2, cv.ss)
            candy(lay, flag, cols[k % len(cols)], lw=2.0, depth=5, rim=0.35, lift=0.6)
            hl = sd_capsule(X, Y, *R(-w_ + 6, 4), *R(-3, h_ - 12), 1.6)
            lay.fill(np.maximum(hl, flag + 3), WHITE, 0.75)
            k += 1
    soft_shadow(lay, 0, 2.5, 2.0, PIECE_SHADOW, 0.3)
    s = sd_polyline(X, Y, string_pts) - 1.4
    cv.fill(s - 0.8, "#B7A6E6", 0.6)
    cv.fill(s, "#FFFFFF", 1.0)
    cv.over(lay)
    _ = sy
    return cv


# ==========================================================================
# icons (96x96) - glossy candy objects with a white sticker edge
# ==========================================================================
GOLD = ("#FFF3B0", "#FFD23F", "#F5A300", "#C27400")
RED = ("#FF9EB5", "#FF4D6D", "#E0183F", "#B3122F")
GREEN = ("#B5FFD0", "#3BE37F", "#18B85A", "#0E8A43")
BLUE = ("#A9DCFF", "#3AA4FF", "#1775E8", "#0B55B8")
PURPLE = ("#D9B8FF", "#9B52FF", "#7426E8", "#5B17C9")
PINK = ("#FFB3D6", "#FF5C9A", "#E0306F", "#A8124C")
ORANGE = ("#FFD08A", "#FF9A1F", "#F07400", "#C25700")
CYAN = ("#C7FAFF", "#3CE0FF", "#12A9E0", "#0B7DB8")
WHITE_P = ("#FFFFFF", "#FFFFFF", "#DCD3F5", "#7B6AAE")
CREAM = ("#FFFFFF", "#FFF4E0", "#F2D7B0", "#C28A4E")
CHROME = ("#FFFFFF", "#E3E9F7", "#AEB9D3", "#6E7A9C")
WOOD = ("#FFD9A3", "#F5A45A", "#DB7A30", "#A5541A")
GREY_P = ("#F4F2FA", "#DAD6E8", "#BDB6D4", "#8E86AE")


def obj(cv, d, pal, lw=3.0, depth=None, **kw):
    candy(cv, d, pal, lw=lw, depth=depth, **kw)


def finish(cv, sticker=3.0, shadow=0.3):
    if sticker > 0:
        cv.outline_under(sticker, "#FFFFFF", 1.0, thresh=0.35)
    soft_shadow(cv, 0, 2.2, 2.0, PIECE_SHADOW, shadow)
    return cv


def hl_drop(cv, x, y, rx, ry, ang_deg, clip, alpha=0.85):
    gloss_drop(cv, x, y, rx, ry, math.radians(ang_deg), clip, alpha=alpha)


def heart_sdf(X, Y, cx, cy, s):
    pts = []
    for k in range(120):
        t = 2 * math.pi * k / 120
        x = 16 * math.sin(t) ** 3
        y = -(13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t))
        pts.append((cx + x * s, cy + y * s))
    return sd_poly(X, Y, pts)


def beamed_notes(X, Y, ox, oy, s=1.0):
    h1 = sd_ellipse(X, Y, ox + 22 * s, oy + 66 * s, 14 * s, 10.5 * s, ang=math.radians(-22))
    h2 = sd_ellipse(X, Y, ox + 62 * s, oy + 58 * s, 14 * s, 10.5 * s, ang=math.radians(-22))
    s1 = sd_capsule(X, Y, ox + 32 * s, oy + 64 * s, ox + 32 * s, oy + 22 * s, 5 * s)
    s2 = sd_capsule(X, Y, ox + 72 * s, oy + 56 * s, ox + 72 * s, oy + 12 * s, 5 * s)
    beam = sd_poly(X, Y, [(ox + 27 * s, oy + 14 * s), (ox + 77 * s, oy + 2 * s), (ox + 77 * s, oy + 18 * s),
                          (ox + 27 * s, oy + 30 * s)])
    d = U(SU(h1, s1, 3 * s), SU(h2, s2, 3 * s))
    return opening(U(d, beam), 2)


def speaker_sdf(X, Y, ox=0.0):
    box = sd_rect(X, Y, 12 + ox, 34, 32 + ox, 62, 5)
    cone = opening(sd_poly(X, Y, [(26 + ox, 34), (52 + ox, 14), (52 + ox, 82), (26 + ox, 62)]), 4)
    return U(box, cone)


def _slash(cv):
    X, Y = cv.X, cv.Y
    sl = sd_capsule(X, Y, 16, 18, 80, 80, 6.5)
    cv.fill(sl - 3, "#FFFFFF")
    obj(cv, sl, RED, lw=2.2, depth=4, rim=0.3)


def icon_coin():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    d = sd_circle(X, Y, 48, 48, 40)
    obj(cv, d, GOLD, depth=14, rim=0.4)
    inner = sd_circle(X, Y, 48, 48, 29)
    inset(cv, inner, "#FFC93A", depth=5, shadow=0.45, hl=0.5, dark="#E08A00", light="#FFF6C8")
    n = note_sdf(X, Y, 48 - 84 * 0.36 + 1, 48 - 74 * 0.36 - 1, 0.36)
    obj(cv, n, ("#FFFFFF", "#FFF6C8", "#FFD23F", "#C27400"), lw=2.0, depth=5, rim=0.2)
    rim_gloss(cv, d, 48, 48, -135, 40, 3.5, 6, alpha=0.8)
    return finish(cv)


def _star_shape(X, Y):
    return opening(sd_star(X, Y, 48, 52, 46, 22), 6, 4)


def icon_star():
    cv = Canvas(96, 96)
    d = _star_shape(cv.X, cv.Y)
    obj(cv, d, PIECES["yellow"], depth=20, rim=0.4)
    hl_drop(cv, 38, 38, 7, 4, -36, d + 5)
    return finish(cv)


def icon_star_empty():
    cv = Canvas(96, 96)
    d = _star_shape(cv.X, cv.Y)
    inset(cv, d, "#EDE6FF", depth=8, shadow=0.5, hl=0.4, dark="#C9B8F2", light="#FFFFFF")
    cv.stroke(d + 1.5, 3.0, "#B9A6EC", 1.0)
    return finish(cv, shadow=0.15)


def icon_heart():
    cv = Canvas(96, 96)
    d = opening(heart_sdf(cv.X, cv.Y, 48, 50, 2.55), 2)
    obj(cv, d, RED, depth=22, rim=0.45)
    hl_drop(cv, 30, 30, 9, 5, -40, d + 5)
    cv.fill(np.maximum(sd_circle(cv.X, cv.Y, 20, 46, 2.8), d + 5), WHITE, 0.8)
    return finish(cv)


def icon_heart_infinite():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    d = opening(heart_sdf(X, Y, 48, 50, 2.55), 2)
    obj(cv, d, RED, depth=22, rim=0.45)
    hl_drop(cv, 28, 28, 7, 4, -40, d + 5)
    pts = []
    for k in range(97):
        t = 2 * math.pi * k / 96
        den = 1 + math.sin(t) ** 2
        pts.append((48 + 25 * math.cos(t) / den, 52 + 25 * math.sin(t) * math.cos(t) / den))
    inf = sd_polyline(X, Y, pts) - 4.6
    cv.fill(inf - 2.0, "#B3122F", 0.9)
    obj(cv, inf, WHITE_P, lw=0, depth=3)
    return finish(cv)


def icon_pause():
    cv = Canvas(96, 96)
    d = U(sd_rect(cv.X, cv.Y, 22, 16, 42, 80, 9), sd_rect(cv.X, cv.Y, 54, 16, 74, 80, 9))
    obj(cv, d, ("#C9B0FF", "#8C63FF", "#7B4FFF", "#5431D6"), depth=8, rim=0.4)
    for x in (27, 59):
        hl_drop(cv, x + 2, 30, 3, 8, 0, d + 5)
    return finish(cv)


def icon_settings():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    d = sd_circle(X, Y, 48, 48, 29)
    for k in range(8):
        a = k * math.pi / 4 + math.pi / 8
        d = SU(d, sd_box(X, Y, 48 + 33 * math.cos(a), 48 + 33 * math.sin(a), 9, 8.5, 3.5, ang=a), 3)
    d = SUB(d, sd_circle(X, Y, 48, 48, 12))
    obj(cv, d, BLUE, depth=10, rim=0.4)
    cv.stroke(sd_circle(X, Y, 48, 48, 12), 2.4, BLUE[3], 1.0)
    rim_gloss(cv, sd_circle(X, Y, 48, 48, 29), 48, 48, -135, 40, 3, 5, alpha=0.75)
    return finish(cv)


def icon_close():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    d = U(sd_capsule(X, Y, 24, 24, 72, 72, 11), sd_capsule(X, Y, 72, 24, 24, 72, 11))
    obj(cv, d, PINK, depth=9, rim=0.4)
    hl_drop(cv, 30, 28, 6, 3, 45, d + 4)
    hl_drop(cv, 66, 28, 6, 3, -45, d + 4, alpha=0.7)
    return finish(cv)


def icon_check():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    d = sd_polyline(X, Y, [(18, 50), (38, 70), (78, 26)]) - 11.5
    obj(cv, d, GREEN, depth=9, rim=0.4)
    hl_drop(cv, 24, 48, 5, 2.6, 45, d + 4)
    hl_drop(cv, 64, 34, 9, 2.8, -48, d + 4)
    return finish(cv)


def icon_lock():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    sh = U(sd_arc(X, Y, 48, 38, 19, math.pi, 2 * math.pi, 10), sd_capsule(X, Y, 29, 38, 29, 52, 5),
           sd_capsule(X, Y, 67, 38, 67, 52, 5))
    obj(cv, sh, CHROME, depth=5, rim=0.3)
    body = sd_rect(X, Y, 16, 44, 80, 88, 14)
    obj(cv, body, GOLD, depth=12, rim=0.45)
    kh = U(sd_circle(X, Y, 48, 61, 7), sd_poly(X, Y, [(44, 63), (52, 63), (55, 78), (41, 78)]))
    cv.fill(kh, "#C27400")
    hl_drop(cv, 28, 54, 6, 3, -20, body + 4)
    return finish(cv)


def icon_shop():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    handle = U(sd_arc(X, Y, 36, 36, 12, math.pi, 2 * math.pi, 6), sd_arc(X, Y, 60, 36, 12, math.pi, 2 * math.pi, 6))
    obj(cv, handle, GOLD, lw=2.2, depth=3)
    bag = opening(sd_poly(X, Y, [(18, 34), (78, 34), (84, 88), (12, 88)]), 8)
    obj(cv, bag, PINK, depth=16, rim=0.45)
    band = I(sd_rect(X, Y, 10, 34, 86, 46, 0), bag + 3)
    cv.fill(band, "#FF9CC6", 0.9)
    st = opening(sd_star(X, Y, 48, 66, 16, 7.5), 1.8)
    obj(cv, st, PIECES["yellow"], lw=2.0, depth=5)
    hl_drop(cv, 26, 58, 3.5, 9, 10, bag + 4)
    return finish(cv)


def icon_city():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    bl = [((8, 40, 36, 88), "#FF9EC7"), ((58, 46, 88, 88), "#8BE39A"), ((30, 16, 64, 88), "#7FC8FF")]
    for (x0, y0, x1, y1), col in bl:
        d = sd_rect(X, Y, x0, y0, x1, y1, 7)
        c = C(col)
        obj(cv, d, (mix(c, WHITE, 0.5), c, mix(c, C("#3B1E8A"), 0.15), mix(c, C("#2A1650"), 0.45)), lw=2.6,
            depth=8, rim=0.3)
        for wy in range(int(y0) + 10, int(y1) - 10, 12):
            for wx in np.arange(x0 + 7, x1 - 7, 10.0):
                wd = sd_rect(X, Y, wx, wy, wx + 6, wy + 7, 2)
                cv.fill(wd, "#FFFFFF", 0.95)
    flag = sd_poly(X, Y, [(47, 2), (61, 6), (47, 11)])
    cv.fill(sd_capsule(X, Y, 47, 3, 47, 16, 1.6), "#5B17C9")
    obj(cv, flag, PIECES["yellow"], lw=1.4, depth=2)
    return finish(cv)


def icon_jukebox():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    body = U(sd_rect(X, Y, 16, 36, 80, 90, 9), sd_circle(X, Y, 48, 38, 32))
    body = I(body, Y - 90.5)
    obj(cv, body, PINK, depth=14, rim=0.4)
    arch = sd_arc(X, Y, 48, 40, 23, math.pi * 1.0, math.pi * 2.0, 6.5)
    t = np.clip((np.arctan2(Y - 40, X - 48) + math.pi) / math.pi, 0, 1)
    rb = ramp(t, [(0, "#FFDB1A"), (0.33, "#3CE0FF"), (0.66, "#9B52FF"), (1, "#FFDB1A")])
    w = cv.win(arch < 1)
    cv.paint(np.clip(0.5 - arch[w] * cv.ss, 0, 1), rb[w], 1, win=w)
    cv.fill(np.maximum(arch + 2.5, Y - 40), WHITE, 0.5)
    win = sd_circle(X, Y, 48, 42, 13)
    inset(cv, win, "#FFF6E0", depth=4, shadow=0.35, dark="#F2B0C9", light="#FFFFFF")
    rr = np.hypot(X - 48, Y - 42)
    cv.fill(sd_circle(X, Y, 48, 42, 9.5), "#9B52FF")
    cv.fill(np.maximum(np.abs(((rr) % 3.0) - 1.5) - 0.4, np.maximum(rr - 9, 4 - rr)), "#C9A1FF", 0.7)
    cv.fill(sd_circle(X, Y, 48, 42, 3.2), "#FFDB1A")
    gr = sd_rect(X, Y, 28, 60, 68, 82, 6)
    inset(cv, gr, "#FFE1EE", depth=3, shadow=0.35, dark="#E0306F", light="#FFFFFF")
    slats = np.maximum(np.abs(((X - 28) % 6.0) - 3) - 1.2, gr + 2)
    cv.fill(slats, "#FF9A1F", 0.95)
    hl_drop(cv, 26, 50, 3.5, 10, 8, body + 4)
    return finish(cv)


def icon_team():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    for (cx, s, pal) in ((24, 0.8, PURPLE), (72, 0.8, GREEN), (48, 1.0, BLUE)):
        by = 88
        body = I(sd_ellipse(X, Y, cx, by, 22 * s, 27 * s), Y - by)
        head = sd_circle(X, Y, cx, by - 37 * s, 14 * s)
        obj(cv, body, pal, lw=2.6, depth=10 * s, rim=0.3)
        obj(cv, head, ("#FFF6EC", "#FFD9B8", "#F2B48A", "#C77A4A"), lw=2.6, depth=8 * s, rim=0.3)
        cv.fill(sd_ellipse(X, Y, cx - 4 * s, by - 42 * s, 3.5 * s, 2 * s, -0.5), WHITE, 0.8, soft=0.5)
    return finish(cv)


def icon_chart():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    for (x0, y0, pal) in ((12, 58, PINK), (37, 40, GOLD), (62, 24, CYAN)):
        d = sd_rect(X, Y, x0, y0, x0 + 22, 88, 6)
        obj(cv, d, pal, lw=2.6, depth=8, rim=0.35)
        hl_drop(cv, x0 + 7, y0 + 10, 2.5, 5, 0, d + 4)
    st = opening(sd_star(X, Y, 73, 12, 11, 5), 1.2)
    obj(cv, st, PIECES["yellow"], lw=2, depth=4)
    return finish(cv)


def icon_play():
    cv = Canvas(96, 96)
    d = opening(sd_poly(cv.X, cv.Y, [(24, 12), (84, 48), (24, 84)]), 9)
    obj(cv, d, GREEN, depth=12, rim=0.45)
    hl_drop(cv, 34, 30, 3.5, 9, -20, d + 5)
    return finish(cv)


def icon_retry():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    a0, a1 = math.radians(-50), math.radians(215)
    arc = sd_arc(X, Y, 48, 52, 26, a0, a1, 13)
    ex, ey = 48 + 26 * math.cos(a0), 52 + 26 * math.sin(a0)
    head = opening(sd_poly(X, Y, [(ex - 22, ey - 8), (ex + 15, ey - 15), (ex + 6, ey + 22)]), 2.5)
    d = U(arc, head)
    obj(cv, d, BLUE, depth=8, rim=0.4)
    rim_gloss(cv, sd_circle(X, Y, 48, 52, 32.5), 48, 52, -150, 30, 2.5, 4.5, alpha=0.8)
    return finish(cv)


def icon_home():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    body = sd_rect(X, Y, 20, 42, 76, 88, 7)
    obj(cv, body, CREAM, depth=10, rim=0.3)
    chim = sd_rect(X, Y, 62, 14, 74, 36, 3)
    obj(cv, chim, PINK, lw=2.4, depth=4)
    roof = opening(sd_poly(X, Y, [(48, 8), (92, 50), (4, 50)]), 6)
    obj(cv, roof, PINK, depth=10, rim=0.4)
    door = sd_rect(X, Y, 39, 60, 57, 88, 6)
    obj(cv, door, PIECES["yellow"], lw=2.4, depth=5)
    cv.fill(sd_circle(X, Y, 52, 75, 1.8), "#C28A00")
    hl_drop(cv, 34, 30, 7, 3, -42, roof + 4)
    return finish(cv)


def icon_music(on=True):
    cv = Canvas(96, 96)
    d = beamed_notes(cv.X, cv.Y, 4, 10, 1.0)
    obj(cv, d, PURPLE if on else GREY_P, depth=7, rim=0.35)
    hl_drop(cv, 20, 70, 5, 3, -25, d + 4)
    if not on:
        _slash(cv)
    return finish(cv)


def icon_sound(on=True):
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    d = speaker_sdf(X, Y, 2)
    obj(cv, d, BLUE if on else GREY_P, depth=8, rim=0.35)
    hl_drop(cv, 22, 44, 2.6, 6, 0, d + 4)
    if on:
        for r, w in ((18, 9), (33, 9)):
            a = sd_arc(X, Y, 56, 48, r, math.radians(-50), math.radians(50), w)
            obj(cv, a, CYAN, lw=2.2, depth=3, rim=0.3)
    else:
        x = U(sd_capsule(X, Y, 62, 36, 84, 60, 5.5), sd_capsule(X, Y, 84, 36, 62, 60, 5.5))
        obj(cv, x, RED, lw=2.2, depth=4, rim=0.3)
    return finish(cv)


def icon_haptics():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    for sgn in (-1, 1):
        zz = [(48 + sgn * 26, 26 + k * 11) if k % 2 == 0 else (48 + sgn * 34, 26 + k * 11) for k in range(5)]
        z = sd_polyline(X, Y, zz) - 3.4
        obj(cv, z, CYAN, lw=2.0, depth=2)
    phone = sd_rect(X, Y, 30, 10, 66, 86, 10)
    obj(cv, phone, PURPLE, depth=8, rim=0.35)
    inset(cv, sd_rect(X, Y, 36, 20, 60, 70, 4), "#E3F3FF", depth=3, shadow=0.35, dark="#A9DCFF", light="#FFFFFF")
    cv.fill(sd_circle(X, Y, 48, 78, 3), "#FFFFFF")
    hl_drop(cv, 42, 30, 3, 7, 20, sd_rect(X, Y, 36, 20, 60, 70, 4) + 2, alpha=0.9)
    return finish(cv)


def icon_hand():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    cuff = sd_rect(X, Y, 34, 76, 72, 94, 6)
    palm = sd_rect(X, Y, 32, 42, 74, 80, 13)
    index = sd_capsule(X, Y, 42, 50, 42, 10, 8.5)
    thumb = sd_capsule(X, Y, 34, 62, 22, 50, 7.5)
    fingers = [sd_capsule(X, Y, 51 + 9 * k, 46, 51 + 9 * k, 56, 7) for k in range(3)]
    hand = U(SU(palm, index, 4), SU(palm, thumb, 4), *fingers)
    lay = cv.blank()
    candy(lay, cuff, BLUE, lw=2.8, depth=6, rim=0.3)
    candy(lay, hand, ("#FFFFFF", "#FFFFFF", "#E2D8FA", "#7B6AAE"), lw=2.8, depth=12, rim=0.2, lift=0.3)
    for k in range(3):
        lay.fill(np.maximum(sd_capsule(X, Y, 46.5 + 9 * k, 50, 46.5 + 9 * k, 60, 0.9), hand + 3), "#9D8FD0", 0.9)
    gloss_drop(lay, 38, 24, 2.4, 6, 0, index + 4, alpha=0.9)
    rot = lay.transformed(-24, pivot=(48, 52), sx=0.92, sy=0.92, dx=4, dy=-2)
    for k in range(3):
        a = math.radians(-150 + k * 40)
        rot.fill(sd_capsule(X, Y, 34 + 14 * math.cos(a), 18 + 14 * math.sin(a),
                            34 + 24 * math.cos(a), 18 + 24 * math.sin(a), 2.6), "#FFDB1A")
    cv.over(rot)
    return finish(cv)


def icon_stick():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    burst = opening(sd_star(X, Y, 74, 24, 19, 9.5, n=8), 1.2)
    obj(cv, burst, PIECES["yellow"], lw=2.2, depth=5)
    st = sd_taper(X, Y, 12, 86, 62, 34, 10, 5.5)
    obj(cv, st, ("#FFF4E0", "#F7C98A", "#E09A50", "#A5601E"), depth=8, rim=0.35)
    tip = sd_ellipse(X, Y, 66, 30, 9.5, 7.5, ang=-0.8)
    obj(cv, tip, ("#FFFFFF", "#FFE8C4", "#F2BE7C", "#A5601E"), lw=2.6, depth=5)
    grip = I(st, sd_capsule(X, Y, 12, 86, 28, 69, 13))
    obj(cv, grip, PINK, lw=0, depth=5)
    for t in (0.3, 0.55):
        gx, gy = 12 + (28 - 12) * t, 86 + (69 - 86) * t
        cv.fill(np.maximum(sd_capsule(X, Y, gx - 8, gy - 8, gx + 8, gy + 8, 0.9), grip + 1.5), "#A8124C", 0.6)
    gloss_drop(cv, 40, 56, 11, 2.2, math.radians(-46), st + 3, alpha=0.8)
    return finish(cv)


def _spotlight(cv, vertical):
    X, Y = cv.X, cv.Y
    lay = cv.blank()
    beam = sd_poly(X, Y, [(48, 36), (94, 22), (94, 74), (48, 60)])
    lay.fill(beam, "#FFF3A6", 0.9, soft=2)
    beam2 = sd_poly(X, Y, [(48, 40), (94, 30), (94, 66), (48, 56)])
    lay.fill(beam2, "#FFFFFF", 0.7, soft=3)
    body = sd_rect(X, Y, 8, 30, 50, 66, 10)
    candy(lay, body, PURPLE, lw=2.8, depth=8, rim=0.35)
    rim_ = sd_rect(X, Y, 42, 26, 56, 70, 5)
    candy(lay, rim_, GOLD, lw=2.4, depth=4, rim=0.3)
    lens = sd_ellipse(X, Y, 50, 48, 5, 17)
    lay.fill(lens, "#FFFBD6")
    yoke = sd_arc(X, Y, 30, 48, 26, math.radians(60), math.radians(120), 5)
    candy(lay, yoke, CHROME, lw=2.0, depth=3)
    gloss_drop(lay, 20, 38, 8, 3, 0, body + 4, alpha=0.8)
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


def icon_remix():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    for (p, pal) in ((bez((10, 74), (46, 74), (46, 24), (72, 24), n=20), CYAN),
                     (bez((10, 24), (46, 24), (46, 74), (72, 74), n=20), PINK)):
        ex, ey = p[-1]
        stroke = sd_polyline(X, Y, p[:-2]) - 6.5
        head = opening(sd_poly(X, Y, [(ex - 12, ey - 16), (ex + 18, ey), (ex - 12, ey + 16)]), 2.5)
        d = U(stroke, head)
        cv.fill(d - 2.5, "#FFFFFF")
        obj(cv, d, pal, lw=2.6, depth=5, rim=0.3)
    return finish(cv)


def icon_plus():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    c = sd_circle(X, Y, 48, 48, 40)
    obj(cv, c, GREEN, depth=14, rim=0.45)
    p = U(sd_rect(X, Y, 39, 22, 57, 74, 6), sd_rect(X, Y, 22, 39, 74, 57, 6))
    obj(cv, p, WHITE_P, lw=0, depth=5, rim=0.1)
    cv.stroke(p, 1.6, GREEN[3], 0.5)
    rim_gloss(cv, c, 48, 48, -135, 38, 3.5, 6, alpha=0.8)
    return finish(cv)


def _chest_body(cv):
    X, Y = cv.X, cv.Y
    body = sd_rect(X, Y, 10, 46, 86, 88, 8)
    obj(cv, body, WOOD, depth=10, rim=0.35)
    for x0 in (20, 68):
        band = I(sd_rect(X, Y, x0, 44, x0 + 8, 90, 1), body + 0.5)
        obj(cv, band, GOLD, lw=1.8, depth=3)
    return body


def icon_chest_closed():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    _chest_body(cv)
    lid = U(sd_rect(X, Y, 10, 26, 86, 50, 7), I(sd_ellipse(X, Y, 48, 30, 38, 18), Y - 30))
    obj(cv, lid, ("#FFE3BF", "#FFB46A", "#F08A3A", "#A5541A"), depth=10, rim=0.4)
    for x0 in (20, 68):
        band = I(sd_rect(X, Y, x0, 8, x0 + 8, 50, 1), lid + 0.5)
        obj(cv, band, GOLD, lw=1.8, depth=3)
    plate = sd_rect(X, Y, 38, 40, 58, 62, 5)
    obj(cv, plate, GOLD, lw=2.2, depth=5)
    cv.fill(U(sd_circle(X, Y, 48, 49, 3.2), sd_rect(X, Y, 46.6, 49, 49.4, 56, 1)), "#C27400")
    hl_drop(cv, 28, 26, 8, 3, -18, lid + 4)
    return finish(cv)


def icon_chest_open():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    rays = cv.blank()
    for k in range(7):
        a = math.radians(-90 + (k - 3) * 22)
        rays.fill(sd_poly(X, Y, [(48, 50), (48 + 60 * math.cos(a - 0.12), 50 + 60 * math.sin(a - 0.12)),
                                 (48 + 60 * math.cos(a + 0.12), 50 + 60 * math.sin(a + 0.12))]), "#FFE66D", 0.8,
                  soft=3)
    rays.paint(smoothstep(52, 14, np.hypot(X - 48, Y - 50)), C("#FFFFFF"), 1.0, "atop")
    cv.over(rays)
    lid = opening(sd_poly(X, Y, [(12, 34), (84, 34), (78, 14), (18, 14)]), 5)
    obj(cv, lid, ("#FFE3BF", "#FFB46A", "#F08A3A", "#A5541A"), depth=8, rim=0.3)
    inner = sd_rect(X, Y, 14, 38, 82, 52, 4)
    cv.fill(inner, "#FFE66D", 1)
    cv.glow_from(np.clip(0.5 - inner * cv.ss, 0, 1), 8, "#FFE66D", 0.7, mode="over")
    for (x, y) in ((30, 44), (44, 40), (58, 44), (68, 40), (38, 48)):
        obj(cv, sd_ellipse(X, Y, x, y, 7, 5), GOLD, lw=1.6, depth=3)
    _chest_body(cv)
    plate = sd_rect(X, Y, 38, 46, 58, 62, 5)
    obj(cv, plate, GOLD, lw=2.2, depth=5)
    sparkle4(cv, 18, 22, 7, WHITE)
    sparkle4(cv, 80, 16, 6, WHITE)
    return finish(cv)


def icon_note(on=True):
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    s = 0.58
    d = note_sdf(X, Y, 48 - 84 * s + 2, 48 - 70 * s, s)
    if on:
        lay = cv.blank()
        obj(lay, d, PIECES["yellow"], depth=10, rim=0.4)
        gloss_drop(lay, 30, 64, 6, 3.5, math.radians(-25), d + 4, alpha=0.9)
        lay.glow_under(9, "#FF6FD8", 0.8)
        for (sx, sy, sz) in ((78, 16, 8), (84, 68, 5.5), (16, 30, 5)):
            sparkle4(lay, sx, sy, sz, WHITE)
        cv.over(lay)
        return finish(cv, sticker=0)
    inset(cv, d, "#EDE6FF", depth=6, shadow=0.45, hl=0.4, dark="#C9B8F2", light="#FFFFFF")
    cv.stroke(d + 1.4, 2.8, "#B9A6EC", 1.0)
    return finish(cv, shadow=0.15)


def icon_arrow():
    cv = Canvas(96, 96)
    d = opening(sd_poly(cv.X, cv.Y, [(10, 38), (46, 38), (46, 14), (88, 48), (46, 82), (46, 58), (10, 58)]), 5)
    obj(cv, d, BLUE, depth=9, rim=0.4)
    hl_drop(cv, 26, 43, 10, 2.6, 0, d + 4)
    return finish(cv)


def icon_gift():
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    for sgn in (-1, 1):
        loop = sd_ellipse(X, Y, 48 + sgn * 14, 24, 14, 9, ang=sgn * -0.45)
        loop = SUB(loop, sd_ellipse(X, Y, 48 + sgn * 14, 24, 6, 3, ang=sgn * -0.45))
        obj(cv, loop, GOLD, lw=2.4, depth=4)
    box = sd_rect(X, Y, 16, 46, 80, 88, 6)
    obj(cv, box, PURPLE, depth=10, rim=0.35)
    lid = sd_rect(X, Y, 10, 32, 86, 50, 6)
    obj(cv, lid, ("#E9D6FF", "#B07AFF", "#8B45FF", "#5B17C9"), depth=7, rim=0.35)
    rib = I(sd_rect(X, Y, 41, 30, 55, 90, 0), U(box, lid) + 0.5)
    obj(cv, rib, GOLD, lw=2.0, depth=4)
    obj(cv, sd_circle(X, Y, 48, 30, 6.5), GOLD, lw=2.0, depth=4)
    hl_drop(cv, 22, 38, 6, 2.5, 0, lid + 4)
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
