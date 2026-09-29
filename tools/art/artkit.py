"""artkit: a tiny deterministic vector painter for GLOW's generated art.

Everything is drawn with signed distance fields (SDF) on a supersampled
float canvas (4x by default) and downscaled with LANCZOS at the end.

Conventions
-----------
* Coordinates and lengths are in OUTPUT pixels; (0, 0) is the top-left corner.
* An SDF is a float32 array (H*ss, W*ss): negative inside, positive outside,
  measured in output pixels.
* The canvas stores premultiplied RGB + alpha in float32, sRGB space.
"""
import math

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage

SS = 4
F32 = np.float32
BAYER4 = (np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]], np.float32) + 0.5) / 16 - 0.5
WHITE = np.array([1, 1, 1], F32)
BLACK = np.array([0, 0, 0], F32)
INK = "#2B2345"          # plan: text / heading outline colour


# --------------------------------------------------------------------------
# colour helpers
# --------------------------------------------------------------------------
def C(c):
    """'#RRGGBB' | (r,g,b) 0..1 | array  ->  float32 array (3,)."""
    if isinstance(c, str):
        h = c.lstrip("#")
        return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], F32) / 255.0
    return np.asarray(c, F32)


def _t(t):
    t = np.asarray(t, F32)
    return t[..., None] if t.ndim == 2 else t


def mix(a, b, t):
    a = C(a) if isinstance(a, str) else np.asarray(a, F32)
    b = C(b) if isinstance(b, str) else np.asarray(b, F32)
    return a + (b - a) * _t(t)


def lighten(c, t=0.45):
    return mix(C(c), mix(WHITE, C("#FFF4E0"), 0.3), t)


def darken(c, t=0.45):
    # cartoon shadows drift toward plum instead of grey
    return mix(C(c), C("#2A1650"), t)


def gray(c):
    c = C(c)
    return float(c @ np.array([0.299, 0.587, 0.114], F32))


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def rng(seed):
    return np.random.default_rng(seed)


# --------------------------------------------------------------------------
# SDF primitives (pure functions of coordinate arrays)
# --------------------------------------------------------------------------
def _rot(X, Y, cx, cy, ang):
    x, y = X - cx, Y - cy
    if ang:
        c, s = math.cos(-ang), math.sin(-ang)
        x, y = x * c - y * s, x * s + y * c
    return x, y


def sd_circle(X, Y, cx, cy, r):
    return np.hypot(X - cx, Y - cy) - r


def sd_ellipse(X, Y, cx, cy, rx, ry, ang=0.0):
    x, y = _rot(X, Y, cx, cy, ang)
    k0 = np.hypot(x / rx, y / ry)
    k1 = np.hypot(x / (rx * rx), y / (ry * ry))
    return k0 * (k0 - 1.0) / np.maximum(k1, 1e-6)


def sd_box(X, Y, cx, cy, hw, hh, r=0.0, ang=0.0):
    x, y = _rot(X, Y, cx, cy, ang)
    r = min(r, hw, hh)
    qx = np.abs(x) - hw + r
    qy = np.abs(y) - hh + r
    return np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - r


