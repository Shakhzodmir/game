"""Extra songs: bossa, ambient, cinematic, chiptune. Same SONGS format as songs.py."""
import numpy as np

import dsp
import music as M
import songs as S
from dsp import TAU, midi_hz, nsamp
from songs import (chord_notes, comp, hits, kits, lay, line, mono, root_of, room, echo, loop_filter, sw, tune, voicing,
                   v_chip, v_tri, v_pad, v_strings, v_nylon, v_vibes, v_epiano, v_brass, v_sub, v_celesta, no_root,
                   guide, strum_comp, choir_pad, v_upright, walk)


def arr(phr, order, plen, octs=None):
    """Lay 4-bar (plen) phrases {letter: tune events} in `order`, optionally shifted by octs[i] semitones."""
    out = []
    for i, ch in enumerate(order):
        for b, d, m, v in phr[ch]:
            out.append((b + i * plen * 4, d, m + (octs[i] if octs else 0), v))
    return out


def phrases(texts, tonic, octave):
    return {k: tune(v, tonic, octave) for k, v in texts.items()}


def pads(s, voice_fn, lo, hi, center, wet=0.3, t60=2.0, cutoff=4500, pick=no_root, key="pad"):
    vo = voicing(s.chords, lo, hi, center, pick)
    buf = s.zeros()
    for c, v in zip(s.chords, vo):
        for j, m in enumerate(v):
            s.add(buf, voice_fn(s, m, c.dur * s.bs, j), c.start - 0.08)
    return room(s, loop_filter(s, buf, "lp", cutoff), wet, t60, key, damp=4000)


# ------------------------------------------------------------------ bossa

