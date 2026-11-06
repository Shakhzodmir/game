"""Jukebox genre icons (96x96, ui/genres/<genre id>.png): a round candy disc in the colour of the genre's group
with a white glyph of a characteristic object. Procedural placeholders: the final art is group B3 of
docs/art-brief-chatgpt.md (genres_a / genres_b sheets) and replaces these files under the same names."""
import math

from artkit import Canvas, sd_box, sd_capsule, sd_circle, sd_ellipse, sd_poly, sd_ring, sd_star, SUB, U
from ui import finish, hl_drop, obj, heart_sdf

# group palettes: (light, base, shadow, outline)
CLASSIC = ("#E6D4FF", "#B58CFF", "#8A5CE0", "#5A32A8")
TRAD = ("#FFE0B5", "#FFA94D", "#E07A1F", "#9C4E0A")
MODERN = ("#C7ECFF", "#4DB5FF", "#2A7FD6", "#1A4E99")
GROUP = {"classical": CLASSIC, "folk": TRAD, "latin": TRAD, "eastern": TRAD}
W = "#FFFFFF"


def _glyph(name, X, Y):
    c = 48
    if name == "classical":      # violin: two bouts, a neck, a scroll
        return U(sd_ellipse(X, Y, c, 58, 15, 13), sd_ellipse(X, Y, c, 40, 11, 10), sd_capsule(X, Y, c, 36, c, 14, 2.5),
                 sd_circle(X, Y, c, 13, 4))
    if name == "folk":           # balalaika: triangle body and a long neck
        return U(sd_poly(X, Y, [(c, 40), (c - 17, 76), (c + 17, 76)]), sd_capsule(X, Y, c, 44, c, 16, 3))
    if name == "latin":          # maracas
        return U(sd_ellipse(X, Y, 34, 36, 11, 15, 0.5), sd_capsule(X, Y, 38, 48, 52, 72, 3),
                 sd_ellipse(X, Y, 62, 36, 11, 15, -0.5), sd_capsule(X, Y, 58, 48, 44, 72, 3))
    if name == "eastern":        # crescent and a star
        return U(SUB(sd_circle(X, Y, 44, 48, 22), sd_circle(X, Y, 53, 44, 19)), sd_star(X, Y, 62, 36, 8, 3.5))
    if name == "pop":
        return sd_star(X, Y, c, 50, 25, 11)
    if name == "hiphop":         # headphones
        return U(sd_ring(X, Y, c, 50, 22, 5), sd_box(X, Y, 26, 58, 6, 11, 3), sd_box(X, Y, 70, 58, 6, 11, 3))
    if name == "edm":            # bolt
        return sd_poly(X, Y, [(56, 18), (30, 54), (46, 54), (38, 80), (68, 42), (50, 42)])
    if name == "rnb":
        return heart_sdf(X, Y, c, c + 2, 1.45)
    if name == "reggae":         # sun with three bars
        return U(sd_circle(X, Y, c, 40, 14), sd_box(X, Y, c, 62, 22, 3.5, 1.5), sd_box(X, Y, c, 70, 22, 3.5, 1.5),
                 sd_box(X, Y, c, 78, 22, 3.5, 1.5))
    if name == "country":        # cactus
        return U(sd_capsule(X, Y, c, 70, c, 26, 6), sd_capsule(X, Y, 34, 56, 34, 42, 4), sd_capsule(X, Y, 34, 56, c, 56, 4),
                 sd_capsule(X, Y, 62, 50, 62, 36, 4), sd_capsule(X, Y, 62, 50, c, 50, 4))
    if name == "blues":          # harmonica
        body = sd_box(X, Y, c, 50, 28, 13, 4)
        holes = U(*[sd_box(X, Y, 25 + i * 9.6, 50, 2.4, 6.5, 1) for i in range(6)])
        return SUB(body, holes)
    if name == "bossa":          # waves
        return U(*[sd_ring(X, Y, c, 30 + k * 16, 26, 4.5) for k in range(3)]) if False else U(
            SUB(sd_ring(X, Y, c, 38, 24, 5), sd_box(X, Y, c, 20, 40, 20)),
            SUB(sd_ring(X, Y, c, 56, 24, 5), sd_box(X, Y, c, 38, 40, 20)),
            SUB(sd_ring(X, Y, c, 74, 24, 5), sd_box(X, Y, c, 56, 40, 20)))
    if name == "ambient":        # cloud
        return U(sd_circle(X, Y, 36, 54, 13), sd_circle(X, Y, 52, 46, 17), sd_circle(X, Y, 64, 56, 12),
                 sd_box(X, Y, 50, 62, 26, 8, 6))
    if name == "cinematic":      # clapperboard
        return U(sd_box(X, Y, c, 58, 26, 15, 3), sd_poly(X, Y, [(22, 38), (74, 28), (74, 40), (22, 46)]))
    if name == "chiptune":       # pixel invader
        cells = ("..#.....#..", "...#...#...", "..#######..", ".##.###.##.", "###########", "#.#######.#", "#.#.....#.#", "...##.##...")
        ds = []
        for r, row in enumerate(cells):
            for k, ch in enumerate(row):
                if ch == "#":
                    ds.append(sd_box(X, Y, 18 + k * 6 + 3, 26 + r * 6 + 3, 3, 3))
        return U(*ds)
    raise KeyError(name)


def _draw(name):
    cv = Canvas(96, 96)
    X, Y = cv.X, cv.Y
    disc = sd_circle(X, Y, 48, 48, 42)
    obj(cv, disc, GROUP.get(name, MODERN), depth=14, rim=0.4)
    cv.fill(_glyph(name, X, Y), W, 0.97)
    hl_drop(cv, 30, 24, 14, 5, -35, disc + 3, alpha=0.7)
    return finish(cv)


GENRE_IDS = ["classical", "folk", "latin", "eastern", "pop", "hiphop", "edm", "rnb", "reggae", "country", "blues",
             "bossa", "ambient", "cinematic", "chiptune"]
GENRE_FUNCS = {g: (lambda g=g: _draw(g)) for g in GENRE_IDS}
