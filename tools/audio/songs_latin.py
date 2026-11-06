"""Jukebox songs of the genres `latin` (C major) and `eastern` (D major): original grooves and tunes.
SONGS = {id: (prog text, function, level overrides)} like songs.py; every song uses the grid of content/genres.json."""
import numpy as np

import dsp
import instruments as ins
import music as M
import songs as S
from dsp import TAU, midi_hz, nsamp
from songs import (at, bs, comp, hits, kits, lay, line, loop_filter, no_root, prog, room, root_of, strum_comp, tune,
                   v_accordion, v_brass, v_gbass, v_nylon, v_pad, v_pluck, v_strings, voicing)


# ------------------------------------------------------------ small new voices

def v_oud(s, m, d, v=0.8):
    """Oud-like pluck: a short nylon string with a sharp pick and a quick mute."""
    return ins.guitar(m, min(s.sec(d), 0.9), s.sr, bright=0.6, t60=0.8, pick=0.3, mute=0.2, key=m % 3, attack=0.002) * v


def v_bow(s, m, d, v=0.8, vib=5.0):
    """Bowed fiddle: a slow-attack saw with vibrato through a warm low-pass."""
    def mk():
        n = nsamp(s.sec(d) + 0.08, s.sr)
        t = np.arange(n) / s.sr
        f = midi_hz(m) * (1 + 0.004 * np.sin(TAU * vib * t) * np.clip(t / 0.25, 0, 1))
        x = dsp.lowpass(dsp.saw(f, n, s.sr) + 0.5 * dsp.saw(f * 1.004, n, s.sr), 2600, s.sr, 2)
        x *= dsp.env_adsr(n, s.sr, 0.06, 0.2, 0.85, s.sec(d), 0.07)
        return dsp.fade(x / (dsp.peak(x) + 1e-9), s.sr, 0.004, 0.02)
    return M.cached(("bow", m, round(s.sec(d), 3), s.sr, vib), mk) * v


def v_flute(s, m, d, v=0.8):
    """Bamboo flute: a sine with a few soft partials, breath noise and vibrato."""
    def mk():
        n = nsamp(s.sec(d) + 0.08, s.sr)
        t = np.arange(n) / s.sr
        f = midi_hz(m) * (1 + 0.005 * np.sin(TAU * 5.0 * t) * np.clip(t / 0.3, 0, 1))
        ph = np.cumsum(f) / s.sr
        x = np.sin(TAU * ph) + 0.25 * np.sin(2 * TAU * ph) + 0.08 * np.sin(3 * TAU * ph)
        x += 0.05 * dsp.bandpass(dsp.rng("flute", m).standard_normal(n), 2500, 6000, s.sr)
        x *= dsp.env_adsr(n, s.sr, 0.05, 0.1, 0.9, s.sec(d), 0.08)
        return dsp.fade(x / (dsp.peak(x) + 1e-9), s.sr, 0.004, 0.02)
    return M.cached(("flute", m, round(s.sec(d), 3), s.sr), mk) * v


def v_zither(s, m, d, v=0.8):
    """Plucked zither: a short FM bell body under a plucked-string attack."""
    a = ins.bell_fm(midi_hz(m), 0.9, s.sr, ratio=2.0, index=1.2, t60=0.9) * 0.7
    b = v_pluck(s, m, d, 0.5, 4500, 0.1)
    out = np.zeros(max(len(a), len(b)))
    out[:len(a)] += a
    out[:len(b)] += b
    return out * v


def drum_set(s):
    """Hand drums tuned to the key: darbuka (dum, tek, ka), frame drum, cajon (bass, slap), gong."""
    p = lambda f: S.pent_hz(f, s.tonic)  # noqa: E731
    sr = s.sr
    return {"dum": [ins.tom(sr, p(120), 0.35, key=21), ins.tom(sr, p(120), 0.33, key=22)],
            "tek": [ins.rim(sr, key=i + 40, f=p(1900)) for i in range(2)],
            "ka": [ins.woodblock(sr, f=p(1500), key=i + 50, t=0.05) * 0.8 for i in range(2)],
            "frame": [ins.tom(sr, p(95), 0.6, key=31), ins.tom(sr, p(95), 0.55, key=32)],
            "cb": [ins.kick(sr, 95, p(55), 0.04, 0.3, 0.15, 1.2, key=61)],
            "cs": [ins.snare(sr, p(210), 0.05, 0.12, 0.9, 1800, 8000, key=70 + i) for i in range(2)],
            "gong": [ins.bell_fm(p(100), 3.0, sr, ratio=1.41, index=3.0, t60=2.5)]}