def bossa(s, mode):
    r = dsp.rng(s.id, "bossa")
    t, ch = s.tonic, s.chords
    k = kits(s, "jazz", "latin")
    d = s.zeros()
    if mode == "sunday":
        hits(s, d, k["rim"], ["x..x..x...x..x..", "..x..x...x..x..."], r, gain=0.7)
        hits(s, d, k["cabasa"], "x.o.x.o.x.o.x.o.", r, gain=0.5)
        hits(s, d, k["feather"], "X.....x.X.....x.", r, gain=0.6)
    elif mode == "samba":
        hits(s, d, k["feather"], "X..xX..xX..xX..x", r, gain=0.7)
        hits(s, d, k["cabasa"], "xoxoxoxoxoxoxoxo", r, gain=0.45)
        hits(s, d, k["chick"], "..x...x...x...x.", r, gain=0.4)
    else:
        hits(s, d, k["cabasa"], "o.x.o.x.o.x.o.x.", r, gain=0.5)
        hits(s, d, k["rim"], "x..x....x..x....", r, gain=0.4)
    d = room(s, d, 0.14, 0.9, "drums", damp=6000)
    out = {"drums": d}
    vo = voicing(ch, 52, 72, 62, no_root)
    if mode == "moon":
        ep = comp(s, ch, voicing(ch, 55, 76, 65, guide), [(0, 1.4, 0.6), (1.5, 0.45, 0.45), (2.5, 1.4, 0.5)],
                  lambda ss, m, du, v: v_epiano(ss, m, du, v, bright=0.6), r=r)
        out["keys"] = room(s, ep, 0.25, 1.5, "keys", damp=5000)
        arp = s.zeros()
        for c, v in zip(ch, vo):
            for q in range(int(c.dur * 2)):
                s.add(arp, v_nylon(s, v[q % len(v)], 0.5, 0.55), c.start + q * 0.5)
        out["guitar"] = room(s, arp, 0.16, 1.0, "gtr", damp=5000)
    else:
        def clave(c, i):
            base = [(0, 0.9, 0.75), (1.5, 0.45, 0.62)]
            return base + ([(2.5, 0.45, 0.62), (3.5, 0.45, 0.62)] if c.dur >= 4 else [(1, 0.45, 0.5)])
        g = strum_comp(s, ch, vo, clave, r=r, bright=0.3, t60=1.1, mute=0.1, spread=0.012)
        out["guitar"] = room(s, g, 0.16, 1.0, "gtr", damp=5000)

    if mode == "samba":
        w = walk(s, 33, 50)
        b = s.zeros()
        for bt, m, v in w:
            s.add(b, v_upright(s, m, 0.9, v), bt)
    else:
        def bass(c, n, i):
            R = root_of(c, 40, 33, 47)
            F = R + 7 if R + 7 <= 50 else R - 5
            return [(0, 1.4, R, 0.9), (1.5, 0.9, F, 0.75)] + ([(2.5, 0.9, R, 0.8), (3.5, 0.45, F, 0.6)] if c.dur >= 4 else [])
        b = line(s, ch, bass, v_upright, r=r)
    out["bass"] = room(s, loop_filter(s, b, "lp", 1200), 0.06, 0.6, "bass", damp=2500)
    T = {"sunday": ({"A": "r:.5 3:.5 5:1 3:.5 2:.5 1:1 | 2:1 3:1 5:2", "B": "5:.5 6:.5 1+:1 6:.5 5:.5 3:1 | 2:1.5 1:.5 2:2",
                     "C": "3:.5 5:.5 6:1 5:.5 3:.5 2:1 | 3:3 r:1", "D": "6:.5 1+:.5 3+:1 2+:.5 1+:.5 6:1 | 5:2 3:1 5:1",
                     "E": "5:1 3:.5 2:.5 1:1 3:1 | 2:2 1:2"}, "ABCDE", 2),
         "samba": ({"A": "1:.5 2:.5 3:1 5:1 3:.5 2:.5 | 3:1 2:1 1:2 | 6-:.5 1:.5 2:1 3:1 5:1 | 3:2 2:1 r:1",
                    "B": "5:1 6:.5 5:.5 3:1 2:1 | 1:1 2:1 3:2 | 6:.5 5:.5 3:.5 2:.5 1:1 2:1 | 1:4"}, "AB", 4),
         "moon": ({"A": "3:2 5:1 6:1 | 5:3 r:1 | 6:1.5 5:.5 3:1 2:1 | 3:4", "B": "2:1 3:1 5:2 | 6:2 5:1 3:1 | 2:2 1:1 2:1 | 1:4"},
                  "AB", 4)}[mode]
    tn = arr(phrases(T[0], t, 4), T[1], T[2])
    if mode == "sunday":
        lead = mono(s, tn, "flute", key="flute")
        lead = room(s, echo(s, lead, 0.75, 0.15, 0.35, 2, 4000), 0.25, 1.4, "flute", damp=5000)
        out["lead"] = lead
        out["vibes"] = room(s, comp(s, ch, voicing(ch, 62, 82, 72, guide), lambda c, i: [(0, 3.4 if c.dur >= 4 else 1.8, 0.5)],
                                    v_vibes, r=r), 0.25, 1.6, "vibes", damp=5000)
    elif mode == "samba":
        out["lead"] = room(s, lay(s, lambda ss, m, du, v: v_vibes(ss, m + 12, du, v, trem=5.5), tn, swing=0.1, r=r, jit=0.004),
                           0.25, 1.4, "lead", damp=5000)
    else:
        out["lead"] = room(s, mono(s, tn, "bell", key="bell"), 0.3, 1.6, "lead", damp=5000)
    return out


# ---------------------------------------------------------------- ambient

def pluck_glass(s, m, d=1.5, v=0.7):
    n = nsamp(d, s.sr)
    t = np.arange(n) / s.sr
    f = midi_hz(m)
    x = sum(a * np.sin(TAU * f * h * t) * np.exp(-t / tau) for h, a, tau in ((1, 1, 0.9), (2, 0.35, 0.4), (3, 0.12, 0.2)))
    return dsp.fade(x, s.sr, 0.003, 0.05) * v


