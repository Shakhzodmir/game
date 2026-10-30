#!/usr/bin/env python3
"""Draws the GUI snapshots of tests/client/gui_snapshot.lua (the nodes the meta screens hand to the
engine) to a PNG.

    python3 tests/client/gui_snapshot.py <in.json> <out.png> [scale = 0.75]

Every scene of the file is drawn in order (the town with its windows, then the overlay with toasts,
modals and the fade). Boxes use their texture: atlas images from assets/images (nine-sliced when the
node has a slice), the procedural textures the scripts upload (their pixels are in the file), loose
images from their files; texts use the generated fonts with the outline and the shadow of the
node. Rotation, tint, alpha and additive blending are applied; the engine's exact text metrics,
filtering and the render script's fit are approximated. Needs numpy and Pillow.
"""
import json
import math
import os
import re
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
CLEAR = (134, 221, 255, 255)

_font_defs = {}
_font_cache = {}
_image_cache = {}
_atlas_cache = {}


def font_def(name):
    if name not in _font_defs:
        text = open(os.path.join(ROOT, 'assets', 'gen', 'fonts', name + '.font'), encoding='utf-8').read()
        ttf = re.search(r'^font:\s*"([^"]+)"', text, re.M).group(1)
        size = int(re.search(r'^size:\s*(\d+)', text, re.M).group(1))
        outline = float(re.search(r'^outline_width:\s*([\d.]+)', text, re.M).group(1))
        _font_defs[name] = (os.path.join(ROOT, ttf.lstrip('/')), size, outline)
    return _font_defs[name]


def load_font(name, px):
    key = (name, max(4, int(round(px))))
    if key not in _font_cache:
        _font_cache[key] = ImageFont.truetype(font_def(name)[0], key[1])
    return _font_cache[key]


def atlas_images(path):
    """animation id -> png path of an atlas file."""
    if path not in _atlas_cache:
        text = open(os.path.join(ROOT, path.lstrip('/')), encoding='utf-8').read()
        out = {}
        for m in re.finditer(r'animations \{\s*id: "([^"]+)"\s*images \{\s*image: "([^"]+)"', text):
            out[m.group(1)] = m.group(2)
        _atlas_cache[path] = out
    return _atlas_cache[path]


def load_png(path):
    if path not in _image_cache:
        _image_cache[path] = Image.open(os.path.join(ROOT, path.lstrip('/'))).convert('RGBA')
    return _image_cache[path]


def unpremultiply(rgba):
    arr = np.asarray(rgba).astype(np.float32)
    a = arr[..., 3:4]
    rgb = np.where(a > 0, arr[..., :3] * 255.0 / np.maximum(a, 1), 0)
    arr[..., :3] = np.clip(rgb, 0, 255)
    return Image.fromarray(arr.astype(np.uint8), 'RGBA')


def texture_image(scene, textures, node):
    """The source image of a node's texture (straight alpha RGBA) or None."""
    tex = node.get('tex')
    if not tex:
        return None
    if node.get('anim') and tex in scene['atlases']:
        png = atlas_images(scene['atlases'][tex]).get(node['anim'])
        return load_png(png) if png else None
    t = textures.get(tex)
    if not t:
        return None
    if t.get('file'):
        return load_png(t['file'])
    if t.get('hex'):
        raw = bytes.fromhex(t['hex'])
        im = Image.frombytes('RGBA', (t['w'], t['h']), raw)
        return unpremultiply(im)
    return None


def nine_slice(img, s9, w, h, k):
    """Scales img to w x h pixels keeping the borders (source px, l t r b) at scale k."""
    l, t, r, b = [int(round(v)) for v in s9]
    sw, sh = img.size
    W, H = max(1, int(round(w))), max(1, int(round(h)))
    dl, dt, dr, db = int(round(l * k)), int(round(t * k)), int(round(r * k)), int(round(b * k))
    if dl + dr > W:
        scale = W / max(1, dl + dr)
        dl, dr = int(dl * scale), int(dr * scale)
    if dt + db > H:
        scale = H / max(1, dt + db)
        dt, db = int(dt * scale), int(db * scale)
    out = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    xs_src = [0, l, sw - r, sw]
    ys_src = [0, t, sh - b, sh]
    xs_dst = [0, dl, W - dr, W]
    ys_dst = [0, dt, H - db, H]
    for j in range(3):
        for i in range(3):
            box = (xs_src[i], ys_src[j], xs_src[i + 1], ys_src[j + 1])
            dw, dh = xs_dst[i + 1] - xs_dst[i], ys_dst[j + 1] - ys_dst[j]
            if dw <= 0 or dh <= 0 or box[2] <= box[0] or box[3] <= box[1]:
                continue
            out.paste(img.crop(box).resize((dw, dh), Image.BILINEAR), (xs_dst[i], ys_dst[j]))
    return out


def tint(img, c):
    arr = np.asarray(img).astype(np.float32)
    arr[..., 0] *= c[0]
    arr[..., 1] *= c[1]
    arr[..., 2] *= c[2]
    arr[..., 3] *= c[3]
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), 'RGBA')


PIVOT_FRACTION = {
    'CENTER': (-0.5, -0.5), 'N': (-0.5, -1), 'NE': (-1, -1), 'E': (-1, -0.5), 'SE': (-1, 0),
    'S': (-0.5, 0), 'SW': (0, 0), 'W': (0, -0.5), 'NW': (0, -1),
}