def bassline(s, ch, fn, lo=33, hi=50, r=None, cut=2200):
    return loop_filter(s, line(s, ch, fn, v_gbass, r=r), "lp", cut)


def drone(s, notes, level=1.0, cutoff=1400.0):
    """Long held notes through the whole loop (pad)."""
    buf = s.zeros()
    for m in notes:
        at(s, buf, v_pad(s, m, s.bars * 4 - 0.5, 0.6, cutoff, 1.5, 1.5), 0.0)
    return buf * level


def dull(cut_drums=4500.0, cut=5500.0):
    """Decorator: low-pass every part of a song (smaller files: the encoder spends its bits on the highs)."""
    def deco(fn):
        def wrapped(s):
            return {k: loop_filter(s, v, "lp", cut_drums if k == "drums" else cut) for k, v in fn(s).items()}
        wrapped.__doc__ = fn.__doc__
        return wrapped
    return deco


# ------------------------------------------------------------------- latin

@dull(4000.0, 4800.0)
def tango_lanterns(s):
    """120 BPM tango: marcato bass, accordion tune with dotted staccato, strings and dramatic stabs."""
    r = dsp.rng(s.id, "tango")
    ch, t = s.chords, s.tonic
    k = kits(s, "latin")
    d = s.zeros()
    hits(s, d, k["surdo"], "X..oX..oX..oX.xo", r, gain=0.8)
    hits(s, d, k["tamborim"], "..x...g...x...g.", r, gain=0.5)
    hits(s, d, k["shaker"], "ogogogogogogogog", r, gain=0.35)
    d = room(s, d, 0.1, 0.6, "perc", damp=6000)
    b = bassline(s, ch, lambda c, n, i: [(0, 0.9, root_of(c, 40, 33, 47), 0.95), (1, 0.4, root_of(c, 40, 33, 47) + 7, 0.6),
                                         (2, 0.9, root_of(c, 40, 33, 47), 0.9), (3, 0.4, root_of(c, 40, 33, 47) + 7, 0.6)],
                 r=r)
    a = ("6:1.5 1+:.5 3+:1 1+:1 | 7:.75 2+:.25 5:1 7:1 6:1 | 6:.5 6:.5 1+:.5 3+:.5 4+:1 3+:1 | 2+:1.5 7:.5 5:1 r:1 |"
         "1+:1.5 6:.5 3:1 6:1 | 5:.75 7:.25 5:1 3:2 | 4:1 6:1 1+:1 4+:1 | 3+:1.5 2+:.5 7:2 |"
         "1+:.5 3+:.5 5+:1 3+:1 1+:1 | 2+:.5 4+:.5 6+:1 4+:1 2+:1 | 7:.75 2+:.25 4+:1 2+:1 7:1 | 6:4")
    acc = room(s, lay(s, v_accordion, tune(a, t, 4), 0.9, r=r, jit=0.003), 0.1, 0.6, "acc", damp=4500)
    st = comp(s, ch, voicing(ch, 52, 72, 62, no_root), [(0, 3.9, 0.6)], S.v_strings, r=r)
    stab = comp(s, ch, voicing(ch, 55, 76, 65, no_root), lambda c, i: [(3.5, 0.3, 0.95)] if i % 2 else [(1.5, 0.3, 0.8)],
                v_brass, r=r, mask=bs("5-6,9-12"))
    return {"drums": d, "bass": b, "lead": acc, "strings": room(s, st, 0.12, 0.7, "st", damp=3500),
            "brass": stab}


