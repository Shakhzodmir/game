"""Genre `folk` (G major): two celtic and two african pieces. Imported by songs.py (load_extra); see songs.py for the notation."""
import numpy as np

import dsp
import instruments as ins
import music as M
import songs as S
from dsp import TAU, midi_hz, nsamp
from music import echo, loop_filter, room

T = 7  # G


def notes(bars, dur):
    """'1 3 5 r ...' bars separated by '|' -> tune text with every note `dur` beats long."""
    return " | ".join(" ".join("%s:%s" % (d, dur) for d in b.split()) for b in bars.split("|"))


def v_fiddle(s, m, d, v=0.8, vib=0.6):
    """Fiddle: two slightly detuned saws, quick bow attack, vibrato on longer notes, a bright body."""
    def mk():
        n = nsamp(s.sec(d) + 0.12, s.sr)
        t = np.arange(n) / s.sr
        f = midi_hz(m) * (1 + vib * 0.004 * np.sin(TAU * 5.8 * t) * np.clip((t - 0.15) / 0.2, 0, 1))
        x = dsp.saw(f * 2 ** (3 / 1200), n, s.sr) + dsp.saw(f * 2 ** (-3 / 1200), n, s.sr, 0.4)
        x = dsp.filt(dsp.lowpass(x, 4500, s.sr, 2), "peak", 1500, s.sr, q=1.0, gain_db=4.0)
        x = x * dsp.env_adsr(n, s.sr, 0.025, 0.1, 0.85, s.sec(d), 0.06)
        return dsp.fade(x / (dsp.peak(x) + 1e-9), s.sr, 0.002, 0.015)
    return M.cached(("fiddle", m, round(s.sec(d), 3), s.sr, vib), mk) * v


def v_whistle(s, m, d, v=0.8):
    """Tin whistle: a nearly pure tone with a little 2nd harmonic and breath noise."""
    def mk():
        n = nsamp(s.sec(d) + 0.08, s.sr)
        t = np.arange(n) / s.sr
        f = midi_hz(m) * (1 + 0.002 * np.sin(TAU * 5.0 * t))
        x = dsp.sine(f, n, s.sr) + 0.12 * dsp.sine(2 * f, n, s.sr) + 0.03 * dsp.sine(3 * f, n, s.sr)
        x += 0.04 * dsp.bandpass(dsp.rng("whistle", m).standard_normal(n), 2500, 6000, s.sr)
        x = x * dsp.env_adsr(n, s.sr, 0.03, 0.1, 0.9, s.sec(d), 0.05)
        return dsp.fade(x / (dsp.peak(x) + 1e-9), s.sr, 0.002, 0.015)
    return M.cached(("whistle", m, round(s.sec(d), 3), s.sr), mk) * v


def v_kalimba(s, m, d, v=0.7):
    """Thumb piano: a metallic tine (a strong inharmonic partial) that dies fast, plus a woody click."""
    def mk():
        n = nsamp(1.1, s.sr)
        t = np.arange(n) / s.sr
        f = midi_hz(m)
        x = dsp.sine(f, n, s.sr) * np.exp(-t / 0.45) + 0.25 * dsp.sine(f * 5.4, n, s.sr) * np.exp(-t / 0.05)
        x += 0.1 * dsp.sine(f * 2, n, s.sr) * np.exp(-t / 0.2)
        x += 0.05 * dsp.bandpass(dsp.rng("kal", m).standard_normal(n), 1500, 5000, s.sr) * np.exp(-t / 0.006)
        return dsp.fade(x, s.sr, 0.0008, 0.05)
    return M.cached(("kalimba", m, s.sr), mk) * v


def bodhran(sr):
    return [dsp.lowpass(ins.tom(sr, 100.0 + 6 * i, 0.3, key=40 + i), 1800, sr) for i in range(3)]


