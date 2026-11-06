"""Songs of the genres rnb, reggae, country and blues (see content/genres.json). Same conventions as songs.py:
SONGS = {id: (prog text, fn(s) -> {part: signal}, level overrides)}. Original tunes only."""
import numpy as np

import dsp
import instruments as ins
import music as M
import songs as S
from songs import (at, bs, comp, echo, hits, kits, lay, line, loop_filter, nearest, no_root, room, root_of, tune,
                   v_epiano, v_gbass, v_organ, v_pad, v_sub, v_upright, voicing, strum_comp, walk)


# ------------------------------------------------------------------ helpers

def fit(pat):
    """Rhythm [(beat, beats, vel)] cut to the length of each chord."""
    return lambda c, i: [p for p in pat if p[0] < c.dur]


def snaps(s, r, pattern, gain=0.7, mask=None):
    """Finger snaps: a short band-limited clap."""
    buf = s.zeros()
    sn = [ins.clap(s.sr, key=60 + i, tail=0.03, lo=1800, hi=5200) for i in range(3)]
    hits(s, buf, sn, pattern, r, gain=gain, mask=mask)
    return buf


def lead_line(s, evs, kind, key, swing=0.0):
    """Single-voice leads built on render_line: harp (harmonica), melodica, fiddle, twang, slide."""
    ev = [(S.sw(b, swing, 0.5) if swing else b, d, m, v) for b, d, m, v in evs]
    p = dict(harp=dict(osc="saw", glide=0.05, attack=0.03, release=0.08, vib_rate=5.2, vib_depth=0.12, vib_delay=0.3),
             melodica=dict(osc="pulse", pw=0.35, glide=0.01, attack=0.04, release=0.06, vib_rate=4.8, vib_depth=0.05,
                           vib_delay=0.4),
             fiddle=dict(osc="saw", glide=0.015, attack=0.02, release=0.05, vib_rate=6.0, vib_depth=0.2,
                         vib_delay=0.15),
             twang=dict(osc="saw", glide=0.004, attack=0.004, release=0.07, vib_rate=5.5, vib_depth=0.1,
                        vib_delay=0.3),
             slide=dict(osc="saw", glide=0.11, attack=0.02, release=0.1, vib_rate=5.5, vib_depth=0.28,
                        vib_delay=0.2))[kind]
    src, env, onset = M.render_line(s, M.events(s, ev), legato_gap=0.006, key=key, **p)
    x = src * env
    if kind == "harp":
        x = dsp.highpass(x, 300, s.sr, 2)
        x = dsp.filt(x, "peak", 1300, s.sr, q=1.2, gain_db=6.0)
        x = dsp.lowpass(x, 3800, s.sr, 2)
        x = dsp.tube(x / (dsp.peak(x) + 1e-9) * 1.6, 1.4, s.sr, 0.1) * (0.85 + 0.15 * np.sin(6.3 * np.arange(len(x)) / s.sr))
        x += 0.1 * ins.breath(len(x), s.sr, key, 1800, 5000) * env
    elif kind == "melodica":
        x = dsp.sweep_filter(x, 1200.0 + 1500.0 * env, s.sr, q=0.8)
        x = dsp.highpass(x, 250, s.sr, 2) + 0.1 * ins.breath(len(x), s.sr, key, 2000, 6000) * env
    elif kind == "fiddle":
        x = dsp.highpass(x, 250, s.sr, 2)
        x = dsp.filt(x, "peak", 2200, s.sr, q=1.0, gain_db=5.0)
        x = dsp.lowpass(x, 4800, s.sr, 2)
    else:  # twang / slide: a clean bright electric guitar, just a touch of grit
        x = dsp.highpass(x * (0.6 + 0.4 * np.clip(onset, 0, 1)), 200, s.sr, 2)
        x = ins.amp_sim(x / (dsp.peak(x) + 1e-9), s.sr, gain=2.5 if kind == "twang" else 4.0, tone=5000, key_hz=2200)
    return M.wrap(s, x / (dsp.peak(x) + 1e-9))


def banjo(s, m, d, v=0.8):
    """Banjo-like pluck: bright, quick decay, thin body."""
    x = ins.guitar(m, min(0.3, s.sec(d)), s.sr, bright=0.95, t60=0.45, pick=0.3, mute=0.03, key=m % 3, damp=0.2)
    return dsp.highpass(x, 350, s.sr, 2) * v


def chop(s, chords, voices_, pat, voice, r, gain=1.0, jit=0.003):
    return comp(s, chords, voices_, fit(pat), voice, gain=gain, r=r, jit=jit)


def mix_bass(s, b, hz=1500, wet=0.04):
    b = b / (dsp.peak(b) + 1e-9)
    b = 0.45 * np.tanh(b / 0.45)  # soft clip: tames plucked-bass peaks
    return room(s, loop_filter(s, b, "lp", hz), wet, 0.6, "bass", damp=2500)


# ==================================================================== R&B (Db)

