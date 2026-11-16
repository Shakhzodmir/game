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
    "beach": {"shaker", "party"},
    "carnival": {"shaker", "party"},
    "cinema": {"party"},
    "bazaar": set(),  # every stem at 22.05 kHz: the zills ring at 2.3 and 6.4 kHz, nothing lives above 10 kHz
    "skyclub": set(),  # every stem at 22.05 kHz: hats, sweeps and the arpeggio are shaped to end below 10 kHz
    "block": set(),  # every stem at 22.05 kHz: boom-bap is warm, its hats and scratches end below 10 kHz
    "island": set(),  # every stem at 22.05 kHz: reggae is round and warm, its hats end below 10 kHz
    "ranch": set(),  # every stem at 22.05 kHz: a washboard, strings and reeds, nothing lives above 10 kHz
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
        elif name == "beach":
            k["cajon"] = [cajon_bass(sr, key=i) for i in range(2)]
            k["tap"] = [dsp.lowpass(ins.brush_tap(sr, key=60 + i, dur=0.08, tone=220.0), 6000, sr) for i in range(4)]
            k["slap"] = [dsp.lowpass(ins.snare(sr, 220, 0.06, 0.09, 0.5, 900, 5000, key=70 + i), 5500, sr)
                         for i in range(2)]
            k["rim"] = [cross_stick(sr, key=i) for i in range(2)]
            k["shaker"] = [ins.shaker(sr, key=20 + i, dur=0.07) for i in range(4)]
            k["maraca"] = [dsp.highpass(ins.shaker(sr, key=30 + i, dur=0.14), 5200, sr, 2) for i in range(3)]
            k["hat"] = [ins.shaker(sr, key=40 + i, dur=0.05) for i in range(3)]
        elif name == "carnival":
            unit = lambda x: x / dsp.peak(x)  # noqa: E731
            hi, lo = float(midi_hz(60)), float(midi_hz(55))  # conga on C4, tumba on G3: the root and the fifth of the key
            k["open"] = [conga(sr, hi, "open", key=i) for i in range(2)]
            k["tumba"] = [conga(sr, lo, "open", key=10 + i) for i in range(2)]
            k["slap"] = [conga(sr, hi, "slap", key=20 + i) for i in range(2)]
            k["heel"] = [conga(sr, hi, "heel", key=30 + i) for i in range(2)]
            k["toe"] = [conga(sr, hi, "toe", key=40 + i) for i in range(3)]
            k["clave"] = [unit(ins.woodblock(sr, f=float(midi_hz(96)), key=60 + i, t=0.09)) for i in range(2)]
            k["kick"] = [unit(dsp.lowpass(ins.kick(sr, 110.0, float(midi_hz(36)), 0.03, 0.3, 0.0, 1.2, key=70 + i),
                                          1800, sr)) for i in range(2)]
            k["maraca"] = [unit(dsp.highpass(ins.shaker(sr, key=80 + i, dur=0.07), 4500, sr, 2)) for i in range(4)]
            k["guiro"] = [guiro_scrape(sr, 0.2, key=i) for i in range(2)]
            k["guiro_short"] = [guiro_scrape(sr, 0.07, key=10 + i) for i in range(3)]
            k["hat"] = [ins.shaker(sr, key=90 + i, dur=0.05) for i in range(3)]
            k["bell"] = [unit(ins.cowbell(sr, key=5, f1=float(midi_hz(72)), f2=float(midi_hz(79)), t60=0.3))]
        elif name == "cinema":
            unit = lambda x: x / dsp.peak(x)  # noqa: E731
            # a concert snare played softly, the big bass drum of the orchestra (a felt thump that settles on Bb1,
            # the fifth of the key), a pair of crash cymbals and the dry stick taps of the tension layer
            k["snare"] = [unit(dsp.lowpass(ins.snare(sr, 196.0, 0.06, 0.15, 1.0, 1700, 8000, key=300 + i), 7500, sr))
                          for i in range(4)]
            k["bd"] = [unit(dsp.lowpass(ins.kick(sr, 76.0, float(midi_hz(34)), 0.02, 0.75, 0.04, 1.15, key=310 + i),
                                        700, sr, 2)) for i in range(2)]
            k["crash"] = [ins.crash(sr, key=41, t60=2.8)]
            k["hat"] = [unit(dsp.highpass(ins.snare(sr, 233.0, 0.025, 0.05, 1.0, 2500, 9000, key=320 + i), 1500, sr, 2))
                        for i in range(3)]
        elif name == "bazaar":
            unit = lambda x: x / dsp.peak(x)  # noqa: E731
            # a goblet drum (dum on G2, the tonic; tek and ka ring on G5 and B5), a frame drum with a snare buzz
            # on G3, finger cymbals and the jingles of a riq
            for st in ("dum", "tek", "ka", "slap"):
                k[st] = [darbuka(sr, st, key=i) for i in range(3)]
            k["frame"] = [frame_drum(sr, key=i) for i in range(2)]
            k["zill"] = [zill(sr, key=i) for i in range(2)]
            k["riq"] = [unit(ins.tambourine(sr, key=40 + i, dur=0.14)) for i in range(3)]
            k["hat"] = [unit(ins.tambourine(sr, key=50 + i, dur=0.07)) for i in range(3)]
        elif name == "skyclub":
            unit = lambda x: x / dsp.peak(x)  # noqa: E731
            # a house kit made for 22.05 kHz: a round kick that settles on Ab1 (with its octave Ab2, which is what
            # a phone plays of it), a wide clap, a tight closed hat and a short open hat that end below 10 kHz
            k["kick"] = [club_kick(sr)]
            k["clap"] = [unit(ins.clap(sr, key=400 + i, tail=0.15, lo=1000.0, hi=4200.0)) for i in range(2)]
            k["hat"] = [unit(dsp.lowpass(ins.hat(sr, 0.035, key=410 + i, lo=6000, tone=0.3), 9500, sr, 2))
                        for i in range(3)]
            no = nsamp(0.2, sr)
            oh = dsp.lowpass(ins.hat(sr, open_=True, key=420, lo=5500, tone=0.3), 9500, sr, 2)[:no]
            k["ohat"] = [unit(dsp.fade(oh * np.exp(-np.arange(no) / (0.07 * sr)), sr, 0.0003, 0.03))]
            k["crash"] = [dsp.lowpass(ins.crash(sr, key=43, t60=2.0), 9500, sr, 2)]
        elif name == "block":
            unit = lambda x: x / dsp.peak(x)  # noqa: E731
            # a boom-bap kit made for 22.05 kHz: a kick whose tail rings on Bb1 (and Bb2), a fat snare with its
            # body on Bb3, ghost notes, crisp hats that end below 10 kHz, hands (claps and finger snaps) and two
            # bongos on Bb3 and F3 (the root and the fifth of the key)
            k["kick"] = [boom_kick(sr, key=i) for i in range(2)]
            k["snare"] = [unit(dsp.lowpass(ins.snare(sr, float(midi_hz(58)), 0.12, 0.2, 0.9, 1100, 6500, key=500 + i),
                                           8000, sr)) for i in range(3)]
            k["ghost"] = [unit(dsp.lowpass(ins.snare(sr, float(midi_hz(58)), 0.05, 0.08, 0.7, 1500, 6000, key=510 + i),
                                           6000, sr)) for i in range(2)]
            k["hat"] = [unit(dsp.lowpass(ins.hat(sr, 0.045, key=520 + i, lo=5000, tone=0.45), 9500, sr, 2))
                        for i in range(4)]
            no = nsamp(0.26, sr)
            oh = dsp.lowpass(ins.hat(sr, open_=True, key=529, lo=5000, tone=0.45), 9500, sr, 2)[:no]
            k["ohat"] = [unit(dsp.fade(oh * np.exp(-np.arange(no) / (0.09 * sr)), sr, 0.0003, 0.03))]
            k["clap"] = [unit(ins.clap(sr, key=530 + i, tail=0.1, lo=800.0, hi=3000.0)) for i in range(3)]
            k["snap"] = [unit(ins.snap(sr, key=540 + i)) for i in range(3)]
            k["bongo_hi"] = [conga(sr, float(midi_hz(58)), "open", key=550 + i) for i in range(2)]
            k["bongo_lo"] = [conga(sr, float(midi_hz(53)), "open", key=560 + i) for i in range(2)]
            k["crash"] = [dsp.lowpass(ins.crash(sr, key=53, t60=1.8), 9500, sr, 2)]
        elif name == "island":
            unit = lambda x: x / dsp.peak(x)  # noqa: E731
            # a one-drop kit made for 22.05 kHz: a soft deep kick that settles on A1 (with its octave A2), a
            # cross-stick (an A6 click over an E5 block), tight hats that end below 10 kHz, two bongos on A4
            # and E4 (the root and the fifth of the key), a timbale for the pick-ups (on A3) and a splash
            k["kick"] = [drop_kick(sr, key=i) for i in range(2)]
            k["rim"] = [unit(dsp.mix(ins.rim(sr, key=600 + i, f=float(midi_hz(93))),
                                     0.5 * ins.woodblock(sr, f=float(midi_hz(76)), key=600 + i, t=0.06)))
                        for i in range(2)]
            k["hat"] = [unit(dsp.lowpass(ins.hat(sr, 0.04, key=610 + i, lo=5500, tone=0.4), 9500, sr, 2))
                        for i in range(4)]
            no = nsamp(0.22, sr)
            oh = dsp.lowpass(ins.hat(sr, open_=True, key=619, lo=5200, tone=0.4), 9500, sr, 2)[:no]
            k["ohat"] = [unit(dsp.fade(oh * np.exp(-np.arange(no) / (0.08 * sr)), sr, 0.0003, 0.03))]
            nh, nl = nsamp(0.22, sr), nsamp(0.28, sr)
            k["bongo_hi"] = [unit(dsp.fade(conga(sr, float(midi_hz(69)), "open", key=620 + i)[:nh]
                                           * np.exp(-np.arange(nh) / (0.07 * sr)), sr, 0.0005, 0.02)) for i in range(2)]
            k["bongo_lo"] = [unit(dsp.fade(conga(sr, float(midi_hz(64)), "open", key=630 + i)[:nl]
                                           * np.exp(-np.arange(nl) / (0.09 * sr)), sr, 0.0005, 0.02)) for i in range(2)]
            k["bongo_tip"] = [conga(sr, float(midi_hz(69)), "toe", key=640 + i) for i in range(3)]
            k["timbale"] = [unit(dsp.lowpass(ins.snare(sr, float(midi_hz(57)), 0.16, 0.05, 0.25, 1500, 6000,
                                                       key=650 + i), 7000, sr)) for i in range(2)]
            k["shaker"] = [unit(ins.shaker(sr, key=660 + i, dur=0.06)) for i in range(3)]
            k["crash"] = [dsp.lowpass(ins.crash(sr, key=63, t60=1.4), 9500, sr, 2)]
        elif name == "ranch":
            k = ranch_kit(sr)
        for v in k.values():
            for a in v:
                a.setflags(write=False)
        return k
    key = ("kit", name, sr)
    if key not in _CACHE:
        _CACHE[key] = mk()
    return _CACHE[key]


def cajon_bass(sr, key=0):
    """Cajon bass tone: a soft low thump that settles on D2 plus the knock of the wooden front plate."""
    y = ins.kick(sr, 125.0, float(midi_hz(38)), 0.022, 0.26, 0.0, 1.1, key=key)
    n = len(y)
    t = np.arange(n) / sr
    wood = dsp.bandpass(dsp.rng("cajon", key).standard_normal(n), 180, 1300, sr) * np.exp(-t / 0.011)
    y = y / dsp.peak(y) + 0.3 * wood / dsp.peak(wood)
    return dsp.fade(dsp.lowpass(y, 2200, sr, 2), sr, 0.0008, 0.02)


def cross_stick(sr, key=0):
    """Cross-stick: the rim click with a woody body under it (A6 click over a D5 block: in the key of the beach)."""
    x = ins.rim(sr, key=key, f=float(midi_hz(93)))
    w = ins.woodblock(sr, f=float(midi_hz(74)), key=key, t=0.06)
    return dsp.mix(x, 0.45 * w)


def conga(sr, f, stroke, key=0):
    """One stroke on a conga tuned to f: 'open' (the ringing tone of the drum), 'slap' (a dry crack), 'heel' and
    'toe' (the muted palm and finger strokes that keep the 8ths going between the accents)."""
    r = dsp.rng("conga", stroke, key)
    n = nsamp({"open": 0.42, "slap": 0.09, "heel": 0.09, "toe": 0.06}[stroke], sr)
    t = np.arange(n) / sr
    nz = r.standard_normal(n)
    if stroke == "open":
        ph = TAU * np.cumsum(f * (1.0 + 0.06 * np.exp(-t / 0.018))) / sr
        x = (np.sin(ph) + 0.3 * np.sin(1.5 * ph) * np.exp(-t / 0.05)) * dsp.env_perc(n, sr, 0.36, 0.001)
        skin = dsp.bandpass(nz, 500, 3500, sr) * np.exp(-t / 0.007)
        x = x + 0.35 * skin / dsp.peak(skin)
    elif stroke == "slap":
        crack = dsp.bandpass(nz, 900, 5000, sr) * np.exp(-t / 0.011)
        x = crack / dsp.peak(crack) + 0.45 * np.sin(TAU * 3.0 * f * t) * np.exp(-t / 0.016)
    elif stroke == "heel":
        thud = dsp.lowpass(nz, 700, sr, 2) * np.exp(-t / 0.012)
        x = np.sin(TAU * 0.5 * f * t) * np.exp(-t / 0.028) + 0.5 * thud / dsp.peak(thud)
    else:
        tick = dsp.bandpass(nz, 600, 2600, sr) * np.exp(-t / 0.007)
        x = tick / dsp.peak(tick) + 0.3 * np.sin(TAU * f * t) * np.exp(-t / 0.014)
    return dsp.fade(x / dsp.peak(x), sr, 0.0005, 0.02)


def guiro_scrape(sr, dur, key=0):
    """A scraped gourd: band-passed noise chopped by the ridges (about 42 a second) under one stroke of the stick."""
    n = nsamp(dur, sr)
    t = np.arange(n) / sr
    x = dsp.bandpass(dsp.rng("guiro_scrape", key).standard_normal(n), 2200, min(9000, 0.44 * sr), sr)
    x = x * (0.3 + 0.7 * (0.5 + 0.5 * np.sin(TAU * 42 * t)) ** 2) * np.sin(np.pi * np.clip(t / dur, 0, 1)) ** 0.6
    return dsp.fade(x / dsp.peak(x), sr, 0.002, 0.01)


def baby_bass(midi, dur, sr, key=0):
    """The 'baby bass' of a salsa band: a dark plucked string over a round sine fundamental (and a little of its
    octave, which is what a phone speaker plays of it), lightly overdriven."""
    def mk():
        y = ins.guitar(midi, dur, sr, bright=0.2, t60=1.1, pick=0.3, mute=0.09, key=key, damp=0.55).copy()
        n = len(y)
        t = np.arange(n) / sr
        f = float(midi_hz(midi))
        gate = np.exp(-dsp.LN1000 * np.maximum(t - dur, 0.0) / 0.09)
        sub = (np.sin(TAU * f * t) + 0.3 * np.sin(2 * TAU * f * t)) * (1.0 - np.exp(-t / 0.012)) * np.exp(-t / 0.5)
        y = y / (dsp.peak(y) + 1e-9) + 0.7 * sub * gate
        y = dsp.tube(y / dsp.peak(y) * 1.2, 1.4, sr, 0.1)
        y = dsp.filt(y, "peak", 800, sr, q=1.0, gain_db=2.0)
        return dsp.fade(y, sr, 0.001, 0.01)
    return cached(("babybass", midi, round(dur, 3), sr, key), mk)


def timpani(midi, sr, hard=1.0, key=0):
    """One stroke on a kettledrum tuned to `midi`: the principal tone with the fifth, the octave and the twelfth
    above it (a tuned head rings close to 1 : 1.5 : 2 : 3; the major third at 2.5 is left out, it would spell a
    chord of its own), a small drop of pitch after the stroke and the thump of the felt mallet. The octave is as
    strong as the principal: that is what a phone plays of the drum. `hard` (0..1) is how hard the stroke is:
    more thump, more of the upper partials."""
    def mk():
        n = nsamp(1.5, sr)
        t = np.arange(n) / sr
        r = dsp.rng("timpani", midi, key)
        ph = TAU * np.cumsum(float(midi_hz(midi)) * (1.0 + 0.02 * hard * np.exp(-t / 0.03))) / sr
        x = 0.5 * np.sin(ph) * np.exp(-t / 0.36) + (0.2 + 0.15 * hard) * np.sin(1.5 * ph + 0.4) * np.exp(-t / 0.2)
        x += (0.6 + 0.2 * hard) * np.sin(2.0 * ph + 1.1) * np.exp(-t / 0.28)
        x += (0.15 + 0.2 * hard) * np.sin(3.0 * ph + 0.7) * np.exp(-t / 0.14)
        x += 0.12 * hard * np.sin(4.0 * ph + 0.2) * np.exp(-t / 0.08)
        th = dsp.lowpass(r.standard_normal(n), 450.0 + 900.0 * hard, sr, 2) * np.exp(-t / 0.014)
        x = x + (0.25 + 0.3 * hard) * th / dsp.peak(th)
        return dsp.fade(x / dsp.peak(x), sr, 0.001, 0.1)
    return cached(("timpani", midi, sr, round(hard, 2), key), mk)


def pizz(midi, sr, key=0):
    """A plucked orchestral string: a short dark pluck, longer and rounder in the bass."""
    low = midi < 60
    return ins.guitar(midi, 0.5 if low else 0.35, sr, bright=0.3 if low else 0.42, t60=0.8 if low else 0.4,
                      pick=0.22 if low else 0.14, mute=0.3, key=key, damp=0.5, attack=0.002)


def bowed(midi, dur, sr, key=0, attack=0.07, release=0.2, vib=1.0, cutoff=2400.0):
    """A bowed string (two players a few cents apart): the bow takes `attack` seconds to speak, vibrato arrives
    after a quarter of a second."""
    def mk():
        n = nsamp(dur + release * 1.6, sr)
        t = np.arange(n) / sr
        r = dsp.rng("bowed", midi, key)
        f = midi_hz(midi) * (1.0 + vib * 0.004 * np.sin(TAU * r.uniform(5.0, 5.8) * t + r.uniform(0, 6))
                             * np.clip((t - 0.22) / 0.3, 0.0, 1.0))
        x = dsp.saw(f * 2 ** (4 / 1200), n, sr, r.uniform()) + dsp.saw(f * 2 ** (-4 / 1200), n, sr, r.uniform())
        x = dsp.lowpass(x, cutoff, sr, 2)
        x *= dsp.env_adsr(n, sr, attack, 0.25, 0.85, dur, release)
        return dsp.fade(x / dsp.peak(x), sr, 0.002, 0.02)
    return cached(("bowed", midi, round(dur, 3), sr, key, attack, release, vib, cutoff), mk)


def horn(midi, dur, sr, vel=0.8, key=0):
    """French horn: one saw behind a low-pass that opens with the breath (never bright), a round peak near
    480 Hz, a soft start from a little under the note."""
    def mk():
        n = nsamp(dur + 0.3, sr)
        t = np.arange(n) / sr
        r = dsp.rng("horn", midi, key)
        cents = -22.0 * np.exp(-t / 0.04) + r.uniform(-4, 4)
        f = midi_hz(midi) * 2 ** (cents / 1200) * (1.0 + 0.002 * np.sin(TAU * r.uniform(4.6, 5.4) * t)
                                                   * np.clip((t - 0.3) / 0.4, 0.0, 1.0))
        env = dsp.env_adsr(n, sr, 0.06, 0.25, 0.82, dur, 0.14)
        y = dsp.sweep_filter(dsp.saw(f, n, sr, r.uniform()), 350.0 + (800.0 + 1100.0 * vel) * env, sr, q=0.8)
        y = dsp.filt(y, "peak", 480, sr, q=1.0, gain_db=4.0)
        return dsp.fade(y * env * vel, sr, 0.002, 0.02)
    return cached(("horn", midi, round(dur, 3), sr, round(vel, 2), key), mk)


def harp(midi, sr, key=0, dur=1.3):
    """A harp string: plucked near the middle (round), left to ring."""
    return ins.guitar(midi, dur, sr, bright=0.55, t60=2.4, pick=0.32, mute=0.35, key=key, damp=0.45, attack=0.0015)


def darbuka(sr, stroke, key=0):
    """One stroke on a goblet drum: 'dum' (the open bass tone in the middle of the skin: it settles on G2 and
    carries its octaves, which is what a phone plays of it; no twelfth: a D under every dum would pull the key
    to D), 'tek' (the right hand on the rim: a short ring on G5 and its octave under a bright crack), 'ka' (the
    left hand: the same, lighter, on B5) and 'slap' (a dry muted crack)."""
    r = dsp.rng("darbuka", stroke, key)
    n = nsamp({"dum": 0.45, "tek": 0.16, "ka": 0.12, "slap": 0.09}[stroke], sr)
    t = np.arange(n) / sr
    nz = r.standard_normal(n)
    if stroke == "dum":
        ph = TAU * np.cumsum(float(midi_hz(43)) * (1.0 + 0.5 * np.exp(-t / 0.02))) / sr
        x = np.sin(ph) * np.exp(-t / 0.11) + 0.5 * np.sin(2.0 * ph + 0.5) * np.exp(-t / 0.075)
        x += 0.15 * np.sin(4.0 * ph + 0.2) * np.exp(-t / 0.045)
        skin = dsp.bandpass(nz, 300, 2500, sr) * np.exp(-t / 0.006)
        x = x + 0.3 * skin / dsp.peak(skin)
    elif stroke in ("tek", "ka"):
        f = float(midi_hz(79 if stroke == "tek" else 83)) * (1.0 + 0.004 * key)
        ring = np.sin(TAU * f * t) * np.exp(-t / 0.03) + 0.5 * np.sin(TAU * 2.0 * f * t + 0.8) * np.exp(-t / 0.018)
        crack = dsp.bandpass(nz, 2500, min(9000, 0.44 * sr), sr) * np.exp(-t / (0.008 if stroke == "tek" else 0.005))
        x = 0.7 * ring + crack / dsp.peak(crack)
    else:
        crack = dsp.bandpass(nz, 900, 5000, sr) * np.exp(-t / 0.012)
        x = crack / dsp.peak(crack) + 0.3 * np.sin(TAU * float(midi_hz(67)) * t) * np.exp(-t / 0.02)
    return dsp.fade(x / dsp.peak(x), sr, 0.0005, 0.02)


def frame_drum(sr, key=0, midi=55):
    """A big frame drum with snare strings inside (bendir): a soft round tone on G3 and a short buzz."""
    y = ins.tom(sr, float(midi_hz(midi)), 0.5, key=90 + key)
    n = len(y)
    t = np.arange(n) / sr
    buzz = dsp.bandpass(dsp.rng("bendir", key).standard_normal(n), 1200, 5000, sr) * np.exp(-t / 0.05)
    y = dsp.lowpass(y / dsp.peak(y), 1800, sr, 2) + 0.16 * buzz / dsp.peak(buzz)
    return dsp.fade(y / dsp.peak(y), sr, 0.0008, 0.03)