def rotated_paste(canvas, img, ax, ay, cx_off, cy_off, z, add):
    """Pastes img whose centre sits at (ax + cx_off, ay + cy_off) (canvas px, y down) after rotating it
    by z degrees (counter-clockwise on screen) about the anchor (ax, ay)."""
    if abs(z) > 0.01:
        rad = math.radians(z)
        dx = cx_off * math.cos(rad) + cy_off * math.sin(rad)
        dy = -cx_off * math.sin(rad) + cy_off * math.cos(rad)
        img = img.rotate(z, expand=True, resample=Image.BICUBIC)
        cx_off, cy_off = dx, dy
    px = int(round(ax + cx_off - img.size[0] / 2))
    py = int(round(ay + cy_off - img.size[1] / 2))
    if add:
        layer = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
        layer.paste(img, (px, py))
        a = np.asarray(layer).astype(np.float32)
        base = np.asarray(canvas).astype(np.float32)
        base[..., :3] = np.clip(base[..., :3] + a[..., :3] * (a[..., 3:4] / 255.0), 0, 255)
        canvas.paste(Image.fromarray(base.astype(np.uint8), 'RGBA'))
    else:
        layer = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
        layer.paste(img, (px, py))
        canvas.alpha_composite(layer)


def wrap_text(text, font, max_w):
    lines = []
    for para in text.split('\n'):
        words = para.split(' ')
        cur = ''
        for w in words:
            trial = (cur + ' ' + w).strip()
            if font.getlength(trial) <= max_w or not cur:
                cur = trial
            else:
                lines.append(cur)
                cur = w
        lines.append(cur)
    return lines


def draw_text(canvas, node, k, H):
    name = node['font']
    path, size, outline_px = font_def(name)
    scale = node['sx'] * k
    px = size * scale
    if px < 2:
        return
    font = load_font(name, px)
    text = node.get('text') or ''
    if text == '':
        return
    if node.get('lb') and node['w'] > 0:
        lines = wrap_text(text, font, node['w'] * node['sx'] * k)
    else:
        lines = text.split('\n')
    line_h = font.size * 1.18
    widths = [font.getlength(l) for l in lines]
    tw = max(widths) if widths else 0
    th = line_h * len(lines)
    pad = int(px * 0.4) + 6
    img = Image.new('RGBA', (int(tw) + pad * 2, int(th) + pad * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    col = node['c']
    fill = (int(col[0] * 255), int(col[1] * 255), int(col[2] * 255), int(col[3] * 255))
    oc = node.get('oc') or [0, 0, 0, 0]
    sc = node.get('sc') or [0, 0, 0, 0]
    stroke = max(1, int(round(outline_px * scale))) if oc[3] > 0.01 else 0
    for i, line in enumerate(lines):
        lx = pad + (tw - widths[i]) / 2 if node['pv'] in ('CENTER', 'N', 'S') else pad
        if node['pv'] in ('E', 'NE', 'SE'):
            lx = pad + tw - widths[i]
        ly = pad + i * line_h
        if sc[3] > 0.01:
            d.text((lx, ly + 3 * scale), line, font=font,
                   fill=(int(sc[0] * 255), int(sc[1] * 255), int(sc[2] * 255), int(sc[3] * 255 * col[3])),
                   stroke_width=stroke, stroke_fill=(int(sc[0] * 255), int(sc[1] * 255), int(sc[2] * 255), int(sc[3] * 255 * col[3])))
        if stroke:
            d.text((lx, ly), line, font=font, fill=fill,
                   stroke_width=stroke, stroke_fill=(int(oc[0] * 255), int(oc[1] * 255), int(oc[2] * 255), int(oc[3] * 255 * col[3])))
        else:
            d.text((lx, ly), line, font=font, fill=fill)
    fx, fy = PIVOT_FRACTION[node['pv']]
    ax, ay = node['x'] * k, H - node['y'] * k
    # the centre of the text block relative to the anchor (y down)
    cx_off = fx * tw + tw / 2
    cy_off = -(fy * th + th / 2)
    rotated_paste(canvas, img, ax, ay, cx_off, cy_off, node['z'], node.get('add'))


def draw_box(canvas, scene, textures, node, k, H):
    sx, sy = node['sx'], node['sy']
    w, h = node['w'] * sx * k, node['h'] * sy * k
    if w < 0.5 or h < 0.5:
        return
    c = node['c']
    src = texture_image(scene, textures, node)
    if src is not None:
        if node.get('s9') and any(node['s9']):
            img = nine_slice(src, node['s9'], w, h, sx * k)
        else:
            img = src.resize((max(1, int(round(w))), max(1, int(round(h)))), Image.BILINEAR)
    elif node.get('tex'):
        return  # a texture we cannot draw (missing)
    else:
        img = Image.new('RGBA', (max(1, int(round(w))), max(1, int(round(h)))), (255, 255, 255, 255))
    img = tint(img, c)
    fx, fy = PIVOT_FRACTION[node['pv']]
    ax, ay = node['x'] * k, H - node['y'] * k
    cx_off = fx * w + w / 2
    cy_off = -(fy * h + h / 2)
    rotated_paste(canvas, img, ax, ay, cx_off, cy_off, node['z'], node.get('add'))


def render(data, scale):
    win = data['window']
    k = scale
    W, H = int(win['w'] * k), int(win['h'] * k)
    canvas = Image.new('RGBA', (W, H), CLEAR)
    for scene in data['scenes']:
        textures = scene['textures']
        for node in scene['nodes']:
            if not node['en'] or node['c'][3] <= 0.004:
                continue
            if node['k'] == 'text':
                draw_text(canvas, node, k, H)
            else:
                draw_box(canvas, scene, textures, node, k, H)
    return canvas


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    data = json.load(open(sys.argv[1]))
    scale = float(sys.argv[3]) if len(sys.argv) > 3 else 0.75
    render(data, scale).convert('RGB').save(sys.argv[2])
    print('wrote', sys.argv[2])
    return 0


if __name__ == '__main__':
    sys.exit(main())