def velvet_evening(s):
    """74 BPM smooth r&b: e-piano chords, finger snaps, a sub bass and a silky e-piano tune."""
    r = dsp.rng(s.id, "velvet")
    ch, t = s.chords, s.tonic
    k = kits(s, "lofi")
    d = s.zeros()
    hits(s, d, k["kick"], "X.....o...x.....", r, gain=0.9)
    hits(s, d, k["hat"], "x.o.x.o.x.o.xoo.", r, gain=0.35)
    d = room(s, d, 0.08, 0.7, "drums", damp=5000) + snaps(s, r, "....X.......X...", 0.8)
    vo = voicing(ch, 52, 70, 61, no_root)
    keys = chop(s, ch, vo, [(0, 1.4, 0.6), (1.5, 0.5, 0.5), (2.5, 1.4, 0.6)],
                lambda ss, m, du, v: v_epiano(ss, m, du, v, bright=0.6, rel=0.5), r, 0.8)
    keys = room(s, keys, 0.18, 1.3, "keys", damp=4500)
    bass = line(s, ch, lambda c, n, i: [(0, 1.4, root_of(c, 37, 30, 44), 0.9), (2.5, 0.6, root_of(c, 37, 30, 44), 0.7),
                                         (3.5, 0.5, root_of(c, 37, 30, 44) + 7, 0.6)][:3 if c.dur >= 4 else 1],
                v_sub, r=r)
    pad = comp(s, ch, voicing(ch, 55, 72, 64, no_root), lambda c, i: [(0, c.dur, 0.5)], v_pad, r=None, gain=0.6)
    tn = tune("5:1.5 3:.5 5:1 1+:1 | 6:1.5 5:.5 3:2 | 4:1.5 2:.5 4:1 6:1 | 5:1 7:1 2+:2 |"
              " 5:1.5 3:.5 5:1 1+:1 | 6:1.5 4:.5 6:1 1+:1 | 5:1 3:1 6:1 3:1 | 2:2 4:1 5:1", t, 4)
    lead = lay(s, lambda ss, m, du, v: v_epiano(ss, m + 12, du, v, bright=1.0, rel=0.6), tn, r=r, jit=0.01, swing=0.2)
    lead = room(s, echo(s, lead, 0.75, 0.15, 0.3, 2, 4000), 0.2, 1.4, "lead", damp=5000)
    return {"drums": d, "keys": keys, "bass": mix_bass(s, bass, 700), "pad": pad, "lead": lead}


def slow_jam_rain(s):
    """68 BPM slow jam: warm pads, soft kit with rim, a melodic bass and a breathy e-piano answer."""
    r = dsp.rng(s.id, "slowjam")
    ch, t = s.chords, s.tonic
    k = kits(s, "lofi")
    d = s.zeros()
    hits(s, d, k["kick"], "X.......o..x....", r, gain=0.8)
    hits(s, d, k["snare"], "........X.......", r, gain=0.5)
    hits(s, d, k["rim"], "..g...g...g...g.", r, gain=0.4)
    hits(s, d, k["shaker"], "..o...o...o...o.", r, gain=0.25)
    d = room(s, d, 0.1, 0.8, "drums", damp=4500)
    pad = comp(s, ch, voicing(ch, 50, 72, 62, no_root), lambda c, i: [(0, c.dur, 0.6)],
               lambda ss, m, du, v: v_pad(ss, m, du, v, cutoff=1500, att=0.9, rel=1.2), r=None, gain=1.0)
    def bl(c, n, i):
        R = root_of(c, 37, 30, 44)
        return [(0, 1.5, R, 0.9), (1.5, 0.5, R + 7, 0.6), (2.0, 1.0, R + (3 if 3 in c.tones else 4), 0.7),
                (3.0, 1.0, R + 7, 0.7)][:4 if c.dur >= 4 else 2]
    bass = line(s, ch, bl, v_sub, r=r)
    keys = chop(s, ch, voicing(ch, 55, 74, 65, no_root), [(0.5, 1.0, 0.5), (2.0, 2.0, 0.5)],
                lambda ss, m, du, v: v_epiano(ss, m, du, v, bright=0.5, rel=0.8), r, 0.7)
    keys = room(s, keys, 0.22, 1.6, "keys", damp=4000)
    tn = tune("r:2 3:1 5:1 | 6:3 5:1 | r:2 4:1 2:1 | 5:2 7:1 5:1 | r:2 3:1 5:1 | 1+:3 6:1 | 4:2 6:1 5:1 | 2:4", t, 4)
    lead = lay(s, lambda ss, m, du, v: v_epiano(ss, m + 12, du, v * 0.9, bright=0.7, rel=0.9), tn, r=r, jit=0.01)
    lead = room(s, echo(s, lead, 1.0, 0.18, 0.35, 3, 3500), 0.25, 1.6, "lead", damp=4500)
    return {"drums": d, "pad": pad, "bass": mix_bass(s, bass, 700), "keys": keys, "lead": lead}


