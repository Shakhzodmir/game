#!/usr/bin/env python3
"""Makes the map backgrounds of the game from the producer's pictures: a map tile is assets/images/mapbg/bg_<district>.png,
720x1080, RGBA, with the bottom FEATHER px fading to transparent.

The map lays the tiles of a district one over another (content/map.json tile_h 1080, tile_step 740, tile_feather 110;
client/map_model.lua, screens/map/view.lua): a tile starts 740 px above the one below it, every second tile is mirrored
left to right. Of the 1080 rows of a tile (row 0 = the top of the picture):

    rows    0..229   hidden under the opaque part of the tile above (the sky of the picture)
    rows  230..339   cross-faded with the bottom 110 rows of the tile above
    rows  340..969   seen as they are
    rows  970..1079  the feather: alpha 255 -> 0, cross-faded with rows 230..339 of the tile below

The last tile of a district of 20 levels is covered down to row 389 by the first tile of the next district, and rows
390..499 are cross-faded with its feather (behind the gate). Without the feather the stack shows a hard horizontal seam
every 740 px and next to every gate (district 16 and 17 had it for a week: ChatGPT's picture was installed as it came).

    python3 tools/art/feather_mapbg.py [district ...]   # default: every tile of assets/images/mapbg
    python3 tools/art/feather_mapbg.py --check          # only look: tools/art/tile_check.py (standard library)
    python3 tools/art/feather_mapbg.py selftest         # the checks of this script (Pillow and numpy)

The picture can be a PNG or a JPEG, any size of the same 2:3 shape (it is scaled to 720x1080), opaque. A picture of another
shape (a 1024x1024 square is the usual mistake) is refused: scaling it to 2:3 would stretch the whole tile. A district with
the producer's picture in assets/art_ready/map/map_bg_<id>.png is made from it, any other from its own file in
assets/images/mapbg (bg_<id>.png or bg_<id>.jpg). A tile that has the feather already is left alone: running it again
changes nothing. A JPEG tile becomes a PNG (the JPEG is deleted, assets/art_ready/installed.json follows).
tools/art/install_district.py and tools/art/install_ready.py put every map tile they install through feather()/write_tile(),
so it comes out feathered whatever the file was.
"""
import glob
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import installed as inst  # noqa: E402

ROOT = inst.ROOT
READY = os.path.join(ROOT, "assets", "art_ready", "map")
IMAGES = os.path.join(ROOT, "assets", "images")
OUT = os.path.join(IMAGES, "mapbg")
W, H = 720, 1080
FEATHER = 110   # the same as tools/gen_map.py TILE_FEATHER; tools/art/tile_check.py compares the files with content/map.json
EXTS = (".png", ".jpg", ".jpeg")
RATIO_TOLERANCE = 0.02   # how far width/height of a picture may be from 2:3: the rounding of a resize, never a square


def mask():
    """The alpha plane of a tile (uint8, H x W)."""
    a = np.full((H, W), 255, np.uint8)
    a[H - FEATHER:, :] = (np.linspace(1.0, 0.0, FEATHER) * 255).astype(np.uint8)[:, None]
    return a


def alpha_of(im):
    """The alpha plane (uint8) of a picture that has one, None for a picture without transparency."""
    if im.mode in ("RGBA", "LA", "PA") or (im.mode == "P" and "transparency" in im.info):
        return np.asarray(im.convert("RGBA").getchannel("A"))
    return None


def is_feathered(im):
    """True for a tile that has the feather already: 720x1080 with exactly the alpha of feather()."""
    a = alpha_of(im)
    return a is not None and a.shape == (H, W) and bool(np.array_equal(a, mask()))


def feather(im):
    """The tile made of a picture: RGBA 720x1080, the bottom FEATHER px fading to transparent. The picture is opaque (a PNG
    or a JPEG, any mode) and of the 2:3 shape; a tile that is feathered already comes out the same (feather(feather(x)) ==
    feather(x)). A picture of another shape is refused (it would be stretched) and so is one with transparency of its own
    (the game would show the hole): ValueError."""
    if abs(im.width / float(im.height) - W / float(H)) > RATIO_TOLERANCE:
        raise ValueError("the map picture is %dx%d: a map tile is portrait 2:3 (1024x1536 from ChatGPT), scaling it to 2:3 "
                         "would stretch the whole tile: ask for a 2:3 picture or crop this one" % im.size)
    a = alpha_of(im)
    if a is not None and a.min() < 250 and not is_feathered(im):
        raise ValueError("the map picture has transparency of its own (a map tile is drawn on the whole canvas; the game "
                         "makes the faded bottom): save it without alpha")
    out = im.convert("RGB").resize((W, H), Image.LANCZOS)
    out.putalpha(Image.fromarray(mask()))
    return out