def zill(sr, key=0, t60=0.55, midi=98):
    """Finger cymbals: two small brass discs a few Hz apart (they beat) ringing on D7, with the fifth and an
    inharmonic partial that die quickly, and the click of the two rims."""
    n = nsamp(t60 + 0.05, sr)
    t = np.arange(n) / sr
    f = float(midi_hz(midi))
    x = np.sin(TAU * f * t) + 0.8 * np.sin(TAU * f * (1.005 + 0.001 * key) * t + 1.0)
    x += 0.35 * np.sin(TAU * 1.5 * f * t + 0.3) * np.exp(-t / (t60 * 0.2))
    x += 0.5 * np.sin(TAU * 2.71 * f * t) * np.exp(-t / (t60 * 0.1))
    x *= dsp.env_perc(n, sr, t60, 0.0005)
    x += 0.4 * dsp.highpass(dsp.rng("zill", key).standard_normal(n), 5000, sr, 2) * np.exp(-t / 0.003)
    return dsp.fade(x / dsp.peak(x), sr, 0.0003, 0.02)


def oud(midi, dur, sr, key=0):
    """One course of an oud: two gut strings a few cents apart, plucked with a long quill close to the bridge.
    A dark, short, nasal tone without sustain over the body of the round back."""
    def mk():
        kw = dict(bright=0.42, t60=1.0, mute=0.12, damp=0.55, attack=0.001)
        a = ins.guitar(midi, dur, sr, pick=0.09, key=key, **kw)
        b = ins.guitar(midi + 0.07, dur, sr, pick=0.11, key=key + 7, **kw)
        n = min(len(a), len(b))
        y = a[:n] + 0.9 * b[:n]
        y = dsp.filt(y, "peak", 220, sr, q=1.0, gain_db=3.0)
        y = dsp.filt(y, "peak", 950, sr, q=1.2, gain_db=3.5)
        y = dsp.lowpass(y, 4500, sr, 2)
        return dsp.fade(y / dsp.peak(y), sr, 0.0005, 0.01)
    return cached(("oud", midi, round(dur, 3), sr, key), mk)


def qanun(midi, sr, key=0, dur=0.9):
    """One course of a qanun: three metal strings (a few cents apart: the shimmer) plucked with finger picks.
    Bright and glassy, left to ring."""
    def mk():
        kw = dict(bright=0.85, t60=1.5, pick=0.07, mute=0.3, damp=0.3, attack=0.0005)
        parts = [ins.guitar(midi + dc, dur, sr, key=key * 3 + j, **kw) for j, dc in enumerate((-0.05, 0.0, 0.06))]
        n = min(len(p) for p in parts)
        y = dsp.highpass(sum(p[:n] for p in parts), 200, sr, 2)
        return dsp.fade(y / dsp.peak(y), sr, 0.0003, 0.01)
    return cached(("qanun", midi, sr, key, round(dur, 3)), mk)


def club_kick(sr, midi=32, key=0):
    """A house kick: a fast drop of pitch onto `midi` (Ab1), a second harmonic an octave above it (Ab2: what small
    speakers play of the drum) and a short click."""
    n = nsamp(0.34, sr)
    t = np.arange(n) / sr
    ph = TAU * np.cumsum(float(midi_hz(midi)) * (1.0 + 3.2 * np.exp(-t / 0.018))) / sr
    x = np.sin(ph) * np.exp(-t / 0.11) + 0.45 * np.sin(2.0 * ph + 0.4) * np.exp(-t / 0.09)
    click = dsp.bandpass(dsp.rng("clubkick", key).standard_normal(n), 1500, 6000, sr) * np.exp(-t / 0.003)
    x = dsp.drive(x / dsp.peak(x) + 0.25 * click / dsp.peak(click), 1.8)
    return dsp.fade(x / dsp.peak(x), sr, 0.0005, 0.03)


def club_bass(midi, dur, sr, key=0):
    """A rubbery house bass: square and saw behind a resonant low-pass that snaps shut, over a sine."""
    def mk():
        f = float(midi_hz(midi))
        n = nsamp(dur + 0.08, sr)
        t = np.arange(n) / sr
        x = 0.7 * dsp.pulse(f, n, sr, 0.5) + 0.5 * dsp.saw(f * 1.004, n, sr, 0.3)
        x = dsp.sweep_filter(x, 150.0 + 1600.0 * np.exp(-t / 0.07) + 2.0 * f, sr, q=2.0)
        x += 0.8 * np.sin(TAU * f * t)
        x *= dsp.env_adsr(n, sr, 0.004, 0.15, 0.6, dur, 0.05)
        return dsp.fade(dsp.drive(x / dsp.peak(x) * 1.3, 1.5), sr, 0.001, 0.01)
    return cached(("clubbass", midi, round(dur, 3), sr, key), mk)


def sky_pluck(midi, sr, dur=0.3, key=0, cutoff=5500.0):
    """A bright trance pluck: two saws a few cents apart and a narrow pulse an octave up behind a low-pass that
    closes in a twentieth of a second, with a glassy sine on the octave."""
    def mk():
        f = float(midi_hz(midi))
        n = nsamp(dur, sr)
        t = np.arange(n) / sr
        src = 0.5 * dsp.saw(f * 1.004, n, sr, 0.1 * key) + 0.5 * dsp.saw(f * 0.996, n, sr, 0.5)
        src += 0.35 * dsp.pulse(2.0 * f, n, sr, 0.3)
        y = dsp.sweep_filter(src, 500.0 + cutoff * np.exp(-t / 0.05), sr, q=1.6)
        y += 0.3 * np.sin(TAU * 2.0 * f * t) * np.exp(-t / 0.08)
        y *= dsp.env_perc(n, sr, dur * 0.9, 0.001)
        return dsp.fade(y / dsp.peak(y), sr, 0.001, 0.02)
    return cached(("skypluck", midi, sr, round(dur, 3), key, cutoff), mk)


def vox_chop(midi, dur, sr, vowel="a_alto", key=0):
    """A chopped vocal sample: one sung vowel (two glottal saws through formants) cut short, with a small fall of
    pitch into the note."""
    def mk():
        n = nsamp(dur + 0.08, sr)
        t = np.arange(n) / sr
        r = dsp.rng("voxchop", midi, vowel, key)
        f = midi_hz(midi) * (1.0 + 0.004 * np.sin(TAU * 5.5 * t + r.uniform(0, 6))) * (1.0 + 0.04 * np.exp(-t / 0.02))
        src = dsp.saw(f, n, sr) + 0.5 * dsp.saw(f * 1.006, n, sr, 0.4) + 0.08 * r.standard_normal(n)
        x = dsp.formant(src, sr, dsp.VOWELS[vowel]) * dsp.env_adsr(n, sr, 0.008, 0.2, 0.8, dur, 0.035)
        return dsp.fade(x / dsp.peak(x), sr, 0.002, 0.02)
    return cached(("voxchop", midi, round(dur, 3), sr, vowel, key), mk)


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


# ====================================================== BEACH (D major)

def beach_song(d):
    # bossa nova in D: I - vi - ii - V, then IV - iii vi - ii V - I with a sus turnaround; all diatonic, the loop
    # ends on the tonic (D6) and the A9sus4 (G/A) of its last two beats leads back into Dmaj7.
    # The two tonic chords keep the root in the voicing (maj7 and 6, not maj9 and 6/9, whose upper notes alone
    # are F#m7 / F#m7sus): the loop reads as D major, not as F# minor
    D, E, Fs, G, A, B = 2, 4, 6, 7, 9, 11
    maj9, m9, m7, d13 = [4, 7, 11, 14], [3, 7, 10, 14], [3, 7, 10, 12], [4, 10, 14, 21]
    return Song(d, progression([
        (4, D, [4, 7, 11, 12], "Dmaj7"), (4, B, m7, "Bm7"), (4, E, m9, "Em9"), (4, A, d13, "A13"),
        (4, G, maj9, "Gmaj9"), (2, Fs, m7, "F#m7"), (2, B, m7, "Bm7"), (2, E, m9, "Em9"), (2, A, d13, "A13"),
        (2, D, [4, 7, 9, 12], "D6"), (2, A, [5, 7, 10, 14], "A9sus4"),
    ]))


BEACH_CLAVE = ((0.0, 1.5, 3.0), (1.0, 2.5))  # the 3-2 bossa clave over two bars (beats)


def beach_perc(s):
    """Cajon and cross-stick: the bossa clave on the rim, the soft 'heartbeat' bass (1, the and of 2, 3, the and
    of 4) and quiet finger taps on the 8ths. The first layer: it has to groove alone."""
    k = kit("beach", s.sr)
    r = dsp.rng(s.id, "perc")
    b = s.zeros()
    for bar in range(s.bars):
        o = bar * 4
        for bt, v in ((0, 0.95), (1.5, 0.5), (2, 0.85), (3.5, 0.55)):
            hit(s, b, k["cajon"], o + bt, v, r, 0.003)
        for bt in BEACH_CLAVE[bar % 2]:
            hit(s, b, k["rim"], o + bt, 0.8, r, 0.003)
        for i in range(8):
            hit(s, b, k["tap"], o + i * 0.5, 0.34 if i % 2 else 0.22, r, 0.005)
        if bar in (3, 7):  # a two-note slap pickup into the next phrase
            for bt, v in ((3.0, 0.4), (3.5, 0.55)):
                hit(s, b, k["slap"], o + bt, v, r, 0.003)
    b = dsp.drive(b / dsp.peak(b) * 1.3, 1.4)  # rounds the cajon thumps: more groove under the same peak
    b = loop_eq(s, b, "highshelf", 4500, 2.0)
    return room(s, b, 0.14, 0.8, "perc", damp=6000)


# What the fingers hold on the D, G and B strings (the thumb has the root): guitar shapes, not computed voicings.
# The top note stays on F#4 through most of the loop while the inner voices step (A-A-G-G, C#-D-D-C#).
BEACH_GRIPS = {
    "Dmaj7": [57, 61, 66], "Bm7": [57, 62, 66], "Em9": [55, 62, 66], "A13": [55, 61, 66],
    "Gmaj9": [59, 66, 69], "F#m7": [57, 61, 64], "D6": [57, 62, 66, 71], "A9sus4": [55, 59, 62, 64],
}

# The e-piano an octave above them: 3rd, 5th or 7th and one colour, without the root.
BEACH_KEYS = {
    "Dmaj7": [66, 69, 73], "Bm7": [66, 69, 74], "Em9": [67, 71, 78], "A13": [67, 73, 78],
    "Gmaj9": [71, 74, 78], "F#m7": [69, 73, 76], "D6": [66, 71, 74], "A9sus4": [67, 71, 74],
}


def beach_guitar(s):
    """Nylon guitar the Joao Gilberto way: the thumb keeps root and fifth on beats 1 and 3, the fingers pluck
    rootless 7th/9th chords on a syncopated two-bar figure, and the last 8th of every bar already plays the
    chord of the next bar (the bossa anticipation)."""
    b = s.zeros()
    r = dsp.rng(s.id, "guitar")
    vo = [BEACH_GRIPS[c.name] for c in s.chords]
    pats = (((0.0, 0.9, 0.8), (1.5, 0.4, 0.6), (2.5, 0.4, 0.64), (3.5, 1.2, 0.72)),
            ((1.0, 0.4, 0.62), (2.5, 0.9, 0.72), (3.5, 0.45, 0.66)))
    for bar in range(s.bars):
        o = bar * 4
        for bt, du, v in pats[bar % 2]:
            c = s.chord_at(o + bt + (0.5 if bt == 3.5 else 0.0))
            x = ins.strum(vo[s.chords.index(c)], s.sec(du), s.sr, spread=0.007, bright=0.32, t60=1.3, pick=0.2,
                          mute=0.09, key=bar % 2, attack=0.003)
            s.add(b, x, o + bt, v, dt=0.007 + r.normal(0, 0.002))  # the fingers answer the thumb a hair late
        c0, c2 = s.chord_at(o), s.chord_at(o + 2)
        R = nearest(c0.root, 47, 40, 52)
        second = nearest(c2.root, 47, 40, 52) if c2 is not c0 else (R + 7 if R + 7 <= 54 else R - 5)
        for bt, m, v in ((0, R, 0.75), (2, second, 0.62)):
            x = ins.guitar(m, s.sec(1.5), s.sr, bright=0.22, t60=1.6, pick=0.25, mute=0.12, key=5, attack=0.004)
            s.add(b, x, o + bt, v, dt=r.normal(0, 0.001))
    b = loop_filter(s, b, "hp", 95)
    b = loop_eq(s, b, "peak", 2300, 2.5, 0.9)
    return room(s, b, 0.16, 1.0, "guitar", damp=5000)


def beach_bass_line(s):
    """Root on 1, a soft pickup on the and of 2, the fifth on 3 and the next bar's root pushed on the and of 4."""
    ev = []
    root = lambda c: nearest(c.root, 40, 35, 46)  # noqa: E731
    for bar in range(s.bars):
        o = bar * 4
        c0, c2, nx = s.chord_at(o), s.chord_at(o + 2), s.chord_at(o + 4)
        R = root(c0)
        F = R + 7 if R + 7 <= 47 else R - 5
        mid = root(c2) if c2 is not c0 else F
        ev += [(o, 1.35, R, 0.9), (o + 1.5, 0.42, R if c2 is c0 else mid, 0.55), (o + 2, 1.35, mid, 0.82),
               (o + 3.5, 0.45, root(nx), 0.62)]
    return ev


def beach_bass(s):
    b = s.zeros()
    r = dsp.rng(s.id, "bass")
    for j, (bt, du, m, v) in enumerate(beach_bass_line(s)):
        s.add(b, upright(m, s.sec(du), s.sr, key=j % 3), bt, v, dt=r.normal(0.003, 0.003))
    b = loop_filter(s, b, "lp", 1300)
    return room(s, b, 0.07, 0.7, "bass", damp=2500)


def beach_shaker(s):
    """Shaker 16ths leaning on the off-beat 8ths, maracas on beats 2 and 4 and a little shake into bars 5 and 1."""
    k = kit("beach", s.sr)
    r = dsp.rng(s.id, "shaker")
    b = s.zeros()
    for bar in range(s.bars):
        o = bar * 4
        for i in range(16):
            v = 0.9 if i % 4 == 2 else (0.5 if i % 4 == 0 else 0.3)
            hit(s, b, k["shaker"], o + i * 0.25, v, r, 0.004)
        for bt in (1, 3):
            hit(s, b, k["maraca"], o + bt, 0.75, r, 0.004)
        if bar in (3, 7):
            for bt, v in ((3.5, 0.6), (3.75, 0.8)):
                hit(s, b, k["maraca"], o + bt, v, r, 0.003)
    return room(s, b, 0.1, 0.8, "shaker", damp=7000)


BEACH_FILLS = {  # e-piano answers in the two bars where the flute breathes: bar -> (beat, beats, midi)
    3: [(2.0, 0.5, 78), (2.5, 0.5, 76), (3.0, 0.5, 73), (3.5, 0.5, 71)],
    7: [(2.0, 0.5, 83), (2.5, 0.5, 81), (3.0, 0.5, 79), (3.5, 0.5, 76)],
}