def silky_groove(s):
    """92 BPM neo-soul: a muted guitar chop, rhodes, tight 16th drums and a behind-the-beat bass."""
    r = dsp.rng(s.id, "silky")
    ch, t = s.chords, s.tonic
    k = kits(s, "lofi")
    d = s.zeros()
    hits(s, d, k["kick"], {"*": "X..x..o...x..o..", 3: "X..x..o..x.x...."}, r, gain=0.9, swing=0.15)
    hits(s, d, k["snare"], "....X..g....X.g.", r, gain=0.7, swing=0.15)
    hits(s, d, k["hat"], "x.xox.xox.xox.xo", r, gain=0.4, swing=0.15)
    d = room(s, d, 0.08, 0.7, "drums", damp=5000)
    vo = voicing(ch, 58, 76, 66, S.guide)
    gtr = strum_comp(s, ch, voicing(ch, 55, 72, 63, no_root), fit([(0, 0.18, 0.7), (0.75, 0.15, 0.5), (1.5, 0.18, 0.7),
                     (2.25, 0.15, 0.5), (3.0, 0.18, 0.7), (3.5, 0.15, 0.55)]), r=r, bright=0.4, t60=0.4, mute=0.02, swing=0.1)
    gtr = room(s, loop_filter(s, gtr, "hp", 200), 0.1, 0.7, "gtr", damp=4500)
    keys = chop(s, ch, vo, [(0, 0.9, 0.6), (1.5, 0.4, 0.5), (2.75, 1.2, 0.6)],
                lambda ss, m, du, v: v_epiano(ss, m, du, v, bright=0.8, rel=0.4), r, 0.8)
    keys = room(s, keys, 0.15, 1.0, "keys", damp=4500)
    def bl(c, n, i):
        R = root_of(c, 40, 32, 46)
        return [(0.0, 0.7, R, 0.9), (0.75, 0.4, R + 12 if R + 12 < 52 else R, 0.6), (1.75, 0.5, R + 7, 0.7),
                (2.5, 0.7, R, 0.8), (3.5, 0.4, R + (3 if 3 in c.tones else 4), 0.6)][:5 if c.dur >= 4 else 3]
    bass = line(s, ch, bl, v_gbass, r=r, swing=0.0)
    tn = tune("5:.5 3:.5 r:.5 5:.5 1+:1 3+:1 | 2+:1 1+:.5 6:.5 5:2 | 4:.5 6:.5 r:.5 1+:.5 2+:1 6:1 | 5:1.5 3:.5 2:2 |"
              " 5:.5 3:.5 r:.5 5:.5 1+:1 3+:1 | 4+:1 3+:.5 1+:.5 6:2 | 7:.5 2+:.5 r:.5 5:.5 3:1 2:1 | 1:4", t, 4)
    lead = lay(s, lambda ss, m, du, v: v_epiano(ss, m + 12, du, v, bright=1.0, rel=0.3), tn, r=r, jit=0.008, swing=0.15)
    lead = room(s, lead, 0.15, 1.0, "lead", damp=5000)
    return {"drums": d, "guitar": gtr, "keys": keys, "bass": mix_bass(s, bass, 1800), "lead": lead}


# ==================================================================== REGGAE (Bb)

def skank(s, ch, r, vo, pat=((0.5, 0.16, 0.8), (1.5, 0.16, 0.8), (2.5, 0.16, 0.8), (3.5, 0.16, 0.8)), bright=0.6):
    g = strum_comp(s, ch, vo, fit(list(pat)), r=r, bright=bright, t60=0.3, mute=0.015, spread=0.005, alt=False)
    return room(s, loop_filter(s, g, "hp", 250), 0.1, 0.7, "gtr", damp=5000)


def island_breeze(s):
    """78 BPM roots reggae: offbeat guitar skank, organ bubble, one-drop drums and a round bass."""
    r = dsp.rng(s.id, "island")
    ch, t = s.chords, s.tonic
    k = kits(s, "lofi")
    d = s.zeros()
    hits(s, d, k["kick"], "........X.......", r, gain=0.9)
    hits(s, d, k["rim"], "........X.......", r, gain=0.7)
    hits(s, d, k["hat"], "x.x.x.x.x.x.x.x.", r, gain=0.35, swing=0.12)
    hits(s, d, k["shaker"], "..o...o...o...o.", r, gain=0.3)
    d = room(s, d, 0.1, 0.8, "drums", damp=5000)
    vo = voicing(ch, 58, 74, 66, no_root)
    gtr = skank(s, ch, r, vo)
    org = chop(s, ch, voicing(ch, 52, 70, 60, no_root),
               [(0.5, 0.2, 0.7), (0.75, 0.2, 0.5), (1.5, 0.2, 0.7), (1.75, 0.2, 0.5), (2.5, 0.2, 0.7), (2.75, 0.2, 0.5),
                (3.5, 0.2, 0.7), (3.75, 0.2, 0.5)],
               lambda ss, m, du, v: v_organ(ss, m, du, v, bars=(8, 4, 8, 4, 0, 0, 0, 0, 0), perc=0.0, att=0.004, rel=0.04), r, 0.8)
    org = room(s, org, 0.1, 0.8, "organ", damp=4500)
    def bl(c, n, i):
        R = root_of(c, 36, 29, 43)
        return [(0, 0.8, R, 0.9), (1.0, 0.4, R + 7, 0.7), (1.5, 0.4, R + (3 if 3 in c.tones else 4), 0.7), (2.0, 0.8, R, 0.85), (3.0, 0.9, R + 7, 0.75)][
            :5 if c.dur >= 4 else 3]
    bass = line(s, ch, bl, v_sub, r=r)
    tn = tune("r:1 5:.5 3:.5 5:1 6:1 | 5:1.5 3:.5 2:2 | r:1 1+:.5 6:.5 1+:1 2+:1 | 1+:1.5 5:.5 7:2 |"
              " r:1 5:.5 3:.5 5:1 6:1 | 4+:1 3+:1 1+:2 | 6:1 5:.5 3:.5 4:1 2:1 | 1:3 r:1", t, 4)
    lead = lay(s, lambda ss, m, du, v: v_epiano(ss, m, du, v * 0.8, bright=0.6, rel=0.2), tn, r=r, jit=0.006)
    lead = room(s, echo(s, lead, 0.75, 0.2, 0.35, 3, 3500), 0.15, 1.0, "lead", damp=5000)
    return {"drums": d, "guitar": gtr, "organ": org, "bass": mix_bass(s, bass, 900), "lead": lead}


