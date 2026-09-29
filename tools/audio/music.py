"""District music: one loop per task stem, plus 'tension' and 'party'.

How a district track is built
-----------------------------
* Song holds the grid: bpm, key, 8 bars, and a loop length of exactly
  round(bars * 4 * 60 / bpm * sr) samples. Every stem of the district has that
  length, so the engine can start them together and keep them in sync.
* Song.add() writes an event into the loop buffer and wraps whatever runs past
  the end back to the start ("tail wrap-around"), so a note ringing over the
  loop point continues seamlessly on the next pass.
* Stem-level effects (reverb, echo, tape wow, leslie, sidechain) are all
  circular/periodic (dsp.convolve_loop, dsp.loop_apply, dsp.loop_lfo), so the
  processed loop is still exactly periodic: no click, no gap at the seam.
* All stems of a district share one chord progression (Song.chords) and key.
  Individual stem levels are set by gen_audio.py (loudness targets below),
  then the whole district is scaled by one common factor.
"""
import itertools

import numpy as np

import dsp
import instruments as ins
from dsp import TAU, midi_hz, nsamp

SR = 22050
SR_HI = 44100  # bright stems (hats, shakers, tambourines, arps, snaps) keep their 11-16 kHz sparkle

# Stems rendered and stored at SR_HI. 44100 = 2 x 22050, so their loop is
# exactly twice as many samples and exactly as long: they stay sample-locked.
HI_RATE = {
    "cafe": {"beat", "vinyl", "party"},
    "jazz": {"brushes", "party"},
    "square": {"shaker", "party"},
    "stadium": {"arp", "snaps", "party"},
    "garage": {"tamb", "party"},
}


# ------------------------------------------------------------------ grid

class Chord:
    def __init__(self, start, dur, root, tones, name):
        self.start, self.dur, self.root, self.tones, self.name = start, dur, root, list(tones), name

    def pcs(self, intervals=None):
        return [(self.root + i) % 12 for i in (self.tones if intervals is None else intervals)]


def progression(spec):
    """spec: list of (beats, root_pc, intervals, name) -> list of Chord."""
    out, b = [], 0.0
    for beats, root, tones, name in spec:
        out.append(Chord(b, beats, root, tones, name))
        b += beats
    return out