@dull(4000.0, 4800.0)
def flamenco_fire(s):
    """100 BPM flamenco: rasgueado strums, palmas and cajon on a 4/4 count, a falseta picked on the high strings."""
    r = dsp.rng(s.id, "flam")
    ch, t = s.chords, s.tonic
    k = kits(s, "latin")
    ds = drum_set(s)
    d = s.zeros()
    hits(s, d, ds["cb"], "X.....x.X.....x.", r, gain=0.9)
    hits(s, d, ds["cs"], "....X.......X.g.", r, gain=0.7)
    hits(s, d, k["rim"], "x.xxx.xxx.xxx.xx", r, gain=0.45, swing=0.0)
    d = room(s, d, 0.08, 0.5, "perc", damp=6000)
    vo = voicing(ch, 50, 74, 62, None, span=13)
    rasg = lambda c, i: [(0, 0.2, 0.9), (0.5, 0.2, 0.6), (0.75, 0.2, 0.7), (1.0, 0.3, 0.8), (1.5, 0.2, 0.6),
                         (2.0, 0.2, 0.9), (2.25, 0.2, 0.6), (2.5, 0.2, 0.7), (3.0, 0.3, 0.9), (3.25, 0.1, 0.7),
                         (3.5, 0.2, 0.8), (3.75, 0.2, 0.7)]
    g = strum_comp(s, ch, vo, lambda c, i: [e for e in rasg(c, i) if e[0] < c.dur], r=r, bright=0.8, t60=0.9, mute=0.05,
                   spread=0.007)
    g = room(s, g, 0.1, 0.8, "g", damp=6000)
    b = bassline(s, ch, lambda c, n, i: [(0, 0.8, root_of(c, 40, 33, 47), 0.9), (2.5, 0.4, root_of(c, 40, 33, 47) + 7, 0.7)], r=r)
    f = ("3+:.5 2+:.25 1+:.25 7:.5 6:.5 7:2 | 6:.5 7:.5 1+:.5 2+:.5 3+:2 | 4+:.5 3+:.25 2+:.25 1+:.5 7:.5 6:1 r:1 |"
         " 7:.5 6:.25 5:.25 6:1 3+:2 | 6+:.25 5+:.25 4+:.25 3+:.25 2+:.5 1+:.5 7:2 | 6:.5 7:.5 1+:.5 7:.5 6:2 |"
         " 4+:.5 4+:.25 3+:.25 2+:1 3+:2 | 4+:.5 3+:.5 2+:.5 1+:.5 7:1 6:1 | 5:.25 6:.25 7:.25 1+:.25 2+:.5 3+:.5 4+:.5 3+:.5 2+:.5 1+:.5 | 6:4")
    lead = room(s, lay(s, v_nylon, tune(f, t, 4), 0.9, r=r, jit=0.004), 0.12, 0.9, "ld", damp=6000)
    return {"drums": d, "guitar": g, "bass": b, "lead": lead}


def cumbia_riverside(s):
    """92 BPM cumbia: gentle shuffle, guiro, offbeat bass and a swaying accordion tune."""
    r = dsp.rng(s.id, "cumbia")
    ch, t = s.chords, s.tonic
    k = kits(s, "latin")
    d = s.zeros()
    hits(s, d, k["conga_lo"], "X..x.x..x..x.x..", r, gain=0.8)
    hits(s, d, k["conga_hi"], "..x..x.x..x..xx.", r, gain=0.5)
    hits(s, d, k["guiro"], "x.xxx.xxx.xxx.xx", r, gain=0.6)
    hits(s, d, k["clave"], "x..x..x.x..x..x.", r, gain=0.45)
    d = room(s, d, 0.12, 0.7, "perc", damp=6000)
    b = bassline(s, ch, lambda c, n, i: [(0, 0.9, root_of(c, 38, 33, 47), 0.9), (1.5, 0.4, root_of(c, 38, 33, 47) + 7, 0.7),
                                         (2.0, 0.9, root_of(c, 38, 33, 47), 0.85), (3.5, 0.4, root_of(c, 38, 33, 47) + 12, 0.7)],
                 r=r)
    vo = voicing(ch, 55, 74, 64, no_root)
    keys = room(s, comp(s, ch, vo, [(0.5, 0.4, 0.6), (1.5, 0.4, 0.6), (2.5, 0.4, 0.6), (3.5, 0.4, 0.6)], S.v_epiano, r=r,
                        gain=0.8), 0.12, 0.8, "k", damp=5000)
    a = ("5:1 3:.5 5:.5 6:1.5 5:.5 | 3:1 2:.5 3:.5 1:2 | 3:.5 5:.5 6:.5 1+:.5 6:1 5:1 | 3:1 2:1 1:2 |"
         "6:1 1+:.5 6:.5 5:1.5 3:.5 | 5:.5 6:.5 5:.5 3:.5 2:2 | 3:.5 2:.5 1:.5 2:.5 3:1 5:1 | 1:3 r:1")
    acc = room(s, lay(s, v_accordion, tune(a, t, 4), 0.85, r=r, jit=0.004, swing=0.15), 0.15, 0.9, "acc", damp=5000)
    return {"drums": d, "bass": b, "keys": keys, "lead": acc}