def one_drop_sun(s):
    """72 BPM one drop: kick and rim on beat three, a deep bass line and a sunny melodica tune."""
    r = dsp.rng(s.id, "onedrop")
    ch, t = s.chords, s.tonic
    k = kits(s, "lofi")
    d = s.zeros()
    hits(s, d, k["kick"], "........X.......", r, gain=1.0)
    hits(s, d, k["snare"], "........o.......", r, gain=0.4)
    hits(s, d, k["rim"], "........X.....g.", r, gain=0.8)
    hits(s, d, k["hat"], "x.x.x.x.x.x.x.x.", r, gain=0.25)
    d = room(s, d, 0.12, 0.9, "drums", damp=5000)
    gtr = skank(s, ch, r, voicing(ch, 58, 74, 66, no_root), pat=((1.5, 0.2, 0.8), (3.5, 0.2, 0.8)), bright=0.5)
    def bl(c, n, i):
        R = root_of(c, 34, 27, 41)
        return [(0, 1.5, R, 0.95), (1.5, 0.5, R + 7, 0.7), (2.0, 0.9, R + 12, 0.8), (3.0, 0.5, R + 7, 0.7),
                (3.5, 0.5, R + (3 if 3 in c.tones else 4), 0.7)][:5 if c.dur >= 4 else 3]
    bass = line(s, ch, bl, v_sub, r=r)
    pad = comp(s, ch, voicing(ch, 55, 72, 63, no_root), lambda c, i: [(0, c.dur, 0.5)],
               lambda ss, m, du, v: v_organ(ss, m, du, v * 0.5, bars=(6, 4, 8, 0, 0, 0, 0, 0, 0), att=0.05, rel=0.2), gain=0.7)
    tn = tune("5:1 3:.5 5:.5 6:1.5 5:.5 | 1+:1 6:.5 5:.5 3:2 | 2:.5 3:.5 5:1 6:1 5:1 | 3:1 2:1 1:2 |"
              " 5:1 3:.5 5:.5 6:1.5 5:.5 | 1+:1 3+:1 2+:2 | 1+:.5 7:.5 6:1 4:1 5:1 | 3:1.5 2:.5 1:2", t, 4)
    lead = lead_line(s, tn, "melodica", "sun")
    lead = room(s, echo(s, lead, 0.75, 0.15, 0.3, 2, 3500), 0.15, 1.0, "lead", damp=5000)
    return {"drums": loop_filter(s, d, "lp", 5000), "guitar": loop_filter(s, gtr, "lp", 4500), "bass": mix_bass(s, bass, 800), "organ": pad, "lead": lead}


def dub_lagoon(s):
    """70 BPM dub: heavy bass, chord stabs thrown into the echo, a spring-reverb snare and a sparse melodica."""
    r = dsp.rng(s.id, "dub")
    ch, t = s.chords, s.tonic
    k = kits(s, "lofi")
    d = s.zeros()
    hits(s, d, k["kick"], "........X.......", r, gain=1.0)
    hits(s, d, k["hat"], "x.x.x.x.x.x.x.x.", r, gain=0.25)
    sn = s.zeros()
    hits(s, sn, k["rim"], {"*": "........X.......", 7: "........X...X..."}, r, gain=0.9)
    # spring: a short metallic comb (two close delays) before a dark reverb, then the dub echo
    sn = echo(s, sn, 0.75, 0.55, 0.55, 5, 2500)
    sn = room(s, dsp.loop_apply(sn, lambda z: z + 0.5 * np.roll(z, 331) + 0.35 * np.roll(z, 677)), 0.35, 1.8, "spring", damp=2800)
    d = room(s, d, 0.1, 0.8, "drums", damp=4500) + sn * 0.8
    gtr = skank(s, ch, r, voicing(ch, 58, 74, 66, no_root), pat=((0.5, 0.2, 0.8), (2.5, 0.2, 0.8)), bright=0.5)
    gtr = echo(s, gtr, 0.75, 0.5, 0.55, 5, 2500) * 1.0
    stab = chop(s, ch, voicing(ch, 52, 70, 60, no_root), [(1.5, 0.25, 0.8)],
                lambda ss, m, du, v: v_organ(ss, m, du, v, bars=(8, 6, 8, 4, 0, 0, 0, 0, 0), att=0.004, rel=0.05), r, 0.8,
                ) * 1.0
    stab = room(s, echo(s, stab, 1.5, 0.6, 0.6, 4, 2200), 0.25, 1.5, "stab", damp=3500)
    def bl(c, n, i):
        R = root_of(c, 33, 26, 40)
        return [(0, 1.8, R, 1.0), (2.0, 0.4, R, 0.8), (2.5, 0.4, R + 12 if R < 36 else R, 0.7), (3.0, 0.9, R + 7, 0.8)][
            :4 if c.dur >= 4 else 2]
    bass = line(s, ch, bl, v_sub, r=r)
    tn = tune("r:4 | r:2 5:1 6:1 | 5:2 3:1 2:1 | r:4 | r:4 | r:2 1+:1 6:1 | 5:3 r:1 | r:4", t, 4)
    lead = lead_line(s, tn, "melodica", "dub")
    lead = room(s, echo(s, lead, 1.5, 0.45, 0.55, 4, 2500), 0.3, 1.8, "lead", damp=4000)
    return {"drums": d, "guitar": gtr, "organ": stab, "bass": mix_bass(s, bass, 700, 0.02), "lead": lead}