def same_pixels(path, tile):
    with Image.open(path) as old:
        return old.size == tile.size and bool(np.array_equal(np.asarray(old.convert("RGBA")), np.asarray(tile)))


def write_tile(src, dst):
    """Makes the tile dst (a PNG path) of the picture file src with feather(). True when dst changed: a dst that is that tile
    already is not written again (its bytes and its time stamp stay)."""
    with Image.open(src) as im:
        tile = feather(im)
    if os.path.isfile(dst) and same_pixels(dst, tile):
        return False
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    tile.save(dst, optimize=True)
    return True


def own_files(did, out=OUT):
    """The files of this district's tile in mapbg (one is right, two are a mistake)."""
    return [p for p in (os.path.join(out, "bg_%s%s" % (did, e)) for e in EXTS) if os.path.isfile(p)]


def tile_ids(out=OUT):
    ids = set()
    for p in glob.glob(os.path.join(out, "bg_*.*")):
        base, ext = os.path.splitext(os.path.basename(p))
        if ext.lower() in EXTS:
            ids.add(base[3:])
    return sorted(ids)


def make(did, ready=READY, out=OUT, state=inst.PATH):
    """Makes mapbg/bg_<did>.png from the producer's picture or from the tile's own file. True when the file changed."""
    own = own_files(did, out)
    if len(own) > 1:
        raise SystemExit("mapbg has %s: keep one picture of the tile (the game needs bg_%s.png)"
                         % (" and ".join(os.path.basename(p) for p in own), did))
    src = os.path.join(ready, "map_bg_%s.png" % did)
    if not os.path.isfile(src):          # a district installed by tools/art/install_district.py: its own file
        if not own:
            raise SystemExit("no picture of the tile of %s: neither %s nor mapbg/bg_%s.png|jpg" % (did, src, did))
        src = own[0]
    dst = os.path.join(out, "bg_%s.png" % did)
    changed = write_tile(src, dst)
    gone = [p for p in own if p != dst]
    for p in gone:                       # a JPEG tile (no alpha) is replaced by the PNG
        os.remove(p)
    if gone:
        inst.rename([("mapbg/" + os.path.basename(p), "mapbg/bg_%s.png" % did) for p in gone], state)
    return changed or bool(gone)


def main(argv):
    if argv[:1] == ["selftest"]:
        return selftest()
    if argv[:1] == ["--check"]:
        import tile_check
        problems = tile_check.check()
        for p in problems:
            print(p)
        print("map tiles: %s" % ("%d problem(s)" % len(problems) if problems else "ok"))
        return 1 if problems else 0
    for did in argv or tile_ids():
        print(("wrote mapbg/bg_%s.png" if make(did) else "mapbg/bg_%s.png is feathered already") % did)
    return 0


# -- self test -------------------------------------------------------------------------------------------------------------

