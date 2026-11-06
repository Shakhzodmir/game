#!/usr/bin/env python3
"""Builds assets/fonts/ko/*.ttf (Korean fonts, SIL OFL 1.1) from the upstream files. Not run by CI or by the build:
the result is committed; run it only to rebuild the fonts.

  Jua            title, button           upstream: Google Fonts "Jua" (https://fonts.google.com/specimen/Jua)
  Noto Sans KR   number, body, small (Bold)    upstream: Google Fonts "Noto Sans KR" (weight 700)

Both are cut to the glyphs the game can draw: ASCII, Latin-1, the punctuation of client/i18n.lua and the 2 350
Hangul syllables of KS X 1001 (the syllables of everyday Korean). tools/gen_defold.py then lists in each .font only the
syllables the texts really use. Usage (each argument is a directory you downloaded the upstream files to):

  python3 tools/ko_fonts.py --jua DIR_WITH_Jua-Regular.ttf --noto DIR_WITH_noto-sans-kr-*-700-normal.woff

The Noto Sans KR source is the fontsource npm package @fontsource/noto-sans-kr (woff slices of weight 700, merged here).
Needs fontTools (pip install fonttools).
"""
import argparse
import glob
import os

from fontTools import merge, subset
from fontTools.ttLib import TTFont

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "fonts", "ko")


def wanted_codepoints():
    cps = set(range(0x20, 0x7F)) | set(range(0xA0, 0x100))
    cps |= {0x2013, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2026, 0x00D7, 0x2212, 0x2192, 0x2605}
    for b in range(0xB0, 0xC9):  # KS X 1001 Hangul rows (EUC-KR lead bytes 0xB0..0xC8)
        for t in range(0xA1, 0xFF):
            try:
                ch = bytes([b, t]).decode("euc_kr")
            except UnicodeDecodeError:
                continue
            if 0xAC00 <= ord(ch) <= 0xD7A3:
                cps.add(ord(ch))
    return sorted(cps)


def cut(font, dest):
    opts = subset.Options()
    opts.layout_features = ["kern", "liga"]
    opts.name_IDs = [0, 1, 2, 3, 4, 5, 6, 13, 14]
    opts.notdef_outline = True
    opts.hinting = False
    opts.desubroutinize = True
    sub = subset.Subsetter(opts)
    sub.populate(unicodes=wanted_codepoints())
    sub.subset(font)
    font.save(dest)
    print(dest, os.path.getsize(dest), "bytes,", len(font.getBestCmap()), "codepoints")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jua")
    ap.add_argument("--noto")
    a = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    if a.jua:
        cut(TTFont(os.path.join(a.jua, "Jua-Regular.ttf")), os.path.join(OUT, "Jua-KS1001.ttf"))
    if a.noto:
        files = sorted(glob.glob(os.path.join(a.noto, "noto-sans-kr-*-700-normal.woff")))
        merged = merge.Merger().merge(files)
        cut(merged, os.path.join(OUT, "NotoSansKR-Bold-KS1001.ttf"))


if __name__ == "__main__":
    main()