# ==================================================================== COUNTRY (D)

def porch_pickin(s):
    """112 BPM porch country: a boom-chick strum, a rolling banjo-like pluck and a train beat on the snare."""
    r = dsp.rng(s.id, "porch")
    ch, t = s.chords, s.tonic
    k = kits(s, "lofi", "rock")
    d = s.zeros()
    hits(s, d, k["kick"], "X.......x.......", r, gain=0.6)
    hits(s, d, k["snare"], "g.xxg.xxg.xxg.xx", r, gain=0.35)
    d = room(s, d, 0.08, 0.7, "drums", damp=5000)
    vo = voicing(ch, 55, 72, 62, no_root, span=12)
    gtr = strum_comp(s, ch, vo, fit([(1.0, 0.4, 0.8), (1.5, 0.3, 0.55), (3.0, 0.4, 0.8), (3.5, 0.3, 0.55)]), r=r, bright=0.6,
                     t60=0.9, mute=0.05, spread=0.009)
    gtr = room(s, loop_filter(s, gtr, "hp", 180), 0.1, 0.8, "gtr", damp=5000)
    bass = line(s, ch, lambda c, n, i: [(0, 0.8, root_of(c, 38, 31, 45), 0.9), (2, 0.8, root_of(c, 38, 31, 45) + 7, 0.8)],
                v_upright, r=r)
    roll = [0, 2, 1, 3, 2, 1, 3, 2]  # banjo roll over the chord notes

    def pick_roll(c, n, i):
        notes = nearest_tones(c, 59, 76)
        return [(q * 0.5, 0.4, notes[roll[q] % len(notes)], 0.75 if q % 2 == 0 else 0.55) for q in range(8)]
    bj = line(s, ch, pick_roll, banjo, r=r, jit=0.004)
    bj = room(s, bj, 0.1, 0.8, "banjo", damp=6000)
    tn = tune("5:.5 6:.5 5:.5 3:.5 5:1 1+:1 | 6:.5 5:.5 3:.5 2:.5 1:2 | 3:.5 5:.5 6:.5 5:.5 3:1 2:1 | 1:4 |"
              " 5:.5 6:.5 5:.5 3:.5 5:1 1+:1 | 6:.5 1+:.5 6:.5 5:.5 3:2 | 4:.5 6:.5 1+:.5 6:.5 5:1 4:1 | 2:.5 3:.5 5:1 7:.5 5:.5 2:1 |"
              " 1+:.5 6:.5 5:.5 3:.5 2:1 3:1 | 4:.5 6:.5 5:.5 4:.5 3:2 | 3:.5 5:.5 6:.5 5:.5 3:.5 2:.5 1:1 | 2:1 5:1 7:1 5:1", t, 4)
    lead = lay(s, lambda ss, m, du, v: ins.guitar(m, s.sec(du), s.sr, bright=0.8, t60=0.9, pick=0.2, mute=0.04, key=m % 3) * v,
               tn, r=r, jit=0.004)
    lead = room(s, lead, 0.12, 0.9, "lead", damp=6000)
    lp = lambda x: loop_filter(s, x, "lp", 4500)  # noqa: E731  (fewer highs, smaller file)
    return {"drums": lp(d), "guitar": lp(gtr), "bass": mix_bass(s, bass, 1500), "lead": lp(bj), "keys": lp(lead)}


def nearest_tones(c, lo, hi):
    """Chord tones (without doubling the root an octave up) between lo and hi, sorted."""
    return S.chord_notes(c, lo, hi, [0, 4, 7])


