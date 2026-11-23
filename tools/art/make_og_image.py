#!/usr/bin/env python3
"""Makes the picture of the link preview of the game page from the logo (assets/images/logo/logo.png):

  python tools/art/make_og_image.py

Writes web/og.png, 1200x630 (the 1.91:1 card that Facebook, Telegram, WhatsApp, Slack, iMessage and X show): the logo, large and
in the middle, on the violet gradient and the soft glow of the app icon (tools/art/make_app_icon.py), and no text.
web/engine_template.html names it in og:image and twitter:image; tools/build_web.sh copies it next to index.html.

The logo is half the width of the card (600 px of 1200): the whole word still fits when an app cuts the card to a square in the
middle (630 x 630; the G and the W of a larger logo lose their edges there). The logo is only scaled, its colours are untouched.

The file stays under 300 KB (the limit set for this picture; WhatsApp is said to drop a bigger preview). A plain full-colour
PNG of this card with a smooth glow is about 280 KB, because a glow is a gradient in two directions (one more step in every
row). One change that nobody can see keeps it at about 250 KB as a full-colour PNG (no palette, no dithering): the background
is read from one colour ramp in 64 slices (neighbouring slices differ by about one level).
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
LOGO = os.path.join(ROOT, "assets", "images", "logo", "logo.png")
OUT = os.path.join(ROOT, "web", "og.png")
W, H = 1200, 630
MAX_BYTES = 300 * 1000        # the limit for this picture (WhatsApp is said to drop a bigger preview picture)
LOGO_WIDTH = 0.50             # of the card: 600 px, inside the 630 px square that an app may cut from the middle
RAMP_STEPS = 64               # slices of the background
# the background is one scalar field s (0 = the dark bottom of the gradient, 0.5 = its light top, up to 1 = the glow) read through a
# colour ramp: the top and the bottom colours of the app icon (tools/art/make_app_icon.py) and a lighter lilac for the glow
RAMP = ((0.0, (110, 80, 214)), (0.5, (168, 140, 255)), (1.0, (226, 204, 246)))
GLOW_BOX = (0.22, 0.22, 0.78, 0.78)    # the ellipse of light, as parts of the card
GLOW_BLUR = 0.13                       # its softness, as a part of the height
GLOW_GAIN = 0.6                        # how far the glow lifts s


def background():
    """The card without the logo: float RGB, H x W x 3. s is the vertical gradient of the icon (light top, dark bottom) plus the
    blurred ellipse of light; its used range is cut into RAMP_STEPS slices and every slice gets its colour from the ramp."""
    top = np.linspace(0.5, 0.0, H)[:, None] * np.ones((1, W))
    light = Image.new("L", (W, H), 0)
    ImageDraw.Draw(light).ellipse((W * GLOW_BOX[0], H * GLOW_BOX[1], W * GLOW_BOX[2], H * GLOW_BOX[3]), fill=255)
    s = top + GLOW_GAIN * np.asarray(light.filter(ImageFilter.GaussianBlur(H * GLOW_BLUR)), dtype=np.float64) / 255.0
    lo, hi = s.min(), s.max()
    index = np.minimum(((s - lo) / (hi - lo) * RAMP_STEPS).astype(np.int64), RAMP_STEPS - 1)
    at = lo + (np.arange(RAMP_STEPS) + 0.5) * (hi - lo) / RAMP_STEPS
    stops = [p for p, _ in RAMP]
    colours = np.stack([np.interp(at, stops, [c[k] for _, c in RAMP]) for k in range(3)], axis=1)
    return np.rint(colours)[index]


def card():
    """The finished card: the logo, in the middle, over the background."""
    logo = Image.open(LOGO).convert("RGBA")
    logo = logo.crop(logo.getchannel("A").getbbox())
    w = round(W * LOGO_WIDTH)
    h = round(logo.height * w / logo.width)
    logo = np.asarray(logo.resize((w, h), Image.LANCZOS), dtype=np.float64)
    alpha = logo[..., 3:4] / 255.0
    rgb = logo[..., :3]
    x, y = (W - w) // 2, (H - h) // 2
    out = background()
    out[y:y + h, x:x + w] = rgb * alpha + out[y:y + h, x:x + w] * (1.0 - alpha)
    return Image.fromarray(np.clip(np.rint(out), 0, 255).astype(np.uint8))


def main():
    card().save(OUT, optimize=True)
    size = os.path.getsize(OUT)
    print("wrote web/og.png %dx%d, %d bytes" % (W, H, size))
    if size > MAX_BYTES:
        sys.exit("web/og.png is over %d bytes, the limit for the link-preview picture" % MAX_BYTES)


if __name__ == "__main__":
    main()