def beach_keys(s):
    """Soft electric piano: a held chord on every change, a light answer on beat 4 (where the guitar rests) and
    a falling fill at the end of each four-bar phrase; slow tremolo."""
    b = s.zeros()
    r = dsp.rng(s.id, "keys")
    for c in s.chords:
        v = BEACH_KEYS[c.name]
        bar = int(c.start // 4)
        hits = [(0.0, c.dur * 0.6, 0.55)]
        if c.dur == 4 and bar not in BEACH_FILLS:
            hits.append((3.0, 0.9, 0.42))
        for bt, du, vel in hits:
            for j, m in enumerate(v):
                x = ins.epiano(m, round(s.sec(du), 4), s.sr, vel=vel, bright=0.7, release=0.3)
                s.add(b, x, c.start + bt, 0.8, dt=0.006 + j * 0.009 + r.normal(0, 0.003))
    for bar, notes in BEACH_FILLS.items():
        for i, (bt, du, m) in enumerate(notes):
            x = ins.epiano(m, round(s.sec(du * 1.6), 4), s.sr, vel=0.6, bright=0.8, release=0.3)
            s.add(b, x, bar * 4 + bt, 0.75 + 0.05 * i, dt=r.normal(0.004, 0.003))
    b = b * (1.0 - 0.16 * (0.5 + 0.5 * s.lfo(4.6)))
    b = loop_filter(s, b, "hp", 150)
    b = loop_filter(s, b, "lp", 6000)
    return room(s, b, 0.22, 1.5, "keys", damp=5000)


BEACH_FLUTE = bars({  # two four-bar phrases; long notes are pushed an 8th early and tied over the bar line
    0: [(0.5, 0.5, 74), (1.0, 0.5, 78), (1.5, 1.0, 81), (2.5, 0.5, 78), (3.0, 0.5, 76), (3.5, 1.5, 78)],
    1: [(1.5, 0.5, 76), (2.0, 0.5, 78), (2.5, 1.5, 74)],
    2: [(0.5, 0.5, 71), (1.0, 0.5, 74), (1.5, 1.0, 79), (2.5, 0.5, 78), (3.0, 0.5, 76), (3.5, 1.0, 78)],
    3: [(1.0, 1.0, 76)],
    4: [(0.5, 0.5, 78), (1.0, 0.5, 79), (1.5, 1.0, 83), (2.5, 0.5, 81), (3.0, 0.5, 79), (3.5, 1.5, 81)],
    5: [(1.5, 0.5, 78), (2.0, 0.5, 81), (2.5, 1.5, 83)],
    6: [(0.5, 0.5, 83), (1.0, 0.5, 81), (1.5, 1.0, 79), (2.5, 0.5, 78), (3.0, 0.5, 76), (3.5, 2.5, 74)],
})


def beach_flute(s):
    """Breathy flute: a sine with a little 2nd and 3rd harmonic, air noise that follows the note and a chiff on
    every attack. The tune climbs to B5 in the second phrase and comes home to D over the last bar."""
    src, env, onset = render_line(s, events(s, BEACH_FLUTE), osc="sine", glide=0.018, legato_gap=0.01, attack=0.045,
                                  release=0.08, vib_rate=5.1, vib_depth=0.11, vib_delay=0.28, key="bflute")
    tone = src + 0.2 * (2.0 * src ** 2 - 1.0) + 0.07 * (4.0 * src ** 3 - 3.0 * src)
    air = ins.breath(len(src), s.sr, "bflute", 1800, 6500)
    x = tone * env + 0.24 * air * env + 0.3 * air * onset * np.clip(env * 4.0, 0, 1)
    x = dsp.highpass(x, 250, s.sr, 2)
    b = wrap(s, x / dsp.peak(x))
    b = echo(s, b, 0.75, 0.14, 0.35, 2, 4000)
    return room(s, b, 0.25, 1.5, "flute", damp=5000)


# ==================================================== CARNIVAL (C major)

def carnival_song(d):
    # salsa / son montuno in C on a grid of 8ths: the guajeo I-IV-V-IV with two chords a bar, then vi-ii-V-I and
    # IV-ii-V-I. Triads and one dominant 7th, all diatonic. The last half bar is the tonic: the trumpet lands on C
    # there and the bass has already played the C of bar 1 on beat 4 (the anticipated tumbao)
    C, D, F, G, A = 0, 2, 5, 7, 9
    maj, mnr, dom7, m7 = [0, 4, 7], [0, 3, 7], [0, 4, 7, 10], [0, 3, 7, 10]
    return Song(d, progression([
        (2, C, maj, "C"), (2, F, maj, "F"), (2, G, dom7, "G7"), (2, F, maj, "F"),
        (2, C, maj, "C"), (2, F, maj, "F"), (4, G, dom7, "G7"),
        (2, A, mnr, "Am"), (2, D, m7, "Dm7"), (2, G, dom7, "G7"), (2, C, maj, "C"),
        (2, F, maj, "F"), (2, D, m7, "Dm7"), (2, G, dom7, "G7"), (2, C, maj, "C"),
    ]))


# The 2-3 son clave over two bars (beats): two strokes in the first bar, three in the second. Every stem of the
# district is written against it: the low drum of the congas, the piano montuno and the phrases of the trumpet.
CARNIVAL_CLAVE = ((1.0, 2.0), (0.0, 1.5, 3.0))


def carnival_congas(s):
    """Conga tumbao (heel-toe-slap-toe, two open tones on beat 4; the low drum answers on beat 3 of the three-side
    bars), the 2-3 son clave on a pair of claves and a soft kick on beats 1 and 3. The first layer: it grooves
    alone."""
    k = kit("carnival", s.sr)
    r = dsp.rng(s.id, "congas")
    b = s.zeros()
    for bar in range(s.bars):
        o = bar * 4
        three = bar % 2 == 1
        for bt, v in ((0, 0.8), (2, 0.5)):
            hit(s, b, k["kick"], o + bt, v, r, 0.002)
        for bt in CARNIVAL_CLAVE[bar % 2]:
            hit(s, b, k["clave"], o + bt, 0.5, r, 0.002)
        tumbao = [(0.0, "heel", 0.34), (0.5, "toe", 0.26), (1.0, "slap", 0.8), (1.5, "toe", 0.26),
                  (2.0, "tumba", 0.85) if three else (2.0, "heel", 0.34),
                  (2.5, "tumba", 0.7) if three else (2.5, "toe", 0.26),
                  (3.0, "open", 0.95), (3.5, "open", 0.8)]
        if bar == 3:  # a quick extra tone at the end of the first phrase
            tumbao.append((3.25, "open", 0.5))
        if bar == s.bars - 1:  # and a roll down the two drums into the repeat
            tumbao = tumbao[:7] + [(3.25, "open", 0.6), (3.5, "tumba", 0.85), (3.75, "tumba", 0.7)]
        for bt, name, v in tumbao:
            hit(s, b, k[name], o + bt, v, r, 0.004)
    b = dsp.drive(b / dsp.peak(b) * 1.2, 1.3)
    b = loop_eq(s, b, "highshelf", 4000, 2.0)
    return room(s, b, 0.12, 0.7, "congas", damp=6000)


def carnival_shaker(s):
    """Maracas on the 8ths (the beats a little stronger, a grace note before each beat) and the guiro: a long
    scrape on beats 1 and 3, two short ones on 2 and 4 (the 'scraaape - chi - chi' of the cha-cha and the son)."""
    k = kit("carnival", s.sr)
    r = dsp.rng(s.id, "shaker")
    b = s.zeros()
    for bar in range(s.bars):
        o = bar * 4
        for i in range(8):
            hit(s, b, k["maraca"], o + i * 0.5, 0.8 if i % 2 == 0 else 0.52, r, 0.004)
            if i % 2 == 1:
                hit(s, b, k["maraca"], o + i * 0.5 + 0.25, 0.22, r, 0.004)
        for half in (0, 2):
            hit(s, b, k["guiro"], o + half, 0.6, r, 0.004)
            hit(s, b, k["guiro_short"], o + half + 1.0, 0.5, r, 0.004)
            hit(s, b, k["guiro_short"], o + half + 1.5, 0.42, r, 0.004)
    return room(s, b, 0.1, 0.8, "shaker", damp=7000)


def carnival_bass_line(s):
    """The salsa tumbao: nothing on beat 1. The 'and of 2' plays the root of the chord that starts on beat 3 (the
    fifth when the chord stays) and beat 4 already plays the root of the next bar, tied over the bar line."""
    ev = []
    root = lambda c: nearest(c.root, 41, 36, 47)  # noqa: E731
    fifth = lambda m: m + 7 if m + 7 <= 48 else m - 5  # noqa: E731
    for bar in range(s.bars):
        o = bar * 4
        c0, c2, nx = s.chord_at(o), s.chord_at(o + 2), s.chord_at(o + 4)
        mid = root(c2) if c2 is not c0 else fifth(root(c0))
        if root(nx) == mid:  # the same root twice (the tonic of the last bar): fifth, then root
            mid = fifth(mid)
        if c2 is c0:  # a whole bar on one chord (the G7 that ends the first phrase): its root on the and of 3
            ev += [(o + 1.5, 0.9, mid, 0.85), (o + 2.5, 0.45, root(c0), 0.65)]
        else:
            ev.append((o + 1.5, 1.4, mid, 0.85))
        ev.append((o + 3.0, 2.4, root(nx), 0.95))
    return ev


def carnival_bass(s):
    b = s.zeros()
    r = dsp.rng(s.id, "bass")
    for j, (bt, du, m, v) in enumerate(carnival_bass_line(s)):
        s.add(b, baby_bass(m, s.sec(du), s.sr, key=j % 3), bt, v, dt=r.normal(0.002, 0.003))
    b = loop_filter(s, b, "lp", 1500)
    return room(s, b, 0.06, 0.6, "bass", damp=2500)


# The right hand of the montuno: the note it plays in octaves (a line that moves by step: E F G F ...) and the
# dyad it plays inside that octave. The left hand doubles an octave below: octaves, and tenths under the dyads.
CARNIVAL_MONTUNO = {
    "C": (64, (67, 72)), "F": (65, (69, 72)), "G7": (67, (71, 74)), "Am": (64, (69, 72)), "Dm7": (65, (69, 72)),
}


def carnival_piano(s):
    """Piano montuno in 2-3: the bar of the two-side starts on the beat (1, 2, the and of 2, of 3, of 4), the bar
    of the three-side plays only off-beats. Octaves and inner dyads alternate; the octaves on the and of 2 and
    of 4 already belong to the next chord, like the bass."""
    b = s.zeros()
    r = dsp.rng(s.id, "piano")
    pats = (((0.0, "o"), (1.0, "i"), (1.5, "o"), (2.5, "i"), (3.5, "o")),
            ((0.5, "i"), (1.5, "o"), (2.5, "i"), (3.5, "o")))
    for bar in range(s.bars):
        o = bar * 4
        for bt, kind in pats[bar % 2]:
            c = s.chord_at(o + bt + (0.5 if bt in (1.5, 3.5) else 0.0))
            octave, dyad = CARNIVAL_MONTUNO[c.name]
            if kind == "o":
                notes, du, vel = ((octave - 12, 0.55), (octave, 0.85), (octave + 12, 1.0)), 0.9, 0.8
            else:
                notes, du, vel = ((dyad[0] - 12, 0.5), (dyad[0], 0.9), (dyad[1], 1.0)), 0.45, 0.6
            dt = r.normal(0.003, 0.003)
            for j, (m, g) in enumerate(notes):
                x = ins.piano(m, round(s.sec(du), 4), s.sr, vel=vel, bright=1.0, release=0.12, key=j)
                s.add(b, x, o + bt, g, dt=dt + j * 0.003)
    b = loop_filter(s, b, "hp", 180)
    b = loop_eq(s, b, "peak", 2500, 3.0, 0.9)
    return room(s, b, 0.12, 0.9, "piano", damp=5500)


# The top strings of the guitar: small bright shapes (the G7 keeps its 7th, the Dm7 its root)
CARNIVAL_GRIPS = {
    "C": [67, 72, 76], "F": [69, 72, 77], "G7": [67, 71, 74, 77], "Am": [69, 72, 76], "Dm7": [69, 72, 74, 77],
}

# Fills in thirds at the end of both phrases (where the trumpet rests or holds): bar -> (beat, top note, lower note)
CARNIVAL_FILLS = {
    3: [(2.0, 77, 74), (2.5, 76, 72), (3.0, 74, 71), (3.5, 72, 69)],
    7: [(2.0, 79, 76), (2.5, 77, 74), (3.0, 76, 72), (3.5, 72, 67)],
}


def carnival_guitar(s):
    """Bright nylon guitar: short up-strokes on the off-beats, accented down-strokes on beats 2 and 4, a muted
    stroke on 3 (the cumbia 'chk-a'), and a run in thirds down to the next chord at the end of each phrase."""
    b = s.zeros()
    r = dsp.rng(s.id, "guitar")
    pat = ((0.5, "up", 0.55), (1.0, "down", 0.9), (2.0, "mute", 0.4), (2.5, "up", 0.55), (3.0, "down", 0.9),
           (3.5, "up", 0.5))
    for bar in range(s.bars):
        o = bar * 4
        fill = CARNIVAL_FILLS.get(bar)
        for bt, kind, v in pat:
            if fill and bt >= 2.0:
                continue
            notes = CARNIVAL_GRIPS[s.chord_at(o + bt + (0.5 if bt == 3.5 else 0.0)).name]
            if kind == "mute":
                x = ins.strum(notes, 0.02, s.sr, spread=0.004, bright=0.85, t60=0.05, pick=0.1, mute=0.015, key=3,
                              damp=0.3)
            else:
                x = ins.strum(notes, s.sec(0.4 if kind == "down" else 0.22), s.sr, spread=0.008, up=kind == "up",
                              bright=0.65, t60=0.8, pick=0.13, mute=0.04, key=bar % 2, damp=0.4)
            s.add(b, x, o + bt, v, dt=r.normal(0, 0.003))
        for i, (bt, top, low) in enumerate(fill or ()):
            for m, g in ((top, 1.0), (low, 0.7)):
                x = ins.guitar(m, s.sec(0.6), s.sr, bright=0.7, t60=0.9, pick=0.12, mute=0.05, key=4 + i % 2)
                s.add(b, x, o + bt, (0.8 + 0.05 * i) * g, dt=r.normal(0.002, 0.002))
    b = loop_filter(s, b, "hp", 200)
    b = loop_eq(s, b, "peak", 3000, 3.0, 0.9)
    b = dsp.drive(b / dsp.peak(b) * 1.4, 1.4)  # rounds the pick transients: the strums stay loud enough to hear
    return room(s, b, 0.14, 0.9, "guitar", damp=5500)


SHAKE = {"vib": 0.9}  # a lip shake: a wide, fast wobble that grows on a long note
SING = {"vib": 0.1}

# Two four-bar phrases. The long notes arrive an 8th early (on the and of 2 and of 4, with the bass and the piano);
# "fall" lets the note drop away at its end. C5-C6: the tune climbs to C6 in the second phrase and ends its
# 'sol la ti do' on the tonic over the last C chord.
CARNIVAL_TPT = {
    0: [(0.0, 0.5, 76), (0.5, 0.5, 79), (1.5, 1.0, 81), (2.5, 0.5, 79), (3.0, 0.5, 77), (3.5, 1.5, 79, 0.9, SHAKE)],
    1: [(1.5, 0.5, 81), (2.0, 0.5, 79), (2.5, 1.0, 77, 0.8, SING)],
    2: [(0.0, 0.5, 76), (0.5, 0.5, 79), (1.5, 1.0, 81), (2.5, 0.5, 79), (3.0, 0.5, 77),
        (3.5, 1.75, 74, 0.85, SING, "fall")],
    4: [(0.0, 0.5, 84, 0.95), (0.5, 0.5, 83), (1.0, 0.5, 81), (1.5, 1.0, 81), (2.5, 0.5, 77), (3.0, 0.5, 81),
        (3.5, 1.5, 79, 0.9, SHAKE)],
    5: [(1.5, 1.0, 76), (2.5, 0.5, 72), (3.0, 0.5, 74), (3.5, 1.0, 77)],
    6: [(0.5, 0.5, 81), (1.0, 0.5, 84), (1.5, 1.0, 81), (2.5, 0.5, 77), (3.0, 1.0, 74, 0.8, SING)],
    7: [(0.0, 0.5, 79), (0.5, 0.5, 81), (1.0, 0.5, 83), (1.5, 1.75, 84, 0.95, SHAKE, "fall")],
}


def carnival_trumpet(s):
    """Salsa trumpet: a bright saw whose filter opens with the breath, a little scoop into every note, shakes on
    the long notes and a fall (a quieter note glued to the end that slides a fifth down) after the two phrases."""
    ev = []
    for e in bars(CARNIVAL_TPT):
        ev.append(e[:5] if len(e) > 3 else e[:3] + (0.8,))
        if len(e) > 5:
            ev.append((e[0] + e[1] * 0.97, 0.45, e[2] - 7, 0.4,
                       {"bend": -7.0, "bend_t": s.sec(0.4), "vib": 0.0, "scoop": 0.0}))
    src, env, onset = render_line(s, events(s, ev), osc="saw", glide=0.005, legato_gap=0.005, attack=0.016,
                                  release=0.06, vib_rate=6.8, vib_depth=0.0, vib_delay=0.12, scoop=0.25, key="ctpt")
    x = src * env
    x = dsp.sweep_filter(x, 1200.0 + 3600.0 * np.clip(env, 0, 1) + 1200.0 * onset, s.sr, q=0.8)
    x = dsp.highpass(x, 500, s.sr, 2)
    x = dsp.filt(x, "peak", 1500, s.sr, q=1.4, gain_db=7.0)
    x = dsp.filt(x, "peak", 2800, s.sr, q=2.0, gain_db=4.0)
    b = wrap(s, x / dsp.peak(x))
    b = echo(s, b, 0.75, 0.1, 0.3, 2, 3500)
    return room(s, b, 0.2, 1.2, "trumpet", damp=5000)


# ===================================================== CINEMA (Eb major)

def cinema_song(d):
    # a warm adventure score in Eb for a small orchestra: I - IV - vi - V (with a 4-3 suspension), then
    # IV - I - ii7 V - I. Triads, one suspension and one minor 7th, all diatonic; the last bar is the tonic, where
    # the choir comes home to Eb and the timpani roll on the fifth leads back into bar 1
    Eb, F, Ab, Bb, C = 3, 5, 8, 10, 0
    maj, mnr, m7, sus4 = [0, 4, 7], [0, 3, 7], [0, 3, 7, 10], [0, 5, 7]
    return Song(d, progression([
        (4, Eb, maj, "Eb"), (4, Ab, maj, "Ab"), (4, C, mnr, "Cm"), (2, Bb, sus4, "Bbsus4"), (2, Bb, maj, "Bb"),
        (4, Ab, maj, "Ab"), (4, Eb, maj, "Eb"), (2, F, m7, "Fm7"), (2, Bb, maj, "Bb"), (4, Eb, maj, "Eb"),
    ]))


# The two kettledrums are tuned to the tonic and the fifth (Eb2, Bb2) and never retuned: bar -> (beat, midi, vel).
# The Eb drum plays under every chord that holds an Eb, the Bb drum under the dominant; the last bar ends in a
# roll on Bb that swells into the repeat.
CINEMA_TIMP = {
    0: [(0, 39, 1.0), (1.5, 39, 0.45), (2, 46, 0.75), (3, 46, 0.5), (3.5, 46, 0.55)],
    1: [(0, 39, 0.9), (2, 39, 0.6), (3.5, 39, 0.45)],
    2: [(0, 39, 0.7), (2, 39, 0.5)],
    3: [(0, 46, 0.9), (1.5, 46, 0.45), (2, 46, 0.75), (3, 46, 0.55), (3.5, 46, 0.6)],
    4: [(0, 39, 0.9), (2, 39, 0.6), (3.5, 39, 0.45)],
    5: [(0, 39, 0.95), (1.5, 39, 0.45), (2, 46, 0.75), (3.5, 46, 0.5)],
    6: [(2, 46, 0.85), (3, 46, 0.5), (3.5, 46, 0.6)],
    7: [(0, 39, 1.0), (2, 39, 0.6)] + [(3.0 + i * 0.125, 46, 0.22 + 0.06 * i) for i in range(8)],
}


def cinema_third(c):
    """The interval that names the chord above its root: the third, or the fourth of a suspension."""
    return [t for t in c.tones if t in (3, 4, 5)][0]


def cinema_timpani(s):
    """Timpani on the tonic and the fifth (beat 1, an answer on 3, soft pickups; a roll into the repeat) over
    pizzicato strings in 8ths: the cellos pluck root and fifth on beats 1 and 3, the violas fill the 8ths between
    with the rest of the chord. The first layer: pulse and harmony on its own (the strings carry it on a phone,
    where the drums are mostly their stroke)."""
    r = dsp.rng(s.id, "timpani")
    tb, pz = s.zeros(), s.zeros()
    for bar, strokes in CINEMA_TIMP.items():
        for j, (bt, m, v) in enumerate(strokes):
            s.add(tb, timpani(m, s.sr, hard=round(0.3 + 0.7 * v, 1), key=j % 2), bar * 4 + bt, v,
                  dt=r.normal(0.002, 0.002))
    for c in s.chords:
        R = nearest(c.root, 51, 46, 57)
        up = nearest(c.root, 63, 58, 69)
        mid, top = up + cinema_third(c), up + 7
        for q in range(int(c.dur * 2)):
            h = q % 4  # the place in the half bar: cello, viola, viola, viola
            if h == 0:
                m = R if (c.start + q * 0.5) % 4 == 0 or c.dur < 4 else R + 7
                m, v = (m if m <= 58 else m - 12), 0.9
            else:
                m, v = (mid, top, mid)[h - 1], (0.5, 0.62, 0.45)[h - 1]
            s.add(pz, pizz(m, s.sr, key=q % 3), c.start + q * 0.5, v, dt=r.normal(0.003, 0.003))
    b = 0.5 * dsp.drive(tb / dsp.peak(tb) * 1.3, 1.5) + pz / dsp.peak(pz)  # the strokes rounded, not peaky
    b = loop_filter(s, b, "hp", 55)
    return room(s, b, 0.2, 1.5, "timpani", damp=4000, predelay=0.02)


# The counter-melody of the first cello: long notes that move where the choir holds, climb through bars 5-6
# while the tune comes down, and rest on the third (G3) under the last Eb. bar -> (beat, beats, midi)
CINEMA_CELLO = bars({
    0: [(0.0, 2.0, 55), (2.0, 2.0, 58)],
    1: [(0.0, 2.0, 60), (2.0, 0.5, 58), (2.5, 0.5, 56), (3.0, 1.0, 60)],
    2: [(0.0, 2.0, 63), (2.0, 1.0, 60), (3.0, 1.0, 58)],
    3: [(0.0, 2.0, 58), (2.0, 1.0, 53), (3.0, 0.5, 55), (3.5, 0.5, 58)],
    4: [(0.0, 2.0, 60), (2.0, 1.0, 63), (3.0, 1.0, 65)],
    5: [(0.0, 1.5, 67), (1.5, 0.5, 65), (2.0, 2.0, 63)],
    6: [(0.0, 2.0, 60), (2.0, 1.0, 62), (3.0, 1.0, 58)],
    7: [(0.0, 3.0, 55)],
})


def cinema_cello(s):
    """Two cello desks. The second rocks an ostinato in 8ths (root, fifth, octave, fifth; the third on top in the
    second half of the bar); the first sings the counter-melody above it with a slow vibrato."""
    r = dsp.rng(s.id, "cello")
    ost = s.zeros()
    for c in s.chords:
        R = nearest(c.root, 51, 46, 57)
        fig = [R, R + 7, R + 12, R + 7, R + 12 + cinema_third(c), R + 7, R + 12, R + 7]
        for q in range(int(c.dur * 2)):
            x = bowed(fig[q % 8], s.sec(0.48), s.sr, key=q % 2, attack=0.035, release=0.12, vib=0.0, cutoff=1900.0)
            s.add(ost, x, c.start + q * 0.5, 0.9 if q % 4 == 0 else (0.7 if q % 2 == 0 else 0.55),
                  dt=r.normal(0.004, 0.003))
    src, env, onset = render_line(s, events(s, CINEMA_CELLO), osc="saw", detune=6.0, glide=0.03, legato_gap=0.02,
                                  attack=0.07, release=0.12, vib_rate=5.3, vib_depth=0.14, vib_delay=0.3, key="ccello")
    x = dsp.sweep_filter(src * env, 900.0 + 1500.0 * np.clip(env, 0, 1), s.sr, q=0.8)
    mel = wrap(s, x / dsp.peak(x))
    b = mel + 0.5 * ost / dsp.peak(ost)
    b = loop_eq(s, b, "peak", 240, 3.0, 1.0)  # the body of the instrument
    b = loop_eq(s, b, "peak", 600, 2.0, 1.2)
    b = loop_filter(s, loop_filter(s, b, "hp", 60), "lp", 3200)
    return room(s, b, 0.24, 1.7, "cello", damp=4000, predelay=0.02)


def cinema_harp(s):
    """Harp: 16ths that climb through two octaves of the chord in the first half of the bar, touch the top on
    beat 3 and come down again; in the last beat of bars 4 and 8 a glissando up the scale of Eb lands on the
    downbeat of the next phrase."""
    r = dsp.rng(s.id, "harp")
    b = s.zeros()
    scale = [m for m in range(55, 92) if (m - s.tonic) % 12 in (0, 2, 4, 5, 7, 9, 11)]
    gliss = {3 * 4 + 3: 82, 7 * 4 + 3: 87}  # the beat it fills -> the note it lands on
    for c in s.chords:
        R = nearest(c.root, 51, 46, 57)
        ns = [m for m in range(R, R + 44) if (m - c.root) % 12 in [t % 12 for t in c.tones]][:9]
        seq = ns[:8] + [ns[8]] + ns[7:0:-1]
        for i in range(int(c.dur * 4)):
            beat = c.start + i * 0.25
            if int(beat) in gliss:
                continue
            v = 0.95 if i == 8 else (0.8 if i % 4 == 0 else 0.55 + 0.02 * (i % 4))
            s.add(b, harp(seq[i], s.sr, key=i % 2), beat, v, dt=r.normal(0.003, 0.003))
    for beat, top in gliss.items():
        run = [m for m in scale if m <= top][-13:]
        for i, m in enumerate(run[:-1]):
            s.add(b, harp(m, s.sr, key=2, dur=0.6), beat + i / 12.0, 0.3 + 0.035 * i)
        for m, g in ((run[-1], 1.0), (run[-1] - 12, 0.6)):
            s.add(b, harp(m, s.sr, key=3), beat + 1.0, g)
    b = loop_filter(s, b, "hp", 120)
    b = loop_eq(s, b, "highshelf", 4000, 2.5)
    return room(s, b, 0.26, 1.8, "harp", damp=7000, predelay=0.02)


def cinema_drums(s):
    """A soft march: the snare taps a two-bar cadence in 16ths (ghost notes between the taps), the big bass drum
    marks beats 1 and 3, and a roll swells through the second half of bars 4 and 8 into the next phrase."""
    k = kit("cinema", s.sr)
    r = dsp.rng(s.id, "drums")
    b = s.zeros()
    pats = ("x..gx.xgx..gx.xx", "x..gx.xgx.xgxgxx")
    vel = {"x": 0.62, "g": 0.25}
    for bar in range(s.bars):
        o = bar * 4
        roll = bar in (3, 7)
        for i, ch in enumerate(pats[bar % 2]):
            if ch in vel and not (roll and i >= 8):
                hit(s, b, k["snare"], o + i * 0.25, vel[ch] * (1.2 if i % 4 == 0 else 1.0), r, 0.003)
        if roll:  # twelve strokes a beat, the two sticks never quite even
            for i in range(24):
                hit(s, b, k["snare"], o + 2.0 + i / 12.0, 0.16 + 0.024 * i, r, 0.006)
        for bt, v in ((0, 0.7), (2, 0.42)):
            hit(s, b, k["bd"], o + bt, 0.3 if roll and bt == 2 else v, r, 0.002)
        if bar in (0, 4):  # the roll lands on the downbeat
            hit(s, b, k["snare"], o, 0.9, r, 0.002)
    b = dsp.drive(b / dsp.peak(b) * 1.4, 1.5)
    return room(s, b, 0.2, 1.4, "drums", damp=5500, predelay=0.02)


def cinema_brass(s):
    """Three french horns hold the chords in a noble rhythm (a long note, a short one before beat 4, a long one)
    and two trombones lay root and fifth under them, one note a chord."""
    r = dsp.rng(s.id, "brass")
    hb, tb = s.zeros(), s.zeros()
    vo = voice_lead([c.pcs() for c in s.chords], 58, 72, 65)
    for i, (c, v) in enumerate(zip(s.chords, vo)):
        last = i == len(s.chords) - 1
        if c.dur >= 4 and not last:
            rhythm = [(0.0, 2.4, 0.85), (2.5, 0.45, 0.6), (3.0, 0.95, 0.8)]
        else:
            rhythm = [(0.0, 3.4 if last else c.dur - 0.15, 0.85)]
        for bt, du, vel in rhythm:
            for j, m in enumerate(v[-3:]):
                s.add(hb, horn(m, s.sec(du), s.sr, vel=vel, key=j), c.start + bt, 1.0, dt=r.normal(0.006, 0.004))
        R = nearest(c.root, 48, 43, 54)
        for j, m in enumerate((R, R + 7)):
            x = ins.brass(m, round(s.sec(3.4 if last else c.dur - 0.2), 4), s.sr, vel=0.55, bright=0.5,
                          release=0.16, key=j)
            s.add(tb, x, c.start, 1.0 if j == 0 else 0.7, dt=r.normal(0.008, 0.004))
    b = hb / dsp.peak(hb) + 0.55 * tb / dsp.peak(tb)
    b = loop_filter(s, b, "lp", 3600)
    return room(s, b, 0.3, 1.9, "brass", damp=4500, predelay=0.025)


# The main theme, sung on "ah": a rising fourth and a third up to G5, a 4-3 suspension over the dominant at the
# end of the first phrase, the top (Ab5) in bar 5, and 're - do' home to Eb5 over the last bar. Bb4-Ab5, all in
# the scale. bar -> (beat, beats, midi)
CINEMA_THEME = bars({
    0: [(0.0, 1.5, 70), (1.5, 0.5, 75), (2.0, 1.5, 79), (3.5, 0.5, 77)],
    1: [(0.0, 2.0, 75), (2.0, 1.0, 72), (3.0, 1.0, 75)],
    2: [(0.0, 1.5, 79), (1.5, 0.5, 75), (2.0, 1.0, 72), (3.0, 1.0, 74)],
    3: [(0.0, 2.0, 75), (2.0, 1.0, 74), (3.0, 1.0, 70)],
    4: [(0.0, 1.5, 72), (1.5, 0.5, 75), (2.0, 1.5, 80), (3.5, 0.5, 79)],
    5: [(0.0, 2.0, 79), (2.0, 1.0, 75), (3.0, 1.0, 79)],
    6: [(0.0, 1.5, 80), (1.5, 0.5, 77), (2.0, 1.0, 77), (3.0, 1.0, 74)],
    7: [(0.0, 3.0, 75)],
})


def choir_ah(midi, dur, sr, key=0):
    """One sung "ah" of a choir section (choir_src through the vowel, with some of its own low end for the body).
    Every note is brought to the same level after the vowel: a tune must not swell on the notes that happen to
    sit on a formant (G5 is right on the 800 Hz of this "ah")."""
    def mk():
        src = choir_src(midi, dur, sr, key=key, attack=0.11, release=0.3)
        rms = lambda z: float(np.sqrt(np.mean(z ** 2)))  # noqa: E731
        y = dsp.formant(src, sr, dsp.VOWELS["a_sop"])
        low = dsp.lowpass(src, 1500, sr, 2)
        return 0.8 * y / rms(y) + 0.3 * low / rms(low)
    return cached(("choir_ah", midi, round(dur, 3), sr, key), mk)


def cinema_choir(s):
    """Wordless choir: sopranos sing the theme, tenors double it an octave lower, and from bar 5 the altos add
    the chord note under the tune. Unlike the stadium choir, which holds chords, this one carries the melody."""
    b = s.zeros()
    for bt, du, m in CINEMA_THEME:
        voices = [(m, 1.0, 0), (m - 12, 0.6, 1)]
        if bt >= 16:
            pcs = set(s.chord_at(bt).pcs())
            voices.append((max(x for x in range(m - 9, m - 2) if x % 12 in pcs), 0.5, 2))
        for mm, g, key in voices:
            s.add(b, choir_ah(mm, s.sec(du) + 0.04, s.sr, key=key), bt, g, dt=0.01 * key)
    b = loop_filter(s, b, "hp", 150)
    return room(s, b, 0.4, 2.4, "choir", damp=5000, predelay=0.03)


# ====================================================== BAZAAR (G major)

def bazaar_song(d):
    # a sunny bazaar tune in G on the maqsum rhythm. The scale is the plain major scale of G (the maqam Ajam):
    # the eastern colour is in the rhythm, the instruments, the ornaments and the way the tune moves -- by step,
    # in sequences, leaning on the two half steps (B-C and F#-G) that a pentatonic tune never touches -- not in
    # notes outside the key, so the match notes (G major pentatonic) stay consonant. Two bars of G over the
    # drone, IV - V, then the falling line vi - V - IV - iii (E, D, C, B in the bass, two chords a bar) and
    # IV - V - I home. Triads only, all diatonic; the last bar is the tonic. (IV and not ii before the dominant:
    # with A minor there the loop holds more A than C and reads as D major.)
    G, B, C, D, E = 7, 11, 0, 2, 4
    maj, mnr = [0, 4, 7], [0, 3, 7]
    return Song(d, progression([
        (4, G, maj, "G"), (4, G, maj, "G"), (4, C, maj, "C"), (4, D, maj, "D"),
        (2, E, mnr, "Em"), (2, D, maj, "D"), (2, C, maj, "C"), (2, B, mnr, "Bm"),
        (2, C, maj, "C"), (2, D, maj, "D"), (4, G, maj, "G"),
    ]))


BAZAAR_SCALE = (7, 9, 11, 0, 2, 4, 6)

# Maqsum, the walking rhythm of the bazaar (dum tek - tek dum - tek -), in 16ths with the left hand filling:
# D dum, T tek, k ka, S slap. Two bars alternate; bars 4 and 8 end in a roll.
BAZAAR_MAQSUM = ("D.T.k.T.D.k.T.kk", "D.T.kkT.D.k.T.Tk")
BAZAAR_FILLS = {3: "D.T.k.T.D.k.TkTS", 7: "D.T.kkT.D.S.TkTk"}


def bazaar_darbuka(s):
    """Darbuka (maqsum with ka fills, a roll into every fourth bar), a frame drum under the dums, finger cymbals
    on beats 2 and 4 (a little gallop every second bar) and a quiet drone on the tonic (on the fifth under the
    dominant), so that the first layer already says where home is."""
    k = kit("bazaar", s.sr)
    r = dsp.rng(s.id, "darbuka")
    b = s.zeros()
    strokes = {"D": ("dum", 1.0), "T": ("tek", 0.72), "k": ("ka", 0.38), "S": ("slap", 0.8)}
    for bar in range(s.bars):
        o = bar * 4
        for i, ch in enumerate(BAZAAR_FILLS.get(bar, BAZAAR_MAQSUM[bar % 2])):
            if ch in strokes:
                name, v = strokes[ch]
                hit(s, b, k[name], o + i * 0.25, v, r, 0.003)
        for bt, v in ((0, 0.8), (2, 0.5), (3.5, 0.3)):
            hit(s, b, k["frame"], o + bt, v, r, 0.003)
        zills = ((1, 0.5), (3, 0.6)) if bar % 2 == 0 else ((1, 0.5), (3, 0.6), (3.25, 0.35), (3.5, 0.5))
        for bt, v in zills:
            hit(s, b, k["zill"], o + bt, 0.5 * v, r, 0.002)
    b = dsp.drive(b / dsp.peak(b) * 1.3, 1.4)
    b = room(s, b, 0.14, 0.8, "darbuka", damp=6000)
    # the drone: G3 under every chord that holds a G (with a soft D3 under the tonic: the open fifth), D3 under
    # D and B minor
    dr = s.zeros()
    for c in s.chords:
        for m, g in {"G": ((55, 1.0), (50, 0.4)), "Em": ((55, 1.0),), "C": ((55, 1.0),)}.get(c.name, ((50, 0.9),)):
            s.add(dr, pad_note(m, s.sec(c.dur) - 0.1, s.sr, cutoff=1100.0, attack=0.3, release=0.5, det=5.0, key=12),
                  c.start, g)
    dr = loop_filter(s, dr, "hp", 110)
    rms = lambda z: float(np.sqrt(np.mean(z ** 2)))  # noqa: E731
    return b + 0.3 * dr * rms(b) / rms(dr)


def bazaar_below(m):
    """The note of the scale of G under m."""
    m -= 1
    while m % 12 not in BAZAAR_SCALE:
        m -= 1
    return m


def bazaar_oud(s):
    """Oud riff on the accents of the drum: root on the dum, fifth and octave on the teks with a quick lower
    neighbour (G F# G), root again on the second dum and the third on top before the bar turns. In the second
    half of bars 4 and 8 the quill trembles on two notes of the chord instead (the tremolo fill)."""
    r = dsp.rng(s.id, "oud")
    b = s.zeros()
    trem = {3: ((2.0, 57), (3.0, 54)), 7: ((2.0, 59), (3.0, 55))}  # bar -> (beat, the note that trembles)
    for c in s.chords:
        bar = int(c.start // 4)
        R = nearest(c.root, 55, 50, 61)
        F, O, T = R + 7, R + 12, R + 12 + c.tones[1]
        fig = [(0.0, R, 0.95), (0.5, F, 0.6), (1.0, O, 0.8), (1.25, bazaar_below(O), 0.5), (1.5, O, 0.7),
               (2.0, R, 0.85), (2.5, F, 0.6), (3.0, T, 0.75), (3.5, O, 0.6)]
        for bt, m, v in fig:
            if bt >= c.dur or (bar in trem and bt >= 2.0):
                continue
            s.add(b, oud(m, s.sec(0.45 if bt in (1.0, 1.25) else 0.7), s.sr, key=int(bt * 4) % 3), c.start + bt, v,
                  dt=r.normal(0.003, 0.003))
    for bar, notes in trem.items():
        for bt, m in notes:
            for i in range(8):  # eight strokes a beat, down and up, swelling
                s.add(b, oud(m, s.sec(0.2), s.sr, key=i % 2), bar * 4 + bt + i / 8.0,
                      (0.45 + 0.05 * i) * (1.0 if i % 2 == 0 else 0.8), dt=r.normal(0.002, 0.002))
    b = loop_filter(s, b, "hp", 100)
    return room(s, b, 0.14, 0.9, "oud", damp=5000)


def bazaar_bass(s):
    """A round bass that walks with the drum: the root on the first dum, the fifth on the second, a short root
    on beat 4 (in the bars of two chords: one root on each dum)."""
    r = dsp.rng(s.id, "bass")
    b = s.zeros()
    root = lambda c: nearest(c.root, 43, 38, 49)  # noqa: E731
    for bar in range(s.bars):
        o = bar * 4
        c0, c2 = s.chord_at(o), s.chord_at(o + 2)
        R = root(c0)
        F = R + 7 if R + 7 <= 50 else R - 5
        if c2 is c0:
            ev = [(0, 1.5, R, 0.9), (2, 0.9, F, 0.8), (3, 0.6, R, 0.65)]
        else:
            ev = [(0, 1.6, R, 0.9), (2, 1.6, root(c2), 0.85)]
        if bar == s.bars - 1:
            ev = [(0, 1.5, R, 0.9), (2, 0.9, R, 0.75), (3, 0.6, F, 0.7)]  # the fifth last: it falls into bar 1
        for j, (bt, du, m, v) in enumerate(ev):
            s.add(b, baby_bass(m, s.sec(du), s.sr, key=j % 3), o + bt, v, dt=r.normal(0.003, 0.002))
    b = loop_filter(s, b, "lp", 1200)
    return room(s, b, 0.06, 0.7, "bass", damp=2500)


def bazaar_qanun(s):
    """Qanun: 16ths that run up two octaves of the chord and down again (the first note of every beat doubled an
    octave lower), and in the second half of bars 2 and 6 a tremolo on one high string that swells and fades."""
    r = dsp.rng(s.id, "qanun")
    b = s.zeros()
    for beat in range(s.beats):
        bar, ib = divmod(beat, 4)
        c = s.chord_at(beat)
        pcs = set(c.pcs())
        tones = [m for m in range(67, 92) if m % 12 in pcs]
        if bar in (1, 5) and ib >= 2:
            m = min(tones, key=lambda x: abs(x - 84))
            for i in range(8):
                p = ((ib - 2) * 8 + i) / 16.0  # 0..1 through the two beats
                v = 0.3 + 0.55 * np.sin(np.pi * p) ** 0.8
                s.add(b, qanun(m, s.sr, key=i % 2, dur=0.3), beat + i / 8.0, v * (1.0 if i % 2 == 0 else 0.85),
                      dt=r.normal(0.002, 0.002))
            continue
        for i in range(4):
            q = ib * 4 + i
            p = q if q < 8 else 15 - q
            m = tones[min(p, len(tones) - 1)]
            v = 0.85 if i == 0 else 0.5 + 0.04 * i
            s.add(b, qanun(m, s.sr, key=q % 2), beat + i * 0.25, v, dt=r.normal(0.003, 0.003))
            if i == 0:
                s.add(b, qanun(m - 12, s.sr, key=2), beat, 0.45, dt=0.012)
    b = loop_filter(s, b, "hp", 250)
    b = loop_eq(s, b, "highshelf", 3500, 2.0)
    return room(s, b, 0.22, 1.4, "qanun", damp=7000, predelay=0.02)


# The tune of the ney, D5-D6, all in the scale of G. Two bars call (and leave room for the strings to answer),
# bars 5-6 are the heart of it: a figure of three notes that steps down four times (B D C / A C B / G B A /
# F# A G) over the falling bass, and 'A G E - F# A F# - G' brings it home. Ornaments: a slide into a long note
# (bend, from the scale step below), mordents (note, upper neighbour, note) and short grace notes.
# bar -> (beat, beats, midi[, vel, opts])
BAZAAR_SLIDE = {"bend": 2.0, "bend_t": 0.14}
BAZAAR_NEY = bars({
    0: [(0.0, 0.5, 74), (0.5, 0.5, 79), (1.0, 0.5, 81), (1.5, 1.0, 83, 0.85, BAZAAR_SLIDE), (2.5, 0.5, 81),
        (3.0, 1.0, 79)],
    1: [(0.0, 0.125, 83), (0.125, 0.125, 84), (0.25, 1.75, 83, 0.85)],
    2: [(0.0, 1.0, 84), (1.0, 0.5, 86), (1.5, 0.5, 84), (2.0, 1.0, 83), (3.0, 0.5, 81), (3.5, 0.5, 79)],
    3: [(0.0, 2.0, 78, 0.85, BAZAAR_SLIDE), (3.875, 0.125, 84, 0.6)],
    4: [(0.0, 1.0, 83), (1.0, 0.5, 86), (1.5, 0.375, 84), (1.875, 0.125, 83, 0.6), (2.0, 1.0, 81), (3.0, 0.5, 84),
        (3.5, 0.5, 83)],
    5: [(0.0, 1.0, 79), (1.0, 0.5, 83), (1.5, 0.375, 81), (1.875, 0.125, 79, 0.6), (2.0, 1.0, 78), (3.0, 0.5, 81),
        (3.5, 0.5, 79)],
    6: [(0.0, 1.0, 81), (1.0, 0.5, 79), (1.5, 0.5, 76), (2.0, 0.125, 78), (2.125, 0.125, 79), (2.25, 0.75, 78),
        (3.0, 0.5, 81), (3.5, 0.5, 78)],
    7: [(0.0, 2.5, 79, 0.85, {"bend": 1.0, "bend_t": 0.12})],
})


def ney_line(s, evs, key="ney"):
    """Ney, the reed flute, on a tune [(beat, beats, midi[, vel, opts])]: a hollow tone (the third harmonic
    stronger than the second), a lot of breath that follows the note, a puff on every attack and a small scoop
    of pitch into it. Unlike the clean flute of the beach, this one is husky and bends. Returns the loop."""
    src, env, onset = render_line(s, events(s, evs), osc="sine", glide=0.028, legato_gap=0.012, attack=0.05,
                                  release=0.09, vib_rate=5.6, vib_depth=0.16, vib_delay=0.22, scoop=0.25, key=key)
    tone = src + 0.1 * (2.0 * src ** 2 - 1.0) + 0.22 * (4.0 * src ** 3 - 3.0 * src)
    air = ins.breath(len(src), s.sr, key, 1200, 5200)
    air = air / float(np.sqrt(np.mean(air ** 2))) * 0.35
    x = tone * env + 0.5 * air * env + 0.6 * air * onset * np.clip(env * 4.0, 0, 1)
    x = dsp.highpass(x, 250, s.sr, 2)
    return wrap(s, x / dsp.peak(x))


def bazaar_flute(s):
    """The ney plays the tune; its ornaments are written in BAZAAR_NEY."""
    b = ney_line(s, BAZAAR_NEY)
    b = echo(s, b, 0.75, 0.12, 0.3, 2, 3500)
    return room(s, b, 0.26, 1.6, "ney", damp=5000, predelay=0.02)


# The string section of the band, all in unison (in octaves): it answers the ney where it holds its breath (a
# run up into bar 3, 'A C B A' into bar 5, 'B A G' at the very end) and plays the falling figure and the way
# home together with it. bar -> (beat, beats, midi)
BAZAAR_STRINGS = bars({
    1: [(2.0, 0.5, 74), (2.5, 0.5, 76), (3.0, 0.5, 78), (3.5, 0.5, 79)],
    3: [(2.0, 0.5, 81), (2.5, 0.5, 84), (3.0, 0.5, 83), (3.5, 0.5, 81)],
    4: [(0.0, 1.0, 83), (1.0, 0.5, 86), (1.5, 0.5, 84), (2.0, 1.0, 81), (3.0, 0.5, 84), (3.5, 0.5, 83)],
    5: [(0.0, 1.0, 79), (1.0, 0.5, 83), (1.5, 0.5, 81), (2.0, 1.0, 78), (3.0, 0.5, 81), (3.5, 0.5, 79)],
    6: [(0.0, 1.0, 81), (1.0, 0.5, 79), (1.5, 0.5, 76), (2.0, 1.0, 78), (3.0, 0.5, 81), (3.5, 0.5, 78)],
    7: [(0.0, 1.0, 79), (2.0, 0.5, 83), (2.5, 0.5, 81), (3.0, 1.0, 79)],
})


def unison_strings(s, evs, key="b"):
    """Violins and, an octave lower, violas and cellos on one line [(beat, beats, midi[, vel])]: no chords, every
    player on the tune, sliding from note to note (the sound of an eastern film orchestra). Returns the loop."""
    b = s.zeros()
    for shift, gain, name in ((0, 0.8, "vn"), (-12, 1.0, "vc")):
        ev = [(e[0], e[1], e[2] + shift) + tuple(e[3:4]) for e in evs]
        src, env, _ = render_line(s, events(s, ev), osc="saw", detune=9.0, glide=0.045, legato_gap=0.03, attack=0.06,
                                  release=0.14, vib_rate=5.7, vib_depth=0.18, vib_delay=0.2, key=key + name)
        x = dsp.sweep_filter(src * env, 1100.0 + 2300.0 * np.clip(env, 0, 1), s.sr, q=0.8)
        b += gain * wrap(s, x / dsp.peak(x))
    b = loop_eq(s, b, "peak", 500, 2.0, 1.0)
    return loop_filter(s, loop_filter(s, b, "hp", 180), "lp", 4200)


def bazaar_strings(s):
    """The string section answers the ney and doubles it (BAZAAR_STRINGS)."""
    b = unison_strings(s, BAZAAR_STRINGS)
    return room(s, b, 0.3, 1.8, "strings", damp=4500, predelay=0.025)


# ====================================================== SKY CLUB (Ab major)

def skyclub_song(d):
    # uplifting house in Ab, 126 BPM: I - V - vi - IV, then I - V - IV V - I. Every phrase starts from the tonic
    # and the loop ends on it (the pop anthem of the stadium starts on IV and only reaches its tonic at the end;
    # the songs of the genre "edm" all start on vi). Fm7 and Dbmaj7 both hold the Ab and C of the tonic triad:
    # home is never far, the colour stays bright. All tones diatonic.
    Ab, Eb, F, Db = 8, 3, 5, 1
    add9, maj, m7, maj7 = [0, 4, 7, 14], [0, 4, 7], [0, 3, 7, 10], [0, 4, 7, 11]
    return Song(d, progression([
        (4, Ab, add9, "Abadd9"), (4, Eb, maj, "Eb"), (4, F, m7, "Fm7"), (4, Db, maj7, "Dbmaj7"),
        (4, Ab, add9, "Abadd9"), (4, Eb, maj, "Eb"), (2, Db, maj7, "Dbmaj7"), (2, Eb, maj, "Eb"),
        (4, Ab, add9, "Abadd9"),
    ]))


SKY_332 = (0.0, 0.75, 1.5, 2.0, 2.75, 3.5)  # three-three-two twice a bar: the accents of the pulse and the arp


def skyclub_beat(s):
    """Four on the floor: the kick on every beat (it settles on Ab), a short open hat on every off-beat, quiet
    closed hats on the 16ths between, a clap on 2 and 4 (two more into bars 5 and 1). Under it a soft round
    pulse in three-three-two that spells the chord (root - fifth - root, root - third - fifth), so that the
    first layer alone already says the key."""
    k = kit("skyclub", s.sr)
    r = dsp.rng(s.id, "beat")
    b = s.zeros()
    for bar in range(s.bars):
        o = bar * 4
        for bt in range(4):
            hit(s, b, k["kick"], o + bt, 1.0, r, 0.0)
            hit(s, b, k["ohat"], o + bt + 0.5, 0.8, r, 0.0)
            hit(s, b, k["hat"], o + bt + 0.25, 0.3, r, 0.002)
            hit(s, b, k["hat"], o + bt + 0.75, 0.42, r, 0.002)
        for bt in (1, 3):
            hit(s, b, k["clap"], o + bt, 1.0, r, 0.0)
        if bar in (3, 7):
            hit(s, b, k["clap"], o + 3.5, 0.45, r, 0.0)
            hit(s, b, k["clap"], o + 3.75, 0.65, r, 0.0)
    b = dsp.drive(b / dsp.peak(b) * 1.2, 1.3)
    b = room(s, b, 0.08, 0.7, "beat", damp=6000)
    pl = s.zeros()
    n = nsamp(0.3, s.sr)
    t = np.arange(n) / s.sr
    for bar in range(s.bars):
        for i, bt in enumerate(SKY_332):
            c = s.chord_at(bar * 4 + bt)
            f = float(midi_hz(nearest(c.root, 54, 49, 60) + (0, 7, 0, 0, c.tones[1], 7)[i]))
            x = (np.sin(TAU * f * t) + 0.3 * np.sin(2 * TAU * f * t + 0.5) * np.exp(-t / 0.05)) * np.exp(-t / 0.1)
            s.add(pl, dsp.fade(x * (1.0 - np.exp(-t / 0.003)), s.sr, 0.001, 0.03), bar * 4 + bt,
                  1.0 if i % 3 == 0 else 0.7)
    pl = sidechain(s, pl, range(s.beats), 0.5, 0.08)
    rms = lambda z: float(np.sqrt(np.mean(z ** 2)))  # noqa: E731
    return b + 0.55 * pl * rms(b) / rms(pl)


def skyclub_bass(s):
    """Off-beat house bass ducked by the kick: the root on the 'and' of every beat, the octave on the third one,
    and a 16th that steps (in the scale) into the root of the next bar."""
    b = s.zeros()
    scale = {(s.tonic + i) % 12 for i in (0, 2, 4, 5, 7, 9, 11)}
    root = lambda c: nearest(c.root, 41, 36, 47)  # noqa: E731
    for bar in range(s.bars):
        o = bar * 4
        for q in range(4):
            R = root(s.chord_at(o + q))
            up = q == 2 and s.chord_at(o) is s.chord_at(o + 3)
            s.add(b, club_bass(R + 12 if up else R, s.sec(0.22 if up else 0.4), s.sr), o + q + 0.5,
                  0.75 if up else 1.0)
        nxt = root(s.chord_at(o + 4))
        step = 1 if nxt <= R else -1  # from under a root that is no higher, from above one that is
        m = nxt - step
        while m % 12 not in scale:
            m -= step
        s.add(b, club_bass(m, s.sec(0.2), s.sr, key=1), o + 3.75, 0.7)
    b = loop_filter(s, b, "lp", 2500)
    return sidechain(s, b, range(s.beats), 0.6, 0.12)


SKY_ARP = (0, 2, 4, 2, 1, 3, 5, 3, 2, 4, 6, 4, 3, 5, 3, 1)  # steps through the chord tones, low to high


def skyclub_arp(s):
    """A bright plucked arpeggio in 16ths that climbs through two octaves of the chord in broken steps, accented
    in three-three-two, with a dotted-8th echo."""
    b = s.zeros()
    for c in s.chords:
        tones = sorted(m for m in range(68, 93) if (m - c.root) % 12 in [t % 12 for t in c.tones])
        for i in range(int(c.dur * 4)):
            m = tones[SKY_ARP[i % 16] % len(tones)]
            v = 0.9 if (i % 16) * 0.25 in SKY_332 else 0.5
            s.add(b, sky_pluck(m, s.sr, dur=0.26, key=i % 2), c.start + i * 0.25, v)
    b = loop_filter(s, loop_filter(s, b, "hp", 300), "lp", 9000)
    b = loop_eq(s, b, "highshelf", 3500, 4.0)
    b = echo(s, b, 0.75, 0.3, 0.4, 3, 6000)
    b = sidechain(s, b, range(s.beats), 0.35, 0.1)
    return room(s, b, 0.16, 1.3, "arp", damp=8000)


def skyclub_pad(s):
    """A wide supersaw pad: every chord held, seven voices a note, a filter that opens and closes once every four
    bars, ducked deep by the kick so that it breathes on every beat."""
    b = s.zeros()
    vo = voice_lead([c.pcs(c.tones[:4]) for c in s.chords], 60, 80, 70)
    for c, v in zip(s.chords, vo):
        for j, m in enumerate(v):
            s.add(b, ins.supersaw(m, round(s.sec(c.dur) - 0.03, 4), s.sr, voices=7, spread=22.0, attack=0.03,
                                  release=0.2, key=20 + j), c.start, 0.8)
        s.add(b, ins.supersaw(nearest(c.root, 56, 51, 62), round(s.sec(c.dur) - 0.03, 4), s.sr, voices=5, attack=0.03,
                              release=0.2, key=29), c.start, 0.45)
    fc = 2600.0 + 3000.0 * (0.5 - 0.5 * np.cos(TAU * 2.0 * np.arange(s.n) / s.n))  # closed on bars 1 and 5
    b = dsp.sweep_filter(np.tile(b, 2), np.tile(fc, 2), s.sr, q=0.8)[s.n:]
    b = loop_filter(s, b, "hp", 180)
    b = sidechain(s, b, range(s.beats), 0.8, 0.18)
    return room(s, b, 0.25, 1.8, "pad", damp=5000, predelay=0.02)


# The tune, C5-C6: a two-bar call (C - Eb - Ab' G Eb | G - F Eb) that is answered over Fm7 and Dbmaj7, then the
# same shape from the octave (Ab' Bb' C'' over the tonic: the top of the tune), down through the dominant, a
# quick 'Ab F Ab | Bb G Bb' over IV - V and the long Ab that everything was heading for. The last two notes
# (Ab Bb) lead back into the C of bar 1. bar -> (beat, beats, midi)
SKY_LEAD = bars({
    0: [(0.0, 1.5, 72), (1.5, 0.5, 75), (2.0, 1.0, 80), (3.0, 0.5, 79), (3.5, 0.5, 75)],
    1: [(0.0, 1.5, 79), (1.5, 0.5, 77), (2.0, 1.5, 75), (3.5, 0.5, 72)],
    2: [(0.0, 1.5, 72), (1.5, 0.5, 75), (2.0, 1.0, 80), (3.0, 0.5, 77), (3.5, 0.5, 75)],
    3: [(0.0, 1.5, 77), (1.5, 0.5, 75), (2.0, 1.5, 72), (3.5, 0.5, 75)],
    4: [(0.0, 1.0, 80), (1.0, 0.5, 82), (1.5, 1.5, 84), (3.0, 0.5, 82), (3.5, 0.5, 80)],
    5: [(0.0, 1.5, 82), (1.5, 0.5, 79), (2.0, 1.0, 75), (3.0, 0.5, 77), (3.5, 0.5, 79)],
    6: [(0.0, 1.0, 80), (1.0, 0.5, 77), (1.5, 0.5, 80), (2.0, 1.0, 82), (3.0, 0.5, 79), (3.5, 0.5, 82)],
    7: [(0.0, 2.5, 80), (3.0, 0.5, 68), (3.5, 0.5, 70)],
})


def skyclub_lead(s):
    """The lead: a hollow pulse wave with a pure whistle an octave above it, gliding from note to note, with a
    dotted-8th echo."""
    kw = dict(glide=0.03, legato_gap=0.01, attack=0.012, release=0.1, vib_rate=5.6, vib_depth=0.14, vib_delay=0.2,
              key="skylead")
    src, env, onset = render_line(s, events(s, SKY_LEAD), osc="pulse", pw=0.32, **kw)
    top, _, _ = render_line(s, events(s, [(e[0], e[1], e[2] + 12) for e in SKY_LEAD]), osc="sine", **kw)
    x = dsp.sweep_filter(src * env, 1800.0 + 2600.0 * onset + 1200.0 * np.clip(env, 0, 1), s.sr, q=0.9)
    x = x / dsp.peak(x) + 0.35 * top * env
    x = dsp.highpass(dsp.drive(x / dsp.peak(x) * 1.1, 1.2), 200, s.sr, 2)
    b = wrap(s, x)
    b = echo(s, b, 0.75, 0.28, 0.4, 3, 4000)
    b = sidechain(s, b, range(s.beats), 0.2, 0.1)
    return room(s, b, 0.24, 1.8, "lead", damp=6000, predelay=0.02)


SKY_CHOPS = ((0.75, 0.25, "a_alto"), (1.5, 0.4, "o_alto"), (2.75, 0.25, "a_alto"), (3.5, 0.4, "e_open"))


def skyclub_fx(s):
    """The effects of the dance floor. A noise riser over the last two bars with a pitched roll in the last one
    (plucks that climb the pentatonic scale of Ab in 16ths), an impact on Ab on the first downbeat, a sweep down
    out of it and another into bar 5, and chopped vocal samples (ah - oh - ah - eh on notes of the chord, off
    the beat, with a stutter every second bar) in bars 1-6."""
    b = s.zeros()
    r = dsp.rng(s.id, "fx")
    sr = s.sr
    L = nsamp(s.sec(8), sr)
    t = np.arange(L) / L
    rise = dsp.sweep_filter(r.standard_normal(L), 400.0 * (6500.0 / 400.0) ** (t ** 1.4), sr, q=3.0, kind="bp")
    rise = dsp.fade(rise * t ** 2.2, sr, 0.01, 0.004)
    s.add(b, rise / dsp.peak(rise), s.beats - 8, 0.5)
    pent = [m for m in range(68, 105) if (m - s.tonic) % 12 in (0, 2, 4, 7, 9)]
    for i in range(16):
        s.add(b, sky_pluck(pent[i], sr, dur=0.2, key=2, cutoff=4000.0), s.beats - 4 + i * 0.25, 0.15 + 0.035 * i)
    # the impact: a boom that settles on Ab1 with its octave, and a short burst of noise
    n = nsamp(1.6, sr)
    tt = np.arange(n) / sr
    ph = TAU * np.cumsum(float(midi_hz(32)) * (1.0 + 0.9 * np.exp(-tt / 0.08))) / sr
    boom = (np.sin(ph) + 0.5 * np.sin(2.0 * ph + 0.3)) * dsp.env_perc(n, sr, 1.3, 0.001)
    boom = dsp.highpass(boom, 40, sr, 4)
    boom += 0.35 * dsp.bandpass(r.standard_normal(n), 300, 3000, sr) * np.exp(-tt / 0.12)
    s.add(b, dsp.fade(dsp.drive(boom / dsp.peak(boom), 1.5), sr, 0.001, 0.2), 0, 0.7)
    for beat, beats, g in ((0, 3, 0.4), (16, 2, 0.35)):  # sweeps down
        L2 = nsamp(s.sec(beats), sr)
        t2 = np.arange(L2) / L2
        down = dsp.sweep_filter(r.standard_normal(L2), 6000.0 * (350.0 / 6000.0) ** t2, sr, q=3.0, kind="bp")
        s.add(b, dsp.fade(down * (1 - t2) ** 2 / dsp.peak(down), sr, 0.005, 0.05), beat, g)
    vx = s.zeros()
    for bar in range(6):
        for j, (bt, du, vowel) in enumerate(SKY_CHOPS):
            c = s.chord_at(bar * 4 + bt)
            tones = sorted(m for m in range(68, 81) if (m - c.root) % 12 in [x % 12 for x in c.tones[:3]])
            m = tones[(bar + j) % len(tones)]
            s.add(vx, vox_chop(m, s.sec(du), sr, vowel, key=j), bar * 4 + bt, 0.9)
            if bar % 2 == 1 and j == 1:  # the stutter: the same slice twice more
                for q in (0.5, 0.75):
                    s.add(vx, vox_chop(m, s.sec(0.2), sr, vowel, key=j), bar * 4 + bt + q, 0.75)
    vx = echo(s, loop_filter(s, vx, "hp", 250), 0.75, 0.25, 0.4, 3, 3500)
    b = b / dsp.peak(b) + 0.9 * vx / dsp.peak(vx)
    return room(s, b, 0.22, 1.6, "fx", damp=5000)


# ================================================ HIP-HOP BLOCK (Bb major)

def block_song(d):
    # sunny boom-bap in Bb, 90 BPM: I - vi - IV - V(sus), then I - iii - IV V(sus) - I. Jazzy colours (major
    # 7ths and 9ths), every tone in the scale. Both halves start on the tonic and the loop ends on it; the
    # dominant is a sus chord (F Bb C Eb: it keeps the Bb), so home is never out of earshot. The café (lo-fi, F)
    # never lands on its tonic at the end, the jazz club (also Bb) swings in triplets through altered dominants.
    Bb, G, Eb, F, D = 10, 7, 3, 5, 2
    maj9, m7, maj7, sus, six9 = [0, 4, 7, 11, 14], [0, 3, 7, 10], [0, 4, 7, 11], [0, 5, 7, 10], [0, 4, 7, 9, 14]
    return Song(d, progression([
        (4, Bb, maj9, "Bbmaj9"), (4, G, m7, "Gm7"), (4, Eb, maj9, "Ebmaj9"), (4, F, sus, "F7sus4"),
        (4, Bb, maj9, "Bbmaj9"), (4, D, m7, "Dm7"), (2, Eb, maj7, "Ebmaj7"), (2, F, sus, "F7sus4"),
        (4, Bb, six9, "Bb6/9"),
    ]))


BLK_SW = 0.3  # how late the off-beat 16ths are (of a 16th): the head-nodding lilt of the whole block


def blk(beat):
    return sw16(beat, BLK_SW)


def blk_home(s, c):
    """The note of the tonic that chord c holds: Bb, or F where it has no Bb (Dm7). What the bass and the tuned
    drum lean on between the roots, so that the low end keeps saying Bb major (not D minor, its neighbour)."""
    return s.tonic if s.tonic in c.pcs() else (s.tonic + 7) % 12


def boom_kick(sr, midi=34, key=0):
    """A boom-bap kick: a knock and a round tail that settles on `midi` (Bb1) with its octave (Bb2: what a phone
    plays of the drum), so the drum itself names the key."""
    n = nsamp(0.3, sr)
    t = np.arange(n) / sr
    ph = TAU * np.cumsum(float(midi_hz(midi)) * (1.0 + 2.4 * np.exp(-t / 0.022))) / sr
    x = np.sin(ph) * np.exp(-t / 0.075) + 0.55 * np.sin(2.0 * ph + 0.4) * np.exp(-t / 0.07)
    knock = dsp.bandpass(dsp.rng("boomkick", key).standard_normal(n), 900, 3500, sr) * np.exp(-t / 0.004)
    x = dsp.drive(x / dsp.peak(x) + 0.3 * knock / dsp.peak(knock), 2.0)
    return dsp.fade(x / dsp.peak(x), sr, 0.0005, 0.04)


def scratch(sr, strokes, key=0):
    """A vinyl scratch: for every stroke (seconds, +1 forward / -1 back) the record speeds up and slows down
    under the hand, so the pitch and the brightness of what is on it rise and fall with the speed. The sound on
    the record is a buzzy voice-like tone with noise; no stable pitch is left of it."""
    r = dsp.rng("scratch", key)
    out = []
    for du, way in strokes:
        n = nsamp(du, sr)
        u = np.arange(n) / n
        speed = np.sin(np.pi * u) ** 0.7
        f = (170.0 if way > 0 else 130.0) + (1000.0 if way > 0 else 700.0) * speed
        src = 0.7 * dsp.saw(f, n, sr, r.uniform()) + 0.9 * r.standard_normal(n)
        x = dsp.sweep_filter(src, 500.0 + (3600.0 if way > 0 else 2600.0) * speed, sr, q=2.2, kind="bp") * speed
        out.append(dsp.fade(x / dsp.peak(x), sr, 0.002, 0.004))
        out.append(np.zeros(nsamp(0.012, sr)))
    return np.concatenate(out)


def BLOCK_BELL(sr):
    """The cowbell of the block party, on Bb5 and F6."""
    return cached(("blockbell", sr), lambda: np.asarray(
        ins.cowbell(sr, key=7, f1=float(midi_hz(82)), f2=float(midi_hz(89)), t60=0.25)))


def block_beat(s):
    """Boom-bap drums: the kick on 1, a push before 3 and on the 'and' of 3 (its tail rings on Bb), a fat snare
    on 2 and 4 with ghost notes, swung 16th hats with an open hat into every second bar. Under the kick a soft
    round tone on the root of the chord (and, on the push, the Bb or the F that the chord holds), so that the first
    layer alone says the key."""
    k = kit("block", s.sr)
    r = dsp.rng(s.id, "beat")
    b = s.zeros()
    for bar in range(s.bars):
        o = bar * 4
        kicks = [(0.0, 0.85), (1.75, 0.55), (2.5, 0.8)]
        if bar % 2 == 1:
            kicks += [(3.75, 0.55)]
        if bar in (3, 7):
            kicks += [(2.25, 0.5)]
        for bt, v in kicks:
            hit(s, b, k["kick"], o + blk(bt), v, r, 0.002)
        for bt in (1, 3):
            hit(s, b, k["snare"], o + bt, 1.0, r, 0.002)
        for bt, v in ((1.75, 0.22), (3.25, 0.18)) if bar % 2 == 0 else ((0.75, 0.2), (2.25, 0.2)):
            hit(s, b, k["ghost"], o + blk(bt), v, r, 0.003)
        if bar in (3, 7):  # a little fill into the next phrase
            for bt, v in ((3.5, 0.35), (3.75, 0.5)):
                hit(s, b, k["snare"], o + blk(bt), v, r, 0.002)
        for i in range(16):
            if i == 14 and bar % 2 == 1:
                hit(s, b, k["ohat"], o + 3.5, 0.6, r, 0.0)
                continue
            v = (0.7, 0.25, 0.5, 0.32)[i % 4]
            hit(s, b, k["hat"], o + blk(i * 0.25), v, r, 0.004)
    b = dsp.drive(b / dsp.peak(b) * 1.3, 1.5)
    b = room(s, b, 0.1, 0.5, "beat", damp=6000)
    tone = s.zeros()
    n = nsamp(0.45, s.sr)
    t = np.arange(n) / s.sr
    for bar in range(s.bars):
        for bt, home, v in ((0.0, False, 0.85), (1.75, True, 0.55), (2.5, False, 0.85)):
            c = s.chord_at(bar * 4 + bt)
            f = float(midi_hz(nearest(blk_home(s, c) if home else c.root, 60, 55, 66)))  # an octave above the bass
            x = (np.sin(TAU * f * t) + 0.35 * np.sin(2 * TAU * f * t + 0.5) * np.exp(-t / 0.08)) * np.exp(-t / 0.1)
            s.add(tone, dsp.fade(x * (1.0 - np.exp(-t / 0.004)), s.sr, 0.001, 0.05), bar * 4 + blk(bt), v)
    rms = lambda z: float(np.sqrt(np.mean(z ** 2)))  # noqa: E731
    return b + 0.3 * tone * rms(b) / rms(tone)


def block_bass(s):
    """A round sub bass that slides: the root held under the first half of the bar, a short push before beat 3,
    then the Bb or F of the chord (or, every fourth bar, the octave of the root, reached by a long slide up) and
    a scale step that glides into the root of the next bar."""
    scale = {(s.tonic + i) % 12 for i in (0, 2, 4, 5, 7, 9, 11)}
    # G2 - F3: a line that climbs (Bb G | Eb F | Bb D | Eb F) back into the Bb; low enough to be round, high
    # enough for a phone to play it
    root = lambda c: nearest(c.root, 48, 43, 54)  # noqa: E731
    ev = []
    for bar in range(s.bars):
        o = bar * 4
        R, R2 = root(s.chord_at(o)), root(s.chord_at(o + 2.5))
        nxt = root(s.chord_at(o + 4))
        m = nxt + (2 if nxt <= R2 else -2)
        while m % 12 not in scale:
            m -= 1
        ev += [(o, 1.5, R, 0.9), (o + blk(1.75), 0.5, R, 0.7)]
        if bar % 4 == 3:
            ev += [(o + 2.5, 1.0, R2 + (12 if R2 <= 47 else 0), 0.8, {"bend": 12.0, "bend_t": 0.2}),
                   (o + 3.5, 0.5, m, 0.75)]
        else:
            c2 = s.chord_at(o + 2.5)
            H = nearest(blk_home(s, c2), R2 + 5, 41, 58)
            if H == R2:  # the tonic itself: its fifth below
                H = R2 - 5
            ev += [(o + 2.5, 0.75, H, 0.85, {"bend": 2.0, "bend_t": 0.08}),
                   (o + blk(3.25), 0.25, R2, 0.6), (o + 3.5, 0.5, m, 0.75)]
    kw = dict(glide=0.045, legato_gap=0.06, attack=0.012, release=0.07, vib_depth=0.0, key="blockbass")
    src, env, _ = render_line(s, events(s, ev), osc="sine", **kw)
    top, _, _ = render_line(s, events(s, [(e[0], e[1], e[2] + 12) + tuple(e[3:]) for e in ev]), osc="tri", **kw)
    x = dsp.tube((src + 0.3 * top) * env * 1.2, 1.7, s.sr, bias=0.15)
    b = wrap(s, dsp.highpass(x, 30, s.sr, 2))
    return loop_filter(s, b, "lp", 1100)


def block_keys(s):
    """A warm electric piano: every chord rolled a little late and left to ring (root, 3rd, 7th and 9th: with
    its root, because Bbmaj9 without it is a plain Dm7), a short answer on the swung 16th before beat 3 and a softer chord after it; a slow tremolo."""
    b = s.zeros()
    r = dsp.rng(s.id, "keys")
    pick = lambda c: c.tones if len(c.tones) == 4 else [t for t in c.tones if t != 7]  # noqa: E731
    vo = voice_lead([c.pcs(pick(c)) for c in s.chords], 56, 76, 66)
    for bar in range(s.bars):
        o = bar * 4
        pat = [(0.0, 1.6, 0.7), (1.75, 0.35, 0.45), (2.5, 1.3, 0.6)]
        if bar % 2 == 1:
            pat += [(3.75, 0.25, 0.4)]
        for bt, du, v in pat:
            ci = s.chords.index(s.chord_at(o + bt))
            for j, m in enumerate(vo[ci]):
                x = ins.epiano(m, round(s.sec(du), 4), s.sr, vel=round(v + 0.03 * j, 2), bright=0.85, release=0.3)
                s.add(b, x, o + blk(bt), 0.8, dt=0.02 + j * 0.016 + r.normal(0, 0.003))
    b = loop_filter(s, loop_filter(s, b, "hp", 120), "lp", 5000)
    b = b * (1.0 - 0.16 * (0.5 + 0.5 * s.lfo(4.5)))
    b = tape(s, b, 4.0, 0.4)
    return room(s, b, 0.2, 1.2, "keys", damp=5000)


BLK_FILLS = {  # bongos on Bb3 (h) and F3 (l): bar -> (beat, drum, vel)
    1: [(3.5, "h", 0.7), (3.75, "l", 0.8)],
    3: [(3.0, "h", 0.7), (3.25, "h", 0.5), (3.5, "l", 0.8), (3.75, "l", 0.6)],
    5: [(3.25, "l", 0.5), (3.5, "h", 0.8), (3.75, "h", 0.6)],
    7: [(2.0, "h", 0.7), (2.5, "l", 0.7), (3.0, "h", 0.8), (3.25, "h", 0.5), (3.5, "l", 0.9), (3.75, "l", 0.65)],
}


def block_claps(s):
    """The friends on the block: hand claps on 2 and 4 (three pairs of hands, never quite together), finger
    snaps on the 'and' of 2 and of 4, a double clap that ends every four bars and bongo fills (tuned to Bb and
    F) at the end of every second bar."""
    k = kit("block", s.sr)
    r = dsp.rng(s.id, "claps")
    b = s.zeros()
    for bar in range(s.bars):
        o = bar * 4
        for bt in (1, 3):
            for j in range(3):
                hit(s, b, k["clap"], o + bt + 0.006 * j, 0.7 - 0.12 * j, r, 0.006)
        for bt, v in ((1.5, 0.6), (3.5, 0.45)):
            hit(s, b, k["snap"], o + bt, v, r, 0.004)
        if bar in (3, 7):
            for j in range(2):
                hit(s, b, k["clap"], o + blk(3.75) + 0.006 * j, 0.5, r, 0.004)
        for bt, drum, v in BLK_FILLS.get(bar, ()):
            hit(s, b, k["bongo_hi" if drum == "h" else "bongo_lo"], o + blk(bt), 0.75 * v, r, 0.004)
    return room(s, b, 0.16, 0.8, "claps", damp=5500)


# The hook, G4-G5, singable: 'da - da-da daa' (D - F D Bb) and its answers through the chords, a turn on the
# G over Dm7, a run down over IV - V and the long Bb everything was heading for; the last two notes (Bb C) lead
# back into the D of bar 1. bar -> (beat, beats, midi)
BLK_HOOK = bars({
    0: [(0.0, 0.5, 74), (0.75, 0.25, 77), (1.0, 0.5, 74), (1.5, 1.0, 70)],
    1: [(0.0, 0.5, 74), (0.75, 0.25, 77), (1.0, 0.5, 74), (1.5, 0.5, 72), (2.0, 0.5, 70), (2.5, 0.75, 67)],
    2: [(0.0, 0.5, 75), (0.75, 0.25, 79), (1.0, 0.5, 75), (1.5, 1.0, 74)],
    3: [(0.0, 0.5, 72), (0.75, 0.25, 75), (1.0, 0.5, 72), (1.5, 0.5, 74), (2.0, 1.0, 72)],
    4: [(0.0, 0.5, 74), (0.75, 0.25, 77), (1.0, 0.5, 74), (1.5, 1.0, 77)],
    5: [(0.0, 0.5, 77), (0.75, 0.25, 79), (1.0, 0.5, 77), (1.5, 0.5, 74), (2.0, 0.5, 70)],
    6: [(0.0, 0.5, 75), (0.75, 0.25, 79), (1.0, 0.5, 77), (1.5, 0.5, 74), (2.0, 0.5, 72), (2.5, 0.5, 74),
        (3.0, 0.5, 72), (3.5, 0.5, 70)],
    7: [(0.0, 2.0, 70), (3.0, 0.5, 70), (3.5, 0.5, 72)],
})
BLK_VOWELS = ("a_alto", "e_open", "a_alto", "o_alto")


def block_hook(s):
    """The hook: chopped vocal samples without words (ah - eh - ah - oh), two voices a breath apart, with a
    short echo."""
    b = s.zeros()
    for i, (bt, du, m) in enumerate(BLK_HOOK):
        d = s.sec(min(du, 1.5)) * 0.88
        vowel = "o_alto" if du >= 1.0 else BLK_VOWELS[i % 4]
        s.add(b, vox_chop(m, d, s.sr, vowel, key=i % 3), blk(bt), 0.9)
        s.add(b, vox_chop(m, d, s.sr, vowel, key=3 + i % 2), blk(bt), 0.45, dt=0.014)
    b = loop_filter(s, loop_filter(s, b, "hp", 250), "lp", 6000)
    b = echo(s, b, 0.75, 0.16, 0.3, 2, 3000)
    return room(s, b, 0.18, 1.1, "hook", damp=5000)


# The answers of the whistle, Bb5-G6, in the gaps of the hook: bar -> (beat, beats, midi)
BLK_LEAD = bars({
    0: [(2.5, 0.5, 86), (3.0, 0.5, 84), (3.5, 0.5, 82)],
    2: [(2.5, 0.5, 87), (3.0, 0.5, 86), (3.5, 0.5, 82)],
    4: [(2.5, 0.5, 86), (3.0, 0.25, 89), (3.25, 0.25, 86), (3.5, 0.5, 84)],
    5: [(2.5, 0.5, 84), (3.0, 0.5, 86), (3.5, 0.5, 89)],
    6: [(0.0, 2.0, 91), (2.0, 1.75, 89)],
    7: [(0.5, 0.5, 84), (1.0, 0.5, 86), (1.5, 1.0, 82)],
})
WICKA = ((0.07, 1), (0.07, -1))
BLK_SCRATCH = {  # bar -> (beat, strokes): 'wicka' after the long phrases, a longer cut before bars 5 and 1
    1: [(3.5, WICKA)],
    3: [(3.0, WICKA), (3.5, ((0.06, 1), (0.06, -1), (0.1, 1)))],
    5: [],
    7: [(2.5, WICKA), (3.0, ((0.05, 1), (0.05, -1), (0.05, 1), (0.05, -1))), (3.5, ((0.08, 1), (0.14, -1)))],
}


def block_lead(s):
    """A whistle-like synth (a pure tone with a breath of air and a slow vibrato, gliding between its notes) that
    answers the hook in its gaps, and the DJ's scratches at the ends of the phrases."""
    kw = dict(glide=0.03, legato_gap=0.02, attack=0.03, release=0.09, vib_rate=5.4, vib_depth=0.2, vib_delay=0.16,
              scoop=0.4, key="blocklead")
    ev = events(s, [(blk(e[0]),) + tuple(e[1:]) for e in BLK_LEAD])
    src, env, _ = render_line(s, ev, osc="sine", **kw)
    x = (src + 0.12 * np.sin(2.0 * np.arcsin(np.clip(src, -1, 1)))) * env
    x += 0.1 * ins.breath(len(src), s.sr, "blocklead", 2000, 6000) * env
    b = wrap(s, x / dsp.peak(x))
    b = echo(s, b, 0.75, 0.22, 0.35, 3, 4000)
    sc = s.zeros()
    for bar, spots in BLK_SCRATCH.items():
        for j, (bt, strokes) in enumerate(spots):
            s.add(sc, scratch(s.sr, strokes, key=bar * 4 + j), bar * 4 + bt, 1.0)
    sc = loop_filter(s, sc, "hp", 300)
    return room(s, b / dsp.peak(b) + 0.55 * sc / dsp.peak(sc), 0.2, 1.3, "lead", damp=6000)


# ================================================ REGGAE ISLAND (A major)

def island_song(d):
    # sunny roots reggae in A, 80 BPM: I - ii - V - I, then vi - IV - ii V - I (the 'rocksteady turn': the
    # dominant comes round twice and both halves end at home). Plain triads and two soft minor sevenths, every tone
    # in the scale. The beach (bossa, D) floats over major sevenths and never plays a plain V - I; the carnival
    # (salsa, C) runs on a montuno; the songs of the genre "reggae" (Bb) go I - IV - I - V or start on vi.
    A, B, E, Fs, D = 9, 11, 4, 6, 2
    maj, m7 = [0, 4, 7], [0, 3, 7, 10]
    return Song(d, progression([
        (4, A, maj, "A"), (4, B, m7, "Bm7"), (4, E, maj, "E"), (4, A, maj, "A"),
        (4, Fs, m7, "F#m7"), (4, D, maj, "D"), (2, B, m7, "Bm7"), (2, E, maj, "E"), (4, A, maj, "A"),
    ]))


ISL_SW = 0.22  # how late the off-beat 16ths are (of a 16th): the lazy shuffle of the island


def isl(beat):
    return sw16(beat, ISL_SW)


def isl_home(s, c):
    """The root or the fifth of the key that chord c holds: A, else E (Bm7 holds the A, E the E)."""
    return s.tonic if s.tonic in c.pcs() else (s.tonic + 7) % 12


def drop_kick(sr, midi=33, key=0):
    """The kick of the one drop: a soft, deep thump whose tail settles on `midi` (A1) with its octave (A2: what a
    phone plays of it) -- the drum says the key every time it falls on beat three."""
    n = nsamp(0.36, sr)
    t = np.arange(n) / sr
    ph = TAU * np.cumsum(float(midi_hz(midi)) * (1.0 + 1.6 * np.exp(-t / 0.02))) / sr
    x = np.sin(ph) * np.exp(-t / 0.1) + 0.5 * np.sin(2.0 * ph + 0.3) * np.exp(-t / 0.09)
    felt = dsp.lowpass(dsp.rng("dropkick", key).standard_normal(n), 1800, sr, 2) * np.exp(-t / 0.005)
    x = dsp.drive(x / dsp.peak(x) + 0.22 * felt / dsp.peak(felt), 1.5)
    return dsp.fade(x / dsp.peak(x), sr, 0.0005, 0.05)


def steel_pan(midi, sr, vel=0.8, dur=0.8, key=0):
    """A steel pan note: the fundamental, a strong octave that blooms a moment after the stroke, the twelfth and
    the double octave ringing shorter (the partials a pan is tuned to), all slightly detuned against each other
    so the note shimmers, and the soft knock of the rubber mallet."""
    def mk():
        f = float(midi_hz(midi))
        n = nsamp(dur + 0.08, sr)
        t = np.arange(n) / sr
        r = dsp.rng("steelpan", midi, key)
        t60 = float(np.clip(0.9 * (440.0 / f) ** 0.4, 0.5, 1.2))
        tau = t60 / 6.9
        x = np.sin(TAU * f * t) * np.exp(-t / tau)
        x += (0.75 * vel) * np.sin(TAU * 2.0 * f * 1.0015 * t + r.uniform(0, TAU)) * (
            1.0 - np.exp(-t / 0.014)) * np.exp(-t / (tau * 0.75))
        if 3.0 * f < 0.42 * sr:
            x += (0.3 * vel) * np.sin(TAU * 3.0 * f * 0.9985 * t + r.uniform(0, TAU)) * np.exp(-t / (tau * 0.4))
        if 4.0 * f < 0.42 * sr:
            x += (0.16 * vel) * np.sin(TAU * 4.0 * f * 1.002 * t + r.uniform(0, TAU)) * np.exp(-t / (tau * 0.3))
        m = nsamp(0.008, sr)
        knock = dsp.lowpass(r.standard_normal(m), 2000 + 2500 * vel, sr) * np.exp(-np.arange(m) / (0.002 * sr))
        x[:m] += 0.2 * vel * knock
        x *= np.exp(-6.9 * np.maximum(t - dur, 0.0) / 0.08)
        return dsp.fade(x * vel, sr, 0.001, 0.02)
    return cached(("steelpan", midi, sr, round(vel, 2), round(dur, 3), key), mk)


ISL_BONGOS = {  # bar -> (beat, drum h/l/t (tip), vel): little answers after the drop, a longer roll into bars 5 and 1
    0: [(3.0, "h", 0.7), (3.5, "l", 0.8)],
    1: [(2.75, "t", 0.4), (3.0, "h", 0.7), (3.25, "h", 0.5), (3.5, "l", 0.8)],
    2: [(3.0, "l", 0.7), (3.5, "h", 0.8)],
    3: [(2.5, "h", 0.6), (2.75, "h", 0.45), (3.0, "l", 0.75), (3.25, "h", 0.55), (3.5, "l", 0.85), (3.75, "l", 0.6)],
    4: [(3.0, "h", 0.7), (3.5, "l", 0.8)],
    5: [(2.75, "t", 0.4), (3.0, "h", 0.7), (3.25, "h", 0.5), (3.5, "l", 0.8)],
    6: [(1.0, "h", 0.6), (1.5, "l", 0.7), (3.0, "l", 0.7), (3.5, "h", 0.8)],
    7: [(2.5, "l", 0.6), (2.75, "h", 0.5), (3.0, "h", 0.8), (3.25, "l", 0.55), (3.5, "h", 0.7), (3.75, "l", 0.85)],
}


def island_drums(s):
    """One drop: nothing on beat one -- the kick and the cross-stick fall together on beat three. Hats on the
    8ths with a lazy swung 16th before the drop, an open hat into every fourth bar, bongos (tuned to A and E)
    that answer after the drop, and a timbale pick-up into the two halves. Where a rock beat has its kick, on
    beat one, a soft round note sounds on the root of the chord (and, with the drop, on the A or E that the chord
    holds), so the first layer alone already says the key."""
    k = kit("island", s.sr)
    r = dsp.rng(s.id, "drums")
    b = s.zeros()
    for bar in range(s.bars):
        o = bar * 4
        hit(s, b, k["kick"], o + 2.0, 1.0, r, 0.002)
        hit(s, b, k["rim"], o + 2.0, 0.8, r, 0.002)
        if bar % 2 == 1:
            hit(s, b, k["rim"], o + isl(3.75), 0.35, r, 0.003)
        for i in range(8):
            if i == 7 and bar % 4 == 3:
                hit(s, b, k["ohat"], o + 3.5, 0.5, r, 0.0)
                continue
            hit(s, b, k["hat"], o + i * 0.5, (0.6, 0.38)[i % 2], r, 0.004)
        hit(s, b, k["hat"], o + isl(1.75), 0.25, r, 0.004)
        for bt, drum, v in ISL_BONGOS.get(bar, ()):
            hit(s, b, k[{"h": "bongo_hi", "l": "bongo_lo", "t": "bongo_tip"}[drum]], o + isl(bt), 0.6 * v, r, 0.004)
        if bar in (3, 7):
            for bt, v in ((3.5, 0.45), (3.75, 0.6)):
                hit(s, b, k["timbale"], o + isl(bt), v, r, 0.002)
    b = dsp.drive(b / dsp.peak(b) * 1.2, 1.3)
    b = room(s, b, 0.14, 0.8, "drums", damp=5500)
    tone = s.zeros()
    n = nsamp(0.6, s.sr)
    t = np.arange(n) / s.sr
    for bar in range(s.bars):
        for bt, home, v in ((0.0, False, 1.0), (2.0, True, 0.7)):
            c = s.chord_at(bar * 4 + bt)
            f = float(midi_hz(nearest(isl_home(s, c) if home else c.root, 57, 52, 63)))  # an octave above the bass
            x = (np.sin(TAU * f * t) + 0.3 * np.sin(2 * TAU * f * t + 0.5) * np.exp(-t / 0.1)
                 + 0.12 * np.sin(3 * TAU * f * t) * np.exp(-t / 0.05)) * np.exp(-t / 0.14)
            s.add(tone, dsp.fade(x * (1.0 - np.exp(-t / 0.005)), s.sr, 0.001, 0.05), bar * 4 + bt, v)
    rms = lambda z: float(np.sqrt(np.mean(z ** 2)))  # noqa: E731
    return b + 0.42 * tone * rms(b) / rms(tone)


# The bass, E2-F#3: it sings. Every bar starts on the root and leaves room after it (the drop belongs to the
# drum), walks through the chord in the second half and steps into the next root. bar -> (beat, beats, midi)
ISL_BASS = bars({
    0: [(0.0, 1.0, 45), (1.5, 0.5, 49), (2.0, 0.75, 52), (3.0, 0.5, 49), (3.5, 0.5, 45)],
    1: [(0.0, 1.0, 47), (1.5, 0.5, 50), (2.0, 0.75, 54), (3.0, 0.5, 50), (3.5, 0.5, 47)],
    2: [(0.0, 0.75, 52), (1.0, 0.5, 52), (1.5, 0.5, 47), (2.0, 1.0, 40), (3.0, 0.5, 44), (3.5, 0.5, 47)],
    3: [(0.0, 1.25, 45), (1.5, 0.5, 45), (2.0, 0.5, 49), (2.5, 0.5, 52), (3.0, 0.5, 54), (3.5, 0.5, 52)],
    4: [(0.0, 1.0, 42), (1.5, 0.5, 45), (2.0, 0.75, 49), (3.0, 0.5, 45), (3.5, 0.5, 42)],
    5: [(0.0, 1.0, 50), (1.5, 0.5, 50), (2.0, 0.5, 54), (2.5, 0.5, 45), (3.0, 0.5, 50), (3.5, 0.5, 49)],
    6: [(0.0, 0.75, 47), (1.0, 0.5, 50), (1.5, 0.5, 54), (2.0, 0.75, 52), (3.0, 0.5, 47), (3.5, 0.5, 44)],
    7: [(0.0, 1.25, 45), (1.5, 0.5, 52), (2.0, 0.5, 49), (2.5, 0.75, 45), (3.5, 0.5, 40)],
})


def island_bass(s):
    """A deep, melodic reggae bass: round and warm (a sine with a soft triangle an octave up so that a phone
    still plays it), every note played short of the next (the rests are part of the line)."""
    ev = [(bt, du * 0.9, m, 0.9 if bt % 4 == 0 else 0.78) for bt, du, m in ISL_BASS]
    kw = dict(glide=0.02, legato_gap=0.005, attack=0.01, release=0.06, vib_depth=0.0, key="islbass")
    src, env, _ = render_line(s, events(s, ev), osc="sine", **kw)
    top, _, _ = render_line(s, events(s, [(e[0], e[1], e[2] + 12, e[3]) for e in ev]), osc="tri", **kw)
    x = dsp.tube((src + 0.32 * top) * env * 1.2, 1.6, s.sr, bias=0.12)
    b = wrap(s, dsp.highpass(x, 30, s.sr, 2))
    return loop_filter(s, b, "lp", 1000)


def island_rhythm(s):
    """The skank: a clean electric guitar chops the chord on every 'and', a short bright up-stroke that is damped
    at once; on the 'and' of two and of four a second, softer stroke follows on the swung 16th ('chk-a')."""
    b = s.zeros()
    r = dsp.rng(s.id, "skank")
    vo = voice_lead([c.pcs(c.tones[:3] if len(c.tones) == 3 else c.tones[1:]) for c in s.chords], 61, 78, 69,
                    span=12)
    for bar in range(s.bars):
        o = bar * 4
        for q in range(4):
            bt = q + 0.5
            notes = vo[s.chords.index(s.chord_at(o + bt))]
            x = ins.strum(notes, s.sec(0.2), s.sr, spread=0.005, up=True, bright=0.7, t60=0.5, pick=0.12,
                          mute=0.02, key=bar % 2, damp=0.35)
            s.add(b, x, o + bt, 0.9 if q % 2 else 0.8, dt=r.normal(0, 0.003))
            if q % 2 == 1:
                y = ins.strum(notes, s.sec(0.1), s.sr, spread=0.004, up=False, bright=0.65, t60=0.3, pick=0.12,
                              mute=0.015, key=2, damp=0.35)
                s.add(b, y, o + isl(bt + 0.25), 0.45, dt=r.normal(0, 0.003))
    b = loop_filter(s, b, "hp", 260)
    b = loop_eq(s, b, "peak", 2200, 3.0, 0.9)
    b = dsp.drive(b / dsp.peak(b) * 1.3, 1.3)
    return room(s, b, 0.12, 0.7, "skank", damp=5500)


def island_organ(s):
    """The bubble: the left hand of the organ plays two low notes of the chord on the swung 16ths around every
    off-beat ('a-ka'), the right hand a short chord on the off-beat itself, through a slow rotary speaker; at the
    end of each half the right hand holds its chord a little longer."""
    b = s.zeros()
    r = dsp.rng(s.id, "organ")
    lo = voice_lead([c.pcs([c.tones[0], c.tones[2]]) for c in s.chords], 45, 59, 52)
    hi = voice_lead([c.pcs(c.tones[:3]) for c in s.chords], 57, 72, 64, span=12)
    for bar in range(s.bars):
        o = bar * 4
        for q in range(4):
            ci = s.chords.index(s.chord_at(o + q + 0.5))
            hold = bar in (3, 7) and q == 3
            for bt, v in ((q + 0.25, 0.55), (q + 0.75, 0.7)):
                if hold and bt > q + 0.5:
                    continue
                for m in lo[ci]:
                    x = ins.organ(m, round(s.sec(0.14), 4), s.sr, bars=(8, 0, 8, 4, 0, 0, 0, 0, 0), perc=0.0,
                                  click=0.3, attack=0.004, release=0.03)
                    s.add(b, x, o + isl(bt), v, dt=r.normal(0, 0.003))
            for m in hi[ci]:
                x = ins.organ(m, round(s.sec(0.32 if hold else 0.2), 4), s.sr, bars=(6, 4, 8, 6, 0, 3, 0, 0, 0),
                              perc=0.25, click=0.25, attack=0.005, release=0.04)
                s.add(b, x, o + q + 0.5, 0.6, dt=r.normal(0, 0.003))
    b = dsp.loop_apply(b / dsp.peak(b) * 1.8, lambda z: dsp.tube(z, 1.3, s.sr, 0.12))
    b = leslie(s, b, 5.8, 0.22)
    b = loop_filter(s, loop_filter(s, b, "hp", 110), "lp", 3800)
    return room(s, b, 0.14, 0.9, "organ", damp=4500)


# The steel pan, A4-D6, singable: 'up the chord and rest' (C# E A), answered a step higher, the same over the
# dominant, home to the low A; then down from the top over F#m, up to the high D over IV, a run through ii - V
# and the long rolled A everything was heading for. The last note (B) leads back into the C# of bar 1.
# bar -> (beat, beats, midi)
ISL_PAN = bars({
    0: [(0.0, 0.5, 73), (0.5, 0.5, 76), (1.0, 1.0, 81), (2.0, 0.5, 78), (2.5, 1.0, 76)],
    1: [(0.0, 0.5, 74), (0.5, 0.5, 78), (1.0, 1.0, 81), (2.0, 1.0, 78)],
    2: [(0.0, 0.5, 76), (0.5, 0.5, 80), (1.0, 1.0, 83), (2.0, 0.5, 80), (2.5, 1.0, 76)],
    3: [(0.0, 0.5, 73), (0.5, 0.5, 76), (1.0, 0.5, 73), (1.5, 1.5, 69)],
    4: [(0.0, 1.0, 81), (1.0, 0.5, 78), (1.5, 0.5, 73), (2.0, 0.5, 76), (2.5, 1.0, 78)],
    5: [(0.0, 0.5, 78), (0.5, 0.5, 81), (1.0, 1.0, 86), (2.0, 1.0, 81)],
    6: [(0.0, 0.5, 83), (0.5, 0.5, 81), (1.0, 0.5, 78), (1.5, 0.5, 74), (2.0, 0.5, 76), (2.5, 0.5, 80),
        (3.0, 0.5, 83), (3.5, 0.5, 80)],
    7: [(0.0, 2.0, 81), (2.5, 0.5, 76), (3.0, 0.5, 73), (3.5, 0.5, 71)],
})


def island_steelpan(s):
    """The steel pan sings the tune: single strokes on the short notes, a roll (soft 32nds) on the long ones, the
    notes on the beat doubled a third to a sixth below by a second, quieter pan; a short echo."""
    b = s.zeros()
    r = dsp.rng(s.id, "pan")
    scale = [(s.tonic + i) % 12 for i in (0, 2, 4, 5, 7, 9, 11)]
    for bt, du, m in ISL_PAN:
        c = s.chord_at(bt)
        v = 0.9 if bt % 1 == 0 else 0.75
        if du >= 1.5:  # a roll
            n = int(round(du * 8))
            for i in range(n):
                g = v * (1.0 if i == 0 else 0.42 + 0.2 * np.sin(np.pi * i / n))
                s.add(b, steel_pan(m, s.sr, 0.8, 0.5, key=i % 2), bt + i * 0.125, g, dt=r.normal(0, 0.002))
        else:
            s.add(b, steel_pan(m, s.sr, round(v, 2), max(0.35, s.sec(du)), key=0), bt, v, dt=r.normal(0, 0.003))
        if bt % 1 == 0 and du >= 0.5:  # the second pan: the chord tone a third to a sixth under the tune
            under = [x for x in range(m - 9, m - 2) if x % 12 in c.pcs() and x % 12 in scale]
            if under:
                s.add(b, steel_pan(under[-1], s.sr, 0.7, max(0.35, s.sec(min(du, 1.0))), key=1), bt, 0.45 * v,
                      dt=0.006 + r.normal(0, 0.003))
    b = loop_filter(s, loop_filter(s, b, "hp", 250), "lp", 7000)
    b = echo(s, b, 0.75, 0.14, 0.3, 2, 4000)
    return room(s, b, 0.2, 1.2, "pan", damp=6000)


# The horns (a trumpet on top, a sax a third to a sixth below, a trombone an octave under the trumpet) answer the
# pan where it breathes, with off-beat 'pah's in between, and land on the last A. bar -> (beat, beats, top midi)
ISL_HORNS = bars({
    0: [(3.5, 0.4, 73)],
    1: [(2.5, 0.5, 69), (3.0, 0.5, 71), (3.5, 0.5, 74)],
    2: [(0.0, 0.3, 76), (3.5, 0.4, 76)],
    3: [(2.5, 0.5, 69), (3.0, 0.5, 73), (3.5, 0.5, 76)],
    4: [(0.0, 0.3, 78), (3.5, 0.4, 73)],
    5: [(2.5, 0.5, 69), (3.0, 0.5, 74), (3.5, 0.5, 78)],
    6: [(0.0, 0.3, 78)],
    7: [(1.5, 0.5, 73), (2.0, 0.5, 76), (2.5, 0.25, 73), (3.0, 0.9, 69)],
})


def island_brass(s):
    """A small horn section, soft and round: three voices move together in short answers and off-beat 'pah's."""
    b = s.zeros()
    r = dsp.rng(s.id, "horns")
    scale = [(s.tonic + i) % 12 for i in (0, 2, 4, 5, 7, 9, 11)]
    for bt, du, m in ISL_HORNS:
        c = s.chord_at(bt)
        under = [x for x in range(m - 9, m - 2) if x % 12 in c.pcs() and x % 12 in scale]
        if not under:
            under = [x for x in range(m - 4, m - 2) if x % 12 in scale]
        for j, (mm, g) in enumerate(((m, 1.0), (under[-1], 0.75), (m - 12, 0.7))):
            x = ins.brass(mm, round(s.sec(du) * 0.9, 4), s.sr, vel=0.8, bright=0.75, key=j)
            s.add(b, x, bt, g, dt=0.004 * j + r.normal(0, 0.003))
    b = loop_filter(s, loop_filter(s, b, "hp", 180), "lp", 5000)
    b = echo(s, b, 0.75, 0.1, 0.3, 2, 3000)
    return room(s, b, 0.2, 1.2, "horns", damp=5000)


# ================================================ COUNTRY RANCH (G major)

def ranch_song(d):
    # sunny barn-dance country in G, 108 BPM felt in two (the bass on every beat, the accent on every 'and'):
    # I - IV - I - V, then I - IV - I V - I. Plain triads, nothing but the three chords of a hoedown, and both
    # halves end the way a fiddle tune does: the first on the dominant (an open question), the second at home.
    # The square (a brass street band, also in G) marches over sixths and sevenths, the bazaar (G) never plays a
    # plain V - I, the garage is rock in E; the songs of the genre "country" are in D.
    G, C, D = 7, 0, 2
    maj = [0, 4, 7]
    return Song(d, progression([
        (4, G, maj, "G"), (4, C, maj, "C"), (4, G, maj, "G"), (4, D, maj, "D"),
        (4, G, maj, "G"), (4, C, maj, "C"), (2, G, maj, "G"), (2, D, maj, "D"), (4, G, maj, "G"),
    ]))


def tub_bass(midi, sr, vel=0.8, key=0):
    """A washtub bass: one gut string on a broomstick over an upturned tub. A short round thump whose pitch is
    pulled up to the note as the stick is leaned back, the octave above it (what a phone plays of it), the hollow
    knock of the tub and no sustain to speak of."""
    def mk():
        f = float(midi_hz(midi))
        n = nsamp(0.42, sr)
        t = np.arange(n) / sr
        r = dsp.rng("tub", midi, key)
        ph = TAU * np.cumsum(f * (1.0 - 0.07 * np.exp(-t / 0.022))) / sr
        x = np.sin(ph) * np.exp(-t / 0.11) + 0.5 * np.sin(2.0 * ph + 0.4) * np.exp(-t / 0.08)
        x += 0.16 * np.sin(3.0 * ph + 1.1) * np.exp(-t / 0.045)
        knock = dsp.bandpass(r.standard_normal(n), 140, 700, sr) * np.exp(-t / 0.012)
        x = x / dsp.peak(x) + 0.3 * knock / dsp.peak(knock)
        x = dsp.drive(x * (1.0 - np.exp(-t / 0.003)), 1.4)
        return dsp.fade(x / dsp.peak(x), sr, 0.0005, 0.05) * vel
    return cached(("tub", midi, sr, round(vel, 2), key), mk)


def washboard(sr, dur=0.05, key=0, thimble=0.0):
    """One stroke of thimbles over a washboard: band-passed noise chopped by the ribs of the tin (about 90 a
    second at this speed), with the click of the thimble in front when the stroke is an accent."""
    n = nsamp(dur, sr)
    t = np.arange(n) / sr
    r = dsp.rng("washboard", key)
    x = dsp.bandpass(r.standard_normal(n), 1800, min(8500, 0.42 * sr), sr)
    x = dsp.filt(x, "peak", 3400, sr, q=1.5, gain_db=6.0)
    x = x * (0.25 + 0.75 * (0.5 + 0.5 * np.sin(TAU * 90.0 * t + r.uniform(0, TAU))) ** 2)
    x = x * np.sin(np.pi * np.clip(t / dur, 0, 1)) ** 0.5 * np.exp(-t / (dur * 0.6))
    x = x / dsp.peak(x)
    if thimble:
        m = nsamp(0.012, sr)
        x[:m] += thimble * np.sin(TAU * 2350.0 * t[:m]) * np.exp(-t[:m] / 0.003)
    return dsp.fade(x / dsp.peak(x), sr, 0.0008, 0.008)


def boot_stomp(sr, key=0):
    """A boot on the boards of the barn floor: a low thud that settles on G1 (with its octave G2), the knock of
    the heel and the rattle of the planks."""
    n = nsamp(0.3, sr)
    t = np.arange(n) / sr
    r = dsp.rng("stomp", key)
    ph = TAU * np.cumsum(float(midi_hz(31)) * (1.0 + 1.3 * np.exp(-t / 0.016))) / sr
    x = np.sin(ph) * np.exp(-t / 0.07) + 0.6 * np.sin(2.0 * ph + 0.2) * np.exp(-t / 0.06)
    heel = dsp.bandpass(r.standard_normal(n), 150, 1100, sr) * np.exp(-t / 0.009)
    planks = dsp.bandpass(r.standard_normal(n), 300, 2400, sr) * np.exp(-t / 0.035) * (t > 0.006)
    x = x / dsp.peak(x) + 0.55 * heel / dsp.peak(heel) + 0.12 * planks / dsp.peak(planks)
    return dsp.fade(dsp.drive(x / dsp.peak(x), 1.5), sr, 0.0005, 0.05)


def banjo_note(midi, dur, sr, vel=0.8, key=0):
    """A five-string banjo: a very bright string that dies quickly, through the skin of the drum it sits on (a
    hollow peak near 650 Hz and a nasal one near 2.3 kHz, no low body at all) with the snap of the finger pick."""
    def mk():
        y = ins.guitar(midi, dur, sr, bright=0.97, t60=0.55, pick=0.32, mute=0.035, key=key, damp=0.16).copy()
        n = len(y)
        t = np.arange(n) / sr
        y = y / (dsp.peak(y) + 1e-9)
        snap = dsp.highpass(dsp.rng("banjo", midi, key).standard_normal(n), 2500, sr, 2) * np.exp(-t / 0.0025)
        y = y + 0.22 * vel * snap / dsp.peak(snap)
        y = dsp.highpass(y, 280, sr, 2)
        y = dsp.filt(y, "peak", 650, sr, q=2.0, gain_db=5.0)
        y = dsp.filt(y, "peak", 2300, sr, q=1.4, gain_db=6.0)
        return dsp.fade(y / dsp.peak(y), sr, 0.0005, 0.008) * vel
    return cached(("banjo", midi, round(dur, 3), sr, round(vel, 2), key), mk)


def fiddle_note(midi, dur, sr, vel=0.8, key=0, slide=0.0, vib=0.5):
    """A country fiddle, one bow stroke: the bow bites at once (a scratch of rosin in the first hundredths), the
    note may be slid into from `slide` semitones below, a quick narrow vibrato comes only on a held note; the
    body of the instrument is two peaks (near 480 Hz and 1.1 kHz) and a bright bridge peak at 2.6 kHz."""
    def mk():
        n = nsamp(dur + 0.09, sr)
        t = np.arange(n) / sr
        r = dsp.rng("fiddle", midi, key)
        bend = 2.0 ** (-slide * np.exp(-t / 0.035) / 12.0)
        f = midi_hz(midi) * bend * (1.0 + vib * 0.005 * np.sin(TAU * r.uniform(5.8, 6.4) * t + r.uniform(0, 6))
                                    * np.clip((t - 0.18) / 0.15, 0.0, 1.0))
        x = dsp.saw(f * 2 ** (2.5 / 1200), n, sr, r.uniform()) + 0.8 * dsp.saw(f * 2 ** (-2.5 / 1200), n, sr, r.uniform())
        rosin = dsp.bandpass(r.standard_normal(n), 2000, 7000, sr) * np.exp(-t / 0.02)
        x = x + 0.5 * rosin
        x = dsp.highpass(x, 180, sr, 2)
        x = dsp.filt(x, "peak", 480, sr, q=2.0, gain_db=4.0)
        x = dsp.filt(x, "peak", 1100, sr, q=1.6, gain_db=3.0)
        x = dsp.filt(x, "peak", 2600, sr, q=1.2, gain_db=7.0)
        x = dsp.lowpass(x, 5200, sr, 2)
        x *= dsp.env_adsr(n, sr, 0.014, 0.08, 0.82, dur, 0.05)
        return dsp.fade(x / dsp.peak(x), sr, 0.001, 0.015) * vel
    return cached(("fiddle", midi, round(dur, 3), sr, round(vel, 2), key, slide, vib), mk)


def harmonica_note(midi, dur, sr, vel=0.8, key=0, bend=0.6, wah=5.5):
    """A harmonica: two brass reeds a few cents apart (they beat), thin and nasal (narrow pulses through a peak
    near 1.4 kHz), blown into from a little below the note (the bend of a draw note), the air of the breath, and
    the cupped hands opening and closing over it (`wah` times a second) once the note is held."""
    def mk():
        n = nsamp(dur + 0.1, sr)
        t = np.arange(n) / sr
        r = dsp.rng("harmonica", midi, key)
        f = midi_hz(midi) * 2.0 ** (-bend * np.exp(-t / 0.05) / 12.0)
        x = dsp.pulse(f * 2 ** (5 / 1200), n, sr, 0.22, r.uniform()) + dsp.pulse(f * 2 ** (-5 / 1200), n, sr, 0.26, r.uniform())
        x = dsp.highpass(x, 320, sr, 2)
        x = dsp.filt(x, "peak", 1400, sr, q=1.3, gain_db=7.0)
        x = dsp.lowpass(x, 4200, sr, 2)
        env = dsp.env_adsr(n, sr, 0.03, 0.1, 0.85, dur, 0.07)
        hands = 1.0 - 0.3 * np.clip((t - 0.2) / 0.2, 0.0, 1.0) * (0.5 - 0.5 * np.cos(TAU * wah * t))
        x = x * env * hands + 0.1 * ins.breath(n, sr, f"harmonica{midi}{key}", 1800, 5000) * env
        return dsp.fade(dsp.tube(x / dsp.peak(x) * 1.3, 1.3, sr, 0.1), sr, 0.002, 0.02) * vel
    return cached(("harmonica", midi, round(dur, 3), sr, round(vel, 2), key, bend, wah), mk)


def whoop(sr, key=0, lo=62, hi=79, dur=0.42):
    """'Yee-hoo!': a happy voice that leaps from `lo` up to `hi` (D4 to G5: the fifth and the root of the key) and
    falls off a little at the end, opening from 'ee' to 'ah'."""
    r = dsp.rng("whoop", key)
    n = nsamp(dur + 0.1, sr)
    t = np.arange(n) / sr
    u = np.clip(t / dur, 0.0, 1.0)
    rise = np.clip(u / 0.3, 0.0, 1.0) ** 0.7
    m = lo + (hi - lo) * rise - 2.0 * np.clip((u - 0.75) / 0.25, 0.0, 1.0) ** 2
    f = midi_hz(m) * (1.0 + 0.008 * np.sin(TAU * 6.5 * t + r.uniform(0, 6)) * (u > 0.4))
    src = dsp.saw(f, n, sr) + 0.12 * r.standard_normal(n)
    a = dsp.formant(src, sr, dsp.VOWELS["i_tenor"])
    b = dsp.formant(src, sr, dsp.VOWELS["a_sop"])
    w = np.clip((u - 0.15) / 0.3, 0.0, 1.0)
    x = ((1 - w) * a / dsp.peak(a) + w * b / dsp.peak(b)) * dsp.env_adsr(n, sr, 0.02, 0.1, 0.85, dur, 0.07)
    return dsp.fade(x / dsp.peak(x), sr, 0.002, 0.03)


def ranch_kit(sr):
    """A jug-band kit made for 22.05 kHz: a washboard (soft strokes and accents with the click of the thimble),
    brushes on a snare, boots on the barn floor (a thud on G1 and G2), hand claps, a pair of spoons (clacks on
    D6 and G6: the fifth and the root of the key) and a small splash."""
    unit = lambda x: x / dsp.peak(x)  # noqa: E731
    k = {}
    k["wash"] = [washboard(sr, 0.045, key=i) for i in range(4)]
    k["wash_acc"] = [washboard(sr, 0.085, key=10 + i, thimble=0.5) for i in range(3)]
    k["hat"] = [washboard(sr, 0.04, key=20 + i) for i in range(3)]
    k["brush"] = [unit(ins.brush_tap(sr, key=700 + i, dur=0.11, tone=196.0)) for i in range(3)]
    k["swish"] = [unit(ins.brush_swish(sr, 0.12, key=710 + i)) for i in range(2)]
    k["stomp"] = [boot_stomp(sr, key=i) for i in range(3)]
    k["clap"] = [unit(ins.clap(sr, key=720 + i, tail=0.1, lo=900.0, hi=3400.0)) for i in range(4)]
    k["spoon_hi"] = [unit(ins.woodblock(sr, f=float(midi_hz(91)), key=730 + i, t=0.05)) for i in range(2)]
    k["spoon_lo"] = [unit(ins.woodblock(sr, f=float(midi_hz(86)), key=740 + i, t=0.05)) for i in range(2)]
    k["crash"] = [dsp.lowpass(ins.crash(sr, key=73, t60=1.3), 9500, sr, 2)]
    return k


# The tub bass, D2-D3: the root of the chord on one and three, its fifth on two and four ('boom' on every beat of
# a tune felt in two), and a walk along the scale into every new chord. bar -> (beat, midi)
RANCH_TUB = {
    0: [(0, 43), (1, 50), (2, 43), (3, 50)],
    1: [(0, 48), (1, 43), (2, 48), (3, 43), (3.5, 45)],
    2: [(0, 43), (1, 50), (2, 43), (2.5, 45), (3, 47), (3.5, 48)],
    3: [(0, 50), (1, 45), (2, 50), (3, 45), (3.5, 42)],
    4: [(0, 43), (1, 50), (2, 43), (2.5, 43), (3, 45), (3.5, 47)],
    5: [(0, 48), (1, 43), (2, 48), (3, 47), (3.5, 45)],
    6: [(0, 43), (1, 47), (2, 50), (3, 45), (3.5, 42)],
    7: [(0, 43), (1, 50), (2, 43), (3, 38), (3.5, 42)],
}


def ranch_drums(s):
    """The train beat: a washboard runs on the 16ths ('chick-a-chick-a') with a thimble accent and a brush on
    every 'and', the way a locomotive puffs, and a little shuffle of strokes into every fourth bar. Under it a
    washtub bass thumps the root and the fifth of the chord on the beats and walks into every new chord: the
    first layer alone already says the key."""
    k = kit("ranch", s.sr)
    r = dsp.rng(s.id, "drums")
    b = s.zeros()
    for bar in range(s.bars):
        o = bar * 4
        for i in range(16):
            bt = o + i * 0.25
            if i % 4 == 2:  # the 'and': the accent of the train
                hit(s, b, k["wash_acc"], bt, 0.95 if i % 8 == 6 else 0.85, r, 0.003)
                hit(s, b, k["brush"], bt, 0.5 if i % 8 == 6 else 0.4, r, 0.003)
            else:
                hit(s, b, k["wash"], bt, (0.5, 0.3, 0.0, 0.38)[i % 4], r, 0.003)
        if bar % 4 == 3:
            for bt, v in ((3.125, 0.3), (3.375, 0.4), (3.625, 0.5), (3.875, 0.6)):
                hit(s, b, k["wash"], o + bt, v, r, 0.002)
            hit(s, b, k["swish"], o + 3.0, 0.4, r, 0.0)
    b = dsp.drive(b / dsp.peak(b) * 1.1, 1.2)
    b = room(s, b, 0.12, 0.7, "drums", damp=6000)
    tub = s.zeros()
    for bar, notes in RANCH_TUB.items():
        for bt, m in notes:
            v = 0.95 if bt in (0, 2) else (0.8 if bt % 1 == 0 else 0.68)
            s.add(tub, tub_bass(m, s.sr, round(v, 2), key=int(bt * 2) % 2), bar * 4 + bt, 1.0, dt=r.normal(0, 0.003))
    tub = loop_filter(s, tub, "lp", 1600)
    rms = lambda z: float(np.sqrt(np.mean(z ** 2)))  # noqa: E731
    return b + 1.5 * tub * rms(b) / rms(tub)


# The banjo in open G tuning (g4 D3 G3 B3 D4): the left hand holds the chord, the right hand rolls.
RANCH_BANJO_CHORD = {  # chord name -> strings 4, 3, 2, 1 (the fifth string is always the high g, midi 67)
    "G": (50, 55, 59, 62), "C": (52, 55, 60, 64), "D": (50, 57, 62, 66),
}
# rolls: eight 16ths, the string plucked on each (5 = the short high string under the thumb)
RANCH_ROLLS = {
    "fwd_rev": (3, 2, 1, 5, 1, 2, 3, 1),   # forward-reverse
    "thumb": (3, 2, 5, 1, 4, 2, 5, 1),     # alternating thumb
    "fwd": (2, 1, 5, 2, 1, 5, 2, 1),       # forward: three against four
}
RANCH_BANJO_BARS = [("fwd_rev", "thumb"), ("thumb", "fwd"), ("fwd_rev", "fwd"), ("thumb", "run"),
                    ("fwd_rev", "thumb"), ("fwd", "thumb"), ("fwd_rev", "thumb"), ("fwd", "tag")]
# the run that closes the first half on the dominant (D E F# A, then up to the high D) and the tag that brings
# the second half home (G A B D, the high G): (16th, midi)
RANCH_BANJO_LICKS = {
    "run": ((0, 50), (1, 52), (2, 54), (3, 57), (4, 62), (5, 66), (6, 69), (7, 66)),
    "tag": ((0, 55), (1, 57), (2, 59), (3, 62), (4, 67), (6, 62), (7, 67)),
}


def ranch_banjo(s):
    """Three-finger picking: rolls of eight 16ths over the strings of the chord, the short fifth string (a high G
    that never changes) ringing through all of it, the thumb's notes a little louder (they carry the tune inside
    the roll); a run up the dominant ends the first half, a tag on G the second."""
    b = s.zeros()
    r = dsp.rng(s.id, "banjo")
    for bar in range(s.bars):
        for half, what in enumerate(RANCH_BANJO_BARS[bar]):
            o = bar * 4 + half * 2
            c = s.chord_at(o)
            if what in RANCH_BANJO_LICKS:
                for q, m in RANCH_BANJO_LICKS[what]:
                    v = 0.9 if q % 2 == 0 else 0.72
                    s.add(b, banjo_note(m, 0.32, s.sr, round(v, 2), key=q % 2), o + q * 0.25, 1.0, dt=r.normal(0, 0.003))
                continue
            strings = RANCH_BANJO_CHORD[c.name]
            for q, st in enumerate(RANCH_ROLLS[what]):
                m = 67 if st == 5 else strings[4 - st]
                v = 0.9 if st in (3, 4) else (0.6 if st == 5 else 0.74)
                if q % 4 == 0:
                    v = min(1.0, v + 0.08)
                s.add(b, banjo_note(m, 0.3, s.sr, round(v, 2), key=q % 2), o + q * 0.25, 1.0, dt=r.normal(0, 0.003))
    b = b / dsp.peak(b)
    return room(s, b, 0.1, 0.7, "banjo", damp=6500)


RANCH_GUITAR = {  # chord -> (bass note on one and three, bass note on two and four, the strummed strings)
    "G": (43, 50, (55, 59, 62, 67)), "C": (48, 52, (55, 60, 64, 67)), "D": (50, 45, (57, 62, 66)),
}


def ranch_guitar(s):
    """Boom-chick: a flat-picked acoustic guitar plays a bass string on every beat (root, then the other bass
    note of the chord) and brushes the top strings down on every 'and', with a light up-stroke after the 'and'
    of two and of four ('boom-chick-a'); the last beat of each half is a full ringing strum."""
    b = s.zeros()
    r = dsp.rng(s.id, "guitar")
    for bar in range(s.bars):
        o = bar * 4
        for q in range(4):
            c = s.chord_at(o + q)
            b1, b2, top = RANCH_GUITAR[c.name]
            last = bar in (3, 7) and q == 3
            m = b1 if q % 2 == 0 else b2
            x = ins.guitar(m, s.sec(0.42), s.sr, bright=0.5, t60=1.4, pick=0.16, mute=0.05, key=q % 2, damp=0.4)
            s.add(b, x, o + q, 0.95 if q % 2 == 0 else 0.8, dt=r.normal(0, 0.003))
            if last:
                x = ins.strum((b1,) + top, s.sec(0.9), s.sr, spread=0.014, bright=0.62, t60=1.6, pick=0.14,
                              mute=0.08, key=2, damp=0.35)
                s.add(b, x, o + q + 0.5, 0.95, dt=r.normal(0, 0.003))
                continue
            x = ins.strum(top, s.sec(0.3), s.sr, spread=0.007, bright=0.65, t60=0.9, pick=0.13, mute=0.03,
                          key=bar % 2, damp=0.35)
            s.add(b, x, o + q + 0.5, 0.8 if q % 2 else 0.7, dt=r.normal(0, 0.003))
            if q % 2 == 1:
                y = ins.strum(top[1:], s.sec(0.14), s.sr, spread=0.005, up=True, bright=0.7, t60=0.5, pick=0.13,
                              mute=0.02, key=2, damp=0.35)
                s.add(b, y, o + q + 0.75, 0.4, dt=r.normal(0, 0.003))
    b = loop_filter(s, b, "hp", 75)
    b = loop_eq(s, b, "peak", 3000, 2.5, 0.8)
    b = dsp.drive(b / dsp.peak(b) * 1.15, 1.2)
    return room(s, b, 0.12, 0.8, "guitar", damp=6000)


RANCH_STOMPS = {  # bar -> (beat, 's' boots / 'c' hands, vel)
    "*": [(0, "s", 1.0), (1, "c", 0.85), (2, "s", 0.95), (2.5, "s", 0.6), (3, "c", 0.9)],
    3: [(0, "s", 1.0), (1, "c", 0.85), (2, "s", 0.95), (2.5, "c", 0.6), (3, "c", 0.9), (3.5, "c", 0.75)],
    7: [(0, "s", 1.0), (1, "c", 0.85), (2, "s", 0.95), (2.5, "c", 0.7), (3, "c", 0.95)],
}


def ranch_claps(s):
    """The barn dance joins in: boots stomp on one and three (with a skip before four), a dozen hands clap on two
    and four, twice at the end of each half, and somebody whoops 'yee-hoo!' (D up to G) as each half begins."""
    k = kit("ranch", s.sr)
    r = dsp.rng(s.id, "claps")
    b = s.zeros()
    for bar in range(s.bars):
        for bt, what, v in RANCH_STOMPS.get(bar, RANCH_STOMPS["*"]):
            if what == "s":
                hit(s, b, k["stomp"], bar * 4 + bt, 0.7 * v, r, 0.004)
                hit(s, b, k["stomp"], bar * 4 + bt, 0.35 * v, r, 0.012)
            else:
                for j in range(4):
                    hit(s, b, k["clap"], bar * 4 + bt, 0.7 * v, r, 0.009)
    b = b / dsp.peak(b)
    w = s.zeros()
    for j, (beat, lo, hi) in enumerate(((0.5, 62, 79), (16.5, 62, 79))):
        s.add(w, whoop(s.sr, key=j, lo=lo, hi=hi), beat, 1.0)
        s.add(w, whoop(s.sr, key=5 + j, lo=lo - 12, hi=hi - 12, dur=0.4), beat, 0.5, dt=0.03)
    w = loop_filter(s, loop_filter(s, w, "hp", 250), "lp", 5000)
    return room(s, b + 0.6 * w / dsp.peak(w), 0.16, 0.9, "claps", damp=5500)


# The fiddle tune, G4-B5, singable: 'da, da-da DAA' on G, the same a step higher on C, a run over the top on G
# and a question held on the dominant; then from the top downwards, the C phrase turned round, a run through G
# and D and the long G everything was heading for. Short-long 'shuffle' bowing (an 8th and two 16ths) starts the
# phrases. bar -> (beat, beats, midi[, the double stop under it (midi)])
RANCH_FIDDLE = bars({
    0: [(0.0, 0.5, 74, 67), (0.5, 0.25, 71), (0.75, 0.25, 74), (1.0, 1.0, 79, 71), (2.0, 0.5, 76), (2.5, 0.5, 74),
        (3.0, 0.5, 71), (3.5, 0.5, 74)],
    1: [(0.0, 0.5, 76, 67), (0.5, 0.25, 72), (0.75, 0.25, 76), (1.0, 1.0, 79, 72), (2.0, 1.75, 76, 72)],
    2: [(0.0, 0.5, 74, 67), (0.5, 0.25, 71), (0.75, 0.25, 74), (1.0, 0.5, 79, 71), (1.5, 0.5, 83), (2.0, 0.5, 81),
        (2.5, 0.5, 79), (3.0, 0.5, 76), (3.5, 0.5, 74)],
    3: [(0.0, 0.5, 78, 69), (0.5, 0.25, 74), (0.75, 0.25, 78), (1.0, 1.4, 81, 74)],
    4: [(0.0, 0.5, 83, 74), (0.5, 0.25, 79), (0.75, 0.25, 83), (1.0, 0.5, 81), (1.5, 0.5, 79), (2.0, 0.5, 76),
        (2.5, 0.5, 74), (3.0, 1.0, 71, 67)],
    5: [(0.0, 0.5, 76, 67), (0.5, 0.25, 79), (0.75, 0.25, 76), (1.0, 0.5, 72), (1.5, 0.5, 76), (2.0, 1.75, 79, 76)],
    6: [(0.0, 0.5, 74, 67), (0.5, 0.5, 71), (1.0, 0.5, 67), (1.5, 0.5, 71), (2.0, 0.5, 69, 62), (2.5, 0.25, 74),
        (2.75, 0.25, 78), (3.0, 0.5, 81), (3.5, 0.5, 78)],
    7: [(0.0, 1.9, 79, 71)],
})


def ranch_fiddle(s):
    """The fiddle sings the tune: every stroke bites, the notes on the beat are slid into from below, the long
    ones get a quick vibrato, and the notes that carry the phrase are double stops (the open string or the chord
    tone under the tune, bowed with it)."""
    b = s.zeros()
    r = dsp.rng(s.id, "fiddle")
    for e in RANCH_FIDDLE:
        bt, du, m = e[:3]
        v = 0.9 if bt % 1 == 0 else 0.76
        d = round(s.sec(du) * 0.94, 4)
        slide = 0.7 if (bt % 1 == 0 and du >= 0.5) else 0.0
        s.add(b, fiddle_note(m, d, s.sr, round(v, 2), key=0, slide=slide, vib=1.0 if du >= 1.0 else 0.3), bt, 1.0,
              dt=r.normal(0, 0.003))
        if len(e) > 3:
            s.add(b, fiddle_note(e[3], d, s.sr, round(v * 0.6, 2), key=1, slide=0.0, vib=0.0), bt, 1.0,
                  dt=0.004 + r.normal(0, 0.003))
    b = loop_filter(s, b, "hp", 200)
    return room(s, b / dsp.peak(b), 0.16, 1.0, "fiddle", damp=6000, predelay=0.012)


# The harmonica answers where the fiddle holds a note or breathes (the second halves of bars 2, 4, 6 and 8) and
# chugs two soft chords like a far-off train in the bars between. bar -> (beat, beats, midi)
RANCH_HARP = bars({
    1: [(2.0, 0.5, 79), (2.5, 0.5, 76), (3.0, 0.25, 72), (3.25, 0.25, 76), (3.5, 0.5, 79)],
    3: [(2.0, 0.25, 74), (2.25, 0.25, 78), (2.5, 1.0, 81), (3.5, 0.5, 78)],
    5: [(2.0, 0.5, 72), (2.5, 0.5, 76), (3.0, 0.5, 79), (3.5, 0.5, 81)],
    7: [(2.0, 0.5, 71), (2.5, 0.25, 74), (2.75, 0.25, 76), (3.0, 0.9, 79)],
})
RANCH_CHUG = {0: (71, 74), 4: (71, 74), 2: (74, 79)}  # bar -> the two reeds blown together on the 'and's of 3 and 4


def ranch_harmonica(s):
    """A harmonica answers the fiddle: bent into from below, the hands opening on the long notes, the last note
    of every answer doubled a third or a fourth lower (two holes at once); in between, soft two-note chugs."""
    b = s.zeros()
    r = dsp.rng(s.id, "harmonica")
    last = {}
    for bt, du, m in RANCH_HARP:
        last[int(bt // 4)] = bt
    for bt, du, m in RANCH_HARP:
        v = 0.9 if bt % 1 == 0 else 0.78
        d = round(s.sec(du) * 0.95, 4)
        s.add(b, harmonica_note(m, d, s.sr, round(v, 2), key=0, bend=0.7 if du >= 0.5 else 0.3), bt, 1.0,
              dt=r.normal(0, 0.003))
        if bt == last[int(bt // 4)] or du >= 1.0:
            c = s.chord_at(bt)
            under = [x for x in range(m - 5, m - 2) if x % 12 in c.pcs()]
            if under:
                s.add(b, harmonica_note(under[-1], d, s.sr, round(v * 0.6, 2), key=1, bend=0.3), bt, 1.0,
                      dt=r.normal(0, 0.003))
    for bar, dyad in RANCH_CHUG.items():
        for bt, v in ((2.5, 0.4), (3.5, 0.45)):
            for j, m in enumerate(dyad):
                s.add(b, harmonica_note(m, round(s.sec(0.3), 4), s.sr, v, key=2 + j, bend=0.2), bar * 4 + bt, 1.0,
                      dt=r.normal(0, 0.003))
    b = loop_filter(s, b, "hp", 300)
    b = echo(s, b / dsp.peak(b), 0.75, 0.1, 0.3, 2, 3000)
    return room(s, b, 0.18, 1.1, "harmonica", damp=5000)


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
    kits = {"cafe": "lofi", "jazz": "jazz", "square": "street", "stadium": "dance", "garage": "rock",
            "beach": "beach", "carnival": "carnival", "cinema": "cinema", "bazaar": "bazaar", "skyclub": "skyclub",
            "block": "block", "island": "island", "ranch": "ranch"}
    k = kit(kits[style], s.sr)
    hats = k["hat"] if "hat" in k else k["chick"]
    if style == "jazz":
        for i in range(s.beats * 3):
            hit(s, b, hats, i / 3.0, 0.5 if i % 3 == 0 else 0.3, r, 0.003)
    else:
        for i in range(s.beats * 4):
            swing = {"cafe": 0.3, "block": BLK_SW}.get(style, 0.0)
            hit(s, b, hats, sw16(i * 0.25, swing), 0.55 if i % 2 == 0 else 0.35, r, 0.002)
    pb = s.zeros()
    for bt, m, v in _pulse_notes(s, 62 if style == "cafe" else 50):
        if style == "garage":
            x = power_chord(m - 12 if m > 52 else m, s.sec(0.3), s.sr, muted=True, key=0)
        elif style == "jazz":
            x = upright(m - 12, s.sec(0.4), s.sr)
        elif style == "cafe":  # bright e-piano pulse in the middle register (no low-mid mud)
            x = ins.epiano(m, s.sec(0.25), s.sr, vel=0.6, bright=1.0, release=0.08)
        elif style == "beach":  # palm-muted nylon string on the chord roots
            x = ins.guitar(m, s.sec(0.3), s.sr, bright=0.45, t60=0.55, pick=0.18, mute=0.04, key=7)
        elif style == "carnival":  # the left hand of the piano, staccato
            x = ins.piano(m, round(s.sec(0.25), 4), s.sr, vel=0.7, bright=0.8, release=0.06)
        elif style == "cinema":  # cellos and basses off the string (spiccato): the chase is on
            x = bowed(m, s.sec(0.2), s.sr, key=9, attack=0.012, release=0.07, vib=0.0, cutoff=1800.0)
        elif style == "bazaar":  # the oud, short strokes on the chord roots
            x = oud(m, s.sec(0.3), s.sr, key=9)
        elif style == "skyclub":  # the pluck of the arpeggio, darker, on the chord roots
            x = sky_pluck(m, s.sr, dur=0.22, key=3, cutoff=2500.0)
        elif style == "block":  # the electric piano, staccato, on the chord roots
            x = ins.epiano(m, round(s.sec(0.25), 4), s.sr, vel=0.7, bright=0.9, release=0.08)
        elif style == "island":  # the left hand of the organ, staccato, on the chord roots
            x = ins.organ(m, round(s.sec(0.2), 4), s.sr, bars=(8, 0, 8, 5, 0, 2, 0, 0, 0), perc=0.3, click=0.3,
                          attack=0.004, release=0.03)
        elif style == "ranch":  # the bass strings of the guitar, palm-muted, on the chord roots
            x = ins.guitar(m, s.sec(0.3), s.sr, bright=0.55, t60=0.5, pick=0.16, mute=0.04, key=7, damp=0.4)
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
    if style == "ranch":  # no synthesizer in the barn: a fiddle shivers on two strings, the fifth and the root above it
        hold = round(s.sec(s.beats) - 0.5, 4)
        s.add(tr, fiddle_note(fifth, hold, s.sr, 0.8, key=3, vib=1.0), 0.0)
        s.add(tr, fiddle_note(fifth + 5, hold, s.sr, 0.8, key=4, vib=1.0), 0.0, 0.8)
    else:
        s.add(tr, pad_note(fifth, s.sec(s.beats) - 0.5, s.sr, cutoff=2500, attack=1.0, release=1.0, det=5, key=3), 0.0)
    tr *= 0.6 + 0.4 * np.sin(TAU * np.arange(s.n) / s.n * s.beats * 2) ** 2  # 8th-note tremolo
    b += 0.35 * tr / (dsp.peak(tr) + 1e-9)
    return room(s, b, 0.14, 1.0, "tension", damp=5000)


def party_chords(s, style):
    """Chords for the finale: the song's chords, except that jazz plays plain
    G13 instead of the altered G7s and Bbmaj9 (the tonic) where the song has
    Dm7(11) (Bbmaj9 contains it): triumphant and clearly in Bb, not G minor;
    and the carnival plays its dominant as a plain G triad (the F of every G7
    on top of the F and Dm7 chords would make the finale read as F major)."""
    out = []
    for c in s.chords:
        if style == "jazz" and c.name.startswith("G7("):
            c = Chord(c.start, c.dur, c.root, [4, 10, 14, 21], "G13")
        elif style == "jazz" and c.name == "Dm7(11)":
            c = Chord(c.start, c.dur, (c.root + 8) % 12, [4, 7, 11, 14], "Bbmaj9")
        elif style == "carnival" and c.name == "G7":
            c = Chord(c.start, c.dur, c.root, [0, 4, 7], "G")
        elif style == "skyclub" and c.name == "Abadd9":  # the plain tonic triad, the root doubled on top
            c = Chord(c.start, c.dur, c.root, [0, 4, 7], "Ab")
        elif style == "block" and c.name in ("Bbmaj9", "Bb6/9"):  # the horns shout the plain tonic triad
            c = Chord(c.start, c.dur, c.root, [0, 4, 7], "Bb")
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
    kits = {"cafe": "lofi", "jazz": "jazz", "square": "street", "stadium": "dance", "garage": "rock",
            "beach": "beach", "carnival": "carnival", "cinema": "cinema", "bazaar": "bazaar", "skyclub": "skyclub",
            "block": "block", "island": "island", "ranch": "ranch"}
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
        if style == "skyclub":  # no shaker in the club: its own closed hats on the 16ths, its open hat and its kick
            for i in range(16):
                hit(s, b, k["hat"], o + i * 0.25, 0.3 if i % 2 else 0.18, r, 0.003)
            for bt in range(4):
                hit(s, b, k["ohat"], o + bt + 0.5, 0.3, r, 0.0)
                hit(s, b, k["kick"], o + bt, 0.5, r, 0.0)
        elif style == "block":  # the whole block joins in: its own swung hats, the kick of the beat, a cowbell on Bb
            for i in range(16):
                hit(s, b, k["hat"], o + blk(i * 0.25), 0.32 if i % 2 == 0 else 0.2, r, 0.003)
            for bt, v in ((0.0, 0.5), (2.5, 0.45)):
                hit(s, b, k["kick"], o + bt, v, r, 0.0)
            for bt, v in ((0.0, 0.5), (1.0, 0.3), (1.5, 0.4), (2.5, 0.5), (3.0, 0.3)):
                hit(s, b, [BLOCK_BELL(s.sr)], o + bt, 0.3 * v, r, 0.002)
        elif style == "island":  # the beach party: the kick on every beat now ('steppers'), bongos on the 16ths
            for i in range(16):
                drum = "bongo_lo" if i in (6, 7, 14) else ("bongo_hi" if i % 4 in (0, 3) else "bongo_tip")
                hit(s, b, k[drum], o + isl(i * 0.25), 0.3 if i % 2 == 0 else 0.2, r, 0.003)
                hit(s, b, k["shaker"], o + isl(i * 0.25), 0.3 if i % 2 else 0.18, r, 0.003)
            for bt in range(4):
                hit(s, b, k["kick"], o + bt, 0.5, r, 0.0)
                hit(s, b, k["ohat"], o + bt + 0.5, 0.22, r, 0.0)
        elif style == "ranch":  # the whole barn: the washboard on the 16ths, boots on every beat, spoons galloping
            for i in range(16):
                hit(s, b, k["wash_acc" if i % 4 == 2 else "wash"], o + i * 0.25, 0.4 if i % 4 == 2 else 0.22, r, 0.003)
            for bt in range(4):
                hit(s, b, k["stomp"], o + bt, 0.55, r, 0.0)
            for bt, drum, v in ((0.0, "lo", 0.5), (0.5, "hi", 0.4), (0.75, "hi", 0.3), (1.0, "lo", 0.5),
                                (1.5, "hi", 0.4), (2.0, "lo", 0.5), (2.5, "hi", 0.4), (2.75, "hi", 0.3),
                                (3.0, "lo", 0.5), (3.5, "hi", 0.4), (3.75, "lo", 0.3)):
                hit(s, b, k["spoon_" + drum], o + bt, 0.5 * v, r, 0.002)
        else:
            for i in range(16):
                hit(s, b, lk["shaker"], o + i * 0.25, 0.6 if i % 2 else 0.35, r, 0.003)
            for bt in range(4):
                hit(s, b, dk["ohat"], o + bt + 0.5, 0.35, r, 0.0)
        if style in ("stadium", "garage", "square"):
            for bt in range(4):
                hit(s, b, dk["kick"], o + bt, 0.5, r, 0.0)
        if style == "carnival":  # the bongo bell of the mambo section: the beats, and the off-beats of 2 and 4
            for bt, v in ((0, 0.9), (1, 0.6), (1.5, 0.45), (2, 0.9), (3, 0.6), (3.5, 0.45)):
                hit(s, b, k["bell"], o + bt, 0.4 * v, r, 0.002)
        if style == "bazaar":  # finger cymbals on every beat with a gallop into the next bar, the riq on the 8ths
            for bt, v in ((0, 0.5), (1, 0.7), (2, 0.5), (3, 0.7), (3.25, 0.4), (3.5, 0.55)):
                hit(s, b, k["zill"], o + bt, 0.4 * v, r, 0.002)
            for i in range(8):
                hit(s, b, k["riq"], o + i * 0.5, 0.4 if i % 2 else 0.25, r, 0.003)
        if bar in (3, 7):
            for j in range(8):
                hit(s, b, dk["snare"], o + 2 + j * 0.25, 0.3 + 0.06 * j, r, 0.002)
    drums = b / dsp.peak(b)
    st = s.zeros()
    chords = party_chords(s, style)
    vo = [party_voicing(c) for c in chords]
    for bar in range(s.bars):
        # off-beat stabs; swung in the jazz club; in the cinema a fanfare rhythm (long, short-long) on the beats;
        # in the bazaar the accents of the maqsum (dum tek - tek dum - tek); in the sky club the piano of a house
        # anthem (three-three-two and two off-beats)
        for bt in {"jazz": (T, 1 + T, 2 + T, 3 + T), "cinema": (0.0, 0.75, 1.0, 2.0, 2.75, 3.0),
                   "bazaar": (0.0, 0.5, 1.5, 2.0, 3.0), "skyclub": (0.0, 0.75, 1.5, 2.5, 3.5),
                   "block": (0.0, 1.5, 2.0, 3.5)}.get(  # horn stabs: on 1, pushed into 3, on 3, pushed into 1
                       style, (0.5, 1.5, 2.5, 3.5)):
            beat = bar * 4 + bt
            ci = s.chords.index(s.chord_at(beat))
            for j, m in enumerate(vo[ci]):
                if style == "stadium":
                    x = ins.supersaw(m, s.sec(0.3), s.sr, attack=0.003, release=0.08, key=j)
                elif style == "garage":
                    x = ins.organ(m, s.sec(0.3), s.sr, bars=(8, 0, 8, 8, 0, 6, 0, 0, 4), perc=0.3, click=0.3)
                elif style in ("cafe", "beach"):
                    x = ins.epiano(m, s.sec(0.3), s.sr, vel=0.8, bright=1.0, release=0.1)
                elif style == "skyclub":  # house piano
                    x = ins.piano(m, round(s.sec(0.4), 4), s.sr, vel=0.85, bright=0.9, release=0.12)
                elif style == "ranch":  # the upright piano of the barn dance, short bright chords
                    x = ins.piano(m, round(s.sec(0.3), 4), s.sr, vel=0.9, bright=1.0, release=0.08, key=j % 2)
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
            elif style == "beach":  # a marimba on the beach instead of the glockenspiel
                x = ins.marimba(m, s.sr, vel=0.8, dur=0.8)
            elif style == "carnival":  # the top of the piano
                x = ins.piano(m, 0.3, s.sr, vel=0.8, bright=1.0, release=0.2)
            elif style == "bazaar":  # the top strings of the qanun
                x = qanun(m, s.sr, key=i % 2, dur=0.6)
            elif style == "island":  # a second steel pan runs up the chord, an octave under the glockenspiel's place
                x = steel_pan(m - 12, s.sr, 0.8, 0.5, key=i % 2)
            elif style == "ranch":  # a second banjo runs up the chord, an octave under the glockenspiel's place
                x = banjo_note(m - 12, 0.3, s.sr, 0.9, key=i % 2)
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
    "beach": dict(song=beach_song, stems={
        "perc": beach_perc, "guitar": beach_guitar, "bass": beach_bass, "shaker": beach_shaker,
        "keys": beach_keys, "flute": beach_flute}),
    "carnival": dict(song=carnival_song, stems={
        "congas": carnival_congas, "shaker": carnival_shaker, "bass": carnival_bass, "piano": carnival_piano,
        "guitar": carnival_guitar, "trumpet": carnival_trumpet}),
    "cinema": dict(song=cinema_song, stems={
        "timpani": cinema_timpani, "cello": cinema_cello, "harp": cinema_harp, "drums": cinema_drums,
        "brass": cinema_brass, "choir": cinema_choir}),
    "bazaar": dict(song=bazaar_song, stems={
        "darbuka": bazaar_darbuka, "oud": bazaar_oud, "bass": bazaar_bass, "qanun": bazaar_qanun,
        "flute": bazaar_flute, "strings": bazaar_strings}),
    "skyclub": dict(song=skyclub_song, stems={
        "beat": skyclub_beat, "bass": skyclub_bass, "arp": skyclub_arp, "pad": skyclub_pad, "lead": skyclub_lead,
        "fx": skyclub_fx}),
    "block": dict(song=block_song, stems={
        "beat": block_beat, "bass": block_bass, "keys": block_keys, "claps": block_claps, "hook": block_hook,
        "lead": block_lead}),
    "island": dict(song=island_song, stems={
        "drums": island_drums, "bass": island_bass, "rhythm": island_rhythm, "organ": island_organ,
        "steelpan": island_steelpan, "brass": island_brass}),
    "ranch": dict(song=ranch_song, stems={
        "drums": ranch_drums, "banjo": ranch_banjo, "guitar": ranch_guitar, "claps": ranch_claps,
        "fiddle": ranch_fiddle, "harmonica": ranch_harmonica}),
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
    "beach": {"perc": -17, "guitar": -18, "bass": -19, "shaker": -20, "keys": -20, "flute": -18,
              "tension": -18, "party": -16},
    "carnival": {"congas": -17, "shaker": -20, "bass": -19, "piano": -19, "guitar": -19, "trumpet": -18,
                 "tension": -18, "party": -16},
    "cinema": {"timpani": -17, "cello": -19, "harp": -20, "drums": -19, "brass": -19, "choir": -18,
               "tension": -18, "party": -16},
    "bazaar": {"darbuka": -17, "oud": -19, "bass": -19, "qanun": -20, "flute": -18, "strings": -19,
               "tension": -18, "party": -16},
    "skyclub": {"beat": -16, "bass": -19, "arp": -19, "pad": -19, "lead": -18, "fx": -18,
                "tension": -18, "party": -16},
    "block": {"beat": -16, "bass": -19, "keys": -19, "claps": -19, "hook": -18, "lead": -18,
              "tension": -18, "party": -16},
    "island": {"drums": -17, "bass": -19, "rhythm": -18, "organ": -20, "steelpan": -18, "brass": -18,
               "tension": -18, "party": -16},
    "ranch": {"drums": -17, "banjo": -19, "guitar": -19, "claps": -18, "fiddle": -18, "harmonica": -18,
              "tension": -18, "party": -16},
}

# Level of a whole district against the common peak target of gen_audio.py (dB, 0 = none). The block is dense on
# its downbeats (kick, tuned tone, bass, keys and hook together) and came out about 1 LU louder than the other
# districts at the same peak: this brings it in line and keeps notes + music in a level under 0 dBTP.
LEVEL_TRIM = {"block": -1.0}


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