def dusty_road_twang(s):
    """100 BPM: palm-muted root-fifth guitar, a steady kick, a twangy tune and slide fills."""
    r = dsp.rng(s.id, "dusty")
    ch, t = s.chords, s.tonic
    k = kits(s, "lofi", "rock")
    d = s.zeros()
    hits(s, d, k["kick"], "X...x...X...x...", r, gain=0.7)
    hits(s, d, k["snare"], "....x.......x...", r, gain=0.45)
    hits(s, d, k["hat"], "x.x.x.x.x.x.x.x.", r, gain=0.3)
    d = room(s, d, 0.1, 0.8, "drums", damp=5000)
    def pm(c, n, i):
        R = root_of(c, 50, 45, 56)
        return [(q * 0.5, 0.3, R if q % 4 != 3 else R + 7, 0.8 if q % 2 == 0 else 0.5) for q in range(8)]
    gtr = line(s, ch, pm, lambda ss, m, du, v: ins.guitar(m, 0.2, ss.sr, bright=0.5, t60=0.4, pick=0.2, mute=0.1, key=m % 3) * v, r=r)
    gtr = room(s, gtr, 0.08, 0.7, "gtr", damp=4500)
    bass = line(s, ch, lambda c, n, i: [(0, 0.9, root_of(c, 38, 31, 45), 0.9), (1, 0.8, root_of(c, 38, 31, 45) + 7, 0.7),
                                         (2, 0.9, root_of(c, 38, 31, 45), 0.85), (3, 0.8, root_of(c, 38, 31, 45) + 7, 0.7)],
                v_gbass, r=r)
    tn = tune("3:.5 5:.5 6:1 5:.5 3:.5 2:1 | 3:1 5:1 1+:2 | 6:.5 5:.5 3:1 5:.5 3:.5 1:1 | 2:1 3:1 5:2 |"
              " 3:.5 5:.5 6:1 5:.5 6:.5 1+:1 | 2+:1 1+:1 6:2 | 5:.5 3:.5 2:1 3:.5 2:.5 1:1 | 1:4", t, 4)
    lead = lead_line(s, tn, "twang", "dusty")
    lead = room(s, echo(s, lead, 0.75, 0.15, 0.3, 2, 3500), 0.14, 0.9, "lead", damp=6000)
    sl = lead_line(s, tune("r:4 | r:2 3+:1 1+:1 | r:4 | 7:1.5 5:.5 2:2 | r:4 | r:2 5:.5 6:.5 1+:1 | r:4 | 3:1 2:1 1:2", t, 4),
                   "slide", "dusty2")
    sl = room(s, echo(s, sl, 0.75, 0.2, 0.35, 3, 3500), 0.2, 1.2, "slide", damp=5000)
    return {"drums": d, "guitar": gtr, "bass": mix_bass(s, bass, 1500), "lead": lead, "keys": sl}


def barn_dance(s):
    """128 BPM barn-dance two-step: a fiddle tune, offbeat guitar chops and an upright bass on one and three."""
    r = dsp.rng(s.id, "barn")
    ch, t = s.chords, s.tonic
    k = kits(s, "lofi", "rock")
    d = s.zeros()
    hits(s, d, k["kick"], "X.......x.......", r, gain=0.7)
    hits(s, d, k["snare"], "....x.......x...", r, gain=0.5)
    hits(s, d, k["hat"], "x.x.x.x.x.x.x.x.", r, gain=0.3)
    d = room(s, d, 0.08, 0.7, "drums", damp=5000)
    vo = voicing(ch, 55, 72, 62, no_root, span=12)
    gtr = strum_comp(s, ch, vo, fit([(0.5, 0.25, 0.6), (1.0, 0.3, 0.8), (1.5, 0.25, 0.6), (2.5, 0.25, 0.6), (3.0, 0.3, 0.8),
                                     (3.5, 0.25, 0.6)]), r=r, bright=0.6, t60=0.6, mute=0.04, spread=0.008)
    gtr = room(s, loop_filter(s, gtr, "hp", 180), 0.08, 0.7, "gtr", damp=5000)
    def bl(c, n, i):
        R = root_of(c, 38, 31, 45)
        return [(0, 0.9, R, 0.95), (1, 0.8, R + 7, 0.7), (2, 0.9, R, 0.9), (3, 0.8, R + 7 if c.dur > 2 else R, 0.7)][
            :4 if c.dur >= 4 else 2]
    bass = line(s, ch, bl, v_upright, r=r)
    tn = tune("5:.5 5:.5 3:.5 5:.5 1+:.5 6:.25 5:.25 3:.5 5:.5 | 6:.5 6:.5 5:.5 3:.5 2:.5 3:.5 1:1 |"
              " 5:.5 5:.5 3:.5 5:.5 1+:.5 3+:.5 2+:.5 1+:.5 | 5:.5 1+:.5 7:.5 5:.5 2+:2 |"
              " 1+:.5 6:.5 5:.5 3:.5 5:.5 6:.5 1+:1 | 6:.5 5:.5 3:.5 2:.5 1:2 |"
              " 4:.5 6:.5 1+:.5 6:.5 4+:.5 1+:.5 6:1 | 5:.5 3:.5 2:.5 3:.5 5:2 |"
              " 2+:.5 2+:.5 7:.5 5:.5 2+:.5 7:.5 5:1 | 4:.5 6:.5 1+:.5 6:.5 4:1 6:1 |"
              " 5:.5 3:.5 5:.5 1+:.5 3+:1 5:1 | 1+:3 r:1", t, 4)
    tn = [(b, d_, m, v) for b, d_, m, v in tn]
    lead = lead_line(s, tn, "fiddle", "barn")
    lead = room(s, lead, 0.12, 0.9, "lead", damp=6000)
    return {"drums": d, "guitar": gtr, "bass": mix_bass(s, bass, 1500), "lead": lead}


# ==================================================================== BLUES (E)