def celtic(s, ch, tn, r, mel_voice, hi_from, kt, drum_pat, strum, drone_note):
    """Shared celtic band: fiddle (+ whistle an octave up from bar `hi_from`), strummed guitar, drone, bodhran."""
    lead = S.lay(s, mel_voice, tn, r=r, jit=0.005)
    lead = room(s, lead, 0.15, 1.0, "fid", damp=5000)
    wh = S.lay(s, lambda ss, m, d, v: v_whistle(ss, m + 12, d, v * 0.8), tn, r=r, jit=0.006, mask=S.bs("%d-%d" % (hi_from, s.bars)))
    wh = room(s, echo(s, wh, 0.75, 0.15, 0.3, 2, 5000), 0.2, 1.4, "wh", damp=6000)
    vo = S.voicing(ch, 50, 69, 59)
    gt = S.strum_comp(s, ch, vo, strum, r=r, bright=0.5, t60=0.8, mute=0.08, spread=0.008)
    gt = room(s, gt, 0.1, 0.8, "gt", damp=5000)
    dr = s.zeros()
    for b in range(0, int(s.bars * 4), 16):
        for j, m in enumerate(drone_note):
            s.add(dr, v_fiddle(s, m, 15.6, 0.5, 0.0), b + 0.02 * j)
    dr = loop_filter(s, dr, "lp", 1800)
    d = s.zeros()
    S.hits(s, d, bodhran(s.sr), drum_pat, r, gain=0.9, jit=0.004)
    return {"lead": lead, "brass": wh, "guitar": gt, "pad": dr, "drums": room(s, d, 0.1, 0.7, "bd", damp=3000)}


def green_hill_jig(s):
    """Jig in 12/8 feel (triplet eighths): fiddle tune, whistle on the repeat, drone, strummed chords, bodhran."""
    r = dsp.rng(s.id, "jig")
    tn = S.tune(notes("1 3 5 1+ 5 3 5 3 1 3 5 3|1+ 5 3 1+ 5 3 1+ 2+ 3+ 2+ 1+ 5|4 6 1+ 6 4 6 1+ 3+ 1+ 6 4 6|"
                      "5 3 5 1+ 5 3 2 3 5 3 1 r|1 3 5 1+ 5 3 5 3 1 3 5 1+|6 1+ 3+ 1+ 6 3 6 1+ 3+ 2+ 1+ 6|"
                      "4+ 3+ 2+ 1+ 6 4 6 1+ 4+ 6+ 4+ 1+|5 7 2+ 7 5 2 5 7 2+ 4+ 2+ 7|3+ 1+ 5 3+ 1+ 5 3+ 5+ 3+ 1+ 5 3|"
                      "4+ 6 4 6+ 6 4 4+ 6 1+ 6 4 6|5 7 2+ 4+ 2+ 7 5 7 2+ 7 5 2|1+ 5 3 1+ 5 3 1+ r r r r r", "1/3"), T, 4)
    out = celtic(s, s.chords, tn, r, v_fiddle, 5, 0, "X.ox.ox.ox.o",
                 [(0, 0.9, 0.9), (1, 0.6, 0.45), (2, 0.9, 0.75), (3, 0.6, 0.45)], [43, 50])
    bass = S.line(s, s.chords, lambda c, n, i: [(0, 1.8, S.root_of(c, 43, 36, 50), 0.9), (2, 1.8, S.root_of(c, 43, 36, 50) + 7, 0.7)],
                  lambda ss, m, d, v: S.v_gbass(ss, m, d, v), r=r)
    out["bass"] = bass
    return out