def sd_rect(X, Y, x0, y0, x1, y1, r=0.0):
    return sd_box(X, Y, (x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 2, (y1 - y0) / 2, r)


def sd_seg(X, Y, ax, ay, bx, by):
    px, py = X - ax, Y - ay
    ex, ey = bx - ax, by - ay
    L = ex * ex + ey * ey
    h = np.clip((px * ex + py * ey) / L, 0, 1) if L > 0 else 0 * X
    return np.hypot(px - ex * h, py - ey * h)


def sd_capsule(X, Y, ax, ay, bx, by, r):
    return sd_seg(X, Y, ax, ay, bx, by) - r


def sd_taper(X, Y, ax, ay, bx, by, ra, rb):
    """Capsule whose radius goes from ra (at a) to rb (at b)."""
    px, py = X - ax, Y - ay
    ex, ey = bx - ax, by - ay
    L = ex * ex + ey * ey
    h = np.clip((px * ex + py * ey) / max(L, 1e-9), 0, 1)
    return np.hypot(px - ex * h, py - ey * h) - (ra + (rb - ra) * h)


def _grid_window(X, Y, x0, y0, x1, y1):
    """If X, Y are a meshgrid, return index slices covering [x0,x1]x[y0,y1]; else None."""
    if X.ndim != 2 or X.shape[0] < 2 or X.shape[1] < 2:
        return None
    xs, ys = X[0], Y[:, 0]
    if not (xs[1] > xs[0] and ys[1] > ys[0]):
        return None
    c0, c1 = np.searchsorted(xs, x0), np.searchsorted(xs, x1, side="right")
    r0, r1 = np.searchsorted(ys, y0), np.searchsorted(ys, y1, side="right")
    return slice(int(r0), int(r1)), slice(int(c0), int(c1))


def _windowed(X, Y, pts, margin, fn):
    """Evaluate fn only near the points' bbox; elsewhere use distance-to-bbox (a lower bound)."""
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    x0, x1 = min(xs) - margin, max(xs) + margin
    y0, y1 = min(ys) - margin, max(ys) + margin
    w = _grid_window(X, Y, x0, y0, x1, y1)
    if w is None or (w[0].stop - w[0].start) * (w[1].stop - w[1].start) > 0.6 * X.size:
        return fn(X, Y)
    out = sd_box(X, Y, (x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 2, (y1 - y0) / 2) + margin
    out = np.maximum(out, margin * 0.5).astype(F32)
    if w[0].stop > w[0].start and w[1].stop > w[1].start:
        out[w] = fn(X[w], Y[w])
    return out



def sd_polyline(X, Y, pts, radii=None, margin=None):
    """Union of segments; radii (per point) makes a tapered stroke."""
    if margin is None and len(pts) > 3:
        m = (max(radii) if radii is not None else 0) + 48
        return _windowed(X, Y, pts, m, lambda x, y: sd_polyline(x, y, pts, radii, margin=-1))
    d = None
    for i in range(len(pts) - 1):
        (ax, ay), (bx, by) = pts[i], pts[i + 1]
        if radii is None:
            di = sd_seg(X, Y, ax, ay, bx, by)
        else:
            di = sd_taper(X, Y, ax, ay, bx, by, radii[i], radii[i + 1])
        d = di if d is None else np.minimum(d, di)
    return d


def _poly_raster(X, Y, pts):
    """SDF of a many-sided polygon via rasterisation + EDT (fast, ~1/8 px accurate)."""
    x0, y0 = float(X[0, 0]), float(Y[0, 0])
    dx = float(X[0, 1] - X[0, 0])
    dy = float(Y[1, 0] - Y[0, 0])
    im = Image.new("L", (X.shape[1], Y.shape[0]), 0)
    ImageDraw.Draw(im).polygon([((x - x0) / dx + 0.5, (y - y0) / dy + 0.5) for x, y in pts], fill=255)
    mask = np.asarray(im) > 127
    return sdf_from_mask(mask, round(1.0 / dx), pad=10 ** 6)


def sd_poly(X, Y, pts, margin=None):
    """Exact SDF of a simple polygon (list of (x, y))."""
    if margin is None and len(pts) > 5:
        return _windowed(X, Y, pts, 48, lambda x, y: sd_poly(x, y, pts, margin=-1))
    if len(pts) > 16 and X.ndim == 2 and X.shape[0] > 1 and X.shape[1] > 1:
        return _poly_raster(X, Y, pts)
    P = [(float(x), float(y)) for x, y in pts]
    n = len(P)
    d = (X - P[0][0]) ** 2 + (Y - P[0][1]) ** 2
    s = np.ones_like(X)
    j = n - 1
    for i in range(n):
        vix, viy = P[i]
        vjx, vjy = P[j]
        ex, ey = vjx - vix, vjy - viy
        wx, wy = X - vix, Y - viy
        L = ex * ex + ey * ey
        h = np.clip((wx * ex + wy * ey) / max(L, 1e-12), 0, 1)
        bx, by = wx - ex * h, wy - ey * h
        d = np.minimum(d, bx * bx + by * by)
        c1 = Y >= viy
        c2 = Y < vjy
        c3 = ex * wy > ey * wx
        flip = (c1 & c2 & c3) | (~c1 & ~c2 & ~c3)
        s = np.where(flip, -s, s)
        j = i
    return s * np.sqrt(d)


def sd_star(X, Y, cx, cy, ro, ri, n=5, rot=-math.pi / 2):
    pts = []
    for k in range(2 * n):
        r = ro if k % 2 == 0 else ri
        a = rot + k * math.pi / n
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return sd_poly(X, Y, pts)


def sd_ring(X, Y, cx, cy, r, w):
    return np.abs(np.hypot(X - cx, Y - cy) - r) - w / 2


def sd_arc(X, Y, cx, cy, r, a0, a1, w, n=48):
    """Stroke of a circular arc from angle a0 to a1 (radians, y down)."""
    pts = [(cx + r * math.cos(a0 + (a1 - a0) * i / n), cy + r * math.sin(a0 + (a1 - a0) * i / n))
           for i in range(n + 1)]
    return sd_polyline(X, Y, pts) - w / 2


def bez(p0, p1, p2, p3=None, n=24):
    """Sample a quadratic (3 pts) or cubic (4 pts) Bezier into a polyline."""
    out = []
    for i in range(n + 1):
        t = i / n
        if p3 is None:
            x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0]
            y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1]
        else:
            x = ((1 - t) ** 3 * p0[0] + 3 * (1 - t) ** 2 * t * p1[0] + 3 * (1 - t) * t * t * p2[0]
                 + t ** 3 * p3[0])
            y = ((1 - t) ** 3 * p0[1] + 3 * (1 - t) ** 2 * t * p1[1] + 3 * (1 - t) * t * t * p2[1]
                 + t ** 3 * p3[1])
        out.append((x, y))
    return out


def U(*ds):
    d = ds[0]
    for e in ds[1:]:
        d = np.minimum(d, e)
    return d


def I(*ds):
    d = ds[0]
    for e in ds[1:]:
        d = np.maximum(d, e)
    return d


def SUB(a, b):
    return np.maximum(a, -b)


def SU(a, b, k):
    """Smooth union with blend radius k (px)."""
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0, 1)
    return b + (a - b) * h - k * h * (1 - h)