def shuffle_drums(s, r, k, gain=1.0, accents="...X.....X.."):
    d = s.zeros()
    hits(s, d, k["hat"], "x.xx.xx.xx.x", r, gain=0.45 * gain)
    hits(s, d, k["snare"], accents, r, gain=0.8 * gain)
    hits(s, d, k["kick"], "X.....x.....", r, gain=0.8 * gain)
    return d


def midnight_shuffle(s):
    """112 BPM twelve-bar shuffle: swung drums, walking bass, piano comping and a clean electric guitar."""
    r = dsp.rng(s.id, "midnight")
    ch, t = s.chords, s.tonic
    k = kits(s, "lofi")
    d = room(s, shuffle_drums(s, r, k), 0.1, 0.8, "drums", damp=5000)
    wk = walk(s, 33, 50, seed="mid")
    bass = s.zeros()
    for b, m, v in wk:
        at(s, bass, S.v_upright(s, m, 0.9, v), b, 1.0, dt=float(r.normal(0, 0.004)))
    vo = voicing(ch, 55, 72, 63, no_root)
    pno = chop(s, ch, vo, [(0, 0.5, 0.65), (1.0, 0.3, 0.5), (1.67, 0.3, 0.6), (2.0, 0.5, 0.65), (3.0, 0.3, 0.5), (3.67, 0.3, 0.6)],
               S.v_piano, r, 0.8)
    pno = room(s, loop_filter(s, pno, "hp", 200), 0.12, 0.9, "piano", damp=5000)
    lick_a = "5:.67 6:.33 5:.67 3:.33 5:1 1+:1 | "
    tn = tune("r:4 | r:4 | " + lick_a + "r:1 3:.5 2:.5 1:2 | 6:.67 1+:.33 6:.67 5:.33 3:2 | 4:1 6:1 5:2 | " +
              lick_a + "3:1 2:1 1:2 | 2+:1 7:1 5:2 | 6:1 5:1 3:1 2:1 | 1:2 3:.67 5:.33 6:1 | 5:2 7:1 5:1", t, 4)
    gtr = lay(s, lambda ss, m, du, v: ins.guitar(m, ss.sec(du), ss.sr, bright=0.7, t60=1.0, pick=0.2, mute=0.04, key=m % 3) * v,
              tn, r=r, jit=0.004)
    gtr = room(s, echo(s, gtr, 1.0, 0.1, 0.3, 2, 3500), 0.15, 1.0, "gtr", damp=5000)
    gtr = 0.3 * np.tanh(gtr / (0.3 * dsp.peak(gtr)))
    return {"drums": loop_filter(s, d, "lp", 5000), "bass": mix_bass(s, bass, 1300), "keys": pno,
            "guitar": loop_filter(s, gtr, "lp", 4500)}


def crossroad_stomp(s):
    """104 BPM stomping blues: heavy kick, handclaps, a gritty riff and a slide guitar line."""
    r = dsp.rng(s.id, "cross")
    ch, t = s.chords, s.tonic
    k = kits(s, "rock", "dance")
    d = s.zeros()
    hits(s, d, k["kick"], "X...x...X...x...", r, gain=1.0)
    hits(s, d, k["clap"], "....X.......X...", r, gain=0.8)
    hits(s, d, k["hat"], "..x...x...x...x.", r, gain=0.25)
    d = room(s, d, 0.12, 0.9, "drums", damp=4500)
    gtr = s.zeros()
    for c in ch:
        R = root_of(c, 40, 40, 52)
        for bt, du, kind in ((0, 0.9, "o"), (1.5, 0.25, "m"), (2.0, 0.4, "o"), (3.0, 0.4, "m"), (3.5, 0.4, "o")):
            if bt < c.dur:
                at(s, gtr, M.power_chord(R, s.sec(du), s.sr, muted=(kind == "m"), key=int(bt * 2) % 2), c.start + bt,
                   1.0 if kind == "o" else 0.8, dt=float(r.normal(0, 0.003)))
    gtr = dsp.loop_apply(gtr / dsp.peak(gtr), lambda z: ins.amp_sim(z, s.sr, gain=5.0, tone=3800))
    gtr = room(s, gtr / dsp.peak(gtr), 0.12, 0.9, "gtr", damp=4000)
    bass = line(s, ch, lambda c, n, i: [(0, 0.9, root_of(c, 33, 28, 40), 1.0), (1.5, 0.4, root_of(c, 33, 28, 40) + 7, 0.7),
                                         (2, 0.9, root_of(c, 33, 28, 40), 0.9), (3.5, 0.4, root_of(c, 33, 28, 40) + 4, 0.7)],
                v_gbass, r=r)
    tn = tune("r:2 5:.5 6:.5 1+:1 | 6:1 5:.5 3:.5 1:2 | r:2 5:.5 6:.5 1+:1 | 3+:1 2+:1 1+:2 |"
              " 6:1 4+:1 6:.5 4+:.5 1+:1 | 6:1 4:1 6:2 | 5:1 3:1 5:1 6:1 | 5:1.5 3:.5 1:2 |"
              " 2+:1 7:1 5:2 | 1+:1 6:1 4:2 | 3:.5 5:.5 6:1 5:1 3:1 | 2:2 5:2", t, 4)
    sl = lead_line(s, tn, "slide", "cross")
    sl = room(s, echo(s, sl, 0.75, 0.15, 0.3, 2, 3500), 0.15, 1.0, "slide", damp=5000)
    lp = lambda x: loop_filter(s, x, "lp", 4500)  # noqa: E731
    return {"drums": lp(d), "guitar": lp(gtr), "bass": mix_bass(s, bass, 1800), "lead": lp(sl)}