def misty_glen_reel(s):
    """Reel in the E-minor mode of G: straight eighths, a bowed drone, whistle lead and driving guitar."""
    r = dsp.rng(s.id, "reel")
    tn = S.tune(notes("6 3 6 7 1+ 7 6 3|6 3 6 3+ 2+ 1+ 7 6|4 6 1+ 6 4 6 1+ 3+|2+ 7 5 7 2+ 7 5 7|"
                      "6 3 6 7 1+ 3+ 1+ 7|7 5 7 3+ 2+ 7 5 3|4 6 1+ 3+ 2+ 1+ 6 4|5 7 2+ 7 5 2 5 7|"
                      "6 3 6 7 1+ 7 6 3|6 1+ 4+ 3+ 1+ 6 4 6|2+ 7 5 7 2+ 4+ 3+ 2+|6 5 3 5 6 r r r", "1/2"), T, 4)
    gs = [(0, 0.45, 0.9), (1, 0.45, 0.7), (1.5, 0.4, 0.5), (2, 0.45, 0.85), (3, 0.45, 0.7), (3.5, 0.4, 0.5)]
    out = celtic(s, s.chords, tn, r, lambda ss, m, d, v: v_whistle(ss, m, d, v), 5, 0, "X...x...X...x.o.",
                 gs, [43, 50])
    del out["brass"]
    out["bass"] = S.line(s, s.chords, lambda c, n, i: [(0, 1.8, S.root_of(c, 40, 33, 47), 0.9), (2, 1.8, S.root_of(c, 40, 33, 47), 0.7)],
                         lambda ss, m, d, v: S.v_gbass(ss, m, d, v), r=r)
    return out