def selftest():
    import tempfile
    import to_jpeg_backgrounds as tj

    failed = []

    def check(ok, what):
        if not ok:
            failed.append(what)
            print("FAIL:", what)

    def picture(seed, mode="RGB", size=(W, H)):
        rng = np.random.RandomState(seed)
        base = np.linspace(0, 255, size[0], dtype=np.float32)[None, :, None] * np.ones((size[1], 1, 3), np.float32)
        base += rng.randint(0, 40, (size[1], size[0], 3))
        return Image.fromarray(np.clip(base, 0, 255).astype(np.uint8), "RGB").convert(mode)

    with tempfile.TemporaryDirectory() as tmp:
        out, ready, state = os.path.join(tmp, "mapbg"), os.path.join(tmp, "ready"), os.path.join(tmp, "installed.json")
        os.makedirs(out)
        os.makedirs(ready)
        inst.save({"mapbg/bg_aa.jpg", "mapbg/bg_bb.png", "keep.png"},
                  {"mapbg/bg_aa.jpg": "placeholder: x", "keep.png": "digest"}, state)

        # 1. a JPEG becomes a PNG with the alpha of feather() and exactly its own pixels
        picture(1).save(os.path.join(out, "bg_aa.jpg"), quality=90, subsampling=0)
        with Image.open(os.path.join(out, "bg_aa.jpg")) as j:
            jpeg_rgb = np.asarray(j.convert("RGB")).copy()
        check(make("aa", ready, out, state), "a JPEG tile is converted")
        png = Image.open(os.path.join(out, "bg_aa.png"))
        check(png.mode == "RGBA" and png.size == (W, H), "the tile is a 720x1080 RGBA PNG")
        arr = np.asarray(png)
        check(np.array_equal(arr[..., 3], mask()), "the alpha is the feather")
        check(np.array_equal(arr[..., :3], jpeg_rgb), "only alpha was added: the colours are those of the JPEG")
        check(int(arr[H - FEATHER:, :, 3].mean()) in (126, 127), "the mean alpha of the bottom rows is about 127")
        check(not os.path.isfile(os.path.join(out, "bg_aa.jpg")), "the JPEG is deleted")
        check(inst.load(state) == {"mapbg/bg_aa.png", "mapbg/bg_bb.png", "keep.png"}, "installed.json lists the PNG once")
        check(inst.load_sources(state) == {"mapbg/bg_aa.png": "placeholder: x", "keep.png": "digest"},
              "the notes follow the file and the others stay")

        # 2. running it again changes nothing (not even the bytes or the time of the file)
        path = os.path.join(out, "bg_aa.png")
        before, stamp = open(path, "rb").read(), os.stat(path).st_mtime_ns
        check(not make("aa", ready, out, state), "a feathered tile is left alone")
        check(open(path, "rb").read() == before and os.stat(path).st_mtime_ns == stamp, "the file is not rewritten")
        check(np.array_equal(np.asarray(feather(png)), np.asarray(png)), "feather(feather(x)) == feather(x)")

        # 3. an opaque PNG, an opaque RGBA (alpha all 255) and a palette picture are feathered, whatever their size
        for name, im in (("pn", picture(2)), ("rgba", picture(3, "RGBA")), ("pal", picture(4).convert("P")),
                         ("big", picture(5, size=(1080, 1620)))):
            im.save(os.path.join(out, "bg_%s.png" % name))
            check(make(name, ready, out, state), "%s: an opaque PNG is feathered" % name)
            t = Image.open(os.path.join(out, "bg_%s.png" % name))
            check(t.mode == "RGBA" and t.size == (W, H) and np.array_equal(np.asarray(t)[..., 3], mask()), "%s: feathered" % name)

        # 4. transparency of the picture's own is refused; two files of one tile are refused
        holes = picture(6, "RGBA")
        a = np.asarray(holes).copy()
        a[100:300, 100:300, 3] = 0
        Image.fromarray(a, "RGBA").save(os.path.join(out, "bg_holes.png"))
        try:
            make("holes", ready, out, state)
            check(False, "a picture with holes is refused")
        except ValueError:
            pass
        picture(7).save(os.path.join(out, "bg_two.jpg"))
        picture(8).save(os.path.join(out, "bg_two.png"))
        try:
            make("two", ready, out, state)
            check(False, "bg_two.png and bg_two.jpg together are refused")
        except SystemExit:
            pass

        # 4b. a picture that is not 2:3 is refused, not stretched (a 1024x1024 square from ChatGPT would come out 1.5x too
        # tall); a picture a little off 2:3 (the rounding of a resize) is accepted. The refused file is not touched.
        for size in ((1024, 1024), (1536, 1024), (1024, 1792), (720, 1280)):
            try:
                feather(picture(20, size=size))
                check(False, "a %dx%d picture is refused" % size)
            except ValueError as e:
                check("2:3" in str(e) and ("%dx%d" % size) in str(e), "the refusal names the shape and the size: %s" % e)
        for size in ((1024, 1536), (1000, 1500), (1024, 1500), (1024, 1560), (700, 1080)):
            check(feather(picture(21, size=size)).size == (W, H), "a %dx%d picture is accepted" % size)
        square = os.path.join(out, "bg_sq.png")
        picture(22, size=(1024, 1024)).save(square)
        kept = open(square, "rb").read()
        try:
            make("sq", ready, out, state)
            check(False, "a square tile file is refused")
        except ValueError:
            pass
        check(open(square, "rb").read() == kept and "mapbg/bg_sq.png" not in inst.load(state),
              "a refused tile is left as it was and is not listed")

        # 5. to_jpeg_backgrounds never turns a map tile into a JPEG (a JPEG has no alpha); a room background it does
        # (tools/art/install_district.py has its own self test: it installs a whole synthetic district)
        images = os.path.join(tmp, "images")
        os.makedirs(os.path.join(images, "mapbg"))
        big = os.path.join(images, "mapbg", "bg_big.png")
        Image.fromarray(np.random.RandomState(11).randint(0, 255, (H, W, 3), np.uint8)).save(big)   # opaque, > 200 KB
        os.makedirs(os.path.join(images, "districts", "cc"))
        room = os.path.join(images, "districts", "cc", "bg.png")
        Image.fromarray(np.random.RandomState(12).randint(0, 255, (1280, 720, 3), np.uint8)).save(room)
        listed = [os.path.relpath(p, images).replace(os.sep, "/") for p in tj.candidates(images)]
        check("mapbg/bg_big.png" not in listed, "to_jpeg_backgrounds leaves map tiles alone: %s" % listed)
        check(listed == ["districts/cc/bg.png"], "to_jpeg_backgrounds still finds the room background: %s" % listed)
    if failed:
        print("feather_mapbg selftest: %d failed" % len(failed))
        return 1
    print("feather_mapbg selftest: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