def ambient(s, mode):
    r = dsp.rng(s.id, "amb")
    t, ch = s.tonic, s.chords
    out = {}
    out["pad"] = pads(s, lambda ss, m, du, j: v_pad(ss, m, du, 1.0, cutoff=1300, att=2.0, rel=2.0, k=j), 50, 72, 60,
                      wet=0.3, t60=2.2, cutoff=2500)
    drone = line(s, ch, lambda c, n, i: [(0, c.dur * 0.97, root_of(c, 30, 24, 38) if mode != "deep" else 30 - (c.root - t) % 12 // 7 * 0 , 0.9)],
                 v_sub)
    out["bass"] = loop_filter(s, drone, "lp", 300)
    if mode == "cloud":
        tn = tune("3:2 5:2 | 6:3 5:1 | 3:2 2:2 | 1:4 | 5:2 6:2 | 1+:3 6:1 | 5:2 3:2 | 2:2 r:2", t, 5)
        out["celesta"] = room(s, lay(s, v_celesta, tn, r=r, jit=0.01), 0.35, 2.0, "bells", damp=5000)
    elif mode == "deep":
        tn = tune("1:3 r:1 | 5:2 3:2 | r:4 | 6:3 5:1 | 3:3 r:1 | 2:2 1:2 | r:4 | 5:4", t, 4)
        out["lead"] = room(s, echo(s, lay(s, pluck_glass, tn, r=r), 1.5, 0.25, 0.4, 3, 3000),
                           0.3, 2.0, "glass", damp=4000)
    else:
        arp = s.zeros()
        for c in ch:
            tones = chord_notes(c, 66, 90, [0, 4, 7, 14])[:6]
            for q in range(int(c.dur * 2)):
                s.add(arp, pluck_glass(s, tones[[0, 2, 4, 3, 5, 1][q % 6] % len(tones)], 1.0, 0.5), c.start + q * 0.5)
        out["arp"] = room(s, echo(s, arp, 0.75, 0.3, 0.45, 3, 3500), 0.3, 1.8, "arp", damp=4000)
    return out


# -------------------------------------------------------------- cinematic

def timp(s, m, v=1.0, d=1.2):
    n = nsamp(d, s.sr)
    t = np.arange(n) / s.sr
    f = midi_hz(m) * (1 + 0.12 * np.exp(-t / 0.05))
    ph = np.cumsum(TAU * f / s.sr)
    x = np.sin(ph) * np.exp(-t / 0.45) + 0.3 * np.sin(1.5 * ph) * np.exp(-t / 0.2)
    x += 0.5 * dsp.lowpass(dsp.rng("timp", m).standard_normal(n), 900, s.sr, 2) * np.exp(-t / 0.02)
    return dsp.fade(x, s.sr, 0.001, 0.05) * v


def snare(s, v=1.0):
    n = nsamp(0.14, s.sr)
    t = np.arange(n) / s.sr
    x = dsp.bandpass(dsp.rng("snr", 1).standard_normal(n), 1500, 7000, s.sr) * np.exp(-t / 0.05)
    return dsp.fade(x, s.sr, 0.0005, 0.02) * v


def cinema(s, mode):
    r = dsp.rng(s.id, "cin")
    t, ch = s.tonic, s.chords
    out = {}
    out["strings"] = pads(s, lambda ss, m, du, j: v_strings(ss, m, du, 1.0, k=j), 52, 79, 64, wet=0.2, t60=1.4, cutoff=2200)
    d = s.zeros()
    for c in ch:
        if mode == "epic" or int(c.start) % 8 == 0:
            s.add(d, timp(s, root_of(c, 43, 38, 50) % 128, 1.0), c.start)
        if mode != "hero":
            for b in (2, 3) if mode == "epic" else (2,):
                s.add(d, timp(s, root_of(c, 43, 38, 50), 0.6), c.start + b)
    if mode != "hero":  # snare roll into the last bars of each 8-bar block and the loop end
        last = s.bars * 4
        for end in (last, last - 16 if s.bars >= 12 else None):
            if end is None or end < 8:
                continue
            for q in range(16):
                s.add(d, snare(s, 0.25 + 0.75 * q / 16), end - 4 + q * 0.25)
        if mode == "epic":
            for bar in range(s.bars):
                s.add(d, snare(s, 0.7), bar * 4 + 1)
                s.add(d, snare(s, 0.7), bar * 4 + 3)
    out["drums"] = room(s, loop_filter(s, d, "lp", 4500), 0.15, 1.2, "drums", damp=3500)
    pz = s.zeros()
    if mode == "quest":  # pizzicato bounce
        for c, v in zip(ch, voicing(ch, 55, 79, 66, no_root)):
            for q in range(int(c.dur * 2)):
                s.add(pz, v_nylon(s, v[q % len(v)], 0.3, 0.7), c.start + q * 0.5)
        out["guitar"] = room(s, pz, 0.1, 1.0, "pizz", damp=5000)
    def bass(c, n, i):
        R = root_of(c, 36, 31, 46)
        return [(0, c.dur * 0.95, R, 0.9)] if mode == "hero" else [(q * 1.0, 0.9, R + (12 if q % 4 == 3 else 0), 0.9) for q in range(int(c.dur))]
    out["bass"] = loop_filter(s, line(s, ch, bass, v_upright, r=r), "lp", 500)
    T = {"hero": ({"A": "1:2 5:2 | 6:1 5:1 3:2 | 1+:3 6:1 | 5:4", "B": "3:2 5:2 | 6:2 1+:2 | 2+:3 1+:1 | 1+:4",
                   "C": "1+:2 3+:2 | 2+:2 1+:2 | 5:2 6:2 | 5:4"}, "ABC", 4),
         "quest": ({"A": "1:1 1:.5 2:.5 3:1 5:1 | 6:1 5:1 3:2 | 2:1 3:.5 5:.5 6:1 5:1 | 3:2 2:2",
                    "B": "5:1 6:.5 1+:.5 3+:1 1+:1 | 6:1 5:1 3:2 | 2:1 3:1 5:1 6:1 | 5:4",
                    "C": "1+:1 1+:.5 2+:.5 3+:1 1+:1 | 6:2 5:2 | 3:1 5:1 6:1 2+:1 | 1+:4"}, "ABC", 4),
         "epic": ({"A": "3:2 5:2 | 6:3 5:1 | 3:2 1:2 | 2:3 3:1", "B": "5:2 1+:2 | 6:2 5:2 | 3:2 6:2 | 5:4",
                   "C": "1+:2 3+:2 | 2+:3 1+:1 | 6:2 1+:2 | 2+:3 3+:1", "D": "3+:2 5+:2 | 6+:2 5+:2 | 3+:2 2+:2 | 1+:4"},
                  "ABCDABCD", 2)}[mode]
    T = ({"hero": T[0], "quest": T[0], "epic": T[0]}[mode], T[1], T[2])
    if mode == "epic":
        T = ({k: v for k, v in T[0].items()}, "AABCAABD" if False else "ABCD", 4)
    tn = arr(phrases(T[0], t, 4), T[1], T[2], None if mode != "hero" else [0, 0, 0])
    tn = [e for e in tn if e[0] < s.bars * 4]
    out["brass"] = room(s, lay(s, lambda ss, m, du, v: v_brass(ss, m, du, v * 0.9), tn, r=r), 0.12, 1.2, "brass", damp=3000)
    if mode == "epic":
        out["choir"] = choir_pad(s, ch, level=1.0)
    return out


# --------------------------------------------------------------- chiptune

def chip(s, mode):
    r = dsp.rng(s.id, "chip")
    t, ch = s.tonic, s.chords
    k = kits(s, "chip")
    d = s.zeros()
    if mode == "boss":
        hits(s, d, k["kick"], ["X..xX..xX..xX.x.", "X..xX..xX.x.X..x"], r, jit=0)
        hits(s, d, k["snare"], "....X.......X...", r, jit=0)
        hits(s, d, k["snare"], {3: "............xxxx", 7: "............xxxx", 11: "............xxxx", 15: "..x.x.x.xxxxxxxx"}, r, jit=0, gain=0.7)
        hits(s, d, k["hat"], "x.o.x.o.x.o.x.o.", r, gain=0.6, jit=0)
    else:
        hits(s, d, k["kick"], "X.......X.x.....", r, jit=0)
        hits(s, d, k["snare"], "....X.......X...", r, jit=0)
        hits(s, d, k["hat"], "x.o.x.o.x.o.x.o.", r, gain=0.7, jit=0)
        hits(s, d, k["crash"], {0: "X..............."}, r, gain=0.4, jit=0)
    out = {"drums": loop_filter(s, d, "lp", 4000)}
    arp = s.zeros()
    patt = [0, 1, 2, 1] if mode != "arcade" else [0, 1, 2, 3, 2, 1, 2, 1]
    for c in ch:
        tones = chord_notes(c, 67, 88)[:4]
        for q in range(int(c.dur * 4)):
            s.add(arp, v_chip(s, tones[patt[q % len(patt)] % len(tones)], 0.2, 0.55, duty=0.125 if (q // 16) % 2 else 0.25, dec=0.1), c.start + q * 0.25)
    out["arp"] = loop_filter(s, arp, "lp", 2800)
    def bass(c, n, i):
        R = root_of(c, 38, 33, 47)
        if mode == "boss":
            return [(q * 0.5, 0.45, R + (12 if q % 4 == 3 else 0), 0.9) for q in range(int(c.dur * 2))]
        return [(q * 0.5, 0.45, R + (12 if q in (3, 6) else 0), 0.9) for q in range(int(c.dur * 2))]
    out["bass"] = line(s, ch, bass, v_tri, r=r)
    T = {"quest": ({"A": "5:.5 5:.5 6:.5 5:.5 3:1 2:1 | 3:1 2:.5 1:.5 2:2 | 5:.5 5:.5 6:.5 1+:.5 6:1 5:1 | 3:2 2:1 r:1",
                    "B": "1+:1 1+:.5 2+:.5 3+:1 1+:1 | 6:2 5:2 | 3:.5 5:.5 6:.5 5:.5 3:1 2:1 | 1:4"}, "ABAB", 4),
         "arcade": ({"A": "1:.5 3:.5 5:.5 3:.5 6:.5 5:.5 3:1 | 4:.5 6:.5 1+:.5 6:.5 5:1 4:1 | 3:.5 5:.5 6:.5 5:.5 2+:1 1+:1 | 7:1 5:1 2+:2",
                     "B": "1+:.5 1+:.5 3+:.5 1+:.5 6:1 5:1 | 4:.5 4:.5 6:.5 4:.5 2:2 | 5:.5 6:.5 1+:.5 2+:.5 3+:1 2+:1 | 1+:3 r:1"}, "ABAB", 4),
         "boss": ({"A": "6:.5 6:.5 r:.5 6:.5 1+:.5 6:.5 5:.5 6:.5 | 4:.5 4:.5 r:.5 4:.5 6:.5 4:.5 3:.5 4:.5 | 3:.5 3:.5 r:.5 3:.5 5:.5 3:.5 2:.5 3:.5 | 5:.5 5:.5 r:.5 5:.5 7:.5 5:.5 4:.5 5:.5",
                   "B": "1+:1 1+:.5 3+:.5 2+:1 1+:1 | 6:1 6:.5 1+:.5 3+:2 | 1+:1 7:.5 1+:.5 2+:1 3+:1 | 2+:2 7:1 5:1"}, "ABAB", 4)}[mode]
    ph = phrases(T[0], t, 5)
    tn = arr(ph, T[1] * 2, T[2], [0] * 4 + [12] * 4 if False else None)
    tn = [e for e in tn if e[0] < s.bars * 4]
    duties = [0.5, 0.25, 0.125]
    lead = s.zeros()
    for b, du, m, v in tn:
        s.add(lead, v_chip(s, m, du, v, duty=duties[int(b // 16) % 3], vib=1.0, dec=0.4), b)
    out["lead"] = loop_filter(s, lead, "lp", 3200)
    return out


def _f(fn, mode):
    return lambda s: fn(s, mode)


SONGS = {
    "bossa_sunday": ("Imaj7:4 vi7:4 ii7:4 V7:4 Imaj7:4 IVmaj7:4 iii7:4 vi7:4 ii7:4 V7:4", _f(bossa, "sunday"), {}),
    "samba_tea": ("Imaj7:2 vi7:2 ii7:2 V7:2 iii7:2 vi7:2 ii7:2 V7:2 IVmaj7:4 iii7:2 vi7:2 ii7:4 V7:4", _f(bossa, "samba"), {}),
    "moonlight_bossa": ("Imaj9:4 IVmaj7:4 iii7:4 vi7:4 ii7:4 V7:4 Imaj9:4 ii7:2 V7:2", _f(bossa, "moon"), {"keys": -20}),
    "floating_clouds": ("Imaj9:8 vi7:8 IVmaj7:8 V7sus4:4 V7:4", _f(ambient, "cloud"), {"pad": -20, "celesta": -22, "bass": -24}),
    "deep_sea_lights": ("vi7:8 Imaj7:8 IVmaj7:8 V7sus4:8", _f(ambient, "deep"), {"pad": -20, "lead": -21, "bass": -19}),
    "stardust_drift": ("Imaj7:4 iii7:4 IVmaj7:4 V:4 vi7:4 IVmaj7:4 Imaj7:4 V7sus4:4", _f(ambient, "star"), {"pad": -22, "arp": -21, "bass": -26}),
    "hero_dawn": ("I:4 V:4 vi:4 IV:4 I:4 V:4 vi:4 IV:4 ii:4 IV:4 V:4 V:4", _f(cinema, "hero"), {"drums": -20, "strings": -20, "brass": -20}),
    "quest_begins": ("vi:4 IV:4 I:4 V:4 vi:4 IV:4 I:4 V:4 IV:4 V:4 I:4 V:4", _f(cinema, "quest"), {"guitar": -24, "strings": -24}),
    "epic_finale": ("I:4 V:4 vi:4 IV:4 I:4 V:4 vi:4 IV:4 vi:4 IV:4 I:4 V:4 vi:4 IV:4 V:4 V:4", _f(cinema, "epic"), {"drums": -19, "choir": -27, "strings": -24}),
    "pixel_quest": ("I:4 V:4 vi:4 IV:4 I:4 V:4 vi:4 IV:4 vi:4 IV:4 I:4 V:4 vi:4 IV:4 I:4 V:4", _f(chip, "quest"), {"arp": -21, "bass": -19}),
    "arcade_sunrise": ("I:4 IV:4 vi:4 V:4 I:4 IV:4 vi:4 V:4 I:4 IV:4 vi:4 V:4 I:4 IV:4 vi:4 V:4", _f(chip, "arcade"), {"arp": -21, "bass": -19}),
    "bit_boss_battle": ("vi:4 vi:4 IV:4 V:4 vi:4 iii:4 IV:4 V:4 vi:4 vi:4 IV:4 V:4 vi:4 iii:4 IV:4 V:4", _f(chip, "boss"), {"drums": -16, "bass": -18}),
}