def rainy_harp(s):
    """84 BPM slow eight-bar blues in 12/8: a harmonica-like lead, an organ bed, brushed drums, upright bass."""
    r = dsp.rng(s.id, "rainy")
    ch, t = s.chords, s.tonic
    k = kits(s, "jazz")
    d = s.zeros()
    hits(s, d, k["tap"], "x.xx.xx.xx.x", r, gain=0.6)
    hits(s, d, k["feather"], "X.....x.....", r, gain=0.7)
    hits(s, d, k["snare"], "...o.....o..", r, gain=0.3)
    d = room(s, d, 0.14, 1.1, "drums", damp=4500)
    org = comp(s, ch, voicing(ch, 50, 70, 60, no_root), lambda c, i: [(0, c.dur, 0.6)],
               lambda ss, m, du, v: v_organ(ss, m, du, v * 0.8, bars=(8, 5, 8, 3, 0, 0, 0, 0, 0), perc=0.0, att=0.08, rel=0.3),
               r=None, gain=0.8)
    org = room(s, S.leslie(s, org, 0.7, 0.2), 0.2, 1.4, "organ", damp=4000)
    bass = s.zeros()
    for b, m, v in walk(s, 31, 46, seed="rainy"):
        at(s, bass, S.v_upright(s, m, 0.9, v), b, 1.0, dt=float(r.normal(0, 0.005)))
    tn = tune("r:1 3:.5 5:.5 6:1.5 5:.5 | 3:2 2:1 3:1 | 5:1.5 6:.5 1+:2 | 6:1 5:1 3:2 |"
              " r:1 3:.5 5:.5 6:1.5 5:.5 | 1+:1.5 2+:.5 7:2 | 6:1 5:1 3:1 2:1 | 1:3 r:1", t, 4)
    harp = lead_line(s, tn, "harp", "rainy")
    harp = room(s, echo(s, harp, 1.0, 0.12, 0.3, 2, 3000), 0.25, 1.5, "harp", damp=4500)
    return {"drums": d, "organ": org, "bass": mix_bass(s, bass, 1100), "lead": harp}


# ============================================================ registry

SONGS = {
    "velvet_evening": ("Imaj9:4 vi9:4 ii9:4 V7sus4:2 V7:2 Imaj9:4 IVmaj7:4 iii7:2 vi7:2 ii9:2 V7sus4:2",
                       velvet_evening, {"lead": -20, "keys": -21, "bass": -18}),
    "slow_jam_rain": ("Imaj7:4 iii7:4 vi7:4 ii7:2 V7sus4:2 IVmaj7:4 iii7:4 ii9:4 V7sus4:2 V7:2",
                      slow_jam_rain, {"pad": -26, "keys": -21, "lead": -21, "bass": -17, "drums": -19}),
    "silky_groove": ("ii9:4 V7:4 Imaj9:4 vi9:4 ii9:4 V7:4 Imaj9:4 IVmaj7:2 V7sus4:2",
                     silky_groove, {"keys": -21, "guitar": -22, "lead": -20}),
    "island_breeze": ("I:4 IV:4 I:4 V:4 I:4 IV:4 vi:2 V:2 I:4", island_breeze, {"organ": -24, "guitar": -22, "drums": -19}),
    "one_drop_sun": ("I:4 V:4 vi:4 IV:4 I:4 V:4 IV:4 I:2 V:2", one_drop_sun, {"organ": -26, "guitar": -23, "drums": -19.5}),
    "dub_lagoon": ("vi:4 IV:4 I:4 V:4 vi:4 IV:4 I:4 V:4", dub_lagoon, {"organ": -24, "guitar": -25, "bass": -17}),
    "porch_pickin": ("I:4 I:4 IV:4 I:4 I:4 I:4 IV:4 V:4 I:4 IV:4 V:4 I:4", porch_pickin,
                     {"keys": -21, "lead": -19, "guitar": -21}),
    "dusty_road_twang": ("I:4 IV:4 I:4 V:4 I:4 IV:4 V:4 I:4", dusty_road_twang, {"keys": -22, "guitar": -23}),
    "barn_dance": ("I:4 I:4 I:4 V:4 I:4 I:4 IV:4 I:4 V:4 IV:4 I:2 V:2 I:4", barn_dance, {"lead": -19}),
    "midnight_shuffle": ("I6:4 I6:4 I6:4 I6:4 IV6:4 IV6:4 I6:4 I6:4 V7:4 IV6:4 I6:4 V7:4", midnight_shuffle,
                         {"keys": -21, "drums": -22}),
    "crossroad_stomp": ("I:4 I:4 I:4 I:4 IV:4 IV:4 I:4 I:4 V:4 IV:4 I:4 I:4", crossroad_stomp, {"drums": -16}),
    "rainy_harp": ("I6:4 V7:4 IV6:4 IV6:4 I6:4 V7:4 I6:2 IV6:2 I6:2 V7:2", rainy_harp, {"organ": -23, "lead": -19}),
}