def savanna_drums(s):
    """Polyrhythm: djembe (3 against 4 shakers), bells, a marimba ostinato and a vocal call and response."""
    r = dsp.rng(s.id, "savanna")
    k = S.kits(s, "latin")
    d = s.zeros()
    S.hits(s, d, k["conga_lo"], "X..x.xo..x.o", r, gain=0.9)
    S.hits(s, d, k["surdo"], "X.....o.....", r, gain=0.8)
    S.hits(s, d, k["shaker"], "x...x...x...x...", r, gain=0.4)
    S.hits(s, d, k["agogo_hi"], "x.x.xx.x.x.x", r, gain=0.5)
    d = loop_filter(s, d, "lp", 6000)
    call = "5:1 5:.5 3:.5 2:1 1:1 | 3:1.5 2:.5 1:2 |"
    resp = "r:2 1+:.5 1+:.5 5:1 | 3:.5 5:.5 3:.5 2:.5 1:2 |"
    tn = S.tune((call + resp + "5:1 6:.5 5:.5 3:1 2:1 | 3:1.5 2:.5 1:2 |" + resp.replace("5:1 |", "6:1 |", 1)
                + "1+:1 1+:.5 6:.5 5:1 3:1 | 2:1.5 3:.5 5:2 |" + resp).rstrip(" |"), T, 4)
    lead = S.lay(s, lambda ss, m, du, v: S.v_vox(ss, m, du, v, "o_alto"), [e for e in tn if int(e[0] // 4) % 4 < 2], r=r, jit=0.01)
    chor = S.lay(s, lambda ss, m, du, v: S.v_vox(ss, m, du, v * 0.8, "a_alto", key=1), [e for e in tn if int(e[0] // 4) % 4 >= 2], r=r, jit=0.01)
    voice = loop_filter(s, lead + chor, "lp", 4500)
    oc = [0, 1, 2, 1, 2, 3]
    keys = s.zeros()
    for c in s.chords:
        ns = S.chord_notes(c, 55, 79, [0, 4, 7, 14])
        for bar in range(int(c.dur // 4)):
            for i, st in enumerate([0, 3, 5, 6, 8, 11]):
                s.add(keys, S.v_marimba(s, ns[oc[i] % len(ns)], 0.3, 0.7 if st in (0, 6) else 0.5), c.start + bar * 4 + st / 3.0)
    bass = S.line(s, s.chords, lambda c, n, i: [(0, 1.5, S.root_of(c, 40, 33, 47), 0.9), (5 / 3, 0.8, S.root_of(c, 40, 33, 47) + 12, 0.7),
                                              (8 / 3, 1.0, S.root_of(c, 40, 33, 47) + 7, 0.7)], S.v_marimba, r=r)
    return {"drums": d, "voice": voice, "keys": loop_filter(s, keys, "lp", 5000), "bass": loop_filter(s, bass, "lp", 900)}


def kalimba_sunrise(s):
    """Kalimba ostinato and a high tune, a thumb-bass, soft shaker and rim ticks, a slow pad like the rising sun."""
    r = dsp.rng(s.id, "sunrise")
    ch = s.chords
    keys = s.zeros()
    for c in ch:
        ns = S.chord_notes(c, 55, 76, [0, 4, 7, 14])
        for i in range(8):
            s.add(keys, v_kalimba(s, ns[[0, 2, 1, 3, 2, 4, 1, 3][i] % len(ns)], 0.5, 0.65 if i % 4 == 0 else 0.45), c.start + i * 0.5,
                  dt=float(r.normal(0, 0.003)))
    tn = S.tune("3:1 5:.5 3:.5 1:1 3:1 | 6:1 4:1 6:1 4:.5 1:.5 | 6:1.5 5:.5 3:2 | 5:1 2:1 5:1 3:1 |"
                " 3:1 5:.5 3:.5 5:2 | 6:1 4:.5 6:.5 4:2 | 6:1.5 4:.5 2:2 | 5:1 7:1 5:1 r:1", T, 5)
    lead = S.lay(s, lambda ss, m, d, v: v_kalimba(ss, m, d, v * 1.1), tn, r=r, jit=0.004)
    lead = room(s, echo(s, lead, 0.75, 0.2, 0.35, 3, 5000), 0.25, 1.6, "kl", damp=6000)
    bass = S.line(s, ch, lambda c, n, i: [(0, 1, S.root_of(c, 43, 36, 50), 0.9), (2.5, 1, S.root_of(c, 43, 36, 50) + 7, 0.6)],
                  lambda ss, m, d, v: v_kalimba(ss, m, d, v * 1.3), r=r)
    k = S.kits(s, "latin")
    d = s.zeros()
    S.hits(s, d, k["shaker"], "x.ox.ox.x.ox.ox", r, gain=0.5)
    S.hits(s, d, k["rim"], "....x.......x...", r, gain=0.4)
    S.hits(s, d, k["conga_lo"], "X.....o.....o...", r, gain=0.6)
    vo = S.voicing(ch, 55, 74, 64)
    pad = s.zeros()
    for c, v in zip(ch, vo):
        for j, m in enumerate(v):
            s.add(pad, S.v_pad(s, m, 3.9, 0.7, cutoff=1500, att=1.0, rel=1.0, k=j), c.start - 0.1)
    pad = room(s, loop_filter(s, pad, "lp", 3500), 0.3, 2.0, "pd", damp=4000)
    return {"keys": room(s, keys, 0.2, 1.4, "kk", damp=6000), "lead": lead, "bass": bass,
            "drums": room(s, d, 0.1, 0.8, "dd", damp=5000), "pad": pad}


SONGS = {
    "green_hill_jig": ("I:4 I:4 IV:4 I:4 I:4 vi:4 IV:4 V:4 I:4 IV:4 V:4 I:4", green_hill_jig,
                       {"lead": -18, "brass": -22, "guitar": -22, "pad": -29, "drums": -20, "bass": -23}),
    "misty_glen_reel": ("vi:4 vi:4 IV:4 V:4 vi:4 iii:4 IV:4 V:4 vi:4 IV:4 V:4 vi:4", misty_glen_reel,
                        {"lead": -17, "brass": -26, "guitar": -22, "pad": -29, "drums": -20, "bass": -23}),
    "savanna_drums": ("I:4 I:4 I:4 I:4 IV:4 IV:4 I:4 I:4 V:4 IV:4 I:4 I:4", savanna_drums,
                      {"drums": -16, "voice": -19, "keys": -22, "bass": -21}),
    "kalimba_sunrise": ("I:4 IV:4 vi:4 V:4 I:4 IV:4 ii:4 V:4", kalimba_sunrise,
                        {"keys": -22, "lead": -19, "bass": -23, "drums": -21, "pad": -25}),
}
