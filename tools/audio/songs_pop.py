"""Pop, hip-hop and EDM jukebox songs (genres pop C, hiphop Eb, edm Ab). Same contract as songs.SONGS."""
import numpy as np

import dsp
import instruments as ins
import music as M
import songs as S
from dsp import TAU, midi_hz, nsamp
from music import echo, hit, loop_eq, loop_filter, room, sidechain

BEATS = lambda s: range(s.beats)  # noqa: E731  (a duck on every beat = four on the floor)


# ---------------------------------------------------------------- small shared voices / helpers

def v808(s, m, d, v=0.9):
    """808 bass: a sine with a quick pitch glide down onto the note, long tail, soft saturation."""
    n = nsamp(s.sec(d) + 0.15, s.sr)
    t = np.arange(n) / s.sr
    f = midi_hz(m) * (1 + 0.35 * np.exp(-t / 0.02))
    x = np.sin(TAU * np.cumsum(f) / s.sr) * dsp.env_adsr(n, s.sr, 0.003, 0.9, 0.8, s.sec(d), 0.08)
    return dsp.fade(np.tanh(1.8 * x) * 0.8, s.sr, 0.001, 0.02) * v


def kick808(sr):
    """Drum-part kick with a long pitch glide (trap / hip-hop)."""
    n = nsamp(0.45, sr)
    t = np.arange(n) / sr
    f = 46 + 130 * np.exp(-t / 0.035)
    x = np.sin(TAU * np.cumsum(f) / sr) * np.exp(-t / 0.16)
    return dsp.fade(np.tanh(2.0 * x), sr, 0.0005, 0.02)


def finish_drums(s, d, wet=0.08, drv=1.4, lp=6500):
    d = dsp.loop_apply(d, lambda z: dsp.lowpass(z, lp, s.sr, 2))
    return room(s, dsp.drive(d / dsp.peak(d) * 1.3, drv), wet * 0.6, 0.6, "drums", damp=5000)


def roll(s, buf, smp, beat, n, step, v0, v1, r):
    """A hat / snare roll of n hits that ramp from velocity v0 to v1."""
    for i in range(n):
        hit(s, buf, smp, beat + i * step, v0 + (v1 - v0) * i / max(1, n - 1), r, 0.0)


