"""Genre `classical` (D major): four original pieces. Imported by songs.py (load_extra); see songs.py for the notation."""
import numpy as np

import dsp
import instruments as ins
import music as M
import songs as S
from dsp import TAU, midi_hz, nsamp
from music import echo, loop_filter, room

T = 2  # D


def v_harpsi(s, m, d, v=0.7):
    """Harpsichord: a bright, quickly dying pluck with a quill click and an octave register shimmer."""
    x = ins.pluck_synth(m, s.sr, dur=0.45, cutoff=7000.0, decay=0.035, q=0.9)
    x = x + 0.35 * ins.pluck_synth(m + 12, s.sr, dur=0.45, cutoff=6000.0, decay=0.03, q=0.9)
    return x * v


def v_bow(s, m, d, v=0.8, vib=1.0, k=0):
    """Bowed string: a saw with delayed vibrato, a slow bow attack, darkened."""
    def mk():
        n = nsamp(s.sec(d) + 0.4, s.sr)
        t = np.arange(n) / s.sr
        f = midi_hz(m) * (1 + vib * 0.0035 * np.sin(TAU * 5.4 * t) * np.clip((t - 0.25) / 0.4, 0, 1))
        x = dsp.saw(f * 2 ** (4 / 1200), n, s.sr) + dsp.saw(f * 2 ** (-4 / 1200), n, s.sr, 0.3)
        x = dsp.lowpass(x, 2800, s.sr, 2)
        x *= dsp.env_adsr(n, s.sr, 0.12, 0.3, 0.85, s.sec(d), 0.25)
        return dsp.fade(x / (dsp.peak(x) + 1e-9), s.sr, 0.002, 0.02)
    return M.cached(("bow", m, round(s.sec(d), 3), s.sr, vib, k), mk) * v


def v_pizz(s, m, d, v=0.8):
    return ins.guitar(m, 0.5, s.sr, bright=0.45, t60=0.35, pick=0.1, mute=0.6, key=m % 3, attack=0.002) * v


def arp(s, ch, voice, lo, hi, order, step, vel=0.6, r=None, gain=1.0, shape=None):
    """Broken chords: `order` indexes the sorted chord tones in [lo, hi], one note every `step` beats."""
    buf = s.zeros()
    for c in ch:
        ns = S.chord_notes(c, lo, hi)
        for i in range(int(c.dur / step)):
            m = ns[order[i % len(order)] % len(ns)]
            a = vel * (1.0 if i % 4 == 0 else 0.8)
            s.add(buf, voice(s, m, step * 1.6, a), c.start + i * step, gain, dt=float(r.normal(0, 0.003)) if r is not None else 0)
    return buf


def salon_morning(s):
    """Solo piano: a rolling left-hand arpeggio under a singing right-hand melody."""
    r = dsp.rng(s.id, "salon")
    ch = s.chords
    lh = arp(s, ch, lambda ss, m, d, v: S.v_piano(ss, m, d, v, bright=0.45, rel=0.4), 40, 66, [0, 2, 4, 3, 5, 3, 4, 2], 0.5,
             0.5, r)
    tn = S.tune("5:1 3:.5 5:.5 1+:2 | 7:1.5 5:.5 3:2 | 6:1 4:.5 6:.5 1+:2 | 2+:1.5 1+:.5 7:2 |"
                " 6:1 1+:.5 3+:.5 2+:1 1+:1 | 6:1.5 4:.5 6:2 | 6:1 4:1 2+:2 | 7:1 5:1 4:1 2:1", T, 4)
    mel = S.lay(s, lambda ss, m, d, v: S.v_piano(ss, m, d, v, bright=0.55, rel=0.5), tn, r=r, jit=0.006)
    return {"arp": room(s, lh, 0.22, 1.6, "lh", damp=4500), "keys": room(s, mel, 0.25, 1.6, "rh", damp=4500)}


def harpsichord_garden(s):
    """Baroque dance in 2/4 feel: harpsichord tune, a walking bass, broken chords and a light string bed."""
    r = dsp.rng(s.id, "garden")
    ch = s.chords
    tn = S.tune("1:.5 3:.5 5:.5 3:.5 1+:1 5:1 | 7:.5 2+:.5 7:.5 5:.5 2+:1 7:1 | 6:.5 1+:.5 3+:.5 1+:.5 6:1 3:1 |"
                " 5:.5 3:.5 5:.5 1+:.5 3+:1 1+:1 | 4+:.5 3+:.5 2+:.5 1+:.5 6:1 4:1 | 5:.5 7:.5 2+:.5 4+:.5 2+:1 7:1 |"
                " 3+:.5 1+:.5 5:.5 3:.5 5:1 1+:1 | 2+:.5 4+:.5 6+:.5 4+:.5 2+:1 6:1 | 7:.5 2+:.5 4+:.5 2+:.5 7:1 5:1 |"
                " 6:.5 1+:.5 3+:.5 1+:.5 6:1 3:1 | 5:.5 7:.5 2+:.5 4+:.5 2+:1 7:1 | 1+:2 5:1 r:1", T, 5)
    mel = S.lay(s, v_harpsi, tn, gain=1.0, r=r, jit=0.004)
    mel = room(s, echo(s, mel, 0.5, 0.18, 0.3, 2, 5000), 0.2, 1.2, "hm", damp=6000)
    ba = S.line(s, ch, lambda c, n, i: [(0, 1, S.root_of(c, 45, 38, 52), 0.9), (1, 1, S.root_of(c, 45, 38, 52) + 7, 0.6),
                                      (2, 1, S.root_of(c, 45, 38, 52), 0.8), (3, 1, S.root_of(c, 45, 38, 52) + 12, 0.6)],
                lambda ss, m, d, v: ins.pluck_synth(m, ss.sr, 0.3, 1800, 0.06) * v, r=r)
    ar = arp(s, ch, v_harpsi, 55, 69, [0, 1, 2, 1], 1.0, 0.45, r, 0.7)
    vo = S.voicing(ch, 55, 74, 64)
    st = s.zeros()
    for c, v in zip(ch, vo):
        for j, m in enumerate(v):
            s.add(st, v_bow(s, m, 3.6, 0.7, 0.8, j), c.start)
    st = room(s, loop_filter(s, st, "lp", 3500), 0.25, 1.6, "st", damp=4500)
    return {"keys": mel, "bass": loop_filter(s, ba, "lp", 1500), "arp": ar, "strings": st}