def salsa_market(s):
    """100 BPM salsa: son clave, congas, cowbell, a piano montuno and brass hits."""
    r = dsp.rng(s.id, "salsa")
    ch, t = s.chords, s.tonic
    k = kits(s, "latin")
    d = s.zeros()
    hits(s, d, k["clave"], ["x..x..x...x.x...", "..x.x...x..x..x."], r, gain=0.7)
    hits(s, d, k["conga_lo"], "..x...xx..x...xx", r, gain=0.7)
    hits(s, d, k["conga_hi"], "x.x.x.xxx.x.x.xx", r, gain=0.5)
    hits(s, d, k["bell"], "x...x...x...x...", r, gain=0.4)
    hits(s, d, k["bongo_hi"], "o.o.x.o.o.o.x.o.", r, gain=0.4)
    d = room(s, d, 0.1, 0.6, "perc", damp=6000)
    vo = voicing(ch, 55, 76, 65, no_root)
    mont = lambda c, i: [(q * 0.5, 0.45, 0.85 if q in (0, 3, 6) else 0.6) for q in range(8) if q in (0, 1, 3, 4, 6, 7)
                         and q * 0.5 < c.dur]
    pn = room(s, comp(s, ch, vo, mont, S.v_piano, r=r, jit=0.004), 0.1, 0.8, "pn", damp=5000)
    b = bassline(s, ch, lambda c, n, i: [(1.5, 0.45, root_of(c, 38, 33, 47) + (0 if c.dur < 4 else 7), 0.85),
                                         (2.0, 0.4, root_of(c, 38, 33, 47), 0.9), (3.5, 0.45, nearest_up(n, c), 0.85)], r=r)
    br = comp(s, ch, voicing(ch, 58, 79, 68, no_root), lambda c, i: [(0.0, 0.3, 0.9), (1.5, 0.3, 0.8), (2.5, 0.45, 0.95)],
              v_brass, r=r, mask=bs("3-4,7-10"))
    return {"drums": d, "keys": pn, "bass": b, "brass": room(s, br, 0.14, 0.9, "br", damp=5000)}


def nearest_up(n, c):
    """An approach note: the next chord's root (an octave kept in the bass range)."""
    return M.nearest(n.root, 40, 33, 47)


# ----------------------------------------------------------------- eastern

@dull(3800.0, 4400.0)
def bazaar_noon(s):
    """108 BPM bazaar: darbuka rhythm, a droning D/A, oud-like plucks and a busy pentatonic melody."""
    r = dsp.rng(s.id, "bazaar")
    ch, t = s.chords, s.tonic
    ds = drum_set(s)
    d = s.zeros()
    hits(s, d, ds["dum"], "X..x..x.X.x.x...", r, gain=0.9)
    hits(s, d, ds["tek"], "..x.x...x..x.x.x", r, gain=0.45)
    hits(s, d, ds["ka"], "o.o.o.o.o.o.o.o.", r, gain=0.35)
    d = room(s, d, 0.1, 0.6, "perc", damp=6000)
    dr = drone(s, [38, 45, 50], 1.0)
    m = ("1:.5 2:.5 3:1 5:.5 3:.5 2:1 | 3:.5 5:.5 6+:0 " if False else
         "1:.5 2:.5 3:1 5:.5 3:.5 2:1 | 3:.5 5:.5 6:1 5:.5 3:.5 2:1 | 1:.5 2:.5 3:.5 5:.5 6:1 5:1 | 3:1 2:.5 1:.5 2:2 |"
         "5:.5 6:.5 1+:1 6:.5 5:.5 3:1 | 5:.5 3:.5 2:.5 3:.5 5:1 6:1 | 1+:.5 2+:.5 3+:1 2+:.5 1+:.5 6:1 | 5:1 3:1 2:2 |"
         "3+:.5 2+:.5 1+:.5 6:.5 5:1 3:1 | 2:.5 3:.5 5:.5 6:.5 1+:2 | 6:.5 5:.5 3:.5 2:.5 3:1 5:1 | 1:4")
    oud = room(s, lay(s, v_oud, tune(m, t, 4), 0.9, r=r, jit=0.004), 0.12, 0.8, "oud", damp=6000)
    b = bassline(s, ch, lambda c, n, i: [(0, 0.9, root_of(c, 38, 33, 47), 0.9), (2.5, 0.4, root_of(c, 38, 33, 47) + 7, 0.7),
                                         (3.5, 0.4, root_of(c, 38, 33, 47), 0.6)], r=r)
    ar = comp(s, ch, voicing(ch, 57, 76, 66, no_root), [(0.5, 0.3, 0.5), (1.5, 0.3, 0.5), (3.0, 0.3, 0.5)], v_oud, r=r,
              gain=0.5)
    return {"drums": d, "pad": dr, "lead": oud, "bass": b, "guitar": room(s, ar, 0.1, 0.8, "ar", damp=5000)}


