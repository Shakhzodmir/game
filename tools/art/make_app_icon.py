#!/usr/bin/env python3
"""Makes the app icons of the web build from the logo (assets/images/logo/logo.png):

  python tools/art/make_app_icon.py

Writes web/apple-touch-icon.png (180x180, what iPhone uses for "Add to Home Screen"), web/icon-192.png,
web/icon-512.png (the manifest icons of Android) and web/favicon.png (48x48). The icons are opaque squares
(iOS rounds the corners itself): a violet gradient with a soft glow and the logo in the middle.
tools/build_web.sh copies them next to index.html; web/engine_template.html links them.
"""
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
LOGO = os.path.join(ROOT, "assets", "images", "logo", "logo.png")
OUT = os.path.join(ROOT, "web")
BIG = 1024


def icon(size):
    logo = Image.open(LOGO).convert("RGBA")
    logo = logo.crop(logo.getchannel("A").getbbox())
    top, bottom = (168, 140, 255), (110, 80, 214)
    bg = Image.new("RGB", (BIG, BIG))
    px = ImageDraw.Draw(bg)
    for y in range(BIG):
        t = y / (BIG - 1)
        px.line([(0, y), (BIG, y)], fill=tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    glow = Image.new("RGBA", (BIG, BIG), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse((BIG * 0.12, BIG * 0.2, BIG * 0.88, BIG * 0.8), fill=(255, 230, 250, 120))
    bg = Image.alpha_composite(bg.convert("RGBA"), glow.filter(ImageFilter.GaussianBlur(BIG * 0.08)))
    w = round(BIG * 0.86)
    h = round(logo.height * w / logo.width)
    logo = logo.resize((w, h), Image.LANCZOS)
    bg.alpha_composite(logo, ((BIG - w) // 2, (BIG - h) // 2 + round(BIG * 0.01)))
    return bg.convert("RGB").resize((size, size), Image.LANCZOS)


def main():
    for name, size in (("apple-touch-icon.png", 180), ("icon-192.png", 192), ("icon-512.png", 512), ("favicon.png", 48)):
        icon(size).save(os.path.join(OUT, name), optimize=True)
        print("wrote web/" + name, size)


if __name__ == "__main__":
    main()