def arp(s, ch, lo, hi, voice, order, step=0.25, vel=0.7, mask=None):
    """Arpeggio over each chord's tones; order = indices (wrapped) cycled per step."""
    buf = s.zeros()
    for c in ch:
        tones = S.chord_notes(c, lo, hi)
        for q in range(int(round(c.dur / step))):
            beat = c.start + q * step
            if mask is not None and int(beat // 4) not in mask:
                continue
            s.add(buf, voice(s, tones[order[q % len(order)] % len(tones)], step, vel * (1.0 if q % 4 == 0 else 0.7)), beat)
    return buf


def rise(s, beat0, beats, level=1.0, seed="rise"):
    """Noise riser that starts at beat0 and ends `beats` later (wraps around the loop)."""
    r = dsp.rng(s.id, seed)
    L = nsamp(s.sec(beats), s.sr)
    t = np.arange(L) / L
    x = dsp.sweep_filter(r.standard_normal(L), 300.0 * (7000.0 / 300.0) ** (t ** 1.5), s.sr, q=2.5, kind="bp")
    buf = s.zeros()
    s.add(buf, dsp.fade(x * t ** 2.2 / dsp.peak(x), s.sr, 0.01, 0.004), beat0, level)
    return buf


def drop_impact(s, beat, midi=32, level=0.8):
    return np.roll(S.impact(s, midi, level, seed="imp%d" % beat), int(round(s.sec(beat) * s.sr)))


def v_soft(s, m, d, v=0.7, **_):
    """A cheap soft pad voice: two slightly detuned triangles under a slow envelope (few spectral peaks, small file)."""
    n = nsamp(s.sec(d) + 0.7, s.sr)
    x = dsp.triangle(midi_hz(m) * 0.9965, n, s.sr) + dsp.triangle(midi_hz(m) * 1.0035, n, s.sr)
    return dsp.fade(x * dsp.env_adsr(n, s.sr, 0.35, 0.3, 0.85, s.sec(d), 0.6), s.sr, 0.001, 0.02) * v * 0.5


def chorus_pad(s, ch, lo=57, hi=76, center=66, gain=1.0, mask=None, cutoff=1800.0):
    vo = S.voicing(ch, lo, hi, center, S.no_root)
    return S.comp(s, ch, vo, [(0, 4, 0.7)], lambda ss, m, du, v: v_soft(ss, m, du, v), gain=gain, mask=mask)


# ---------------------------------------------------------------- POP

def sunny_hook(s):
    """118 BPM bright pop: claps, a plucky synth hook, warm round bass."""
    r = dsp.rng(s.id, "sunny")
    ch, k = s.chords, S.kits(s, "dance")
    d = s.zeros()
    S.hits(s, d, k["kick"], "X.....x...x.....", r, jit=0.0)
    S.hits(s, d, k["clap"], "....X.......X...", r, gain=0.9, jit=0.0)
    S.hits(s, d, k["hat"], "o.x.o.x.o.x.o.xo", r, gain=0.4, jit=0.0)
    S.hits(s, d, k["crash"], {0: "X...............", 8: "X..............."}, r, gain=0.4, jit=0.0)
    d = finish_drums(s, d)
    bass = S.line(s, ch, lambda c, n, i: [(0, 0.9, S.root_of(c, 40, 33, 47), 1.0), (1.5, 0.4, S.root_of(c, 40, 33, 47), 0.8),
                                          (2.0, 0.9, S.root_of(c, 40, 33, 47) + 7, 0.8), (3.5, 0.4, S.root_of(c, 40, 33, 47) + 12, 0.7)],
                  S.v_sbass, r=r, jit=0.0)
    vo = S.voicing(ch, 55, 74, 64, S.no_root)
    keys = S.comp(s, ch, vo, [(0, 0.45, 0.8), (1.5, 0.45, 0.7), (2.5, 0.45, 0.8)], lambda ss, m, du, v: S.v_pluck(ss, m, du, v, cutoff=3000, decay=0.12), r=r, jit=0.0)
    keys = room(s, echo(s, keys, 0.75, 0.2, 0.35, 3, 4500), 0.15, 1.0, "keys", damp=6000)
    tn = S.tune("3:.5 5:.5 5:1 3:.5 5:.5 1+:1 | 5:.5 7:.5 2+:1 7:.5 5:.5 7:1 | 6:.5 1+:.5 3+:1 1+:.5 6:.5 1+:1 | 4:.5 6:.5 1+:1 6:.5 4:.5 6:1 |"
                " 3:.5 5:.5 5:1 3:.5 5:.5 3+:1 | 5:.5 7:.5 2+:1 7:.5 2+:.5 5+:1 | 6:.5 1+:.5 3+:1 5+:.5 3+:.5 1+:1 | 4+:.5 3+:.5 1+:1 6:1 4:1 |"
                " 6:1 4+:1 1+:2 | 5:.5 7:.5 2+:1 5+:2", s.tonic, 5)
    lead = S.lay(s, lambda ss, m, du, v: dsp.mix(S.v_pluck(ss, m, du, v, cutoff=5000, decay=0.14), 0.4 * S.v_celesta(ss, m + 12, du, v, t60=0.4)), tn)
    lead = room(s, echo(s, lead, 0.75, 0.2, 0.35, 3, 4500), 0.18, 1.2, "lead", damp=7000)
    return {"drums": d, "bass": sidechain(s, bass, BEATS(s), 0.3, 0.1), "keys": keys, "lead": lead,
            "pad": chorus_pad(s, ch, gain=0.8)}


def city_lights_pop(s):
    """104 BPM indie-pop: jangly picked guitar, soft kit, airy pad, a vibes hook."""
    r = dsp.rng(s.id, "city")
    ch, k = s.chords, S.kits(s, "lofi")
    d = s.zeros()
    S.hits(s, d, k["kick"], "X.....x...x.....", r, jit=0.002, swing=0.08)
    S.hits(s, d, k["snare"], "....x.......x...", r, jit=0.002)
    S.hits(s, d, k["rim"], "....o..g....o...", r, gain=0.5, jit=0.002, mask=S.bs("5-8"))
    S.hits(s, d, k["hat"], "x.o.x.o.x.o.x.ox", r, gain=0.45, jit=0.002, swing=0.08)
    d = finish_drums(s, d, 0.12, 1.2)
    gtr = arp(s, ch, 52, 79, lambda ss, m, du, v: S.v_nylon(ss, m, 0.5, v), [0, 3, 5, 3, 4, 3, 5, 2], step=0.5, vel=0.8)
    gtr = room(s, echo(s, gtr, 0.75, 0.2, 0.4, 3, 4000), 0.2, 1.3, "gtr", damp=6000)
    bass = S.line(s, ch, lambda c, n, i: [(0, 1.4, S.root_of(c, 40, 33, 47), 1.0), (2.0, 0.9, S.root_of(c, 40, 33, 47), 0.8),
                                          (3.0, 0.9, S.root_of(c, 40, 33, 47) + 7, 0.7)], S.v_gbass, r=r, jit=0.002)
    tn = S.tune("r:1 5:.5 3:.5 5:1 1+:1 | 7:1.5 5:.5 3:2 | 6:.5 1+:.5 4+:1 3+:.5 1+:.5 6:1 | 7:1 5:1 2+:2 |"
                " r:1 5:.5 3:.5 5:1 1+:1 | 7:.5 3+:.5 5+:1 3+:2 | 4+:1 3+:.5 1+:.5 6:2 | 2+:1 1+:1 7:2", s.tonic, 5)
    lead = room(s, S.lay(s, S.v_vibes, tn, gain=1.0), 0.25, 1.6, "lead", damp=6000)
    pad = chorus_pad(s, ch, 55, 76, 65, 1.0, cutoff=1400)
    return {"drums": d, "guitar": gtr, "bass": bass, "lead": lead, "pad": pad}


def summer_crush(s):
    """124 BPM upbeat pop: four on the floor, piano off-beat chords, vocal chops and a bouncy hook."""
    r = dsp.rng(s.id, "crush")
    ch, k = s.chords, S.kits(s, "dance")
    d = s.zeros()
    S.hits(s, d, k["kick"], "X...X...X...X...", r, jit=0.0)
    S.hits(s, d, k["clap"], "....X.......X...", r, gain=0.8, jit=0.0)
    S.hits(s, d, k["ohat"], "..x...x...x...x.", r, gain=0.5, jit=0.0)
    S.hits(s, d, k["hat"], "o.o.o.o.o.o.o.o.", r, gain=0.3, jit=0.0)
    S.hits(s, d, k["crash"], {0: "X...............", 8: "X..............."}, r, gain=0.4, jit=0.0)
    d = finish_drums(s, d)
    vo = S.voicing(ch, 55, 76, 65, S.no_root)
    pno = S.comp(s, ch, vo, [(0.5, 0.4, 0.8), (1.5, 0.4, 0.7), (2.5, 0.4, 0.8), (3.5, 0.4, 0.7)],
                 lambda ss, m, du, v: S.v_piano(ss, m, du, v, bright=0.7), r=r, jit=0.002)
    pno = sidechain(s, pno, BEATS(s), 0.35, 0.12)
    bass = S.line(s, ch, lambda c, n, i: [(q + 0.5, 0.4, S.root_of(c, 40, 33, 47), 1.0) for q in range(4)], S.v_sbass, r=r, jit=0.0)
    bass = sidechain(s, bass, BEATS(s), 0.5, 0.1)
    vox = S.comp(s, ch, S.voicing(ch, 64, 80, 72, S.no_root), [(0.75, 0.25, 0.8), (1.25, 0.25, 0.7), (2.75, 0.25, 0.8)],
                 lambda ss, m, du, v: S.v_vox(ss, m, du, v, vowel="a_alto"), r=r, jit=0.0, mask=S.bs("5-12"))
    vox = room(s, vox, 0.25, 1.2, "vox", damp=6000)
    tn = S.tune("5:.5 5:.5 3:.5 5:.5 1+:2 | 7:.5 7:.5 5:.5 3:.5 5:2 | 6:.5 6:.5 4+:.5 1+:.5 6:2 | 5:.5 7:.5 2+:1 7:.5 5:.5 2:1 |"
                " 5:.5 5:.5 3:.5 5:.5 3+:2 | 7:.5 7:.5 5:.5 3:.5 7:2 | 6:.5 6:.5 4+:.5 1+:.5 6:2 | 2+:1 7:1 5:2 |"
                " 6:1 1+:1 3+:2 | 4+:1 1+:1 6:2 | 6:1 4:1 2+:2 | 7:.5 2+:.5 5+:1 2+:2", s.tonic, 5)
    lead = S.lay(s, lambda ss, m, du, v: S.v_pluck(ss, m, du, v, cutoff=4500, decay=0.12), tn)
    lead = sidechain(s, room(s, echo(s, lead, 0.75, 0.2, 0.35, 3, 4500), 0.15, 1.1, "lead", damp=6500), BEATS(s), 0.25, 0.1)
    return {"drums": d, "keys": pno, "bass": bass, "voice": vox, "lead": lead}


# ---------------------------------------------------------------- HIP-HOP

def boom_bap_sunrise(s):
    """88 BPM boom-bap: dusty swung kick and snare, a mellow e-piano loop, upright bass."""
    r = dsp.rng(s.id, "boom")
    ch, k = s.chords, S.kits(s, "lofi")
    d = s.zeros()
    S.hits(s, d, k["kick"], "X.....x..xx.....", r, swing=0.18, jit=0.004)
    S.hits(s, d, k["snare"], "....X.......X..g", r, jit=0.004)
    S.hits(s, d, k["hat"], "x.o.x.o.x.o.x.og", r, gain=0.45, swing=0.18, jit=0.004)
    d = finish_drums(s, d, 0.1, 1.3)
    vo = S.voicing(ch, 55, 76, 65, S.no_root)
    ep = S.comp(s, ch, vo, [(0, 1.4, 0.8), (1.75, 0.5, 0.6), (2.5, 1.4, 0.7)], lambda ss, m, du, v: S.v_epiano(ss, m, du, v, 0.7, 0.35), r=r, jit=0.004, swing=0.18)
    ep = room(s, ep, 0.15, 1.2, "ep", damp=5000)
    bass = S.line(s, ch, lambda c, n, i: [(0, 1.4, S.root_of(c, 39, 31, 46), 1.0), (1.5, 0.4, S.root_of(c, 39, 31, 46) + 7, 0.7),
                                          (2.5, 0.9, S.root_of(c, 39, 31, 46), 0.9), (3.5, 0.4, S.root_of(c, 39, 31, 46) + 12, 0.6)],
                  S.v_upright, r=r, jit=0.004, swing=0.18)
    tn = S.tune("r:1 3:.5 5:.5 6:1 5:1 | 4:1 2:.5 4:.5 6:2 | 5:1.5 4:.5 2:2 | 3:1 5:1 7:2 |"
                " r:1 3:.5 5:.5 6:1 1+:1 | 4:1 6:.5 4:.5 2:2 | 7:1 5:1 2+:2 | 1+:3 r:1", s.tonic, 5)
    lead = room(s, echo(s, S.lay(s, S.v_vibes, tn, gain=1.0), 0.75, 0.2, 0.35, 3, 3500), 0.2, 1.4, "lead", damp=5000)
    return {"drums": d, "keys": ep, "bass": bass, "lead": lead}


def trap_playground(s):
    """140 BPM trap: half-time clap, rolling hats, 808 sub and a bell melody."""
    r = dsp.rng(s.id, "trap")
    ch, k = s.chords, S.kits(s, "street", "dance")
    kk = [kick808(s.sr)]
    hat = [ins.hat(s.sr, 0.03, key=100 + i) * 0.8 for i in range(3)]
    d = s.zeros()
    S.hits(s, d, kk, {0: "X..x......x.....", 1: "X.....x....x....", 2: "X..x......x..x..", "*": "X.....x...x.....", 3: "X..x......x.....",}, r, jit=0.0, gain=1.0)
    S.hits(s, d, k["clap"], "........X.......", r, jit=0.0, gain=0.9)
    S.hits(s, d, hat, "x.x.x.x.x.x.x.x.", r, gain=0.5, jit=0.0)
    for bar in range(s.bars):
        b = bar * 4
        if bar % 2 == 1:
            roll(s, d, hat, b + 3.0, 6, 1 / 6, 0.3, 0.7, r)
        if bar % 4 == 0:
            roll(s, d, hat, b + 1.5, 4, 0.125, 0.4, 0.5, r)
        if bar % 4 == 3:
            roll(s, d, hat, b + 3.5, 8, 0.0625, 0.3, 0.8, r)
    d = finish_drums(s, d, 0.05, 1.1)
    bass = S.line(s, ch, lambda c, n, i: [(0, 1.5, S.root_of(c, 47, 43, 54), 1.0), (1.75, 0.25, S.root_of(c, 47, 43, 54), 0.8),
                                          (2.5, 1.0, S.root_of(c, 47, 43, 54), 0.9), (3.5, 0.5, S.root_of(c, 47, 43, 54) + 7, 0.7)], v808, r=r, jit=0.0)
    a = "3+:1 1+:.5 6:.5 1+:1 3+:1 | 4+:1 1+:.5 6:.5 4:1 6:1 | 5:1 3+:.5 1+:.5 5:1 3+:1 | 7:1 5:.5 2+:.5 7:1 5:1"
    a2 = "3+:1 1+:.5 6:.5 1+:1 5+:1 | 4+:1 1+:.5 6:.5 4:1 1+:1 | 5:1 3+:.5 1+:.5 3+:1 5+:1 | 7:.5 5:.5 2+:.5 5:.5 7:2"
    tn = S.tune(a + " | " + a + " | " + a2, s.tonic, 4)
    bell = S.lay(s, lambda ss, m, du, v: ins.bell_fm(float(midi_hz(m)), 1.0, ss.sr, 3.5, 1.6, 0.9) * v * 0.6, tn)
    bell = room(s, echo(s, bell, 0.75, 0.25, 0.4, 3, 5000), 0.2, 1.3, "bell", damp=6000)
    return {"drums": d, "bass": bass, "lead": bell, "pad": chorus_pad(s, ch, 55, 74, 64, 0.7, cutoff=1000)}


def street_cipher(s):
    """94 BPM hip-hop groove: heavy kick, claps, plucky keys and a sub bass."""
    r = dsp.rng(s.id, "cipher")
    ch, k = s.chords, S.kits(s, "street", "dance")
    d = s.zeros()
    S.hits(s, d, k["bass"], "X.....x..x.x....", r, jit=0.002, gain=1.0)
    S.hits(s, d, k["clap"], "....X.......X...", r, gain=0.9, jit=0.002)
    S.hits(s, d, k["hat"], "x.xox.xox.xox.xo", r, gain=0.4, jit=0.002, swing=0.1)
    S.hits(s, d, k["snare"], "....o.......o..g", r, gain=0.4, jit=0.002)
    d = finish_drums(s, d, 0.08, 1.4)
    vo = S.voicing(ch, 55, 74, 64, S.no_root)
    keys = S.comp(s, ch, vo, [(0, 0.4, 0.8), (0.75, 0.4, 0.6), (2.0, 0.4, 0.8), (3.0, 0.3, 0.6)],
                  lambda ss, m, du, v: S.v_pluck(ss, m, du, v, cutoff=2600, decay=0.1), r=r, jit=0.002)
    keys = room(s, keys, 0.15, 0.9, "keys", damp=5000)
    bass = S.line(s, ch, lambda c, n, i: [(0, 1.0, S.root_of(c, 39, 31, 44), 1.0), (1.5, 0.4, S.root_of(c, 39, 31, 44), 0.8),
                                          (2.25, 0.5, S.root_of(c, 39, 31, 44), 0.9), (3.0, 0.9, S.root_of(c, 39, 31, 44) + 7, 0.8)], S.v_sub, r=r, jit=0.0)
    p = "6:.5 1+:.5 3+:1 1+:.5 6:.5 3:1 | 5:.5 7:.5 2+:1 7:.5 5:.5 2:1 | 4:.5 6:.5 1+:1 6:.5 4:.5 1:1 | "
    tn = S.tune(p + "5:.5 7:.5 2+:.5 7:.5 5:2 | " + p + "1+:.5 5:.5 3:1 1:2", s.tonic, 4)
    lead = room(s, echo(s, S.lay(s, lambda ss, m, du, v: S.v_pluck(ss, m, du, v, cutoff=3800, decay=0.1), tn), 0.75, 0.2, 0.3, 3, 3500), 0.12, 0.9, "lead", damp=6000)
    return {"drums": d, "keys": keys, "bass": bass, "lead": lead}


# ---------------------------------------------------------------- EDM

def festival_drop(s):
    """128 BPM big-room: an 8-bar build (pad, snare roll, riser) then a supersaw drop on a pumping kick."""
    r = dsp.rng(s.id, "fest")
    ch, k = s.chords, S.kits(s, "dance")
    d = s.zeros()
    S.hits(s, d, k["kick"], "X...X...X...X...", r, jit=0.0, mask=set(range(4, 16)))
    S.hits(s, d, k["clap"], "....X.......X...", r, gain=0.9, jit=0.0, mask=set(range(8, 16)))
    S.hits(s, d, k["ohat"], "..x...x...x...x.", r, gain=0.55, jit=0.0, mask=set(range(8, 16)))
    S.hits(s, d, k["crash"], {0: "X...............", 8: "X...............", 12: "X..............."}, r, gain=0.5, jit=0.0)
    roll(s, d, k["snare"], 24, 16, 0.25, 0.2, 0.7, r)
    roll(s, d, k["snare"], 28, 16, 0.25, 0.4, 1.0, r)
    d = finish_drums(s, d, 0.05, 1.3, 4500)
    vo = S.voicing(ch, 56, 80, 68, S.no_root)
    saw = S.comp(s, ch, vo, [(0, 4, 0.9)], lambda ss, m, du, v: S.v_super(ss, m, du, v, att=0.01, rel=0.1, k=m % 3), r=r, jit=0.0, mask=set(range(8, 16)))
    saw = sidechain(s, loop_filter(s, saw, "lp", 4500), BEATS(s), 0.8, 0.16)
    saw = room(s, saw, 0.06, 0.8, "saw", damp=4000)
    pad = chorus_pad(s, ch, 57, 78, 67, 1.0, mask=set(range(0, 8)), cutoff=500)
    bass = S.line(s, ch, lambda c, n, i: [(q + 0.5, 0.45, S.root_of(c, 48, 43, 55), 1.0) for q in range(4)], S.v_sbass, r=r, jit=0.0, mask=set(range(8, 16)))
    bass = sidechain(s, loop_filter(s, bass, "lp", 400, 4), BEATS(s), 0.6, 0.12)
    a = "6:1 1+:1 3+:1.5 1+:.5 | 4+:1 6:1 1+:2 | 7:1 2+:1 5+:1.5 2+:.5 | 7:1 5:1 3:2"
    b = "3+:1 1+:.5 6:.5 3+:2 | 4+:2 1+:.5 6:.5 4:1 | 5+:1 2+:1 7:1 5:1 | 3+:3 r:1"
    tn = S.tune(" | ".join(["r:4"] * 8) + " | " + a + " | " + b, s.tonic, 4)
    lead = S.lay(s, lambda ss, m, du, v: S.v_super(ss, m, du, v, att=0.01, rel=0.12), tn)
    lead = sidechain(s, room(s, echo(s, lead, 0.75, 0.15, 0.3, 2, 3500), 0.1, 0.9, "lead", damp=4500), BEATS(s), 0.5, 0.12)
    fx = rise(s, 16, 16, 0.5) + drop_impact(s, 32)
    return {"drums": d, "keys": saw, "pad": pad, "bass": bass, "lead": lead, "fx": fx}


def deep_house_sunset(s):
    """122 BPM deep house: soft four on the floor, off-beat bass, warm chord stabs, shaker."""
    r = dsp.rng(s.id, "deep")
    ch, k = s.chords, S.kits(s, "dance", "lofi")
    d = s.zeros()
    S.hits(s, d, k["kick"], "X...X...X...X...", r, jit=0.0, gain=0.9)
    S.hits(s, d, k["clap"], "....x.......x...", r, gain=0.6, jit=0.0)
    S.hits(s, d, k["ohat"], "..x...x...x...x.", r, gain=0.5, jit=0.0)
    S.hits(s, d, k["shaker"], "o.g.o.g.o.g.o.g.", r, gain=0.35, jit=0.002, swing=0.1)
    d = finish_drums(s, d, 0.1, 1.2)
    bass = S.line(s, ch, lambda c, n, i: [(q + 0.5, 0.4, S.root_of(c, 40, 33, 46) + (12 if (q == 3) else 0), 1.0 if q % 2 == 0 else 0.8) for q in range(4)],
                  S.v_sbass, r=r, jit=0.0)
    bass = sidechain(s, bass, BEATS(s), 0.6, 0.12)
    vo = S.voicing(ch, 55, 76, 65, S.no_root)
    ep = S.comp(s, ch, vo, [(0, 0.75, 0.8), (1.5, 0.5, 0.7), (2.5, 0.5, 0.8), (3.25, 0.5, 0.6)],
                lambda ss, m, du, v: S.v_epiano(ss, m, du, v, 0.6, 0.3), r=r, jit=0.002)
    ep = room(s, sidechain(s, echo(s, ep, 0.75, 0.2, 0.4, 3, 3500), BEATS(s), 0.35, 0.12), 0.2, 1.4, "ep", damp=5000)
    ph = "5:1 3:.5 5:.5 6:1 r:1 | 4:1 2:.5 4:.5 6:2 | 3+:1.5 1+:.5 6:2 | 5:1 7:1 1+:2 | "
    tn = S.tune(ph + ph + "5:1 3:.5 5:.5 6:1 1+:1 | 4:1 2:.5 4:.5 6:2 | 3+:1.5 1+:.5 6:2 | 7:3 r:1", s.tonic, 4)
    lead = room(s, echo(s, S.lay(s, lambda ss, m, du, v: S.v_vibes(ss, m, du, v, 4.0), tn), 0.75, 0.2, 0.4, 3, 3500), 0.2, 1.6, "lead", damp=5500)
    return {"drums": d, "bass": bass, "keys": ep, "lead": lead, "pad": chorus_pad(s, ch, 55, 76, 65, 0.9, cutoff=1300)}


def laser_trance(s):
    """138 BPM trance: driving kick, rolling bass, 16th saw arpeggio, long pads and a breakdown lead."""
    r = dsp.rng(s.id, "laser")
    ch, k = s.chords, S.kits(s, "dance")
    d = s.zeros()
    S.hits(s, d, k["kick"], "X...X...X...X...", r, jit=0.0, mask=set(range(16)) - {6, 7})
    S.hits(s, d, k["clap"], "....x.......x...", r, gain=0.6, jit=0.0, mask=set(range(8, 16)))
    S.hits(s, d, k["ohat"], "..x...x...x...x.", r, gain=0.5, jit=0.0, mask=set(range(16)) - {6, 7})
    S.hits(s, d, k["crash"], {0: "X...............", 8: "X...............", 12: "X..............."}, r, gain=0.45, jit=0.0)
    roll(s, d, k["snare"], 24, 16, 0.5, 0.2, 0.9, r)
    d = finish_drums(s, d, 0.05, 1.3, 4500)
    bass = S.line(s, ch, lambda c, n, i: [(q + o, 0.2, S.root_of(c, 48, 43, 55), 1.0) for q in range(4) for o in (0.25, 0.5, 0.75)],
                  S.v_sbass, r=r, jit=0.0, mask=set(range(16)) - {6, 7})
    bass = sidechain(s, loop_filter(s, bass, "lp", 400, 4), BEATS(s), 0.7, 0.1)
    ar = arp(s, ch, 62, 90, lambda ss, m, du, v: S.v_pluck(ss, m, du, v, cutoff=3200, decay=0.06), [0, 2, 4, 2, 1, 3, 5, 3])
    ar = sidechain(s, echo(s, ar, 0.75, 0.2, 0.35, 2, 3000), BEATS(s), 0.3, 0.1)
    pad = chorus_pad(s, ch, 57, 78, 67, 1.0, cutoff=500)
    a = "3+:1.5 1+:.5 6:1 1+:1 | 2+:1.5 7:.5 5:1 7:1 | 1+:1.5 6:.5 4:1 6:1 | 7:1 2+:1 5+:2"
    b = "3+:1 5+:1 3+:1 1+:1 | 2+:1 5+:1 2+:1 7:1 | 1+:1 4+:1 6+:1 4+:1 | 7:1 2+:1 5+:2"
    tn = S.tune(" | ".join(["r:4"] * 8) + " | " + a + " | " + b, s.tonic, 4)
    lead = S.lay(s, lambda ss, m, du, v: S.v_super(ss, m, du, v, att=0.01, rel=0.12), tn)
    lead = sidechain(s, room(s, echo(s, lead, 0.75, 0.15, 0.3, 2, 3500), 0.1, 0.9, "lead", damp=4500), BEATS(s), 0.4, 0.1)
    fx = rise(s, 24, 8, 0.5) + drop_impact(s, 32)
    return {"drums": d, "bass": bass, "arp": ar, "pad": pad, "lead": lead, "fx": fx}


def trimmed(fn, hz):
    """Wraps a song: every part is low-passed (circularly) at hz, which keeps the Vorbis file small."""
    def f(s):
        return {k: loop_filter(s, v, "lp", hz, 2) for k, v in fn(s).items()}
    f.__doc__ = fn.__doc__
    return f


SONGS = {
    "sunny_hook": ("I:4 V:4 vi:4 IV:4 I:4 V:4 vi:4 IV:4 IV:4 V:4", sunny_hook, {"drums": -16}),
    "city_lights_pop": ("I:4 iii:4 IV:4 V:4 I:4 iii:4 IV:4 ii:2 V:2", city_lights_pop, {"pad": -23}),
    "summer_crush": ("I:4 iii:4 IV:4 V:4 I:4 iii:4 IV:4 V:4 vi:4 IV:4 ii:4 V:4", trimmed(summer_crush, 5500), {"drums": -16, "voice": -23}),
    "boom_bap_sunrise": ("vi7:4 ii7:4 V7:4 Imaj7:4 vi7:4 ii7:4 V7:4 Imaj7:4", boom_bap_sunrise, {"drums": -16, "bass": -19}),
    "trap_playground": ("vi:4 IV:4 I:4 V:4 vi:4 IV:4 I:4 V:4 vi:4 IV:4 I:4 V:4", trap_playground, {"bass": -17, "pad": -27}),
    "street_cipher": ("vi:4 V:4 IV:4 V:4 vi:4 V:4 IV:4 I:4", street_cipher, {"drums": -16, "bass": -19}),
    "festival_drop": ("vi:4 IV:4 V:4 iii:4 vi:4 IV:4 V:4 iii:4 vi:4 IV:4 V:4 iii:4 vi:4 IV:4 V:4 iii:4", trimmed(festival_drop, 3000),
                      {"drums": -16.5, "keys": -20, "pad": -28}),
    "deep_house_sunset": ("vi7:4 ii7:4 IVmaj7:4 Imaj7:4 vi7:4 ii7:4 IVmaj7:4 Imaj7:4 vi7:4 ii7:4 IVmaj7:4 Imaj7:4", trimmed(deep_house_sunset, 4500),
                          {"drums": -18}),
    "laser_trance": ("vi:4 V:4 IV:4 V:4 vi:4 V:4 IV:4 V:4 vi:4 V:4 IV:4 V:4 vi:4 V:4 IV:4 V:4", trimmed(laser_trance, 3200), {"drums": -17, "arp": -25, "pad": -28}),
}