# --------------------------------------------------------------------------
# canvas
# --------------------------------------------------------------------------
class Canvas:
    def __init__(self, w, h, ss=SS, bg=None, out=1):
        """w, h: size in coordinate units; ss: samples per unit; out: output pixels per unit
        (out=2 renders a 360x640 scene as a 720x1280 image with ss/out samples per output pixel)."""
        self.w, self.h, self.ss, self.out = int(w), int(h), ss, int(out)
        self.H, self.W = self.h * ss, self.w * ss
        self.cmap = None        # optional colour transform applied by paint() (e.g. a night re-light)
        self.rgb = np.zeros((self.H, self.W, 3), F32)
        self.a = np.zeros((self.H, self.W), F32)
        xs = (np.arange(self.W, dtype=F32) + 0.5) / ss
        ys = (np.arange(self.H, dtype=F32) + 0.5) / ss
        self.X, self.Y = np.meshgrid(xs, ys)
        if bg is not None:
            self.rgb[:] = C(bg)
            self.a[:] = 1

    # ---- basic helpers ---------------------------------------------------
    def blank(self):
        c = Canvas(self.w, self.h, self.ss, out=self.out)
        c.cmap = self.cmap
        return c

    def cov(self, sdf, soft=0.0):
        if soft <= 0:
            return np.clip(0.5 - sdf * self.ss, 0, 1).astype(F32)
        return smoothstep(soft, -soft, sdf).astype(F32)

    def win(self, mask, pad=2):
        """Bounding slice of a boolean mask (None if empty)."""
        rows = np.flatnonzero(mask.any(1))
        if rows.size == 0:
            return None
        cols = np.flatnonzero(mask.any(0))
        p = pad * self.ss
        return (slice(max(rows[0] - p, 0), min(rows[-1] + p + 1, self.H)),
                slice(max(cols[0] - p, 0), min(cols[-1] + p + 1, self.W)))

    def paint(self, cov, color, alpha=1.0, mode="over", win=None):
        """Composite `color` (3,) or (h,w,3) with coverage `cov`."""
        if win is None:
            win = (slice(None), slice(None))
        k = (cov * alpha).astype(F32)
        col = C(color) if isinstance(color, str) else np.asarray(color, F32)
        if self.cmap is not None and mode not in ("erase",):
            col = self.cmap(col)
        rgb, a = self.rgb[win], self.a[win]
        k3 = k[..., None]
        if mode == "over":
            rgb[:] = col * k3 + rgb * (1 - k3)
            a[:] = k + a * (1 - k)
        elif mode == "add":
            rgb[:] = rgb + col * k3
            a[:] = a + k * (1 - a)
        elif mode == "under":
            rgb[:] = rgb + col * k3 * (1 - a[..., None])
            a[:] = a + k * (1 - a)
        elif mode == "atop":
            rgb[:] = col * k3 * a[..., None] + rgb * (1 - k3)
        elif mode == "erase":
            rgb[:] = rgb * (1 - k3)
            a[:] = a * (1 - k)
        elif mode == "mul":      # multiply existing colour, keep alpha
            rgb[:] = rgb * (1 - k3 + col * k3)
        else:
            raise ValueError(mode)

    def fill(self, sdf, color, alpha=1.0, soft=0.0, mode="over"):
        pad = soft + 2
        w = self.win(sdf < pad)
        if w is None:
            return
        self.paint(self.cov(sdf[w], soft), color, alpha, mode, w)

    def stroke(self, sdf, width, color, alpha=1.0, soft=0.0, mode="over"):
        self.fill(np.abs(sdf) - width / 2, color, alpha, soft, mode)

    def fill_grad(self, sdf, stops, axis="y", p0=None, p1=None, alpha=1.0, soft=0.0, mode="over"):
        """Linear gradient fill; stops = [(t, color), ...]; axis 'y' | 'x' | (dx, dy)."""
        w = self.win(sdf < soft + 2)
        if w is None:
            return
        X, Y = self.X[w], self.Y[w]
        if axis == "y":
            v = Y
            lo, hi = (p0, p1) if p0 is not None else (Y.min(), Y.max())
        elif axis == "x":
            v = X
            lo, hi = (p0, p1) if p0 is not None else (X.min(), X.max())
        else:
            dx, dy = axis
            v = X * dx + Y * dy
            lo, hi = (p0, p1) if p0 is not None else (v.min(), v.max())
        t = np.clip((v - lo) / max(hi - lo, 1e-6), 0, 1)
        self.paint(self.cov(sdf[w], soft), ramp(t, stops), alpha, mode, w)

    def over(self, other, alpha=1.0):
        k = alpha
        self.rgb = other.rgb * k + self.rgb * (1 - other.a[..., None] * k)
        self.a = other.a * k + self.a * (1 - other.a * k)

    def under(self, other, alpha=1.0):
        a3 = self.a[..., None]
        self.rgb = self.rgb + other.rgb * alpha * (1 - a3)
        self.a = self.a + other.a * alpha * (1 - self.a)

    # ---- alpha-derived effects -------------------------------------------
    def alpha_sdf(self, thresh=0.5):
        return sdf_from_mask(self.a > thresh, self.ss)

    def outline_under(self, width, color, alpha=1.0, thresh=0.5):
        """Sticker outline: grow the current silhouette and paint beneath."""
        d = self.alpha_sdf(thresh)
        self.fill(d - width, color, alpha, mode="under")

    def shadow_under(self, dx, dy, blur, color="#000000", alpha=0.2):
        sh = shift(self.a, dx * self.ss, dy * self.ss)
        if blur > 0:
            sh = gblur(sh, blur * self.ss)
        self.paint(np.clip(sh, 0, 1), color, alpha, mode="under")

    def glow_under(self, radius, color, alpha=0.5, grow=0.0):
        m = self.a
        if grow > 0:
            m = self.cov(self.alpha_sdf() - grow)
        g = gblur(m, radius * self.ss / 2.0)
        self.paint(np.clip(g * 1.4, 0, 1), color, alpha, mode="under")

    def glow_from(self, cov, radius, color, alpha=0.5, mode="under", gain=1.4):
        g = gblur(cov, radius * self.ss / 2.0)
        self.paint(np.clip(g * gain, 0, 1), color, alpha, mode=mode)

    # ---- transforms ------------------------------------------------------
    def transformed(self, ang_deg=0.0, pivot=None, sx=1.0, sy=1.0, dx=0.0, dy=0.0):
        """Return a new canvas with this one rotated/scaled around pivot (output px)."""
        px, py = pivot if pivot is not None else (self.w / 2, self.h / 2)
        ss = self.ss
        a = math.radians(ang_deg)
        c, s = math.cos(a), math.sin(a)
        # inverse map: dst -> src (in supersampled px)
        # dst = P + R*S*(src - P) + D  =>  src = P + S^-1 R^-1 (dst - P - D)
        Px, Py = px * ss, py * ss
        Dx, Dy = dx * ss, dy * ss
        ia, ib = c / sx, s / sx
        ic, id_ = -s / sy, c / sy
        off_x = Px - ia * (Px + Dx) - ib * (Py + Dy)
        off_y = Py - ic * (Px + Dx) - id_ * (Py + Dy)
        coeffs = (ia, ib, off_x, ic, id_, off_y)
        out = self.blank()
        chans = [self.rgb[..., 0], self.rgb[..., 1], self.rgb[..., 2], self.a]
        res = []
        for ch in chans:
            im = Image.fromarray(np.ascontiguousarray(ch, F32))
            im = im.transform((self.W, self.H), Image.AFFINE, coeffs, resample=Image.BICUBIC)
            res.append(np.asarray(im, F32))
        out.rgb = np.clip(np.stack(res[:3], -1), 0, None)
        out.a = np.clip(res[3], 0, 1)
        out.rgb = np.minimum(out.rgb, out.a[..., None])
        return out

    # ---- output ----------------------------------------------------------
    def to_array(self, opaque=False, dither=0.0):
        """Downscale -> uint8 RGBA / RGB array.

        Alpha and colour are resampled with LANCZOS in premultiplied space (sharp edges). Where the
        result is only partly covered (soft shadows, glows, anti-aliased rims) the colour comes from
        an exact box average instead, so LANCZOS ringing cannot tint faint pixels (e.g. a blue
        fringe in a plum shadow). `dither` adds a deterministic ordered (Bayer) pattern of +-dither/2 levels
        before the 8-bit rounding of opaque images (kills banding in long gradients)."""
        ow, oh = self.w * self.out, self.h * self.out
        f = self.ss // self.out if self.ss % self.out == 0 else 0
        chans = [self.rgb[..., 0], self.rgb[..., 1], self.rgb[..., 2], self.a]
        out = []
        for ch in chans:
            im = Image.fromarray(np.ascontiguousarray(ch, F32))
            out.append(np.asarray(im.resize((ow, oh), Image.LANCZOS), F32))
        a = np.clip(out[3], 0, 1)
        rgb = np.clip(np.stack(out[:3], -1), 0, None)
        if opaque:
            rgb = np.clip(rgb, 0, 1) * 255
            if dither > 0:
                # ordered (Bayer 4x4) dither: breaks up banding, compresses far better than noise
                th = np.tile(BAYER4, (-(-oh // 4), -(-ow // 4)))[:oh, :ow] * dither
                rgb = rgb + th[..., None]
            return np.clip(rgb + 0.5, 0, 255).astype(np.uint8)
        rgb = np.minimum(rgb, a[..., None])
        col = np.where(a[..., None] > 1e-5, rgb / np.maximum(a[..., None], 1e-5), 0)
        if f >= 1:
            bh, bw = oh, ow
            box_rgb = self.rgb[:bh * f, :bw * f].reshape(bh, f, bw, f, 3).mean((1, 3))
            box_a = self.a[:bh * f, :bw * f].reshape(bh, f, bw, f).mean((1, 3))
            bcol = np.where(box_a[..., None] > 1e-6, box_rgb / np.maximum(box_a[..., None], 1e-6), 0)
            k = smoothstep(0.3, 0.8, a)[..., None]
            col = bcol + (col - bcol) * k
            a = np.where(box_a <= 1e-4, 0, a)
        a8 = (a * 255 + 0.5).astype(np.uint8)
        rgb8 = (np.clip(col, 0, 1) * 255 + 0.5).astype(np.uint8)
        rgb8[a8 == 0] = 0
        return np.dstack([rgb8, a8])

    def image(self, opaque=False, dither=0.0):
        arr = self.to_array(opaque, dither)
        return Image.fromarray(arr, "RGB" if opaque else "RGBA")


def edge_fade(cv, px=10.0, sides="lrtb"):
    """Fade everything to transparent within `px` of the canvas border (glows, beams, rays) so no
    sprite ends in a hard straight edge."""
    X, Y = cv.X, cv.Y
    k = np.ones_like(X)
    if "l" in sides:
        k = k * smoothstep(0.5, px, X)
    if "r" in sides:
        k = k * smoothstep(cv.w - 0.5, cv.w - px, X)
    if "t" in sides:
        k = k * smoothstep(0.5, px, Y)
    if "b" in sides:
        k = k * smoothstep(cv.h - 0.5, cv.h - px, Y)
    cv.rgb = cv.rgb * k[..., None]
    cv.a = cv.a * k


def grow(cv, l=0, t=0, r=0, b=0):
    """Return a copy of the canvas with extra transparent margins (in coordinate units)."""
    out = Canvas(cv.w + l + r, cv.h + t + b, cv.ss, out=cv.out)
    ss = cv.ss
    out.rgb[t * ss:t * ss + cv.H, l * ss:l * ss + cv.W] = cv.rgb
    out.a[t * ss:t * ss + cv.H, l * ss:l * ss + cv.W] = cv.a
    return out


def contact_shadow(cv, cx, by, rx, ry=None, alpha=0.23, blur=10.0, color="#5A3FA0"):
    """Soft ellipse under an object's base (painted beneath the drawing) so it sits on the floor."""
    ry = ry if ry is not None else max(rx * 0.14, 5.0)
    m = np.clip(0.5 - sd_ellipse(cv.X, cv.Y, cx, by, rx, ry) * cv.ss, 0, 1)
    m = gblur(m, blur * cv.ss / 2.5)
    cv.paint(np.clip(m * 1.15, 0, 1), C(color), alpha, mode="under")


class raw:
    """`with raw(cv): ...` paints without the canvas colour transform (lights, neon, lit windows)."""
    def __init__(self, cv):
        self.cv = cv

    def __enter__(self):
        self.m, self.cv.cmap = self.cv.cmap, None
        return self.cv

    def __exit__(self, *a):
        self.cv.cmap = self.m


def save_png(img, path):
    img.save(path, optimize=True)


def ramp(t, stops):
    """Piecewise-linear colour ramp; stops = [(t, colour), ...]."""
    t = np.asarray(t, F32)
    out = np.zeros(t.shape + (3,), F32)
    ts = [s[0] for s in stops]
    cs = [C(s[1]) for s in stops]
    out[:] = cs[0]
    for i in range(len(stops) - 1):
        t0, t1 = ts[i], ts[i + 1]
        k = np.clip((t - t0) / max(t1 - t0, 1e-6), 0, 1)
        seg = (t >= t0)
        val = cs[i] + (cs[i + 1] - cs[i]) * k[..., None]
        out = np.where(seg[..., None], val, out)
    return out


# --------------------------------------------------------------------------
# field helpers
# --------------------------------------------------------------------------
def sdf_from_mask(mask, ss=SS, pad=64):
    """Signed distance (output px) of a boolean mask via EDT.
    Computed in the mask's bbox + pad (output px); farther pixels get a positive lower bound."""
    mask = np.asarray(mask, bool)
    if not mask.any():
        return np.full(mask.shape, 1e4, F32)
    if mask.all():
        return np.full(mask.shape, -1e4, F32)
    rows = np.flatnonzero(mask.any(1))
    cols = np.flatnonzero(mask.any(0))
    p = pad * ss
    r0, r1 = max(rows[0] - p, 0), min(rows[-1] + p + 1, mask.shape[0])
    c0, c1 = max(cols[0] - p, 0), min(cols[-1] + p + 1, mask.shape[1])
    if (r1 - r0) * (c1 - c0) < 0.6 * mask.size:
        out = np.full(mask.shape, float(pad), F32)
        out[r0:r1, c0:c1] = sdf_from_mask(mask[r0:r1, c0:c1], ss, pad=10 ** 6)
        return out
    inside = ndimage.distance_transform_edt(mask)
    outside = ndimage.distance_transform_edt(~mask)
    d = np.where(mask, -(inside - 0.5), outside - 0.5)
    return (d / ss).astype(F32)


def opening(sdf, r, ss=SS):
    """Round convex corners by r (exact, via EDT)."""
    return sdf_from_mask(sdf < -r, ss) - r


def closing(sdf, r, ss=SS):
    """Fillet concave corners by r."""
    return sdf_from_mask(sdf < r, ss) + r


def gblur(arr, sigma):
    """Gaussian blur (sigma in array pixels); large sigmas run on a reduced grid."""
    arr = np.asarray(arr, F32)
    if sigma <= 0:
        return arr
    if sigma < 8:
        return ndimage.gaussian_filter(arr, sigma, mode="constant").astype(F32)
    f = int(sigma // 4)
    H, W = arr.shape
    Hp, Wp = -(-H // f) * f, -(-W // f) * f
    pad = np.zeros((Hp, Wp), F32)
    pad[:H, :W] = arr
    small = pad.reshape(Hp // f, f, Wp // f, f).mean((1, 3))
    small = ndimage.gaussian_filter(small, sigma / f, mode="constant")
    big = ndimage.zoom(small, f, order=1, mode="nearest", grid_mode=True)
    return big[:H, :W].astype(F32)


def shift(arr, dx, dy):
    return ndimage.shift(arr, (dy, dx), order=1, mode="constant", cval=0.0).astype(F32)


def noise2(shape, scale, seed, octaves=3):
    """Smooth value noise in [0,1]; scale = feature size in array pixels."""
    g = rng(seed)
    H, W = shape
    out = np.zeros(shape, F32)
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        s = max(scale / (2 ** o), 1.0)
        h, w = int(H / s) + 3, int(W / s) + 3
        base = g.random((h, w)).astype(F32)
        z = ndimage.zoom(base, (s, s), order=3, mode="reflect")[:H, :W]
        if z.shape != shape:
            z = np.pad(z, ((0, H - z.shape[0]), (0, W - z.shape[1])), mode="edge")
        out += z * amp
        tot += amp
        amp *= 0.5
    out /= tot
    lo, hi = np.percentile(out, 1), np.percentile(out, 99)
    return np.clip((out - lo) / max(hi - lo, 1e-6), 0, 1).astype(F32)


# --------------------------------------------------------------------------
# text
# --------------------------------------------------------------------------
_FONT_CACHE = {}


def font(path, size):
    key = (path, size)
    if key not in _FONT_CACHE:
        _FONT_CACHE[key] = ImageFont.truetype(path, size)
    return _FONT_CACHE[key]


def text_mask(cv, text, font_path, size, cx, cy, anchor="mm", tracking=0.0, sx=1.0):
    """Coverage mask (float32, canvas res) of text centred at (cx, cy)."""
    ss = cv.ss
    f = font(font_path, int(size * ss))
    im = Image.new("L", (cv.W, cv.H), 0)
    dr = ImageDraw.Draw(im)
    if tracking == 0 and sx == 1.0:
        dr.text((cx * ss, cy * ss), text, font=f, fill=255, anchor=anchor)
        return np.asarray(im, F32) / 255.0
    # manual tracking / horizontal scale: draw glyph by glyph on a wide strip
    widths = [f.getlength(ch) for ch in text]
    total = sum(widths) + tracking * ss * (len(text) - 1)
    strip = Image.new("L", (int(total + 8 * ss), cv.H), 0)
    ds = ImageDraw.Draw(strip)
    x = 4 * ss
    for ch, wch in zip(text, widths):
        ds.text((x, cy * ss), ch, font=f, fill=255, anchor="lm")
        x += wch + tracking * ss
    sw = int(strip.width * sx)
    strip = strip.resize((sw, cv.H), Image.LANCZOS)
    im.paste(strip, (int(cx * ss - sw / 2), 0))
    return np.asarray(im, F32) / 255.0


def text_sdf(cv, *args, **kw):
    m = text_mask(cv, *args, **kw)
    return sdf_from_mask(m > 0.5, cv.ss)


# --------------------------------------------------------------------------
# shading
# --------------------------------------------------------------------------
LIGHT = np.array([-0.55, -0.75, 0.9], F32)
LIGHT /= np.linalg.norm(LIGHT)


def vol(cv, sdf, base, light=None, dark=None, line=None, lw=0.0, depth=None, bulge=0.9,
        grad=0.55, lift=0.55, shade=0.65, spec=0.35, spec_pow=24, rim=0.35, alpha=1.0,
        bbox=None, grad_dir=(1.0, 1.0), flat=False, mode="over", shade_sdf=None):
    """Paint a glossy volumetric shape.

    base/light/dark: palette (light = highlight tone, dark = shadow tone).
    line/lw: outline colour/width drawn inside the silhouette.
    depth: bevel depth in px (default ~0.8 of the thickest part).
    grad: strength of the base gradient toward `dark` at the bottom-right.
    """
    w = cv.win(sdf < 1.5)
    if w is None:
        return
    s = sdf[w]
    X, Y = cv.X[w], cv.Y[w]
    base = C(base)
    light = C(light) if light is not None else lighten(base, 0.5)
    dark = C(dark) if dark is not None else darken(base, 0.5)
    line = C(line) if line is not None else dark
    inner = s + lw
    # shade_sdf: a smoother companion shape used only for the lighting normals
    d = np.maximum(-(shade_sdf[w] + lw if shade_sdf is not None else inner), 0)
    if depth is None:
        depth = max(float(d.max()) * 0.8, 1.0)
    t = np.clip(d / depth, 0, 1)
    h = 1 - (1 - t) ** 2
    gy, gx = np.gradient(h)
    k = depth * bulge * cv.ss
    nx, ny, nz = -gx * k, -gy * k, np.ones_like(h)
    nl = np.sqrt(nx * nx + ny * ny + 1)
    nx, ny, nz = nx / nl, ny / nl, nz / nl
    lam = nx * LIGHT[0] + ny * LIGHT[1] + nz * LIGHT[2]
    ssh = lam - LIGHT[2]

    # base diagonal gradient over the shape's bbox
    m = s < 0
    if bbox is None:
        if m.any():
            xs, ys = X[m], Y[m]
            bbox = (xs.min(), ys.min(), xs.max(), ys.max())
        else:
            bbox = (X.min(), Y.min(), X.max(), Y.max())
    x0, y0, x1, y1 = bbox
    gdx, gdy = grad_dir
    u = (gdx * (X - x0) / max(x1 - x0, 1) + gdy * (Y - y0) / max(y1 - y0, 1)) / max(gdx + gdy, 1e-6)
    col = np.broadcast_to(base, X.shape + (3,)).copy()
    col = mix(col, dark, smoothstep(0.35, 1.05, u) * grad)
    col = mix(col, light, smoothstep(0.45, -0.05, u) * lift * 0.55)
    if not flat:
        col = mix(col, light, np.clip(ssh * 2.2, 0, 1) * lift)
        col = mix(col, dark, np.clip(-ssh * 1.6, 0, 1) * shade)
        # bounce light on the lower-right rim
        rr = np.clip(nx * 0.55 + ny * 0.85, 0, 1) * (1 - t) ** 2
        col = mix(col, light, np.clip(rr * 1.6, 0, 1) * rim * (inner < 0))
        if spec > 0:
            H = LIGHT + np.array([0, 0, 1], F32)
            H /= np.linalg.norm(H)
            nh = np.clip(nx * H[0] + ny * H[1] + nz * H[2], 0, 1)
            sp = nh ** spec_pow * (t < 0.999)
            col = col + (1 - col) * _t(np.clip(sp * spec, 0, 1))
    if lw > 0:
        ci = np.clip(0.5 - inner * cv.ss, 0, 1)
        col = mix(line, col, ci)
    cv.paint(np.clip(0.5 - s * cv.ss, 0, 1), col, alpha, mode, w)


def inset(cv, sdf, color, depth=4.0, shadow=0.45, hl=0.35, line=None, lw=0.0, alpha=1.0,
          dark=None, light=None):
    """A recessed area: flat colour, inner shadow along the top-left edge,
    soft reflected light along the bottom-right edge."""
    w = cv.win(sdf < 1.5)
    if w is None:
        return
    s = sdf[w]
    col = np.broadcast_to(C(color), s.shape + (3,)).copy()
    dark = C(dark) if dark is not None else darken(color, 0.6)
    light = C(light) if light is not None else lighten(color, 0.4)
    gy, gx = np.gradient(s)                      # outward normal direction
    nrm = np.hypot(gx, gy) + 1e-6
    tl = np.clip((gx * -0.55 + gy * -0.83) / nrm, 0, 1)
    br = np.clip((gx * 0.55 + gy * 0.83) / nrm, 0, 1)
    col = mix(col, dark, smoothstep(depth, 0.0, -s) * (0.3 + 0.7 * tl) * shadow)
    col = mix(col, light, smoothstep(depth * 0.6, 0.0, -s) * br * hl)
    if lw > 0 and line is not None:
        col = mix(C(line), col, np.clip(0.5 - (s + lw) * cv.ss, 0, 1))
    cv.paint(np.clip(0.5 - s * cv.ss, 0, 1), col, alpha, "over", w)


def droplet(cv, pts, radii, alpha=0.7, clip_sdf=None, color=WHITE, soft=0.6):
    """Curved tapered highlight (the plan's 'white 70% droplet')."""
    d = sd_polyline(cv.X, cv.Y, pts, radii)
    if clip_sdf is not None:
        d = np.maximum(d, clip_sdf)
    cv.fill(d, color, alpha, soft=soft)


def gloss_band(cv, sdf, top, bottom, alpha=0.35, inset_px=3.0):
    """Horizontal glossy band on the upper part of a shape, clipped inside."""
    d = np.maximum(sdf + inset_px, np.maximum(top - cv.Y, cv.Y - bottom))
    w = cv.win(d < 1)
    if w is None:
        return
    fade = smoothstep(bottom, top, cv.Y[w])
    cv.paint(np.clip(0.5 - d[w] * cv.ss, 0, 1) * fade, WHITE, alpha, "over", w)


# --------------------------------------------------------------------------
# v2 "candy" style: bright glossy shapes (docs/design/art-direction.md)
# --------------------------------------------------------------------------
def candy(cv, sdf, pal, lw=2.6, depth=None, grad_dir=(1.0, 1.0), stops=(0.0, 0.45, 1.0), bbox=None,
          lift=0.55, shade=0.45, rim=0.45, bulge=0.9, alpha=1.0, mode="over", shade_sdf=None, spec=0.0,
          inner_glow=0.0):
    """Glossy candy fill.

    pal = (light, base, shadow, outline): diagonal gradient light (top-left) -> base -> shadow
    (bottom-right), a pillow bevel lit from the top-left, a soft bounce-light rim on the lower
    right and an outline of `lw` px drawn inside the silhouette in the outline colour.
    """
    light, base, shadow, line = [C(c) for c in pal]
    w = cv.win(sdf < 1.5)
    if w is None:
        return
    s = sdf[w]
    X, Y = cv.X[w], cv.Y[w]
    m = s < 0
    if bbox is None:
        if m.any():
            xs, ys = X[m], Y[m]
            bbox = (xs.min(), ys.min(), xs.max(), ys.max())
        else:
            bbox = (X.min(), Y.min(), X.max(), Y.max())
    x0, y0, x1, y1 = bbox
    gdx, gdy = grad_dir
    u = (gdx * (X - x0) / max(x1 - x0, 1) + gdy * (Y - y0) / max(y1 - y0, 1)) / max(abs(gdx) + abs(gdy), 1e-6)
    if gdx < 0:
        u = u + abs(gdx) / (abs(gdx) + abs(gdy))
    col = ramp(np.clip(u, 0, 1), [(stops[0], light), (stops[1], base), (stops[2], shadow)])
    inner = s + lw
    d = np.maximum(-(shade_sdf[w] + lw if shade_sdf is not None else inner), 0)
    if depth is None:
        depth = max(float(d.max()) * 0.7, 1.0)
    t = np.clip(d / depth, 0, 1)
    h = 1 - (1 - t) ** 2
    gy, gx = np.gradient(h)
    k = depth * bulge * cv.ss
    nx, ny = -gx * k, -gy * k
    nl = np.sqrt(nx * nx + ny * ny + 1)
    nx, ny, nz = nx / nl, ny / nl, 1 / nl
    lam = nx * LIGHT[0] + ny * LIGHT[1] + nz * LIGHT[2]
    ssh = lam - LIGHT[2]
    hi = mix(light, WHITE, 0.35)
    col = mix(col, hi, np.clip(ssh * 2.4, 0, 1) * lift)
    col = mix(col, shadow, np.clip(-ssh * 1.8, 0, 1) * shade)
    if rim > 0:
        rr = np.clip(nx * 0.45 + ny * 0.9, 0, 1) * (1 - t) ** 1.5
        col = mix(col, mix(base, light, 0.75), np.clip(rr * 2.0, 0, 1) * rim * (inner < 0))
    if inner_glow > 0:
        col = mix(col, light, smoothstep(0.35, 1.0, t) * inner_glow)
    if spec > 0:
        Hh = LIGHT + np.array([0, 0, 1], F32)
        Hh /= np.linalg.norm(Hh)
        nh = np.clip(nx * Hh[0] + ny * Hh[1] + nz * Hh[2], 0, 1)
        sp = nh ** 30 * (t < 0.999)
        col = col + (1 - col) * _t(np.clip(sp * spec, 0, 1))
    if lw > 0:
        ci = np.clip(0.5 - inner * cv.ss, 0, 1)
        col = mix(line, col, ci)
    cv.paint(np.clip(0.5 - s * cv.ss, 0, 1), col, alpha, mode, w)


def pal4(light, base, shadow, line):
    return (light, base, shadow, line)


def auto_pal(base, line_t=0.45):
    """Derive a candy palette (light, base, shadow, outline) from one colour."""
    b = C(base)
    lt = mix(b, WHITE, 0.55)
    sh = mix(b, C("#3B1E8A"), 0.18)
    ln = mix(b, C("#2A1650"), line_t)
    return (lt, b, sh, ln)


def gloss(cv, sdf_shape, clip, alpha=0.8, soft=0.7, color=WHITE):
    """White glossy highlight shape clipped inside `clip` (sdf)."""
    d = np.maximum(sdf_shape, clip)
    cv.fill(d, color, alpha, soft=soft)


def gloss_drop(cv, cx, cy, rx, ry, ang, clip, alpha=0.8, soft=0.7):
    gloss(cv, sd_ellipse(cv.X, cv.Y, cx, cy, rx, ry, ang), clip, alpha, soft)


def soft_shadow(cv, dx=0.0, dy=2.5, blur=2.5, color="#5A3FA0", alpha=0.33):
    cv.shadow_under(dx, dy, blur, color, alpha)


def sparkle4(cv, x, y, r, color=WHITE, alpha=1.0, thin=0.28, glow=0.0, glow_color=None):
    d = opening(sd_star(cv.X, cv.Y, x, y, r, r * thin, n=4, rot=-math.pi / 2), max(r * 0.04, 0.3))
    if glow > 0:
        cv.glow_from(np.clip(0.5 - d * cv.ss, 0, 1), glow, glow_color or color, 0.7 * alpha, mode="over")
    cv.fill(d, color, alpha)


def fit(cv, box, cx=None, cy=None, thresh=0.5):
    """Scale + move the drawing so its alpha bbox's larger side == box, centred at (cx, cy)."""
    a = cv.a > thresh
    rows = np.flatnonzero(a.any(1))
    cols = np.flatnonzero(a.any(0))
    ss = cv.ss
    x0, x1 = cols[0] / ss, (cols[-1] + 1) / ss
    y0, y1 = rows[0] / ss, (rows[-1] + 1) / ss
    k = box / max(x1 - x0, y1 - y0)
    cx = cv.w / 2 if cx is None else cx
    cy = cv.h / 2 if cy is None else cy
    mx, my = (x0 + x1) / 2, (y0 + y1) / 2
    return cv.transformed(0, pivot=(mx, my), sx=k, sy=k, dx=cx - mx, dy=cy - my)


def bbox_px(cv, thresh=0.5):
    a = cv.a > thresh
    rows = np.flatnonzero(a.any(1))
    cols = np.flatnonzero(a.any(0))
    ss = cv.ss
    return cols[0] / ss, rows[0] / ss, (cols[-1] + 1) / ss, (rows[-1] + 1) / ss


def svg_path(d, scale=1.0, ox=0.0, oy=0.0, n=16):
    """Tiny SVG path parser (M L C Q Z, absolute) -> list of polygons (lists of points)."""
    import re
    toks = re.findall(r"[MLCQZ]|-?\d*\.?\d+", d)
    polys, cur, i = [], [], 0
    pen = (0.0, 0.0)
    cmd = None

    def P(x, y):
        return (ox + float(x) * scale, oy + float(y) * scale)
    while i < len(toks):
        tk = toks[i]
        if tk in "MLCQZ":
            cmd = tk
            i += 1
            if cmd == "Z":
                if cur:
                    polys.append(cur)
                cur = []
            continue
        if cmd == "M":
            if cur:
                polys.append(cur)
            pen = P(toks[i], toks[i + 1])
            cur = [pen]
            i += 2
            cmd = "L"
        elif cmd == "L":
            pen = P(toks[i], toks[i + 1])
            cur.append(pen)
            i += 2
        elif cmd == "C":
            p1, p2, p3 = P(toks[i], toks[i + 1]), P(toks[i + 2], toks[i + 3]), P(toks[i + 4], toks[i + 5])
            cur += bez(pen, p1, p2, p3, n=n)[1:]
            pen = p3
            i += 6
        elif cmd == "Q":
            p1, p2 = P(toks[i], toks[i + 1]), P(toks[i + 2], toks[i + 3])
            cur += bez(pen, p1, p2, n=n)[1:]
            pen = p2
            i += 4
        else:
            i += 1
    if cur:
        polys.append(cur)
    return polys


def rim_gloss(cv, sdf, cx, cy, a_mid_deg, a_span_deg, inset_px, width, alpha=0.8, soft=0.6, color=WHITE,
              power=0.6):
    """Crescent highlight that hugs the inside of a silhouette around angle a_mid (deg, y down)."""
    X, Y = cv.X, cv.Y
    ang = np.arctan2(Y - cy, X - cx)
    am, sp = math.radians(a_mid_deg), math.radians(a_span_deg)
    da = (ang - am + math.pi) % (2 * math.pi) - math.pi
    taper = np.clip(1 - (da / sp) ** 2, 0, 1) ** power
    half = width / 2 * taper
    d = np.abs(sdf + inset_px + width / 2) - half
    d = np.where(taper <= 0.02, 1e3, d).astype(F32)
    cv.fill(d, color, alpha, soft=soft)