def oasis_nights(s):
    """84 BPM desert night: a slow plucked melody over a drone pad, frame drum and a distant gong."""
    r = dsp.rng(s.id, "oasis")
    ch, t = s.chords, s.tonic
    ds = drum_set(s)
    d = s.zeros()
    hits(s, d, ds["frame"], "X.......x..x....", r, gain=0.8)
    hits(s, d, ds["tek"], "......g.....g.g.", r, gain=0.3)
    d = room(s, d, 0.2, 1.2, "perc", damp=5000)
    pad = comp(s, ch, voicing(ch, 50, 74, 62, None), [(0, 3.95, 0.7)], v_pad, r=r)
    pad = room(s, pad, 0.2, 1.5, "pad", damp=3500) + drone(s, [38, 45], 0.8)
    m = ("2:1.5 3:.5 5:2 | 6:1 5:1 3:2 | 2:1 3:1 5:1 6:1 | 5:4 | 6:1.5 1+:.5 6:1 5:1 | 3:1 5:1 3:1 2:1 | 3:2 2:1 1:1 | 1:4")
    oud = room(s, lay(s, v_zither, tune(m, t, 4), 0.8, r=r, jit=0.005), 0.25, 1.4, "oud", damp=5000)
    b = bassline(s, ch, lambda c, n, i: [(0, 2.5, root_of(c, 38, 33, 47), 0.8)], r=r, cut=900)
    gong = s.zeros()
    for bar in (0, 4):
        at(s, gong, ds["gong"][0], bar * 4, 0.5)
    return {"drums": d, "pad": pad, "lead": oud, "bass": b, "fx": gong}


def bamboo_garden(s):
    """88 BPM pentatonic garden: a bamboo flute tune, plucked zither arpeggios and a soft gong."""
    r = dsp.rng(s.id, "bamboo")
    ch, t = s.chords, s.tonic
    ds = drum_set(s)
    gong = s.zeros()
    for bar in (0, 2, 4, 6):
        at(s, gong, ds["gong"][0], bar * 4, 0.3)
    pent = lambda c: [x for x in c.tones if x in (0, 7, 4, 9, 14)] or [0, 7]
    arp = lambda c, i: [(q * 0.5, 0.5, 0.7 if q % 4 == 0 else 0.5) for q in range(8) if q * 0.5 < c.dur]
    vo = voicing(ch, 57, 81, 69, pent, span=12)
    zi = s.zeros()
    for i, c in enumerate(ch):
        for q, (bt, du, v) in enumerate(arp(c, i)):
            at(s, zi, v_zither(s, vo[i][q % len(vo[i])], du, v), c.start + bt, 0.7)
    zi = room(s, zi, 0.2, 1.2, "zi", damp=5000)
    m = ("5:1 6:.5 5:.5 3:2 | 2:1 3:1 5:2 | 6:1.5 1+:.5 6:1 5:1 | 3:3 r:1 | 2:.5 3:.5 5:1 3:1 2:1 | 1:1 2:1 3:2 |"
         "5:1 6:1 1+:1 2+:1 | 1+:4")
    fl = room(s, lay(s, v_flute, tune(m, t, 5), 0.85, r=r, jit=0.004), 0.2, 1.3, "fl", damp=6000)
    pad = drone(s, [50, 57], 0.7, 1000.0)
    d = s.zeros()
    hits(s, d, ds["frame"], "x.......o.......", r, gain=0.5)
    d = room(s, d, 0.2, 0.8, "perc", damp=5000)
    return {"drums": d, "lead": fl, "arp": zi, "pad": pad, "fx": gong}


