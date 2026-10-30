#!/usr/bin/env python3
"""Draws the snapshots of tests/client/level_snapshot.lua (the world sprites and particles of the
level board, as the scripts would hand them to the engine) to a PNG: one column per frame.

    python3 tests/client/level_snapshot.py <in.json> <out.png> [x0,y0,x1,y1] [scale]

The optional crop (image pixels, y down) and scale make a contact sheet of the interesting part,
e.g. the board: 0,250,720,1050 and 0.8. Every sprite is alpha blended in z order (the board is bright, so
the sprite material is alpha too); particles are approximated by dots. Needs numpy and Pillow.
"""
import json, math, os, sys
import numpy as np
from PIL import Image, ImageDraw

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'assets', 'images')
CACHE = {}

def image_path(anim):
    head, _, rest = anim.partition('_')
    return os.path.join(ROOT, head, rest + '.png')

def load(anim):
    if anim not in CACHE:
        p = image_path(anim)
        if anim == 'white':
            im = Image.new('RGBA', (8, 8), (255, 255, 255, 255))
        else:
            im = Image.open(p).convert('RGBA')
        CACHE[anim] = im
    return CACHE[anim]

def blit(canvas, patch, cx, cy, additive):
    """patch: float RGBA (h, w, 4) straight alpha; centre at pixel (cx, cy)."""
    h, w = patch.shape[:2]
    x0, y0 = int(round(cx - w / 2)), int(round(cy - h / 2))
    H, W = canvas.shape[:2]
    sx0, sy0 = max(0, -x0), max(0, -y0)
    ex, ey = min(w, W - x0), min(h, H - y0)
    if ex <= sx0 or ey <= sy0:
        return
    p = patch[sy0:ey, sx0:ex]
    region = canvas[y0 + sy0:y0 + ey, x0 + sx0:x0 + ex]
    a = p[..., 3:4]
    if additive:
        region += p[..., :3] * a
    else:
        region[:] = p[..., :3] * a + region * (1 - a)

def draw_sprite(canvas, s):
    im = load(s['image'])
    w = max(1, int(round(im.size[0] * abs(s['sx']))))
    h = max(1, int(round(im.size[1] * abs(s['sy']))))
    if w > 3000 or h > 3000:
        return
    im2 = im.resize((w, h), Image.LANCZOS)
    if s.get('hflip'):
        im2 = im2.transpose(Image.FLIP_LEFT_RIGHT)
    if abs(s['rot']) > 0.01:
        im2 = im2.rotate(s['rot'], resample=Image.BICUBIC, expand=True)
    arr = np.asarray(im2).astype(np.float32) / 255.0
    rgb = arr[..., :3] * np.array([s['r'], s['g'], s['b']], dtype=np.float32)
    f = max(0.0, min(1.0, s['flash']))
    rgb = rgb * (1 - f) + f * arr[..., 3:4].clip(0, 1) * 0 + f
    alpha = arr[..., 3:4] * float(s['a'])
    patch = np.concatenate([rgb, alpha], axis=2)
    cx, cy = s['x'], 1280 - s['y']
    if s['clip'] < 90000:
        clip_y = 1280 - s['clip']
        # rows above the clip line (logical y > clip) are cut
        top = cy - patch.shape[0] / 2
        cut = int(round(clip_y - top))
        if cut > 0:
            patch[:max(0, cut)] = 0
    blit(canvas, patch, cx, cy, False)

def draw_particles(canvas, parts):
    img = Image.fromarray((canvas.clip(0, 1) * 255).astype(np.uint8))
    d = ImageDraw.Draw(img, 'RGBA')
    for p in parts:
        k = max(0.0, min(1.0, p['age'] / max(p['life'], 0.01)))
        reach = 70 * p['scale'] * (1 - (1 - k) ** 2)
        for i in range(p['n']):
            ang = (i / max(p['n'], 1)) * 2 * math.pi + i * 0.7
            r = reach * (0.6 + 0.4 * ((i * 37) % 10) / 10)
            x = p['x'] + math.cos(ang) * r
            y = 1280 - (p['y'] + math.sin(ang) * r)
            rad = max(1.5, 7 * p['scale'] * (1 - k))
            col = (int(p['r'] * 255), int(p['g'] * 255), int(p['b'] * 255), int(255 * (1 - k)))
            d.ellipse([x - rad, y - rad, x + rad, y + rad], fill=col)
    return np.asarray(img).astype(np.float32) / 255.0

def background(data):
    bg = Image.open(os.path.join(ROOT, 'backgrounds', 'level_bg.png')).convert('RGB')
    img = bg.copy()
    g = data['geom']
    cell = g['cell']
    cells = data['cells']
    d = ImageDraw.Draw(img, 'RGBA')
    x0, y1 = g['x0'], g['y1']
    W, H = g['W'], g['H']
    d.rounded_rectangle([x0 - 14, 1280 - y1 - 14, x0 + W * cell + 14, 1280 - y1 + H * cell + 14], radius=26, fill=(255, 255, 255, 170), outline=(155, 82, 255, 120), width=4)
    for yy in range(1, H + 1):
        for xx in range(1, W + 1):
            c = cells[(yy - 1) * W + xx - 1]
            if not c['exists']:
                continue
            px, py = x0 + (xx - 1) * cell, (1280 - y1) + (yy - 1) * cell
            col = (255, 255, 255, 240) if (xx + yy) % 2 == 0 else (239, 232, 255, 240)
            if (c.get('floor') or 0) > 0:
                col = (192, 169, 255, 255)
            d.rectangle([px, py, px + cell, py + cell], fill=col)
    return np.asarray(img).astype(np.float32) / 255.0

def render(data, shot):
    canvas = background(data).copy()
    sprites = sorted(enumerate(shot['sprites']), key=lambda t: (t[1]['z'], t[0]))
    for _, s in sprites:
        if s['a'] <= 0.001:
            continue
        draw_sprite(canvas, s)
    canvas = draw_particles(canvas, shot['particles'])
    return Image.fromarray((canvas.clip(0, 1) * 255).astype(np.uint8))

def main():
    if len(sys.argv) < 3 or sys.argv[1] in ('-h', '--help'):
        print(__doc__)
        return
    data = json.load(open(sys.argv[1]))
    out = sys.argv[2]
    crop = None
    if len(sys.argv) > 3:
        crop = tuple(int(v) for v in sys.argv[3].split(','))
    ims = []
    for shot in data['shots']:
        im = render(data, shot)
        if crop:
            im = im.crop(crop)
        if len(sys.argv) > 4:
            k = float(sys.argv[4])
            im = im.resize((int(im.size[0] * k), int(im.size[1] * k)), Image.LANCZOS)
        ims.append((shot['frame'], im))
    w, h = ims[0][1].size
    sheet = Image.new('RGB', (w * len(ims), h), (0, 0, 0))
    d = ImageDraw.Draw(sheet)
    for i, (fr, im) in enumerate(ims):
        sheet.paste(im, (i * w, 0))
        d.text((i * w + 8, 8), 'frame %d' % fr, fill=(0, 0, 0))
    sheet.save(out)
    print('saved', out, sheet.size)

main()