class Song:
    def __init__(self, district, chords, sr=SR):
        self.d = district
        self.id = district["id"]
        self.bpm = district["bpm"]
        self.bars = district["bars"]
        self.tonic = district["semitones_from_c"] % 12
        self.beats = self.bars * 4
        self.sr = sr
        # loop length is set on the 22.05 kHz grid, so a 44.1 kHz stem is exactly 2x as long in samples
        assert sr % SR == 0, sr
        self.n = int(round(self.beats * 60.0 / self.bpm * SR)) * (sr // SR)
        self.bs = self.n / sr / self.beats  # seconds per beat on the exact loop grid
        self.chords = chords
        assert abs(sum(c.dur for c in chords) - self.beats) < 1e-9

    def at_rate(self, sr):
        """The same song (grid, chords, loop duration) rendered at another rate."""
        return Song(self.d, self.chords, sr)

    def sec(self, beat):
        return beat * self.bs

    def zeros(self):
        return np.zeros(self.n)

    def add(self, buf, sig, beat, gain=1.0, dt=0.0):
        """Mix sig into the loop at `beat` (+dt seconds), wrapping the tail."""
        n = self.n
        p = int(round((beat * self.bs + dt) * self.sr)) % n
        s = np.asarray(sig) * gain
        if len(s) > n:
            s = np.pad(s, (0, (-len(s)) % n)).reshape(-1, n).sum(axis=0)
        first = min(len(s), n - p)
        buf[p: p + first] += s[:first]
        if len(s) > first:
            buf[: len(s) - first] += s[first:]

    def chord_at(self, beat):
        b = beat % self.beats
        for c in self.chords:
            if c.start <= b < c.start + c.dur - 1e-9:
                return c
        return self.chords[-1]

    def next_chord(self, c):
        i = self.chords.index(c)
        return self.chords[(i + 1) % len(self.chords)]

    def lfo(self, hz, phase=0.0):
        return dsp.loop_lfo(self.n, self.sr, hz, phase)


def sw16(beat, amount):
    """Swing the off-beat 16ths by `amount` of a 16th (0.33 ~ triplet feel)."""
    q = beat * 4.0
    if abs(q - round(q)) < 1e-6 and int(round(q)) % 2 == 1:
        return beat + amount * 0.25
    return beat


def sw8(beat, amount):
    """Swing the off-beat 8ths by `amount` of an 8th (0.33 = triplet swing)."""
    q = beat * 2.0
    if abs(q - round(q)) < 1e-6 and int(round(q)) % 2 == 1:
        return beat + amount * 0.5
    return beat


def voice_lead(pcs_list, lo, hi, center, span=13):
    """Pick a voicing for every chord (lists of pitch classes) inside [lo, hi]
    minimising motion between consecutive chords (the loop is closed: the
    second pass starts from the last chord's voicing)."""
    prev = None
    res = []
    for _ in range(2):
        res = []
        for pcs in pcs_list:
            opts = [[p + 12 * o for o in range(11) if lo <= p + 12 * o <= hi] for p in pcs]
            best = None
            for combo in itertools.product(*opts):
                v = sorted(combo)
                if len(set(v)) < len(v) or v[-1] - v[0] > span:
                    continue
                cost = 0.35 * abs(np.mean(v) - center)
                if prev is not None:
                    cost += sum(min(abs(a - b) for b in prev) for a in v)
                    cost += 0.5 * sum(min(abs(a - b) for a in v) for b in prev)
                for a, b in zip(v, v[1:]):
                    if b - a <= 2 and a < 57:
                        cost += 4.0  # avoid mud: seconds low in the register
                if best is None or cost < best[0]:
                    best = (cost, v)
            res.append(best[1])
            prev = best[1]
    return res


def nearest(pc, target, lo, hi):
    """MIDI note with pitch class pc nearest to target within [lo, hi]."""
    cands = [pc + 12 * o for o in range(11) if lo <= pc + 12 * o <= hi]
    return min(cands, key=lambda m: (abs(m - target), m))


# ------------------------------------------------------------- stem FX

def room(s, x, wet=0.2, t60=1.2, key="room", damp=4000.0, predelay=0.015, hp=150.0):
    ir = dsp.reverb_ir(s.sr, t60=t60, predelay=predelay, damp_hz=damp, key=f"{s.id}/{key}")
    send = dsp.loop_apply(x, lambda z: dsp.highpass(z, hp, s.sr, 2))
    return x + wet * dsp.convolve_loop(send, ir)


def echo(s, x, beats=0.75, wet=0.25, fb=0.4, taps=4, lp=3000.0):
    return x + wet * dsp.delay_loop(x, s.sr, s.sec(beats), fb, taps, lp)


def tape(s, x, cents=8.0, hz=0.45, flutter=0.0):
    """Tape wow (and optional flutter) as a periodic modulated delay."""
    depth = (2 ** (cents / 1200) - 1) / (TAU * hz)
    d = 0.004 + depth * s.lfo(hz)
    if flutter:
        d = d + (2 ** (flutter / 1200) - 1) / (TAU * 7.0) * s.lfo(7.0, 0.3)
    return dsp.mod_delay(x, d, s.sr)


def leslie(s, x, hz=0.8, depth=0.35):
    l = s.lfo(hz)
    y = dsp.mod_delay(x, 0.002 + 0.00035 * l, s.sr)
    return y * (1.0 - depth * 0.5 * (1 + s.lfo(hz, 0.25)))


def sidechain(s, x, beats, depth=0.6, release=0.16):
    """Duck x after each beat in `beats` (loop-safe pumping)."""
    t = np.arange(s.n) / s.sr
    g = np.zeros(s.n)
    for b in beats:
        tb = s.sec(b)
        dtt = (t - tb) % (s.n / s.sr)
        g = np.maximum(g, np.exp(-dtt / release) * (1 - np.exp(-dtt / 0.004)))
    g = dsp.loop_apply(g, lambda z: dsp.onepole_lp(z, 80.0, s.sr))
    return x * (1.0 - depth * g / max(g.max(), 1e-9))


def loop_filter(s, x, kind, f, order=2):
    fn = {"lp": dsp.lowpass, "hp": dsp.highpass}[kind]
    return dsp.loop_apply(x, lambda z: fn(z, f, s.sr, order))


def loop_eq(s, x, kind, f, gain_db, q=0.7):
    return dsp.loop_apply(x, lambda z: dsp.filt(z, kind, f, s.sr, q=q, gain_db=gain_db))


def render_line(s, notes, **kw):
    """mono_line over the loop (plus a tail that wraps). Returns (src, env, onset)."""
    n = s.n + nsamp(1.0, s.sr)
    return ins.mono_line(notes, n, s.sr, **kw)


def wrap(s, x):
    buf = s.zeros()
    s.add(buf, x, 0.0)
    return buf


def events(s, evs, swing=None):
    """(beat, beats, midi[, vel, opts]) -> (sec, sec, midi, vel, opts)."""
    out = []
    for e in evs:
        b, d, m = e[:3]
        v = e[3] if len(e) > 3 else 0.8
        o = e[4] if len(e) > 4 else {}
        bb = swing(b) if swing else b
        out.append((s.sec(bb), s.sec(d) * 0.97, m, v, o))
    return out


def bars(spec):
    """Melody helper: {bar: [(beat, beats, midi[, vel, opts]), ...]} -> absolute events."""
    out = []
    for bar, notes in spec.items():
        for e in notes:
            out.append((bar * 4 + e[0],) + tuple(e[1:]))
    return out


# ------------------------------------------------------ shared voices

_CACHE = {}


def cached(key, fn):
    if key not in _CACHE:
        v = fn()
        v.setflags(write=False)
        _CACHE[key] = v
    return _CACHE[key]


def pad_note(midi, dur, sr, cutoff=1200.0, attack=0.5, release=0.9, det=7.0, tri=0.3, key=0):
    def mk():
        f = midi_hz(midi)
        n = nsamp(dur + release * 1.5, sr)
        r = dsp.rng("pad", midi, key)
        x = dsp.saw(f * 2 ** (det / 1200), n, sr, r.uniform()) + dsp.saw(f * 2 ** (-det / 1200), n, sr, r.uniform())
        x += tri * 2 * dsp.triangle(f, n, sr)
        x = dsp.lowpass(x, cutoff, sr, 2)
        x *= dsp.env_adsr(n, sr, attack, 0.6, 0.85, dur, release)
        return dsp.fade(x, sr, 0.002, 0.02)
    return cached(("pad", midi, round(dur, 3), sr, cutoff, attack, release, det, tri, key), mk)


def string_note(midi, dur, sr, key=0):
    return pad_note(midi, dur, sr, cutoff=2600.0, attack=0.45, release=0.5, det=11.0, tri=0.0, key=key)


def choir_src(midi, dur, sr, key=0, attack=0.35, release=0.6):
    """Three glottal saw voices with independent vibrato/jitter (unfiltered;
    the vowel formant is applied to the whole stem)."""
    def mk():
        f = midi_hz(midi)
        n = nsamp(dur + release * 1.5, sr)
        t = np.arange(n) / sr
        r = dsp.rng("choir", midi, key)
        x = np.zeros(n)
        for v in range(3):
            vib = 1 + 0.004 * np.sin(TAU * r.uniform(4.6, 5.6) * t + r.uniform(0, 6))
            drift = 1 + 0.002 * np.sin(TAU * r.uniform(0.2, 0.5) * t + r.uniform(0, 6))
            x += dsp.saw(f * vib * drift * 2 ** (r.uniform(-7, 7) / 1200), n, sr, r.uniform())
        x += 0.25 * ins.breath(n, sr, f"ch{midi}{key}", 600, 6000)
        x *= dsp.env_adsr(n, sr, attack, 0.5, 0.9, dur, release)
        return dsp.fade(x, sr, 0.002, 0.02)
    return cached(("choir", midi, round(dur, 3), sr, key, attack, release), mk)


def synth_bass(midi, dur, sr, cutoff=1400.0, decay=0.09, key=0):
    def mk():
        f = midi_hz(midi)
        n = nsamp(dur + 0.08, sr)
        t = np.arange(n) / sr
        x = 0.6 * dsp.saw(f, n, sr) + 0.5 * dsp.pulse(f * 0.5, n, sr, 0.5)
        x = dsp.sweep_filter(x, 180.0 + cutoff * np.exp(-t / decay) + 2.5 * f, sr, q=1.3)
        x += 0.5 * np.sin(TAU * f * 0.5 * t)
        x *= dsp.env_adsr(n, sr, 0.003, 0.2, 0.75, dur, 0.04)
        return dsp.fade(dsp.drive(x, 1.6), sr, 0.001, 0.01)
    return cached(("sbass", midi, round(dur, 3), sr, cutoff, decay, key), mk)


def sub_note(midi, dur, sr):
    def mk():
        f = midi_hz(midi)
        n = nsamp(dur + 0.12, sr)
        t = np.arange(n) / sr
        x = np.sin(TAU * f * t) + 0.18 * np.sin(TAU * 2 * f * t + 0.3)
        x *= dsp.env_adsr(n, sr, 0.012, 0.6, 0.75, dur, 0.07)
        return dsp.fade(dsp.tube(x, 1.6, sr, bias=0.15), sr, 0.002, 0.02)
    return cached(("sub", midi, round(dur, 3), sr), mk)


def upright(midi, dur, sr, vel=0.8, key=0):
    """Upright bass: dark KS pluck + finger thump + body resonance."""
    def mk():
        y = ins.guitar(midi, dur, sr, bright=0.16, t60=1.6, pick=0.22, mute=0.07, key=key, damp=0.5).copy()
        n = len(y)
        t = np.arange(n) / sr
        y = y / (dsp.peak(y) + 1e-9)
        th = dsp.lowpass(dsp.rng("thump", midi, key).standard_normal(n), 400, sr) * np.exp(-t / 0.01)
        y = y + 0.25 * th / (dsp.peak(th) + 1e-9)
        y = dsp.filt(y, "peak", 110, sr, q=1.0, gain_db=3.0)
        y = dsp.filt(y, "peak", 750, sr, q=1.2, gain_db=2.5)
        return dsp.fade(y, sr, 0.001, 0.01)
    return cached(("upright", midi, round(dur, 3), sr, key), mk)


def power_chord(root, dur, sr, muted=False, key=0, vel=1.0):
    def mk():
        notes = [root, root + 7, root + 12]
        if muted:
            x = ins.strum(notes, dur, sr, spread=0.004, bright=0.45, t60=0.16, pick=0.1, mute=0.02, key=key)
        else:
            x = ins.strum(notes, dur, sr, spread=0.009, bright=0.7, t60=2.5, pick=0.13, mute=0.06, key=key)
        return x
    return cached(("power", root, round(dur, 3), sr, muted, key), mk)


# ---------------------------------------------------------- drum kits

def kit(name, sr):
    """Drum samples per genre (a few variants each, to avoid machine-gun)."""
    def mk():
        k = {}
        if name == "lofi":
            k["kick"] = [dsp.lowpass(ins.kick(sr, 105, 50, 0.03, 0.34, 0.12, 1.4, key=i), 3500, sr) for i in range(2)]
            k["snare"] = [dsp.lowpass(ins.snare(sr, 195, 0.11, 0.19, 0.8, 1500, 6500, key=i), 6000, sr) for i in range(3)]
            k["hat"] = [dsp.lowpass(ins.hat(sr, 0.04, key=i, lo=5500), 13000, sr) for i in range(4)]
            k["ohat"] = [dsp.lowpass(ins.hat(sr, open_=True, key=9, lo=5500), 12000, sr) * 0.6]
            k["clap"] = [ins.clap(sr, key=i) for i in range(2)]
            k["rim"] = [ins.rim(sr, key=i) for i in range(2)]
            k["shaker"] = [ins.shaker(sr, key=i) for i in range(3)]
        elif name == "jazz":
            k["ride"] = [ins.ride(sr, key=i, t60=1.9, bell=0.22) for i in range(3)]
            k["chick"] = [ins.hat(sr, 0.035, key=20 + i, lo=3500, tone=0.6) for i in range(2)]
            k["tap"] = [ins.brush_tap(sr, key=i) for i in range(4)]
            k["feather"] = [dsp.lowpass(ins.kick(sr, 90, 52, 0.02, 0.25, 0.0, 1.0, key=5), 800, sr)]
            k["snare"] = [ins.snare(sr, 210, 0.1, 0.2, 0.9, 1500, 8000, key=30 + i) for i in range(2)]
            k["crash"] = [ins.crash(sr, key=3, t60=2.2)]
            k["hat"] = [ins.hat(sr, 0.05, key=40 + i, lo=5000) for i in range(3)]
        elif name == "street":
            k["bass"] = [ins.kick(sr, 95, 56, 0.04, 0.5, 0.35, 1.3, key=i) for i in range(2)]
            k["snare"] = [ins.snare(sr, 240, 0.08, 0.16, 1.0, 1800, 9000, key=i) for i in range(4)]
            k["cym"] = [ins.crash(sr, key=7, t60=0.9) * 0.8]
            k["crash"] = [ins.crash(sr, key=8, t60=2.2)]
            k["hat"] = [ins.hat(sr, 0.05, key=50 + i) for i in range(3)]
            k["clap"] = [ins.clap(sr, key=10 + i) for i in range(3)]
        elif name == "dance":
            k["kick"] = [ins.kick(sr, 190, 50, 0.028, 0.36, 0.3, 2.2, key=i) for i in range(1)]
            k["clap"] = [ins.clap(sr, key=20 + i, tail=0.18) for i in range(2)]
            k["snare"] = [ins.snare(sr, 200, 0.1, 0.18, 0.8, 1500, 9000, key=40)]
            k["hat"] = [ins.hat(sr, 0.04, key=60 + i) for i in range(3)]
            k["ohat"] = [ins.hat(sr, open_=True, key=70) * 0.55]
            k["crash"] = [ins.crash(sr, key=11, t60=2.4)]
        elif name == "rock":
            k["kick"] = [ins.kick(sr, 150, 52, 0.03, 0.4, 0.45, 1.8, key=i) for i in range(2)]
            k["snare"] = [ins.snare(sr, 200, 0.14, 0.28, 0.95, 1300, 8000, key=50 + i) for i in range(3)]
            k["hat"] = [ins.hat(sr, 0.1, key=80 + i, lo=5500, tone=0.5) for i in range(3)]
            k["crash"] = [ins.crash(sr, key=21, t60=2.6)]
            k["ride"] = [ins.ride(sr, key=22, t60=1.6, bell=0.5)]
        for v in k.values():
            for a in v:
                a.setflags(write=False)
        return k
    key = ("kit", name, sr)
    if key not in _CACHE:
        _CACHE[key] = mk()
    return _CACHE[key]


def hit(s, buf, samples, beat, vel, r, jitter=0.004, key=None):
    """Place one drum hit with a little timing/velocity humanisation."""
    smp = samples[r.integers(len(samples))]
    s.add(buf, smp, beat, gain=vel * r.uniform(0.9, 1.05), dt=r.normal(0, jitter) if jitter else 0.0)


# ======================================================== CAFE (F major)

def cafe_song(d):
    # sunny I-iii-IV-V: the loop opens on the tonic Fmaj9 and the C9sus4 at the end
    # resolves into it again, so the café reads as F major (not D minor)
    # (Am7 and C7sus4 without the added D: fewer D's, more C's, so it does not lean to D minor)
    Bb, A, G, F, C = 10, 9, 7, 5, 0
    maj9, m7, m9, sus7 = [4, 7, 11, 14], [3, 7, 10, 12], [3, 7, 10, 14], [5, 7, 10, 12]
    return Song(d, progression([
        (4, F, maj9, "Fmaj9"), (4, A, m7, "Am7"), (4, Bb, maj9, "Bbmaj9"), (4, C, sus7, "C7sus4"),
        (4, F, maj9, "Fmaj9"), (4, A, m7, "Am7"), (4, G, m9, "Gm9"), (4, C, sus7, "C7sus4"),
    ]))


def cafe_beat(s):
    k = kit("lofi", s.sr)
    r = dsp.rng(s.id, "beat")
    b = s.zeros()
    sw = lambda x: sw16(x, 0.45)
    for bar in range(s.bars):
        o = bar * 4
        kicks = [(0, 1.0), (2.5, 0.85)]
        if bar % 2 == 1:
            kicks += [(1.75, 0.55)]
        if bar in (3, 7):
            kicks += [(3.25, 0.5)]
        for bt, v in kicks:
            hit(s, b, k["kick"], o + sw(bt), v, r)
        for bt in (1, 3):
            hit(s, b, k["snare"], o + bt, 0.9, r, 0.003)
        if bar in (3, 7):
            hit(s, b, k["snare"], o + sw(3.75), 0.3, r)
        if bar % 2 == 0:
            hit(s, b, k["snare"], o + sw(2.25), 0.18, r)
        for i in range(8):
            bt = i * 0.5
            v = 0.8 if i % 2 == 0 else 0.55
            hit(s, b, k["hat"], o + sw(bt), v, r, 0.005)
        for bt in (1.75, 3.25):
            hit(s, b, k["hat"], o + sw(bt), 0.3, r, 0.005)
        for i in range(16):  # light shaker on the 16ths: air on top of the groove
            hit(s, b, k["shaker"], o + sw(i * 0.25), 0.35 if i % 2 else 0.2, r, 0.004)
    b = dsp.drive(b / dsp.peak(b) * 1.2, 1.3)
    b = loop_eq(s, b, "highshelf", 5000, 3.0)
    return room(s, b, 0.12, 0.6, "beat", damp=8000)


def cafe_vinyl(s):
    """Lamps: the café lights come on. A twinkling celesta figure on the
    swung off-beats (G5-Bb6, chord tones), echoed, over a light vinyl crackle."""
    tw = s.zeros()
    r = dsp.rng(s.id, "twinkle")
    steps = [(0.5, 0), (1.25, 1), (1.5, 2), (2.5, 3), (3.0, 2), (3.5, 1)]
    for i, c in enumerate(s.chords):
        pcs = {(c.root + t) % 12 for t in [0] + c.tones}
        tones = sorted(m for m in range(79, 95) if m % 12 in pcs)
        tones = tones[1:5] if i % 2 else tones[:4]
        for bt, j in steps:
            m = tones[j % len(tones)]
            x = ins.glock(m, s.sr, vel=0.65, dur=1.0, octave_up=False, t60_scale=0.55)
            s.add(tw, x, c.start + sw16(bt, 0.45), 0.9 if j == 0 else 0.6, dt=r.normal(0.004, 0.003))
    tw = echo(s, tw, 0.75, 0.3, 0.35, 3, 7000)
    tw = room(s, tw, 0.25, 1.4, "twinkle", damp=8000)
    crackle = vinyl_crackle(s)
    return tw / dsp.peak(tw) + 0.12 * crackle / dsp.peak(crackle)


def vinyl_crackle(s):
    r = dsp.rng(s.id, "vinyl")
    n = s.n
    imp = np.zeros(n)
    cnt = int(n / s.sr * 22)
    pos = r.integers(0, n, cnt)
    np.add.at(imp, pos, r.lognormal(-1.2, 0.7, cnt) * r.choice([-1.0, 1.0], cnt))
    crackle = dsp.loop_apply(imp, lambda z: dsp.bandpass(z, 1500, 7500, s.sr))
    pops = np.zeros(n)
    pc = int(n / s.sr * 0.7)
    np.add.at(pops, r.integers(0, n, pc), r.uniform(0.5, 1.0, pc) * r.choice([-1.0, 1.0], pc))
    pops = dsp.loop_apply(pops, lambda z: dsp.lowpass(dsp.highpass(z, 200, s.sr), 1500, s.sr))
    hiss = dsp.loop_apply(r.standard_normal(n), lambda z: dsp.bandpass(z, 2500, 9000, s.sr))
    rumble = dsp.loop_apply(r.standard_normal(n), lambda z: dsp.lowpass(z, 160, s.sr, 2))
    rot = 1 + 0.25 * s.lfo(0.555)  # 33 1/3 rpm swish
    x = 1.0 * crackle / dsp.peak(crackle) + 0.5 * pops / dsp.peak(pops)
    x += 0.035 * hiss / np.std(hiss) * rot + 0.06 * rumble / np.std(rumble)
    return x


def cafe_keys(s):
    b = s.zeros()
    r = dsp.rng(s.id, "keys")
    vo = voice_lead([c.pcs() for c in s.chords], 55, 77, 66)
    pats = {0: [(0, 1.9, 0.62), (2.5, 1.4, 0.45)], 1: [(0, 1.4, 0.58), (1.5, 0.9, 0.4), (3, 0.9, 0.46)]}
    for i, c in enumerate(s.chords):
        o = c.start
        pat = pats[1] if i in (3, 7) else pats[0]
        for bt, du, v in pat:
            for j, m in enumerate(vo[i]):
                x = ins.piano(m, s.sec(du), s.sr, vel=round(v + 0.04 * j, 2), bright=0.7, release=0.25)
                s.add(b, x, o + sw16(bt, 0.45), 0.8, dt=0.012 + j * 0.018 + r.normal(0, 0.003))
        lh = nearest(c.root, 45, 40, 51)
        s.add(b, ins.piano(lh, s.sec(3.6), s.sr, vel=0.45, bright=0.45, release=0.3), o, 0.6, dt=0.008)
    b = loop_filter(s, b, "hp", 90)
    b = loop_eq(s, b, "highshelf", 2500, 6.0)
    b = tape(s, b, 5.0, 0.42, 1.0)
    b = dsp.drive(b / dsp.peak(b), 1.2)
    return room(s, b, 0.2, 1.3, "keys", damp=6000)


def cafe_bass(s):
    b = s.zeros()
    for i, c in enumerate(s.chords):
        R = nearest(c.root, 38, 33, 44)
        # beat 4 walks to the chord's 3rd on minor chords (A -> C, G -> Bb), else to the 5th
        pat = [(0, 1.6, R), (2.5, 0.42, R), (3.0, 0.8, R + (3 if c.tones[0] == 3 else 7))]
        for bt, du, m in pat:
            s.add(b, sub_note(m, s.sec(du), s.sr), c.start + sw16(bt, 0.45))
    b = loop_filter(s, b, "lp", 900)
    return b


CAFE_LEAD = bars({
    0: [(0.5, 0.5, 72), (1.0, 0.5, 74), (1.5, 1.0, 77), (2.5, 0.5, 74), (3.0, 1.0, 72)],
    1: [(0.0, 1.5, 69), (2.0, 0.5, 67), (2.5, 0.5, 69), (3.0, 1.0, 72)],
    2: [(0.0, 1.0, 74), (1.0, 0.5, 72), (1.5, 0.5, 70), (2.0, 1.0, 69), (3.5, 0.5, 67)],
    3: [(0.0, 1.5, 69), (1.5, 0.5, 67), (2.0, 2.0, 65)],
    4: [(0.5, 0.5, 72), (1.0, 0.5, 74), (1.5, 0.5, 77), (2.0, 1.0, 79), (3.0, 0.5, 77), (3.5, 0.5, 74)],
    5: [(0.0, 1.5, 76), (1.5, 0.5, 74), (2.0, 1.0, 72), (3.0, 0.5, 69), (3.5, 0.5, 72)],
    6: [(0.0, 1.0, 74), (1.0, 0.5, 77), (1.5, 0.5, 74), (2.0, 0.5, 72), (2.5, 1.0, 70), (3.5, 0.5, 69)],
    7: [(0.0, 2.0, 67), (3.0, 0.5, 69), (3.5, 0.5, 70)],
})


def cafe_lead(s):
    b = s.zeros()
    r = dsp.rng(s.id, "lead")
    for bt, du, m in CAFE_LEAD:
        x = ins.guitar(m, s.sec(du) + 0.05, s.sr, bright=0.42, t60=1.6, pick=0.18, mute=0.1, key=m % 3, attack=0.003)
        s.add(b, x, sw16(bt, 0.45), r.uniform(0.75, 0.95), dt=0.015 + r.normal(0, 0.004))
    b = loop_filter(s, b, "lp", 9000)
    b = loop_eq(s, b, "peak", 2200, 3.0, 0.9)
    b = tape(s, b, 5.0, 0.42)
    b = echo(s, b, 0.75, 0.22, 0.35, 3, 4000)
    return room(s, b, 0.2, 1.3, "lead", damp=5500)


def cafe_pad(s):
    b = s.zeros()
    def shell_of(c):  # 3rd, 7th, 9th/11th: three distinct pitch classes
        out = []
        for i in (0, 2, 3, 1):
            if len(out) < 3 and c.tones[i] % 12 not in [t % 12 for t in out]:
                out.append(c.tones[i])
        return out
    shell = [shell_of(c) for c in s.chords]
    vo = voice_lead([c.pcs(sh) for c, sh in zip(s.chords, shell)], 50, 70, 60)
    for c, v in zip(s.chords, vo):
        for j, m in enumerate(v):
            s.add(b, pad_note(m, s.sec(c.dur) + 0.3, s.sr, cutoff=3200, attack=0.6, release=1.1, key=j), c.start)
    b = tape(s, b, 8.0, 0.33, 1.5)
    b = loop_filter(s, b, "lp", 6000)
    b = loop_filter(s, b, "hp", 140)
    return room(s, b, 0.3, 2.0, "pad", damp=5000)


# ====================================================== JAZZ (Bb major)

T = 2.0 / 3.0  # swung off-beat


def jazz_song(d):
    Bb, G, C, F, D = 10, 7, 0, 5, 2
    return Song(d, progression([
        (4, Bb, [4, 7, 11, 14], "Bbmaj9"), (4, G, [4, 10, 15, 20], "G7(#9,b13)"),
        (4, C, [3, 7, 10, 14], "Cm9"), (4, F, [4, 10, 14, 21], "F13"),
        (4, D, [3, 7, 10, 17], "Dm7(11)"), (4, G, [4, 10, 13, 20], "G7(b9,b13)"),
        (4, C, [3, 7, 10, 14], "Cm9"), (4, F, [4, 10, 14, 21], "F13"),
    ]))


def jazz_brushes(s):
    k = kit("jazz", s.sr)
    r = dsp.rng(s.id, "brushes")
    b = s.zeros()
    for bar in range(s.bars):
        o = bar * 4
        for bt, v in ((0, 0.75), (1, 0.9), (1 + T, 0.5), (2, 0.75), (3, 0.9), (3 + T, 0.5)):
            hit(s, b, k["ride"], o + bt, v * 0.8, r, 0.004)
        for bt in (1, 3):
            hit(s, b, k["chick"], o + bt, 0.55, r, 0.003)
            hit(s, b, k["tap"], o + bt, 0.9, r, 0.004)
        for bt in range(4):
            s.add(b, ins.brush_swish(s.sr, s.sec(0.95), key=(bar * 4 + bt) % 5), o + bt, 0.16)
            hit(s, b, k["feather"], o + bt, 0.35, r, 0.003)
        if bar % 2 == 1:
            hit(s, b, k["tap"], o + 2 + T, 0.35, r)
        if bar in (3, 7):
            hit(s, b, k["tap"], o + 3 + T, 0.5, r)
    return room(s, b, 0.14, 1.1, "brushes", damp=6000)


def jazz_piano(s):
    b = s.zeros()
    r = dsp.rng(s.id, "piano")
    vo = voice_lead([c.pcs() for c in s.chords], 50, 74, 62)
    pats = [
        [(0, 0.9, 0.62, 0), (1 + T, 0.45, 0.55, 0)],
        [(2 / 3, 0.5, 0.52, 0), (2, 0.9, 0.6, 0)],
        [(0, 0.45, 0.58, 0), (1 + T, 0.4, 0.5, 0), (3 + T, 1.1, 0.6, 1)],
        [(1, 0.5, 0.55, 0), (2 + T, 0.8, 0.52, 0)],
    ]
    order = [0, 2, 3, 1, 0, 2, 3, 1]
    for i, c in enumerate(s.chords):
        for bt, du, v, nxt in pats[order[i]]:
            ci = (i + nxt) % len(s.chords)
            for j, m in enumerate(vo[ci]):
                x = ins.piano(m, s.sec(du), s.sr, vel=v, bright=0.6, release=0.15)
                s.add(b, x, c.start + bt, 0.8, dt=j * 0.006 + r.normal(0, 0.004))
    b = loop_eq(s, b, "peak", 3000, 1.5, 0.8)
    return room(s, b, 0.2, 1.6, "piano", damp=4500)


def walking_line(s, lo=28, hi=50, start=38, seed="walk"):
    r = dsp.rng(s.id, seed)
    line = []
    prev = start
    for i, c in enumerate(s.chords):
        nx = s.next_chord(c)
        third = c.tones[0] if c.tones[0] in (3, 4) else 4
        v = i % 4
        if v == 0:
            degs = [0, third, 7]
        elif v == 1:
            degs = [0, 2, third]
        elif v == 2:
            degs = [0, 7, 12]
        else:
            degs = [0, third, 5 if third == 3 else 7]
        notes = []
        for dg in degs:
            m = nearest((c.root + dg) % 12, prev, lo, hi)
            notes.append(m)
            prev = m
        tgt = nearest(nx.root, prev, lo, hi)
        appr = tgt + (1 if (i % 3 == 0 and tgt + 1 <= hi) else -1)
        if i % 5 == 4:
            appr = nearest((nx.root + 7) % 12, prev, lo, hi)
        if appr == prev:  # never repeat the 3rd beat: approach from the other side
            appr = tgt + 1 if appr < tgt else tgt - 1
        notes.append(appr)
        prev = appr
        for k, m in enumerate(notes):
            line.append((c.start + k, m, 0.85 if k % 2 == 0 else 0.75))
        if i in (2, 6):
            line.append((c.start + 2 + T, notes[3], 0.3))  # swung skip note
    return line


def jazz_bass(s):
    b = s.zeros()
    r = dsp.rng(s.id, "bass")
    line = walking_line(s)
    for j, (bt, m, v) in enumerate(line):
        nxt = line[(j + 1) % len(line)][0]
        du = ((nxt - bt) % s.beats) * 0.92
        s.add(b, upright(m, s.sec(du), s.sr, key=j % 3), bt, v, dt=r.normal(0.004, 0.004))
    return room(s, b, 0.08, 0.8, "bass", damp=2500)


def jazz_organ(s):
    b = s.zeros()
    shell = [[c.tones[0], c.tones[1], c.tones[2]] for c in s.chords]
    vo = voice_lead([c.pcs(sh) for c, sh in zip(s.chords, shell)], 53, 70, 61)
    for c, v in zip(s.chords, vo):
        for m in v:
            x = ins.organ(m, s.sec(c.dur) + 0.05, s.sr, bars=(3, 0, 7, 4, 0, 2, 0, 0, 0), perc=0.0,
                          click=0.0, attack=0.25, release=0.35)
            s.add(b, x, c.start - 0.08)
    b = leslie(s, b, 0.75, 0.3)
    b = loop_filter(s, b, "lp", 2500)
    return room(s, b, 0.28, 1.8, "organ", damp=3000)


JAZZ_SAX = bars({
    0: [(0.0, T, 65), (T, 1 / 3, 67), (1.0, T, 70), (1 + T, 1 / 3, 72), (2.0, 1.5, 74, 0.85, {"scoop": 1.0}),
        (3 + T, 1 / 3, 72)],
    1: [(0.0, T, 70), (T, 1 / 3, 68), (1.0, T, 65), (1 + T, 1 / 3, 63), (2.0, 1.2, 62)],
    4: [(0.0, 1.0, 69), (1.0, T, 72), (1 + T, 1 / 3, 74), (2.0, 1.0, 77, 0.85, {"scoop": 1.0}), (3.0, T, 74),
        (3 + T, 1 / 3, 72)],
    5: [(0.0, T, 71), (T, 1 / 3, 74), (1.0, T, 77), (1 + T, 1 / 3, 75), (2.0, T, 74), (2 + T, 1 / 3, 71),
        (3.0, 1.0, 67)],
})

JAZZ_TPT = bars({
    2: [(T, 1 / 3, 67), (1.0, T, 70), (1 + T, 1 / 3, 74), (2.0, 1.0, 75), (3.0, T, 74)],
    3: [(0.0, T, 72), (T, 1 / 3, 69), (1.0, 1.5, 67)],
    6: [(1.0, 1.0, 79), (2.0, T, 77), (2 + T, 1 / 3, 75), (3.0, 1.0, 74)],
    7: [(0.0, T, 72), (T, 1 / 3, 75), (1.0, 1.2, 74)],
})


def sax_voice(s, notes, key="sax"):
    src, env, onset = render_line(s, notes, osc="saw", glide=0.015, legato_gap=0.005, attack=0.03,
                                  release=0.06, vib_rate=5.0, vib_depth=0.16, vib_delay=0.22, key=key)
    x = src * env
    x = dsp.sweep_filter(x, 700.0 + 2600.0 * np.clip(env, 0, 1), s.sr, q=0.8)
    x = dsp.filt(x, "peak", 520, s.sr, q=1.0, gain_db=4.0)
    x = dsp.filt(x, "peak", 1500, s.sr, q=1.4, gain_db=3.0)
    x = dsp.highpass(x, 140, s.sr, 2)
    x += 0.12 * ins.breath(len(x), s.sr, key, 1500, 5000) * env
    return dsp.tube(x / (dsp.peak(x) + 1e-9), 1.3, s.sr, 0.1)


def jazz_sax(s):
    x = sax_voice(s, events(s, JAZZ_SAX))
    b = wrap(s, x)
    b = echo(s, b, 1.0 + 1 / 3, 0.1, 0.3, 2, 2500)
    return room(s, b, 0.25, 1.8, "sax", damp=4000)


def jazz_trumpet(s):
    src, env, _ = render_line(s, events(s, JAZZ_TPT), osc="saw", glide=0.01, legato_gap=0.005, attack=0.02,
                              release=0.06,
                              vib_rate=5.6, vib_depth=0.08, vib_delay=0.2, scoop=0.3, key="tpt")
    x = src * env
    x = dsp.highpass(x, 550, s.sr, 2)
    x = dsp.filt(x, "peak", 1800, s.sr, q=1.6, gain_db=10.0)
    x = dsp.filt(x, "peak", 3200, s.sr, q=2.0, gain_db=4.0)
    x = dsp.lowpass(x, 5000, s.sr, 2)
    b = wrap(s, x / dsp.peak(x))
    return room(s, b, 0.3, 1.8, "tpt", damp=4000)


def jazz_vibes(s):
    b = s.zeros()
    r = dsp.rng(s.id, "vibes")
    lines = [(69, 74), (71, 77), (70, 75), (69, 75), (72, 77), (71, 77), (70, 75), (69, 75)]
    fills = {1: 74, 3: 72, 5: 74, 7: 67}
    for i, c in enumerate(s.chords):
        lo, hi = lines[i]
        for m in (lo, hi):
            s.add(b, ins.vibes(m, s.sr, vel=0.6, dur=3.0, release=s.sec(2.4)), c.start, 0.8, dt=r.normal(0, 0.004))
        s.add(b, ins.vibes(lo, s.sr, vel=0.45, dur=2.0, release=s.sec(1.2)), c.start + 2 + T, 0.6)
        if i in fills:
            s.add(b, ins.vibes(fills[i], s.sr, vel=0.5, dur=1.5, release=s.sec(0.6)), c.start + 3 + T, 0.6)
    return room(s, b, 0.25, 1.8, "vibes", damp=5000)


# =================================================== SQUARE (G major)

def square_song(d):
    G, C, D, E, A = 7, 0, 2, 4, 9
    six, dom7, m7 = [0, 4, 7, 9], [0, 4, 7, 10], [0, 3, 7, 10]
    return Song(d, progression([
        (4, G, six, "G6"), (4, C, six, "C6"), (4, G, six, "G6"), (4, D, dom7, "D7"),
        (4, E, m7, "Em7"), (4, C, six, "C6"), (2, A, m7, "Am7"), (2, D, dom7, "D7"),
        (2, G, six, "G6"), (2, D, dom7, "D7"),
    ]))


SQ_SW = 0.22


def square_drums(s):
    k = kit("street", s.sr)
    r = dsp.rng(s.id, "drums")
    b = s.zeros()
    sw = lambda x: sw16(x, SQ_SW)
    for bar in range(s.bars):
        o = bar * 4
        for bt, v in ((0, 1.0), (1.5, 0.8), (2.75, 0.7), (3.5, 0.85)):
            hit(s, b, k["bass"], o + sw(bt), v, r)
        for bt in (1, 3):
            hit(s, b, k["cym"], o + bt, 0.35, r)
            hit(s, b, k["snare"], o + bt, 1.0, r, 0.003)
        for bt in (0.5, 0.75, 1.5, 2.25, 2.5, 3.25, 3.75):
            if not (bar in (3, 7) and bt >= 3):
                hit(s, b, k["snare"], o + sw(bt), r.uniform(0.18, 0.35), r)
        if bar in (3, 7):
            for j in range(8):  # 32nd-note roll with crescendo into the next bar
                hit(s, b, k["snare"], o + 3 + j * 0.125, 0.3 + 0.08 * j, r, 0.002)
        if bar in (1, 5):
            for j in range(4):
                hit(s, b, k["snare"], o + 3.5 + j * 0.125, 0.25 + 0.05 * j, r, 0.002)
    return room(s, b, 0.14, 0.9, "drums", damp=6000)


def square_shaker(s):
    k = kit("lofi", s.sr)
    r = dsp.rng(s.id, "shaker")
    b = s.zeros()
    bell = [ins.cowbell(s.sr, key=i, f1=587.3, f2=880.0) for i in range(2)]
    for bar in range(s.bars):
        o = bar * 4
        for i in range(16):
            bt = i * 0.25
            v = 0.9 if i % 4 == 2 else (0.35 if i % 2 else 0.55)
            hit(s, b, k["shaker"], o + sw16(bt, SQ_SW), v, r, 0.004)
        for bt, v in ((0, 0.9), (1.5, 0.7), (2, 0.5), (3, 0.8)):
            hit(s, b, bell, o + sw16(bt, SQ_SW), v * 0.5, r, 0.003)
    return room(s, b, 0.12, 0.9, "shaker", damp=6000)


def square_guitar(s):
    b = s.zeros()
    r = dsp.rng(s.id, "guitar")
    triads = [[c.tones[0], c.tones[1], c.tones[2]] for c in s.chords]
    vo = voice_lead([c.pcs(t) for c, t in zip(s.chords, triads)], 60, 77, 68, span=12)
    pat = [(0.5, "c", 0.8), (1.0, "c", 0.95), (1.25, "x", 0.5), (1.75, "c", 0.7), (2.5, "c", 0.85),
           (3.0, "c", 0.95), (3.25, "x", 0.45), (3.75, "x", 0.5)]
    for bar in range(s.bars):
        for bt, kind, v in pat:
            beat = bar * 4 + bt
            ci = s.chords.index(s.chord_at(beat))
            notes = vo[ci]
            up = int(round(bt * 4)) % 2 == 1
            if kind == "c":
                x = ins.strum(notes, s.sec(0.18), s.sr, spread=0.006, up=up, bright=0.75, t60=1.2,
                              pick=0.12, mute=0.03, key=bar % 2, damp=0.3)
            else:
                x = ins.strum(notes, 0.02, s.sr, spread=0.004, up=up, bright=0.9, t60=0.05, pick=0.1,
                              mute=0.015, key=3, damp=0.3)
            s.add(b, x, sw16(beat, SQ_SW), v, dt=r.normal(0, 0.003))
    b = loop_filter(s, b, "hp", 180)
    b = loop_eq(s, b, "peak", 2500, 3.0, 1.0)
    b = dsp.drive(b / dsp.peak(b) * 1.5, 1.5)
    return room(s, b, 0.12, 0.9, "guitar", damp=5000)


def square_tuba_line(s):
    ev = []
    for c in s.chords:
        R = nearest(c.root, 43, 36, 47)
        nx = nearest(s.next_chord(c).root, R, 36, 50)
        fifth = R + 7 if R + 7 <= 52 else R - 5
        if c.dur == 4:
            ev += [(c.start, 0.55, R, 0.95), (c.start + 0.75, 0.2, R, 0.55), (c.start + 1.5, 0.45, fifth, 0.8),
                   (c.start + 2.0, 0.45, R + 12 if R + 12 <= 55 else R, 0.85), (c.start + 2.75, 0.2, fifth, 0.55),
                   (c.start + 3.0, 0.45, fifth, 0.8), (c.start + 3.5, 0.45, nx - 1 if nx - 1 != R else nx + 2, 0.75)]
        else:
            ev += [(c.start, 0.55, R, 0.95), (c.start + 0.75, 0.2, R, 0.55), (c.start + 1.5, 0.45, fifth, 0.8)]
    return ev


def square_tuba(s):
    ev = [(sw16(b, SQ_SW), d, m, v) for b, d, m, v in square_tuba_line(s)]
    src, env, onset = render_line(s, events(s, ev), osc="saw", glide=0.012, attack=0.012, release=0.05,
                                  vib_depth=0.0, key="tuba", legato_gap=0.0)
    x = src * env
    x = dsp.sweep_filter(x, 220.0 + 1300.0 * onset + 400.0 * env, s.sr, q=0.9)
    x = dsp.tube(x / dsp.peak(x) * 1.4, 1.6, s.sr, 0.1)
    x = dsp.filt(x, "peak", 400, s.sr, q=0.8, gain_db=3.0)
    b = wrap(s, x)
    return room(s, b, 0.1, 0.9, "tuba", damp=3000)


def square_brass(s):
    b = s.zeros()
    r = dsp.rng(s.id, "brass")
    vo = voice_lead([c.pcs() for c in s.chords], 58, 79, 68)
    pats = {
        "a": [(1.5, 0.3, 0.8), (2.0, 0.6, 0.95), (3.5, 0.5, 0.85)],
        "b": [(0.0, 0.8, 0.9), (2.75, 0.25, 0.75), (3.0, 0.8, 0.95)],
    }
    for bar in range(s.bars):
        pat = pats["a"] if bar % 2 == 0 else pats["b"]
        if bar >= 6:
            pat = [(0.0, 0.3, 0.9), (0.5, 0.3, 0.8), (2.0, 0.3, 0.9), (2.5, 0.3, 0.8), (3.5, 0.45, 0.95)]
        for bt, du, v in pat:
            beat = bar * 4 + bt
            ci = s.chords.index(s.chord_at(beat))
            for j, m in enumerate(vo[ci]):
                x = ins.brass(m, s.sec(du), s.sr, vel=v, bright=1.0, key=j)
                s.add(b, x, sw16(beat, SQ_SW), 1.0, dt=r.normal(0, 0.004))
    return room(s, b, 0.18, 1.2, "brass", damp=5000)


SQ_CLAR = bars({
    0: [(0.0, 0.5, 74), (0.5, 0.5, 76), (1.0, 1.0, 79), (2.0, 0.5, 76), (2.5, 0.5, 74), (3.0, 1.0, 71)],
    1: [(0.0, 0.5, 72), (0.5, 0.5, 76), (1.0, 0.5, 79), (1.5, 1.5, 81), (3.0, 0.5, 79), (3.5, 0.5, 76)],
    2: [(0.0, 1.0, 74), (1.0, 0.5, 71), (1.5, 0.5, 74), (2.0, 1.0, 79), (3.0, 0.5, 81), (3.5, 0.5, 83)],
    3: [(0.0, 1.0, 81), (1.0, 0.5, 78), (1.5, 0.5, 74), (2.0, 0.5, 72), (2.5, 0.5, 69), (3.0, 0.5, 66),
        (3.5, 0.5, 69)],
    4: [(0.0, 0.5, 71), (0.5, 0.5, 74), (1.0, 1.0, 76), (2.0, 0.5, 79), (2.5, 0.5, 76), (3.0, 1.0, 74)],
    5: [(0.0, 0.5, 76), (0.5, 0.5, 79), (1.0, 0.5, 81), (1.5, 1.0, 84), (2.5, 0.5, 81), (3.0, 1.0, 79)],
    6: [(0.0, 0.5, 72), (0.5, 0.5, 76), (1.0, 1.0, 81), (2.0, 0.5, 78), (2.5, 0.5, 81), (3.0, 0.5, 84),
        (3.5, 0.5, 81)],
    7: [(0.0, 1.0, 83), (1.0, 1.0, 79), (2.0, 0.5, 81), (2.5, 0.5, 78), (3.0, 0.5, 74), (3.5, 0.5, 72)],
})


def square_clarinet(s):
    ev = [(sw8(e[0], 0.18), e[1], e[2], 0.8) for e in SQ_CLAR]
    src, env, _ = render_line(s, events(s, ev), osc="pulse", pw=0.5,
                              glide=0.008, legato_gap=0.004, attack=0.025, release=0.05, vib_rate=5.5, vib_depth=0.06,
                              vib_delay=0.3, key="clar")
    x = src * env
    x = dsp.sweep_filter(x, 900.0 + 2400.0 * np.clip(env, 0, 1), s.sr, q=0.7)
    x = dsp.filt(x, "peak", 1500, s.sr, q=1.0, gain_db=2.0)
    x += 0.06 * ins.breath(len(x), s.sr, "clar", 1800, 6000) * env
    b = wrap(s, x / dsp.peak(x))
    return room(s, b, 0.2, 1.3, "clar", damp=5000)


def square_claps(s):
    k = kit("street", s.sr)
    r = dsp.rng(s.id, "claps")
    b = s.zeros()
    for bar in range(s.bars):
        for bt in (1, 3):
            for j in range(5):
                s.add(b, k["clap"][j % 3], bar * 4 + bt, r.uniform(0.5, 0.8), dt=r.uniform(-0.006, 0.014))
    for bar, bt, key in ((3, 3.0, "h1"), (7, 2.0, "h2"), (7, 3.0, "h3")):
        s.add(b, ins.crowd_hey(s.sr, f"{s.id}/{key}", voices=8, f_lo=130, f_hi=280), bar * 4 + bt, 0.9,
              dt=-0.03)
    return room(s, b, 0.22, 1.1, "claps", damp=5000)


def square_whistle(s):
    b = s.zeros()
    for bar in (0, 4):
        for bt, du, g in ((0.0, 0.2, 0.8), (0.5, 0.2, 0.8), (1.0, 0.7, 1.0)):
            s.add(b, ins.whistle(s.sr, f=2349.3, dur=s.sec(du), key=bar * 10 + int(bt * 2)), bar * 4 + bt, 0.35 * g)
    ev = [(3 * 4 + 2.5, 1.2, 50, 0.9, {"bend": 5, "bend_t": 0.28}),
          (5 * 4 + 3.25, 0.7, 52, 0.8, {"bend": 4, "bend_t": 0.22}),
          (7 * 4 + 1.75, 1.0, 50, 0.9, {"bend": -4, "bend_t": 0.3})]
    src, env, onset = render_line(s, events(s, ev), osc="saw", glide=0.01, attack=0.04, release=0.12,
                                  vib_depth=0.12, vib_delay=0.25, vib_rate=5.0, key="tbn", legato_gap=0.0)
    x = src * env
    x = dsp.sweep_filter(x, 500.0 + 1500.0 * env, s.sr, q=0.8)
    x = dsp.filt(x, "peak", 700, s.sr, q=0.9, gain_db=3.0)
    b += wrap(s, 0.8 * x / dsp.peak(x))
    return room(s, b, 0.25, 1.4, "whistle", damp=4500)


# ================================================== STADIUM (A major)

def stadium_song(d):
    D, E, Cs, Fs, B, A = 2, 4, 1, 6, 11, 9
    return Song(d, progression([
        (4, D, [0, 4, 7, 11, 14], "Dmaj9"), (4, E, [0, 4, 7, 14], "Eadd9"), (4, Cs, [0, 3, 7, 10], "C#m7"),
        (4, Fs, [0, 3, 7, 10, 14], "F#m9"), (4, B, [0, 3, 7, 10, 14], "Bm9"), (2, E, [0, 5, 7, 14], "Esus4"),
        (2, E, [0, 4, 7, 14], "E"), (4, A, [0, 4, 7, 14], "Aadd9"), (4, A, [0, 4, 7, 14], "Aadd9"),
    ]))


def stadium_beat(s):
    k = kit("dance", s.sr)
    r = dsp.rng(s.id, "beat")
    b = s.zeros()
    for bar in range(s.bars):
        o = bar * 4
        for bt in range(4):
            hit(s, b, k["kick"], o + bt, 1.0, r, 0.0)
            hit(s, b, k["ohat"], o + bt + 0.5, 0.55, r, 0.0)
            hit(s, b, k["hat"], o + bt + 0.25, 0.22, r, 0.002)
            hit(s, b, k["hat"], o + bt + 0.75, 0.3, r, 0.002)
        for bt in (1, 3):
            hit(s, b, k["clap"], o + bt, 0.9, r, 0.0)
            hit(s, b, k["snare"], o + bt, 0.55, r, 0.0)
        if bar in (3, 7):
            hit(s, b, k["snare"], o + 3.5, 0.45, r, 0.0)
            hit(s, b, k["snare"], o + 3.75, 0.6, r, 0.0)
    b = dsp.drive(b / dsp.peak(b) * 1.3, 1.4)
    return room(s, b, 0.1, 0.9, "beat", damp=7000)


def stadium_bass(s):
    b = s.zeros()
    for c in s.chords:
        R = nearest(c.root, 40, 35, 46)
        for q in range(int(c.dur)):
            bt = c.start + q
            s.add(b, synth_bass(R, s.sec(0.42), s.sr), bt + 0.5, 1.0)
            if q % 2 == 1:
                s.add(b, synth_bass(R + 12, s.sec(0.2), s.sr, cutoff=2200), bt + 0.75, 0.6)
    b = sidechain(s, b, range(s.beats), 0.45, 0.1)
    return b


def stadium_chords(s):
    b = s.zeros()
    vo = voice_lead([c.pcs([t for t in c.tones if t != 0][:4]) for c in s.chords], 57, 78, 67)
    for c, v in zip(s.chords, vo):
        for j, m in enumerate(v):
            s.add(b, ins.supersaw(m, s.sec(c.dur) - 0.02, s.sr, attack=0.01, release=0.18, key=j), c.start, 0.8)
        s.add(b, ins.supersaw(nearest(c.root, 50, 45, 56), s.sec(c.dur) - 0.02, s.sr, voices=5, key=9),
              c.start, 0.5)
    b = loop_filter(s, b, "lp", 6500)
    b = loop_eq(s, b, "highshelf", 3000, 2.0)
    b = sidechain(s, b, range(s.beats), 0.65, 0.14)
    return room(s, b, 0.2, 1.6, "chords", damp=6000)


def stadium_arp(s):
    b = s.zeros()
    for c in s.chords:
        tones = sorted({m for m in range(69, 94) if (m - c.root) % 12 in [t % 12 for t in c.tones]})
        tones = tones[:5]
        seq = tones[:4] + [tones[-1]] + tones[1:4][::-1]
        for i in range(int(c.dur * 4)):
            m = seq[i % len(seq)]
            v = 0.9 if i % 4 == 0 else 0.6
            s.add(b, ins.pluck_synth(m, s.sr, dur=0.26, cutoff=8000, decay=0.06), c.start + i * 0.25, v)
            if i % 4 == 0:  # glassy sparkle an octave up on each beat (the 'lasers')
                s.add(b, ins.glock(m + 12, s.sr, vel=0.5, dur=0.6, octave_up=False, t60_scale=0.4),
                      c.start + i * 0.25, 0.35)
    b = loop_eq(s, b, "highshelf", 4000, 3.0)
    b = echo(s, b, 0.75, 0.35, 0.4, 3, 8000)
    b = sidechain(s, b, range(s.beats), 0.3, 0.1)
    return room(s, b, 0.18, 1.4, "arp", damp=10000)


def stadium_choir(s):
    b = s.zeros()
    vo = voice_lead([c.pcs([t for t in c.tones][:4]) for c in s.chords], 60, 79, 69)
    for c, v in zip(s.chords, vo):
        for j, m in enumerate(v):
            s.add(b, choir_src(m, s.sec(c.dur) + 0.1, s.sr, key=j), c.start - 0.05)
    x = dsp.loop_apply(b, lambda z: dsp.formant(z, s.sr, dsp.VOWELS["a_sop"]))
    x = 0.8 * x / dsp.peak(x) + 0.15 * loop_filter(s, b, "lp", 1500) / dsp.peak(b)
    return room(s, x, 0.45, 2.6, "choir", damp=5000, predelay=0.03)


def stadium_fx(s):
    b = s.zeros()
    r = dsp.rng(s.id, "fx")
    sr = s.sr
    # riser over the last two bars, ends exactly on the loop point
    L = nsamp(s.sec(8), sr)
    t = np.arange(L) / L
    nz = r.standard_normal(L)
    rise = dsp.sweep_filter(nz, 300.0 * (7000.0 / 300.0) ** (t ** 1.5), sr, q=2.5, kind="bp")
    rise += 0.3 * dsp.saw(220.0 * 2 ** (t * 1.0), L, sr) * t
    rise *= t ** 2.2
    rise = dsp.fade(rise, sr, 0.01, 0.004)
    s.add(b, rise / dsp.peak(rise), s.beats - 8, 0.55)
    # impact on the downbeat of bar 1: settles on the tonic A1 (55 Hz), nothing below 40 Hz
    n = nsamp(2.0, sr)
    tt = np.arange(n) / sr
    a1 = float(midi_hz(33))
    boom = np.sin(TAU * np.cumsum(a1 * (1 + 0.9 * np.exp(-tt / 0.08))) / sr) * dsp.env_perc(n, sr, 1.6, 0.001)
    boom = dsp.highpass(boom, 40, sr, 4)
    boom += 0.4 * dsp.bandpass(r.standard_normal(n), 300, 3000, sr) * np.exp(-tt / 0.15)
    boom = dsp.convolve(boom, dsp.reverb_ir(sr, 2.2, key="stad-imp"))[:n] * 0.5 + boom
    s.add(b, dsp.fade(dsp.drive(boom / dsp.peak(boom), 1.5), sr, 0.001, 0.2), 0, 0.8)
    # downlifter into bar 5, short sweep up before bar 3
    L2 = nsamp(s.sec(4), sr)
    t2 = np.arange(L2) / L2
    down = dsp.sweep_filter(r.standard_normal(L2), 6000.0 * (200.0 / 6000.0) ** t2, sr, q=2.0, kind="bp")
    down *= (1 - t2) ** 2
    s.add(b, dsp.fade(down / dsp.peak(down), sr, 0.005, 0.05), 16, 0.4)
    L3 = nsamp(s.sec(2), sr)
    t3 = np.arange(L3) / L3
    sw = dsp.sweep_filter(r.standard_normal(L3), 800.0 * (9000.0 / 800.0) ** t3, sr, q=3.0, kind="bp") * t3 ** 2
    s.add(b, dsp.fade(sw / dsp.peak(sw), sr, 0.01, 0.01), 6, 0.3)
    return room(s, b, 0.25, 2.0, "fx", damp=6000)


ST_HOOK = bars({
    0: [(0.0, 0.5, 76), (0.5, 0.5, 78), (1.0, 0.75, 81), (1.75, 0.25, 78), (2.0, 0.5, 76), (2.5, 0.5, 73),
        (3.0, 1.0, 76)],
    1: [(0.5, 0.25, 76), (0.75, 0.25, 78), (1.0, 0.5, 76), (1.5, 0.5, 71), (2.0, 1.0, 73), (3.0, 1.0, 71)],
    2: [(0.0, 0.5, 76), (0.5, 0.5, 78), (1.0, 0.75, 80), (1.75, 0.25, 78), (2.0, 0.5, 76), (2.5, 0.5, 73),
        (3.0, 1.0, 71)],
    3: [(0.5, 0.25, 73), (0.75, 0.25, 76), (1.0, 1.0, 78), (2.0, 0.5, 81), (2.5, 0.5, 80), (3.0, 1.0, 78)],
    4: [(0.0, 0.5, 78), (0.5, 0.5, 81), (1.0, 0.75, 83), (1.75, 0.25, 81), (2.0, 0.5, 78), (2.5, 0.5, 76),
        (3.0, 1.0, 74)],
    5: [(0.0, 0.5, 76), (0.5, 0.5, 81), (1.0, 0.5, 83), (1.5, 0.5, 81), (2.0, 1.0, 80), (3.0, 0.5, 83),
        (3.5, 0.5, 85)],
    6: [(0.0, 1.5, 85), (1.5, 0.5, 83), (2.0, 0.5, 81), (2.5, 0.5, 76), (3.0, 0.5, 78), (3.5, 0.5, 76)],
    7: [(0.0, 2.0, 81), (3.0, 0.5, 73), (3.5, 0.5, 74)],
})


def stadium_hook(s):
    src, env, onset = render_line(s, events(s, ST_HOOK), osc="saw", detune=9.0, glide=0.02, legato_gap=0.004,
                                  attack=0.01,
                                  release=0.08, vib_rate=5.8, vib_depth=0.12, vib_delay=0.15, key="hook")
    x = src * env
    x = dsp.sweep_filter(x, 1800.0 + 2500.0 * onset, s.sr, q=1.0)
    x = dsp.drive(x / dsp.peak(x) * 1.2, 1.3)
    b = wrap(s, x)
    b = echo(s, b, 0.75, 0.25, 0.35, 3, 3500)
    return room(s, b, 0.2, 1.6, "hook", damp=6000)


def stadium_snaps(s):
    k = kit("dance", s.sr)
    r = dsp.rng(s.id, "snaps")
    b = s.zeros()
    snaps = [ins.snap(s.sr, key=i) for i in range(3)]
    for bar in range(s.bars):
        o = bar * 4
        for bt in (1, 3):
            hit(s, b, snaps, o + bt, 0.9, r, 0.003)
        if bar % 2 == 1:
            hit(s, b, snaps, o + 3.75, 0.5, r, 0.003)
        if bar >= 4:
            for bt in (1, 3):
                hit(s, b, k["clap"], o + bt + 0.01, 0.6, r, 0.004)
        if bar == 7:
            for bt in (2.0, 2.5, 3.0, 3.25, 3.5, 3.75):
                hit(s, b, k["clap"], o + bt, 0.5 + 0.1 * (bt - 2), r, 0.003)
    return room(s, b, 0.2, 1.2, "snaps", damp=6000)


# ==================================================== GARAGE (E major)

def garage_song(d):
    E, A, B, Cs = 4, 9, 11, 1
    maj, mn = [0, 4, 7], [0, 3, 7]
    return Song(d, progression([
        (4, E, maj, "E"), (4, A, maj, "A"), (4, E, maj, "E"), (4, B, maj, "B"),
        (4, Cs, mn, "C#m"), (4, A, maj, "A"), (4, E, maj, "E"), (4, B, maj, "B"),
    ]))


def garage_drums(s):
    k = kit("rock", s.sr)
    r = dsp.rng(s.id, "drums")
    b = s.zeros()
    for bar in range(s.bars):
        o = bar * 4
        kicks = [0, 2, 2.5] if bar % 2 == 0 else [0, 0.5, 2, 2.5]
        for bt in kicks:
            hit(s, b, k["kick"], o + bt, 1.0 if bt in (0, 2) else 0.8, r, 0.003)
        for bt in (1, 3):
            hit(s, b, k["snare"], o + bt, 1.0, r, 0.003)
        for i in range(8):
            if bar == 7 and i >= 6:
                continue
            hit(s, b, k["hat"], o + i * 0.5, 0.7 if i % 2 == 0 else 0.45, r, 0.004)
        if bar == 7:
            for bt, v in ((3.0, 0.7), (3.5, 0.85)):
                hit(s, b, k["snare"], o + bt, v, r, 0.002)
    b = dsp.drive(b / dsp.peak(b) * 1.4, 1.5)
    return room(s, b, 0.18, 0.8, "drums", damp=5000, predelay=0.008)


def garage_rhythm(s):
    b = s.zeros()
    r = dsp.rng(s.id, "rhythm")
    for c in s.chords:
        R = nearest(c.root, 43, 40, 51)
        for bt, kind, du in ((0, "o", 0.95), (1.0, "m", 0.4), (1.5, "m", 0.4), (2.0, "m", 0.4), (2.5, "o", 0.45),
                             (3.0, "m", 0.4), (3.5, "m", 0.4)):
            x = power_chord(R, s.sec(du), s.sr, muted=(kind == "m"), key=int(bt * 2) % 2)
            s.add(b, x, c.start + bt, 1.0 if kind == "o" else 0.8, dt=r.normal(0, 0.003))
    b = b / dsp.peak(b)
    b = dsp.loop_apply(b, lambda z: ins.amp_sim(z, s.sr, gain=9.0, tone=4200))
    # faint amp hum, tuned to the key (E1 + E2) so it never beats against the song
    t = np.arange(s.n) / s.sr
    hum = 0.004 * (np.sin(TAU * midi_hz(28) * t) + 0.5 * np.sin(TAU * midi_hz(40) * t))
    return room(s, b / dsp.peak(b) + hum, 0.14, 0.9, "rhythm", damp=4000)


def garage_bass(s):
    b = s.zeros()
    r = dsp.rng(s.id, "bass")
    for c in s.chords:
        R = nearest(c.root, 33, 28, 39)
        for i in range(8):
            m = R + 12 if (i == 7 and c.start % 8 == 4) else R
            x = ins.guitar(m, s.sec(0.46), s.sr, bright=0.5, t60=1.5, pick=0.1, mute=0.04, key=i % 2, damp=0.45)
            s.add(b, x, c.start + i * 0.5, 1.0 if i % 2 == 0 else 0.85, dt=r.normal(0, 0.003))
    b = b / dsp.peak(b)
    b = dsp.loop_apply(b, lambda z: dsp.tube(z * 1.8, 1.2, s.sr, 0.1))
    b = loop_eq(s, b, "peak", 900, 3.0, 1.0)
    return loop_filter(s, b, "lp", 3500)


GA_LEAD = bars({
    0: [(0.0, 0.5, 71), (0.5, 0.5, 73), (1.0, 0.75, 76, 0.9, {"bend": 2}), (1.75, 0.25, 73), (2.0, 0.5, 71),
        (2.5, 0.5, 68), (3.0, 1.0, 71)],
    1: [(0.0, 0.5, 73), (0.5, 0.5, 76), (1.0, 1.0, 78, 0.9, {"bend": 2}), (2.0, 0.5, 76), (2.5, 0.5, 73),
        (3.0, 1.0, 69)],
    2: [(0.0, 0.5, 71), (0.5, 0.5, 73), (1.0, 0.75, 76, 0.9, {"bend": 2}), (1.75, 0.25, 73), (2.0, 0.5, 71),
        (2.5, 0.5, 68), (3.0, 1.0, 76)],
    3: [(0.0, 0.5, 78), (0.5, 0.5, 76), (1.0, 1.0, 75), (2.0, 0.5, 71), (2.5, 0.5, 73), (3.0, 1.0, 71)],
    4: [(0.0, 1.0, 80, 0.9, {"bend": 2}), (1.0, 0.5, 76), (1.5, 0.5, 73), (2.0, 0.5, 76), (2.5, 0.5, 71),
        (3.0, 0.5, 68), (3.5, 0.5, 71)],
    5: [(0.0, 1.0, 73), (1.0, 0.5, 76), (1.5, 0.5, 78), (2.0, 1.0, 81, 0.9, {"bend": 2}), (3.0, 0.5, 78),
        (3.5, 0.5, 76)],
    6: [(0.0, 1.5, 76), (1.5, 0.5, 73), (2.0, 0.5, 71), (2.5, 0.5, 73), (3.0, 0.5, 76), (3.5, 0.5, 78)],
    7: [(0.0, 2.0, 83, 0.95, {"bend": 2, "bend_t": 0.14}), (3.0, 0.5, 78), (3.5, 0.5, 76)],
})


def garage_lead(s):
    src, env, onset = render_line(s, events(s, GA_LEAD), osc="saw", glide=0.006, legato_gap=0.004, attack=0.003,
                                  release=0.045, vib_rate=5.6, vib_depth=0.22, vib_delay=0.28, key="glead")
    x = src * (env * (0.55 + 0.45 * np.clip(onset, 0, 1)))
    x = dsp.highpass(x, 250, s.sr, 2)  # keep lows out of the distortion (no intermodulation rumble)
    x = ins.amp_sim(x / dsp.peak(x), s.sr, gain=9.0, tone=4200, key_hz=1600)
    x = dsp.highpass(x, 140, s.sr, 2)
    b = wrap(s, x / dsp.peak(x))
    b = echo(s, b, 0.5, 0.18, 0.3, 3, 2500)
    return room(s, b, 0.18, 1.2, "lead", damp=4000)


def garage_organ(s):
    b = s.zeros()
    vo = voice_lead([c.pcs() for c in s.chords], 55, 72, 63)
    for c, v in zip(s.chords, vo):
        for bt, du in ((0, 1.9), (2.5, 0.45), (3.0, 0.9)):
            for m in v:
                x = ins.organ(m, s.sec(du), s.sr, bars=(8, 6, 8, 6, 0, 4, 0, 0, 0), perc=0.35, click=0.3,
                              attack=0.005, release=0.05)
                s.add(b, x, c.start + bt, 1.0)
    b = dsp.tube(b / dsp.peak(b) * 2.5, 1.4, s.sr, 0.15)
    b = leslie(s, b, 6.2, 0.25)
    b = loop_filter(s, b, "lp", 4000)
    return room(s, b, 0.16, 1.0, "organ", damp=4000)


def garage_tamb(s):
    r = dsp.rng(s.id, "tamb")
    b = s.zeros()
    t = [ins.tambourine(s.sr, key=i, hit=0.0) for i in range(4)]
    th = [ins.tambourine(s.sr, key=10 + i, dur=0.25, hit=0.3) for i in range(2)]
    for bar in range(s.bars):
        for i in range(8):
            bt = bar * 4 + i * 0.5
            if i in (2, 6):
                hit(s, b, th, bt, 0.9, r, 0.004)
            else:
                hit(s, b, t, bt, 0.55 if i % 2 == 0 else 0.4, r, 0.005)
        if bar % 2 == 1:
            hit(s, b, t, bar * 4 + 3.75, 0.35, r, 0.003)
    return room(s, b, 0.14, 0.9, "tamb", damp=6000)


def garage_toms(s):
    k = kit("rock", s.sr)
    r = dsp.rng(s.id, "toms")
    b = s.zeros()
    toms = {f: ins.tom(s.sr, f, 0.6, key=int(f)) for f in (210, 165, 125, 92)}
    for bar in (0, 4):
        s.add(b, k["crash"][0], bar * 4, 0.8)
        s.add(b, toms[92], bar * 4, 0.7)
    for j, f in enumerate((210, 210, 165, 125)):
        s.add(b, toms[f], 3 * 4 + 3 + j * 0.25, 0.7 + 0.08 * j, dt=r.normal(0, 0.003))
    for j, f in enumerate((210, 210, 165, 165, 125, 125, 92, 92)):
        s.add(b, toms[f], 7 * 4 + 2 + j * 0.25, 0.6 + 0.05 * j, dt=r.normal(0, 0.003))
    for bar in (2, 6):
        s.add(b, toms[92], bar * 4 + 2.5, 0.45)
    b = dsp.drive(b / dsp.peak(b) * 1.2, 1.3)
    return room(s, b, 0.2, 1.0, "toms", damp=5000)


def garage_strings(s):
    b = s.zeros()
    vo = voice_lead([c.pcs(c.tones + [12]) for c in s.chords], 55, 79, 67, span=17)
    for c, v in zip(s.chords, vo):
        for j, m in enumerate(v):
            s.add(b, string_note(m, s.sec(c.dur) + 0.1, s.sr, key=j), c.start - 0.1)
    b = leslie(s, b, 0.3, 0.0)
    return room(s, b, 0.35, 2.2, "strings", damp=4000)


def garage_gang(s):
    b = s.zeros()
    for bar, bt, key in ((1, 3.0, "a"), (3, 3.0, "b"), (5, 3.0, "c"), (7, 2.5, "d"), (7, 3.0, "e")):
        s.add(b, ins.crowd_hey(s.sr, f"{s.id}/{key}", voices=7, f_lo=105, f_hi=190), bar * 4 + bt, 1.0, dt=-0.03)
    return room(s, b, 0.25, 1.0, "gang", damp=4500)


# ============================================ tension / party (shared)

def _pulse_notes(s, octave_center):
    out = []
    for c in s.chords:
        R = nearest(c.root, octave_center, octave_center - 6, octave_center + 5)
        for i in range(int(c.dur * 2)):
            out.append((c.start + i * 0.5, R + (12 if i % 4 == 3 else 0), 1.0 if i % 2 == 0 else 0.7))
    return out


def tension_stem(s, style):
    """Plays when <= 5 moves remain: pulsing 8ths on the chord roots, faster
    hats (16ths or swung triplets) and a soft tremolo on the key's fifth."""
    r = dsp.rng(s.id, "tension")
    b = s.zeros()
    kits = {"cafe": "lofi", "jazz": "jazz", "square": "street", "stadium": "dance", "garage": "rock"}
    k = kit(kits[style], s.sr)
    hats = k["hat"] if "hat" in k else k["chick"]
    if style == "jazz":
        for i in range(s.beats * 3):
            hit(s, b, hats, i / 3.0, 0.5 if i % 3 == 0 else 0.3, r, 0.003)
    else:
        for i in range(s.beats * 4):
            hit(s, b, hats, sw16(i * 0.25, 0.3 if style == "cafe" else 0.0), 0.55 if i % 2 == 0 else 0.35, r, 0.002)
    pb = s.zeros()
    for bt, m, v in _pulse_notes(s, 62 if style == "cafe" else 50):
        if style == "garage":
            x = power_chord(m - 12 if m > 52 else m, s.sec(0.3), s.sr, muted=True, key=0)
        elif style == "jazz":
            x = upright(m - 12, s.sec(0.4), s.sr)
        elif style == "cafe":  # bright e-piano pulse in the middle register (no low-mid mud)
            x = ins.epiano(m, s.sec(0.25), s.sr, vel=0.6, bright=1.0, release=0.08)
        else:
            x = ins.pluck_synth(m, s.sr, dur=0.22, cutoff=1500, decay=0.05)
        s.add(pb, x, bt, v)
    if style == "garage":
        pb = dsp.loop_apply(pb / dsp.peak(pb), lambda z: ins.amp_sim(z, s.sr, gain=8.0))
    if style == "cafe":
        pb = loop_filter(s, pb, "hp", 180)
    b = b / dsp.peak(b) * 0.55 + pb / dsp.peak(pb)
    fifth = nearest((s.tonic + 7) % 12, 76, 70, 82)
    tr = s.zeros()
    s.add(tr, pad_note(fifth, s.sec(s.beats) - 0.5, s.sr, cutoff=2500, attack=1.0, release=1.0, det=5, key=3), 0.0)
    tr *= 0.6 + 0.4 * np.sin(TAU * np.arange(s.n) / s.n * s.beats * 2) ** 2  # 8th-note tremolo
    b += 0.35 * tr / (dsp.peak(tr) + 1e-9)
    return room(s, b, 0.14, 1.0, "tension", damp=5000)


def party_chords(s, style):
    """Chords for the finale: the song's chords, except that jazz plays plain
    G13 instead of the altered G7s and Bbmaj9 (the tonic) where the song has
    Dm7(11) (Bbmaj9 contains it): triumphant and clearly in Bb, not G minor."""
    out = []
    for c in s.chords:
        if style == "jazz" and c.name.startswith("G7("):
            c = Chord(c.start, c.dur, c.root, [4, 10, 14, 21], "G13")
        elif style == "jazz" and c.name == "Dm7(11)":
            c = Chord(c.start, c.dur, (c.root + 8) % 12, [4, 7, 11, 14], "Bbmaj9")
        out.append(c)
    return out


def party_voicing(c):
    """Stab voicing: root at the bottom (~C4), the 7th (else the 5th) and a
    second colour tone above it (never the 6th: G6 without a clear root is
    Em7) and the 3rd on top, so every stab states root and quality."""
    root = nearest(c.root % 12, 62, 57, 68)
    ts = [t for t in c.tones if t % 12 != 0]
    thirds = [t for t in ts if t % 12 in (3, 4)]
    third = thirds[0] if thirds else ([t for t in ts if t % 12 == 5] or [4])[0]  # sus: the 4th
    pref = ([t for t in ts if t % 12 in (10, 11)] + [t for t in ts if t % 12 == 7]
            + [t for t in ts if t % 12 in (2, 5, 6, 8, 1) and t != third])
    colour = []
    for t in pref:
        if len(colour) < 2 and t % 12 not in [u % 12 for u in colour]:
            colour.append(t)
    v = [root]
    for t in colour:
        pc = (c.root + t) % 12
        v.append(min(m for m in range(root + 1, root + 13) if m % 12 == pc))
    if len(v) < 3:
        v.append(root + 12)  # double the root rather than add a 6th
    top = max(v)
    v.append(min(m for m in range(top + 1, top + 13) if m % 12 == (c.root + third) % 12))
    return sorted(set(v))


def party_stem(s, style):
    """Final concert: crashes, claps, 16th percussion, stabs and a bright arp."""
    r = dsp.rng(s.id, "party")
    kits = {"cafe": "lofi", "jazz": "jazz", "square": "street", "stadium": "dance", "garage": "rock"}
    k = kit(kits[style], s.sr)
    dk = kit("dance", s.sr)
    lk = kit("lofi", s.sr)
    b = s.zeros()
    crash = k.get("crash", dk["crash"])
    for bar in (0, 4):
        s.add(b, crash[0], bar * 4, 0.7)
    for bar in range(s.bars):
        o = bar * 4
        for bt in (1, 3):
            for j in range(3):
                hit(s, b, dk["clap"], o + bt, 0.45, r, 0.008)
        for i in range(16):
            hit(s, b, lk["shaker"], o + i * 0.25, 0.6 if i % 2 else 0.35, r, 0.003)
        for bt in range(4):
            hit(s, b, dk["ohat"], o + bt + 0.5, 0.35, r, 0.0)
        if style in ("stadium", "garage", "square"):
            for bt in range(4):
                hit(s, b, dk["kick"], o + bt, 0.5, r, 0.0)
        if bar in (3, 7):
            for j in range(8):
                hit(s, b, dk["snare"], o + 2 + j * 0.25, 0.3 + 0.06 * j, r, 0.002)
    drums = b / dsp.peak(b)
    st = s.zeros()
    chords = party_chords(s, style)
    vo = [party_voicing(c) for c in chords]
    for bar in range(s.bars):
        for bt in (0.5, 1.5, 2.5, 3.5) if style != "jazz" else (T, 1 + T, 2 + T, 3 + T):
            beat = bar * 4 + bt
            ci = s.chords.index(s.chord_at(beat))
            for j, m in enumerate(vo[ci]):
                if style == "stadium":
                    x = ins.supersaw(m, s.sec(0.3), s.sr, attack=0.003, release=0.08, key=j)
                elif style == "garage":
                    x = ins.organ(m, s.sec(0.3), s.sr, bars=(8, 0, 8, 8, 0, 6, 0, 0, 4), perc=0.3, click=0.3)
                elif style == "cafe":
                    x = ins.epiano(m, s.sec(0.3), s.sr, vel=0.8, bright=1.0, release=0.1)
                else:
                    x = ins.brass(m, s.sec(0.3), s.sr, vel=0.9, key=j)
                s.add(st, x, beat, 1.0)
    arp = s.zeros()
    for c in chords:  # root, 3rd, 5th and 7th only (no 6ths/9ths): a triumphant arpeggio that names the chord
        pcs = [0] + [t % 12 for t in c.tones if t % 12 in (3, 4, 5, 7, 10, 11)]
        tones = sorted({m for m in range(76, 100) if (m - c.root) % 12 in pcs})[:4]
        for i in range(int(c.dur * 2)):
            m = tones[i % len(tones)]
            if style == "jazz":
                x = ins.vibes(m, s.sr, vel=0.6, dur=0.8, release=0.3)
            else:
                x = ins.glock(m, s.sr, vel=0.7, dur=0.8, octave_up=False)
            s.add(arp, x, c.start + i * 0.5, 0.8 if i % 2 == 0 else 0.6)
    x = drums * 0.9 + 0.8 * st / dsp.peak(st) + 0.45 * arp / dsp.peak(arp)
    return room(s, x, 0.2, 1.4, "party", damp=6000)


# ================================================== district registry

DISTRICTS = {
    "cafe": dict(song=cafe_song, stems={
        "beat": cafe_beat, "vinyl": cafe_vinyl, "keys": cafe_keys, "bass": cafe_bass, "lead": cafe_lead,
        "pad": cafe_pad}),
    "jazz": dict(song=jazz_song, stems={
        "brushes": jazz_brushes, "piano": jazz_piano, "bass": jazz_bass, "organ": jazz_organ, "sax": jazz_sax,
        "vibes": jazz_vibes, "trumpet": jazz_trumpet}),
    "square": dict(song=square_song, stems={
        "drums": square_drums, "shaker": square_shaker, "guitar": square_guitar, "tuba": square_tuba,
        "brass": square_brass, "clarinet": square_clarinet, "claps": square_claps, "whistle": square_whistle}),
    "stadium": dict(song=stadium_song, stems={
        "beat": stadium_beat, "bass": stadium_bass, "chords": stadium_chords, "arp": stadium_arp,
        "choir": stadium_choir, "fx": stadium_fx, "hook": stadium_hook, "snaps": stadium_snaps}),
    "garage": dict(song=garage_song, stems={
        "drums": garage_drums, "rhythm": garage_rhythm, "bass": garage_bass, "lead": garage_lead,
        "organ": garage_organ, "tamb": garage_tamb, "toms": garage_toms, "strings": garage_strings,
        "gang": garage_gang}),
}

# Relative stem loudness (gated K-weighted dB, see dsp.loudness). Only the
# differences matter: gen_audio.py scales the whole district afterwards.
# Expensive (4-5 star) tasks must be clearly heard when they unlock, so sparse
# layers (gang shouts, toms, snaps, risers, whistles, shaker, strings) sit 3-6 dB
# hotter than a plain balance would put them; tension (+3 dB) and party (+2 dB)
# are up so the last-moves and finale moments are felt.
LOUDNESS = {
    "cafe": {"beat": -16, "vinyl": -22, "keys": -18, "bass": -21, "lead": -19, "pad": -20,
             "tension": -18, "party": -16},
    "jazz": {"brushes": -19, "piano": -18, "bass": -19, "organ": -24, "sax": -18, "vibes": -21,
             "trumpet": -19, "tension": -18, "party": -16},
    "square": {"drums": -16, "shaker": -21, "guitar": -20, "tuba": -19, "brass": -19, "clarinet": -19,
               "claps": -17, "whistle": -18, "tension": -18, "party": -16},
    "stadium": {"beat": -15, "bass": -19, "chords": -19, "arp": -21, "choir": -21, "fx": -17, "hook": -18,
                "snaps": -17, "tension": -18, "party": -16},
    "garage": {"drums": -15, "rhythm": -18, "bass": -19, "lead": -18, "organ": -21, "tamb": -19,
               "toms": -15, "strings": -19, "gang": -15, "tension": -18, "party": -16},
}


def render_district(d):
    """Render every stem of district d (dict from districts.json).
    Returns (song, {stem_id: raw signal}, {stem_id: sample rate}) in task
    order + tension + party. `song` is the 22.05 kHz grid; stems listed in
    HI_RATE are rendered on the same grid at 44.1 kHz."""
    spec = DISTRICTS[d["id"]]
    s = spec["song"](d)
    hi = s.at_rate(SR_HI)
    fns = [(t["stem"], spec["stems"][t["stem"]]) for t in d["tasks"]]
    fns += [("tension", lambda z: tension_stem(z, d["id"])), ("party", lambda z: party_stem(z, d["id"]))]
    out, rates = {}, {}
    for k, fn in fns:
        ss = hi if k in HI_RATE.get(d["id"], ()) else s
        out[k] = np.asarray(fn(ss), dtype=float)
        rates[k] = ss.sr
        assert len(out[k]) == ss.n, (d["id"], k, len(out[k]), ss.n)
        assert np.all(np.isfinite(out[k])), (d["id"], k)
    return s, out, rates