@dull(3000.0, 3000.0)
def silk_road_caravan(s):
    """100 BPM caravan: walking hand-drum groove, a drone, bowed strings playing a pentatonic tune that answers itself."""
    r = dsp.rng(s.id, "silk")
    ch, t = s.chords, s.tonic
    ds = drum_set(s)
    d = s.zeros()
    hits(s, d, ds["dum"], "X..x..x...x..x..", r, gain=0.9)
    hits(s, d, ds["frame"], "x.....x.x.....x.", r, gain=0.5)
    hits(s, d, ds["tek"], "..x.x.x..x.x..x.", r, gain=0.4)
    d = room(s, d, 0.08, 0.5, "perc", damp=6000)
    m = ("1:1 3:.5 5:.5 6:1 5:1 | 3:1 5:1 3:.5 2:.5 1:1 | 2:1 3:.5 5:.5 6:1 1+:1 | 6:1 5:1 3:2 |"
         "1+:1 6:.5 5:.5 3:1 5:1 | 6:1 5:.5 3:.5 2:1 3:1 | 5:1 6:.5 1+:.5 2+:1 1+:1 | 6:2 5:2 |"
         "3:1 5:1 6:1 1+:1 | 2+:1 1+:.5 6:.5 5:1 6:1 | 5:1 3:.5 2:.5 3:1 5:1 | 1:4")
    bow = room(s, lay(s, v_bow, tune(m, t, 4), 0.9, r=r, jit=0.004), 0.1, 0.7, "bow", damp=4500)
    st = comp(s, ch, voicing(ch, 50, 70, 60, None), [(0, 3.9, 0.55)], S.v_strings, r=r)
    st = room(s, st, 0.1, 0.6, "st", damp=3500)
    b = bassline(s, ch, lambda c, n, i: [(0, 0.9, root_of(c, 38, 33, 47), 0.9), (1.5, 0.4, root_of(c, 38, 33, 47) + 7, 0.7),
                                         (2.5, 0.4, root_of(c, 38, 33, 47), 0.7), (3.0, 0.8, root_of(c, 38, 33, 47) + 7, 0.75)],
                 r=r)
    return {"drums": d, "lead": bow, "strings": st, "bass": b, "pad": drone(s, [38, 45], 0.6)}


SONGS = {
    "tango_lanterns": ("vi:4 vi:4 IV:4 V7:4 vi:4 iii:4 IV:4 V7:4 I:4 IV:4 V7:4 vi:4", tango_lanterns, {"lead": -18}),
    "flamenco_fire": ("vi:4 IV:4 V:4 vi:4 vi:4 IV:4 V:4 iii:4 IV:4 vi:4", flamenco_fire, {"guitar": -20}),
    "cumbia_riverside": ("I:4 IV:4 V7:4 I:4 vi:4 IV:4 V7:4 I:4", cumbia_riverside, {}),
    "salsa_market": ("I:4 IV:4 V7:4 I:4 vi:4 ii:4 V7:4 I:4 IV:4 V7:4", salsa_market, {}),
    "bazaar_noon": ("I:4 I:4 ii:4 I:4 vi:4 ii:4 I:4 V:4 vi:4 ii:4 V:4 I:4", bazaar_noon, {"pad": -27, "guitar": -26}),
    "oasis_nights": ("I:4 vi:4 ii:4 V:4 I:4 vi:4 ii:4 I:4", oasis_nights, {"pad": -23, "fx": -28}),
    "bamboo_garden": ("I:4 vi:4 V:4 I:4 ii:4 vi:4 V:4 I:4", bamboo_garden, {"pad": -28, "arp": -24, "fx": -32}),
    "silk_road_caravan": ("vi:4 vi:4 I:4 V:4 vi:4 ii:4 I:4 V:4 vi:4 I:4 V:4 vi:4", silk_road_caravan, {"pad": -28}),
}
