"""Placeholder art of the songbook (WP-9): drawn by code until the real pictures arrive (docs/art-brief-chatgpt.md,
group A2). Every picture has the in-game name and size the notebook screen (gui/notebook.lua) asks for, so the
real art drops in without a code change. Loose images (group `notebook`), transparent where nothing is drawn.

  notebook/paper_sheet.png      640x900   cream paper, a staff of 5 lines repeated in rows, soft shadow, curled corners
  notebook/closed.png           384x384   closed lavender songbook: gold star and note, ribbon bookmark, stitching
  notebook/stationery_<1..9>    128x128   pencil, big pencil, eraser, pen, marker, star sticker, clip, tape, bookmark
  notebook/doodle_<1..9>        96x96     note, two notes, clef, heart, star, flower, sun, cloud, lightning
  notebook/stamp_ready.png      192x192   golden seal with a star and two ribbon tails
  notebook/sparkle_<1..6>.png   128x128   a burst of stars that grows and fades

Plain PIL with 4x supersampling (no text anywhere).
"""
import math

from PIL import Image, ImageDraw, ImageFilter

SS = 4
PAPER, PAPER_EDGE, LINE = "#FFF6DD", "#EAD9AE", "#C9B98E"
LAVENDER, LAV_DARK, GOLD = "#9C7BFF", "#6A44D6", "#FFB020"
INK = {"pencil": "#FFD84D", "pink": "#FF4D8D", "blue": "#3AA4FF", "green": "#2BE38F", "purple": "#8B45FF", "orange": "#FF9A1F"}

STATIONERY = ("pencil", "big_pencil", "eraser", "pen", "marker", "sticker", "clip", "tape", "bookmark")
DOODLES = ("note", "notes", "clef", "heart", "star", "flower", "sun", "cloud", "bolt")


def _canvas(w, h):
    return Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))


def _done(im, w, h):
    return im.resize((w, h), Image.LANCZOS)


def _star_pts(cx, cy, r, ratio=0.45, n=5, rot=-90):
    pts = []
    for i in range(n * 2):
        a = math.radians(rot + i * 180 / n)
        rr = r if i % 2 == 0 else r * ratio
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    return pts