def dawn_quartet(s):
    """String quartet: a slow rising violin line, an alto and viola middle, a cello on the roots."""
    r = dsp.rng(s.id, "quartet")
    ch = s.chords
    tn = S.tune("3:3 5:1 | 7:2 2+:2 | 1+:3 6:1 | 5:2 3+:2 | 4+:3 2+:1 | 1+:1 2+:1 4+:2 | 5+:2 4+:1 2+:1 | 3+:3 r:1", T, 5)
    vln = S.lay(s, lambda ss, m, d, v: v_bow(ss, m, d, v), tn, r=r, jit=0.01)
    vo = S.voicing(ch, 57, 72, 64)
    mid = s.zeros()
    for c, v in zip(ch, vo):
        for j, m in enumerate(v[:3]):
            s.add(mid, v_bow(s, m, 3.7, 0.6, 0.9, j + 1), c.start, dt=0.015 * j)
    cello = S.line(s, ch, lambda c, n, i: [(0, 3.8, S.root_of(c, 43, 38, 50), 0.9)], lambda ss, m, d, v: v_bow(ss, m, d, v, 1.0, 7),
                   r=r, jit=0.01)
    return {"lead": room(s, vln, 0.3, 2.0, "vl", damp=5000), "strings": room(s, loop_filter(s, mid + cello, "lp", 3500), 0.3, 2.0, "vi", damp=4500)}


def sparrow_rondo(s):
    """Rondo A-B-A-C: staccato piano tune, pizzicato bass on the beats and chords on the off-beats."""
    r = dsp.rng(s.id, "rondo")
    ch = s.chords
    A = ("1:.5 3:.5 5:.5 3:.5 1+:.5 r:.5 5:1 | 7:.5 2+:.5 7:.5 5:.5 2+:.5 r:.5 7:1 |"
         " 1+:.5 3+:.5 1+:.5 5:.5 3:.5 r:.5 1:1 | 2:.5 5:.5 7:.5 5:.5 2+:1 r:1 |")
    A2 = A.replace("1+:.5 3+:.5 1+:.5 5:.5 3:.5 r:.5 1:1", "1+:.5 3+:.5 5+:.5 3+:.5 1+:1 5:1")
    B = ("6:.5 1+:.5 4+:.5 1+:.5 6+:1 4+:1 | 5+:.5 3+:.5 1+:.5 3+:.5 5:1 3:1 |"
         " 4+:.5 2+:.5 6:.5 4:.5 2+:1 r:1 | 5:.5 7:.5 2+:.5 4+:.5 2+:.5 7:.5 5:1 |")
    C = ("6:.5 1+:.5 3+:.5 1+:.5 6:.5 1+:.5 3+:1 | 6:.5 4+:.5 1+:.5 4+:.5 6:1 1+:1 |"
         " 2+:.5 5:.5 7:.5 2+:.5 4+:.5 2+:.5 7:1 | 1+:1 5:.5 3:.5 1:1 r:1")
    tn = S.tune(A + B + A2 + C, T, 5)
    mel = S.lay(s, lambda ss, m, d, v: S.v_piano(ss, m, min(d, 0.4), v, bright=0.7, rel=0.08), tn, r=r, jit=0.004)
    bass = S.line(s, ch, lambda c, n, i: [(0, 1, S.root_of(c, 38, 33, 45), 0.9), (2, 1, S.root_of(c, 38, 33, 45) + 7, 0.8)],
                  lambda ss, m, d, v: v_pizz(ss, m, d, v), r=r)
    vo = S.voicing(ch, 55, 72, 63, S.no_root)
    pz = S.comp(s, ch, vo, [(1.5, 0.3, 0.55), (3.5, 0.3, 0.55)], v_pizz, spread=0.01, r=r)
    return {"keys": room(s, mel, 0.12, 0.9, "rm", damp=6000), "bass": bass, "guitar": room(s, pz, 0.1, 0.8, "rp", damp=6000)}


SONGS = {
    "salon_morning": ("I:4 iii:4 IV:4 V:4 vi:4 IV:4 ii7:4 V7:4", salon_morning, {"keys": -18, "arp": -21}),
    "harpsichord_garden": ("I:4 V:4 vi:4 I:4 IV:4 V:4 I:4 ii:4 V7:4 vi:4 V7:4 I:4", harpsichord_garden,
                           {"keys": -19, "arp": -25, "strings": -26, "bass": -24}),
    "dawn_quartet": ("I:4 V:4 vi:4 iii:4 IV:4 ii:4 V7:4 I:4", dawn_quartet, {"lead": -19, "strings": -21}),
    "sparrow_rondo": ("I:4 V:4 I:4 V7:4 IV:4 I:4 ii:4 V7:4 I:4 V:4 I:4 V7:4 vi:4 IV:4 V7:4 I:4", sparrow_rondo,
                      {"keys": -18, "bass": -21, "guitar": -23}),
}