def paper_sheet():
    w, h = 640, 900
    im = _canvas(w, h)
    d = ImageDraw.Draw(im)
    s = SS
    # a soft shadow under the sheet
    sh = Image.new("RGBA", im.size, (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle([34 * s, 40 * s, (w - 22) * s, (h - 14) * s], radius=18 * s, fill=(90, 60, 140, 90))
    im.alpha_composite(sh.filter(ImageFilter.GaussianBlur(10 * s)))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([24 * s, 24 * s, (w - 30) * s, (h - 30) * s], radius=16 * s, fill=PAPER_EDGE)
    d.rounded_rectangle([28 * s, 28 * s, (w - 34) * s, (h - 36) * s], radius=14 * s, fill=PAPER)
    # the staff: rows of 5 thin lines, 8 px apart, a row every 64 px
    y = 96
    while y + 32 < h - 70:
        for k in range(5):
            d.line([(64 * s, (y + k * 8) * s), ((w - 70) * s, (y + k * 8) * s)], fill=LINE, width=max(1, int(1.4 * s)))
        y += 64
    # the margin line and curled corners
    d.line([(52 * s, 40 * s), (52 * s, (h - 48) * s)], fill="#F2B8C6", width=2 * s)
    for cx, cy, sx, sy in ((w - 34, h - 36, -1, -1), (28, h - 36, 1, -1)):
        d.polygon([(cx, cy), (cx + sx * 36 * s / s, cy), (cx, cy + sy * 36)], fill="#EBDDB6")
    return _done(im, w, h)


def closed():
    w = h = 384
    im = _canvas(w, h)
    d = ImageDraw.Draw(im)
    s = SS
    d.rounded_rectangle([64 * s, 40 * s, 336 * s, 350 * s], radius=26 * s, fill=LAV_DARK)
    d.rounded_rectangle([60 * s, 34 * s, 326 * s, 340 * s], radius=26 * s, fill=LAVENDER)
    d.rounded_rectangle([60 * s, 34 * s, 100 * s, 340 * s], radius=22 * s, fill="#7F5CF0")     # the spine
    for y in range(60, 330, 34):                                                               # the stitching
        d.line([(84 * s, y * s), (84 * s, (y + 16) * s)], fill="#EADFFF", width=3 * s)
    d.pieslice([140 * s, 70 * s, 180 * s, 110 * s], 200, 340, fill="#C9B3FF")                  # a soft shine
    cx, cy = 208, 168
    d.polygon(_star_pts(cx * s, cy * s, 62 * s), fill=GOLD, outline="#C27400")
    d.ellipse([(cx - 20) * s, (cy + 56) * s, (cx + 4) * s, (cy + 76) * s], fill="#FFE680")      # a note under the star
    d.rectangle([(cx - 2) * s, (cy + 4) * s, (cx + 4) * s, (cy + 66) * s], fill="#FFE680")
    d.polygon([((cx + 4) * s, (cy + 4) * s), ((cx + 30) * s, (cy + 20) * s), ((cx + 4) * s, (cy + 26) * s)], fill="#FFE680")
    d.polygon([(280 * s, 330 * s), (280 * s, 372 * s), (293 * s, 358 * s), (306 * s, 372 * s), (306 * s, 330 * s)], fill="#FF4D8D")  # ribbon
    return _done(im, w, h)


def stationery(kind):
    w = h = 128
    im = _canvas(w, h)
    d = ImageDraw.Draw(im)
    s = SS

    def pencil(cx, cy, length, thick, ang, body):
        c, sn = math.cos(math.radians(ang)), math.sin(math.radians(ang))

        def p(u, v):
            return ((cx + u * c - v * sn) * s, (cy + u * sn + v * c) * s)
        hl = length / 2
        d.polygon([p(-hl, -thick), p(hl - thick * 1.6, -thick), p(hl - thick * 1.6, thick), p(-hl, thick)], fill=body)
        d.polygon([p(hl - thick * 1.6, -thick), p(hl, 0), p(hl - thick * 1.6, thick)], fill="#F6D7A8")
        d.polygon([p(hl - thick * 0.45, -thick * 0.3), p(hl, 0), p(hl - thick * 0.45, thick * 0.3)], fill="#3B3355")
        d.polygon([p(-hl, -thick), p(-hl + thick * 1.2, -thick), p(-hl + thick * 1.2, thick), p(-hl, thick)], fill="#FF8AB8")
    if kind == "pencil":
        pencil(64, 64, 100, 8, -45, "#FFD84D")
    elif kind == "big_pencil":
        pencil(64, 64, 118, 12, 0, "#3AA4FF")
    elif kind == "eraser":
        d.rounded_rectangle([26 * s, 44 * s, 102 * s, 88 * s], radius=10 * s, fill="#FF8AB8")
        d.rounded_rectangle([26 * s, 44 * s, 62 * s, 88 * s], radius=10 * s, fill="#FFFFFF")
    elif kind == "pen":
        d.polygon([(30 * s, 98 * s), (44 * s, 98 * s), (100 * s, 36 * s), (86 * s, 24 * s)], fill="#8B45FF")
        d.polygon([(30 * s, 98 * s), (24 * s, 108 * s), (38 * s, 104 * s)], fill="#3B3355")
    elif kind == "marker":
        d.rounded_rectangle([22 * s, 52 * s, 96 * s, 78 * s], radius=8 * s, fill="#2BE38F")
        d.polygon([(96 * s, 56 * s), (112 * s, 62 * s), (112 * s, 68 * s), (96 * s, 74 * s)], fill="#FFD84D")
    elif kind == "sticker":
        d.polygon(_star_pts(64 * s, 66 * s, 50 * s, 0.5), fill=GOLD, outline="#FFFFFF")
    elif kind == "clip":
        d.arc([40 * s, 20 * s, 88 * s, 108 * s], 180, 360, fill="#9AA3B5", width=6 * s)
        d.arc([52 * s, 36 * s, 76 * s, 90 * s], 180, 360, fill="#9AA3B5", width=6 * s)
        d.line([(40 * s, 64 * s), (40 * s, 100 * s)], fill="#9AA3B5", width=6 * s)
        d.line([(76 * s, 64 * s), (76 * s, 90 * s)], fill="#9AA3B5", width=6 * s)
    elif kind == "tape":
        d.rounded_rectangle([20 * s, 40 * s, 108 * s, 88 * s], radius=14 * s, fill="#FF8AB8")
        for x in range(30, 104, 18):
            d.line([(x * s, 42 * s), ((x + 8) * s, 86 * s)], fill="#FFE0EE", width=4 * s)
    else:  # bookmark
        d.polygon([(40 * s, 14 * s), (88 * s, 14 * s), (88 * s, 112 * s), (64 * s, 92 * s), (40 * s, 112 * s)], fill="#FF4D8D")
    return _done(im, w, h)


def doodle(kind):
    w = h = 96
    im = _canvas(w, h)
    d = ImageDraw.Draw(im)
    s = SS
    ink = {"note": INK["purple"], "notes": INK["blue"], "clef": INK["purple"], "heart": INK["pink"], "star": INK["pencil"],
           "flower": INK["pink"], "sun": INK["orange"], "cloud": INK["blue"], "bolt": INK["pencil"]}[kind]
    wd = 7 * s

    def line(pts):
        d.line([(x * s, y * s) for x, y in pts], fill=ink, width=wd, joint="curve")
        for x, y in (pts[0], pts[-1]):
            d.ellipse([(x - 3.5) * s, (y - 3.5) * s, (x + 3.5) * s, (y + 3.5) * s], fill=ink)
    if kind == "note":
        d.ellipse([22 * s, 58 * s, 50 * s, 78 * s], outline=ink, width=wd)
        line([(50, 66), (50, 18), (72, 30)])
    elif kind == "notes":
        d.ellipse([12 * s, 60 * s, 36 * s, 78 * s], outline=ink, width=wd)
        d.ellipse([54 * s, 54 * s, 78 * s, 72 * s], outline=ink, width=wd)
        line([(36, 68), (36, 24), (78, 16), (78, 62)])
    elif kind == "clef":
        d.arc([30 * s, 40 * s, 66 * s, 76 * s], 0, 340, fill=ink, width=wd)
        line([(52, 18), (46, 64), (46, 82)])
        line([(52, 18), (66, 30), (50, 48)])
    elif kind == "heart":
        line([(48, 78), (18, 48), (22, 28), (38, 24), (48, 36), (58, 24), (74, 28), (78, 48), (48, 78)])
    elif kind == "star":
        pts = _star_pts(48, 50, 36, 0.45)
        line([(x, y) for x, y in pts] + [pts[0]])
    elif kind == "flower":
        for i in range(5):
            a = math.radians(i * 72 - 90)
            cx, cy = 48 + 22 * math.cos(a), 44 + 22 * math.sin(a)
            d.ellipse([(cx - 11) * s, (cy - 11) * s, (cx + 11) * s, (cy + 11) * s], outline=ink, width=5 * s)
        d.ellipse([40 * s, 36 * s, 56 * s, 52 * s], fill=INK["pencil"])
        line([(48, 66), (48, 90)])
    elif kind == "sun":
        d.ellipse([30 * s, 30 * s, 66 * s, 66 * s], outline=ink, width=wd)
        for i in range(8):
            a = math.radians(i * 45)
            line([(48 + 28 * math.cos(a), 48 + 28 * math.sin(a)), (48 + 40 * math.cos(a), 48 + 40 * math.sin(a))])
    elif kind == "cloud":
        d.arc([14 * s, 44 * s, 46 * s, 76 * s], 90, 270, fill=ink, width=wd)
        d.arc([28 * s, 22 * s, 64 * s, 58 * s], 180, 360, fill=ink, width=wd)
        d.arc([52 * s, 38 * s, 84 * s, 70 * s], 270, 450, fill=ink, width=wd)
        line([(30, 76), (68, 70)])
    else:
        line([(54, 10), (28, 52), (48, 52), (38, 88), (68, 40), (48, 40), (54, 10)])
    return _done(im, w, h)


def stamp_ready():
    w = h = 192
    im = _canvas(w, h)
    d = ImageDraw.Draw(im)
    s = SS
    d.polygon([(54 * s, 130 * s), (84 * s, 130 * s), (66 * s, 184 * s), (54 * s, 170 * s), (36 * s, 176 * s)], fill="#FF4D8D")
    d.polygon([(108 * s, 130 * s), (138 * s, 130 * s), (156 * s, 176 * s), (138 * s, 170 * s), (126 * s, 184 * s)], fill="#FF4D8D")
    pts = []
    for i in range(24):  # a scalloped seal
        a = math.radians(i * 15)
        r = 82 if i % 2 == 0 else 74
        pts.append(((96 + r * math.cos(a)) * s, (96 + r * math.sin(a)) * s))
    d.polygon(pts, fill="#C27400")
    d.ellipse([20 * s, 20 * s, 172 * s, 172 * s], fill=GOLD)
    d.ellipse([34 * s, 34 * s, 158 * s, 158 * s], outline="#FFE680", width=4 * s)
    d.polygon(_star_pts(96 * s, 98 * s, 40 * s), fill="#FFFFFF", outline="#C27400")
    return _done(im, w, h)


def sparkle(n):
    w = h = 128
    im = _canvas(w, h)
    d = ImageDraw.Draw(im)
    s = SS
    t = (n - 1) / 5.0
    grow = math.sin(t * math.pi * 0.85) if n < 6 else 0.0
    scale = 0.25 + 0.75 * grow
    alpha = 255 if n < 6 else 90
    spots = [(64, 64, 34), (30, 40, 15), (98, 38, 17), (34, 94, 13), (96, 92, 15), (64, 18, 11), (64, 112, 11)]
    for i, (x, y, r) in enumerate(spots):
        rr = r * scale
        if rr < 2:
            continue
        col = (255, 255, 255, alpha) if i % 2 == 0 else (255, 216, 77, alpha)
        d.polygon(_star_pts(x * s, y * s, rr * s, 0.28, 4, -90), fill=col)
    return _done(im, w, h)


def jobs():
    out = [("notebook", "notebook/paper_sheet.png", "paper_sheet", (), {"pil": True}),
           ("notebook", "notebook/closed.png", "closed", (), {"pil": True}),
           ("notebook", "notebook/stamp_ready.png", "stamp_ready", (), {"pil": True})]
    for i, k in enumerate(STATIONERY, 1):
        out.append(("notebook", f"notebook/stationery_{i}.png", "stationery", (k,), {"pil": True}))
    for i, k in enumerate(DOODLES, 1):
        out.append(("notebook", f"notebook/doodle_{i}.png", "doodle", (k,), {"pil": True}))
    for i in range(1, 7):
        out.append(("notebook", f"notebook/sparkle_{i}.png", "sparkle", (i,), {"pil": True}))
    return out
