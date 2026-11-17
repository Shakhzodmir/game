"""Jukebox songs: single full-mix loops in the genre (key) of each district.

Every district of content/districts.json is also a jukebox genre; its `songs`
list names the extra songs of that genre. The first song of a genre is the
layered district theme (music.py); the songs here are ready-made mixes that play
as ONE file (no progress layers), so the jukebox can offer them at once.

How a song is built (same rules as music.py)
--------------------------------------------
* Song (music.py) holds the grid: bpm, bars, the key of the genre and a loop of
  exactly round(bars * 4 * 60 / bpm * 22050) samples. Events that ring past the
  loop end wrap to the start, every effect is circular (room, echo, tape,
  sidechain, ...), so the finished loop is exactly periodic: no click, no gap.
* A song is a function(s) -> {part: signal}. The progression is written with
  Roman numerals relative to the key (prog), tunes with scale degrees (tune),
  grooves as step strings (hits). render_song() balances the parts to relative
  loudness targets (the same K-weighted meter as the district stems) and sums
  them; gen_audio.py then levels the mix (loudness + true-peak limiter), encodes
  and checks it.
* Everything is deterministic: randomness comes from dsp.rng(song id, part).

Notation
--------
  prog:  "vi7:4 IVmaj7:4 Imaj7:4 V9:4"      numeral[quality]:beats (see SHAPES)
  tune:  "5:1 3:.5 2+:.5 r:1 | 1:4"         degree[octave marks][!|_]:beats, bars split by |
         degrees 1-7 of the major scale, b3 / #4 accidentals, + / - one octave up / down,
         ! accent, _ soft, r rest, durations 1 .5 .25 1/3 2/3 ...
  hits:  "X..x..o.g..x...."                  one bar per string (X loud, x normal, o soft,
         g ghost); the length gives the grid: 16 = 16ths, 12 = triplets, 8 = 8ths
"""
import re

import numpy as np

import dsp
import instruments as ins
import music as M
from dsp import TAU, midi_hz, nsamp
from music import (Chord, Song, SR, echo, events, hit, kit, leslie, loop_eq, loop_filter, nearest, render_line, room,
                   sidechain, tape, voice_lead, wrap)

KEY_NAMES = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
DEGREE = {"I": 0, "II": 2, "III": 4, "IV": 5, "V": 7, "VI": 9, "VII": 11}
MAJOR = [0, 2, 4, 5, 7, 9, 11]

# quality suffix -> intervals above the root (the root included) and the name suffix, per numeral case
SHAPES = {
    ("", "M"): ([0, 4, 7], ""), ("", "m"): ([0, 3, 7], "m"),
    ("5", "M"): ([0, 7], "5"), ("5", "m"): ([0, 7], "5"),
    ("6", "M"): ([0, 4, 7, 9], "6"), ("6", "m"): ([0, 3, 7, 9], "m6"),
    ("7", "M"): ([0, 4, 7, 10], "7"), ("7", "m"): ([0, 3, 7, 10], "m7"),
    ("maj7", "M"): ([0, 4, 7, 11], "maj7"),
    ("9", "M"): ([0, 4, 7, 10, 14], "9"), ("9", "m"): ([0, 3, 7, 10, 14], "m9"),
    ("maj9", "M"): ([0, 4, 7, 11, 14], "maj9"),
    ("add9", "M"): ([0, 4, 7, 14], "add9"), ("add9", "m"): ([0, 3, 7, 14], "madd9"),
    ("sus2", "M"): ([0, 2, 7], "sus2"), ("sus2", "m"): ([0, 2, 7], "sus2"),
    ("sus4", "M"): ([0, 5, 7], "sus4"), ("sus4", "m"): ([0, 5, 7], "sus4"),
    ("7sus4", "M"): ([0, 5, 7, 10], "7sus4"), ("7sus4", "m"): ([0, 5, 7, 10], "7sus4"),
}
CHORD_RE = re.compile(r"^(VII|VI|IV|V|III|II|I|vii|vi|iv|v|iii|ii|i)([a-z0-9]*):([\d.]+)$")
TUNE_RE = re.compile(r"^([b#]?)([1-7r])([+-]*)([!_]?):([\d./]+)$")


# ---------------------------------------------------------------- notation

def prog(tonic, text):
    """Roman-numeral progression in the key `tonic` (pitch class) -> [Chord]. Only diatonic roots, so a
    song never leaves the key of its genre (the match notes and effects are transposed to that key)."""
    out, beat = [], 0.0
    for tok in text.split():
        m = CHORD_RE.match(tok)
        if not m:
            raise ValueError("bad chord " + tok)
        num, quality, beats = m.group(1), m.group(2), float(m.group(3))
        case = "M" if num.isupper() else "m"
        shape = SHAPES.get((quality, case))
        if not shape:
            raise ValueError("no chord shape " + tok)
        root = (tonic + DEGREE[num.upper()]) % 12
        out.append(Chord(beat, beats, root, shape[0], KEY_NAMES[root] + shape[1]))
        beat += beats
    return out


def _dur(text):
    if "/" in text:
        a, b = text.split("/")
        return float(a) / float(b)
    return float(text)


def tune(text, tonic, octave=5, bar=4.0):
    """Tune in scale degrees -> [(beat, beats, midi, vel)] ; octave = the octave of degree 1 (C4 = 60);
    bar = the beats between two | (3 for a waltz)."""
    base = 12 * (octave + 1) + tonic
    out = []
    bar_len = bar
    for bar, chunk in enumerate(text.split("|")):
        pos = bar * bar_len
        for tok in chunk.split():
            m = TUNE_RE.match(tok)
            if not m:
                raise ValueError("bad note " + tok)
            acc, deg, octs, mark, du = m.groups()
            d = _dur(du)
            if deg != "r":
                midi = base + MAJOR[int(deg) - 1] + {"b": -1, "#": 1, "": 0}[acc]
                midi += 12 * (octs.count("+") - octs.count("-"))
                out.append((pos, d, midi, {"!": 1.0, "_": 0.55, "": 0.8}[mark]))
            pos += d
        if abs(pos - (bar + 1) * bar_len) > 1e-6:
            raise ValueError("bar %d of the tune has %.3f beats" % (bar + 1, pos - bar * bar_len))
    return out


def bs(text):
    """Bars '1-4,7' (1-based) -> {0..3, 6}."""
    out = set()
    for part in text.split(","):
        a, _, b = part.partition("-")
        out.update(range(int(a) - 1, int(b or a)))
    return out


GRID_VEL = {"X": 1.0, "x": 0.8, "o": 0.5, "g": 0.3}


def pattern_for(spec, bar):
    if isinstance(spec, str):
        return spec
    if isinstance(spec, (list, tuple)):
        return spec[bar % len(spec)]
    return spec.get(bar, spec.get("*"))


def hits(s, buf, samples, spec, r, swing=0.0, gain=1.0, jit=0.003, mask=None, shift=0.0):
    """Drum / percussion pattern. spec: a bar string, a list cycled per bar or {bar0: string, "*": default}."""
    for bar in range(s.bars):
        if mask is not None and bar not in mask:
            continue
        p = pattern_for(spec, bar)
        if not p:
            continue
        chars = [c for c in p if c not in " |"]
        n = len(chars)
        step = 4.0 / n
        for i, ch in enumerate(chars):
            v = GRID_VEL.get(ch)
            if v is None:
                continue
            beat = bar * 4 + i * step + shift
            if swing and n in (8, 16) and i % 2 == 1:
                beat += swing * step
            hit(s, buf, samples, beat, v * gain, r, jit)


def at(s, buf, x, beat, gain=1.0, dt=0.0):
    s.add(buf, x, beat, gain, dt=dt)


def sw(beat, amount, grid=0.25):
    """Swing the off-beat step of a `grid`-beat grid."""
    q = beat / grid
    if abs(q - round(q)) < 1e-6 and int(round(q)) % 2 == 1:
        return beat + amount * grid
    return beat


# -------------------------------------------------------------- voicings

def voicing(chords, lo, hi, center, pick=None, span=13):
    """Voice-led MIDI voicings, one list per chord. pick(c) -> the intervals to voice (default: all)."""
    return voice_lead([c.pcs(pick(c) if pick else c.tones) for c in chords], lo, hi, center, span)


def guide(c):
    """3rd and 7th (or 6th): what names the chord without the root and 5th."""
    return [t for t in c.tones if t % 12 in (3, 4, 9, 10, 11)][:2] or c.tones[1:3]


def no_root(c):
    return [t for t in c.tones if t % 12 != 0] or c.tones


def chord_notes(c, lo, hi, intervals=None):
    pcs = {(c.root + t) % 12 for t in (intervals or c.tones)}
    return sorted(m for m in range(lo, hi + 1) if m % 12 in pcs)


def chord_at(s, beat):
    return s.chord_at(beat)


# ----------------------------------------------------------------- voices
# (s, midi, beats, vel) -> signal. The instruments are memoised in instruments.py.

def v_epiano(s, m, d, v=0.7, bright=0.9, rel=0.3):
    return ins.epiano(m, s.sec(d), s.sr, vel=v, bright=bright, release=rel)


def v_piano(s, m, d, v=0.7, bright=0.6, rel=0.2):
    return ins.piano(m, s.sec(d), s.sr, vel=v, bright=bright, release=rel)


def v_nylon(s, m, d, v=0.7):
    return ins.guitar(m, s.sec(d), s.sr, bright=0.3, t60=1.6, pick=0.22, mute=0.1, key=m % 3, attack=0.004) * v


def v_vibes(s, m, d, v=0.6, trem=4.8):
    return ins.vibes(m, s.sr, vel=v, dur=max(1.0, s.sec(d) + 0.5), trem=trem, release=s.sec(d))


def v_marimba(s, m, d, v=0.7):
    return ins.marimba(m, s.sr, vel=v, dur=max(0.5, s.sec(d)))


def v_celesta(s, m, d, v=0.6, t60=0.8):
    return ins.glock(m, s.sr, vel=v, dur=max(0.8, s.sec(d) + 0.4), octave_up=False, t60_scale=t60)


def v_steel(s, m, d, v=0.8):
    """Steel pan: a marimba-like body with a strong octave 'bloom' and a short ring."""
    return ins.marimba(m, s.sr, vel=v, dur=max(0.4, min(s.sec(d), 1.0)), pan_sheen=0.7)


def v_organ(s, m, d, v=1.0, bars=(8, 6, 8, 6, 0, 4, 0, 0, 0), perc=0.2, att=0.01, rel=0.06):
    return ins.organ(m, s.sec(d), s.sr, bars=bars, perc=perc, click=0.2, attack=att, release=rel) * v


def v_brass(s, m, d, v=0.8, k=0):
    return ins.brass(m, s.sec(d), s.sr, vel=v, key=k)


def v_super(s, m, d, v=1.0, att=0.01, rel=0.15, k=0):
    return ins.supersaw(m, s.sec(d), s.sr, attack=att, release=rel, key=k) * v


def v_pluck(s, m, d, v=1.0, cutoff=3500.0, decay=0.1):
    return ins.pluck_synth(m, s.sr, dur=max(0.12, min(s.sec(d), 0.5)), cutoff=cutoff, decay=decay) * v


def v_pad(s, m, d, v=1.0, cutoff=1800.0, att=0.5, rel=0.9, k=0):
    return M.pad_note(m, s.sec(d), s.sr, cutoff=cutoff, attack=att, release=rel, key=k) * v


def v_strings(s, m, d, v=1.0, k=0):
    return M.string_note(m, s.sec(d), s.sr, key=k) * v


def v_upright(s, m, d, v=0.8, k=0):
    return M.upright(m, s.sec(d), s.sr, key=k) * v


def v_sub(s, m, d, v=0.8):
    return M.sub_note(m, s.sec(d), s.sr) * v


def v_sbass(s, m, d, v=0.8, cutoff=1400.0, decay=0.09):
    return M.synth_bass(m, s.sec(d), s.sr, cutoff=cutoff, decay=decay) * v


def v_gbass(s, m, d, v=0.8, bright=0.5, mute=0.05, k=0):
    return ins.guitar(m, s.sec(d), s.sr, bright=bright, t60=1.5, pick=0.1, mute=mute, key=k, damp=0.45) * v


def v_chip(s, m, d, v=0.7, duty=0.5, vib=0.0, dec=0.18, key=0):
    """8-bit voice: a pulse wave under a quick decay, optional slow vibrato."""
    n = nsamp(s.sec(d) + 0.03, s.sr)
    t = np.arange(n) / s.sr
    f = midi_hz(m) * (1.0 + vib * 0.006 * np.sin(TAU * 5.5 * t))
    x = dsp.pulse(f, n, s.sr, duty)
    x = x * (0.55 + 0.45 * np.exp(-t / dec)) * dsp.env_adsr(n, s.sr, 0.003, 0.2, 0.85, s.sec(d), 0.02)
    return dsp.fade(x, s.sr, 0.001, 0.008) * v


def v_tri(s, m, d, v=0.8):
    n = nsamp(s.sec(d) + 0.03, s.sr)
    x = dsp.triangle(midi_hz(m), n, s.sr) * dsp.env_adsr(n, s.sr, 0.004, 0.2, 0.9, s.sec(d), 0.025)
    return dsp.fade(x, s.sr, 0.001, 0.008) * v


def v_strum(s, notes, d, v=0.8, up=False, spread=0.010, bright=0.5, t60=1.3, mute=0.06, key=0):
    return ins.strum(notes, s.sec(d), s.sr, spread=spread, up=up, bright=bright, t60=t60, pick=0.13, mute=mute,
                     key=key, damp=0.4) * v


# ------------------------------------------------------------ part builders

def lay(s, voice, events_, gain=1.0, swing=0.0, grid=0.25, jit=0.0, r=None, mask=None, dt=0.0):
    """Places a voice on every event (beat, beats, midi, vel) of a tune; returns the loop buffer."""
    buf = s.zeros()
    for e in events_:
        beat, d, m, v = e[:4]
        if mask is not None and int(beat // 4) % s.bars not in mask:
            continue
        b = sw(beat, swing, grid) if swing else beat
        j = float(r.normal(0, jit)) if (r is not None and jit) else 0.0
        s.add(buf, voice(s, m, d, v), b, gain, dt=dt + j)
    return buf


def comp(s, chords, voices_, rhythm, voice, gain=1.0, swing=0.0, spread=0.0, r=None, jit=0.004, mask=None, grid=0.25):
    """Chord comping: rhythm = [(beat in chord, beats, vel)] or fn(chord, index) -> that list. Every voiced
    note goes through voice(s, midi, beats, vel); `spread` strums the notes (seconds apart)."""
    buf = s.zeros()
    for i, c in enumerate(chords):
        pat = rhythm(c, i) if callable(rhythm) else rhythm
        for bt, du, v in pat:
            beat = c.start + bt
            if mask is not None and int(beat // 4) % s.bars not in mask:
                continue
            b = sw(beat, swing, grid) if swing else beat
            for j, m in enumerate(voices_[i]):
                x = voice(s, m, du, v)
                s.add(buf, x, b, gain, dt=j * spread + (float(r.normal(0, jit)) if r is not None else 0.0))
    return buf


def line(s, chords, fn, voice, gain=1.0, swing=0.0, r=None, jit=0.004, mask=None, grid=0.25):
    """Bass line: fn(chord, next_chord, index) -> [(beat in chord, beats, midi, vel)]; a negative or 0 duration
    runs to the next note. voice(s, midi, beats, vel)."""
    buf = s.zeros()
    for i, c in enumerate(chords):
        nxt = chords[(i + 1) % len(chords)]
        for bt, du, m, v in fn(c, nxt, i):
            beat = c.start + bt
            if mask is not None and int(beat // 4) % s.bars not in mask:
                continue
            b = sw(beat, swing, grid) if swing else beat
            s.add(buf, voice(s, m, du, v), b, gain, dt=(float(r.normal(0, jit)) if r is not None else 0.0))
    return buf


def root_of(c, center, lo, hi):
    return nearest(c.root, center, lo, hi)


def scale_step(tonic, midi, up):
    """The nearest note of the major scale of `tonic` above (up) or below `midi` (a diatonic approach note)."""
    pcs = {(tonic + i) % 12 for i in MAJOR}
    m = midi + (1 if up else -1)
    while m % 12 not in pcs:
        m += 1 if up else -1
    return m


def walk(s, lo=33, hi=52, start=None, seed="walk"):
    """A walking bass over s.chords, one note per beat: root, chord tones, a diatonic step into the next chord.
    Returns [(beat, midi, vel)] (a chord of 2 beats gets 2 notes)."""
    r = dsp.rng(s.id, seed)
    out = []
    prev = start if start is not None else root_of(s.chords[0], 38, lo, hi)
    for i, c in enumerate(s.chords):
        nxt = s.chords[(i + 1) % len(s.chords)]
        third = 3 if 3 in c.tones else 4
        n = int(c.dur)
        tones = [0, third, 7, 12]
        notes = []
        for k in range(n):
            if k == 0:
                pc = c.root
            elif k == n - 1:
                tgt = nearest(nxt.root, prev, lo, hi)
                notes.append(scale_step(s.tonic, tgt, up=bool(int(r.integers(2))) and tgt + 2 <= hi))
                prev = notes[-1]
                continue
            else:
                pc = (c.root + tones[(k * 2 + int(r.integers(2))) % 4]) % 12
            notes.append(nearest(pc, prev, lo, hi))
            prev = notes[-1]
        for k, m in enumerate(notes):
            out.append((c.start + k, m, 0.85 if k % 2 == 0 else 0.72))
    return out


def v_vox(s, m, d, v=0.8, vowel="a_alto", key=0, burst=True):
    """A sung or scatted syllable: a glottal saw through vowel formants, a little consonant burst at the start."""
    def mk():
        n = nsamp(s.sec(d) + 0.1, s.sr)
        t = np.arange(n) / s.sr
        r = dsp.rng("vox", m, vowel, key)
        f = midi_hz(m) * (1 + 0.004 * np.sin(TAU * 5.3 * t + r.uniform(0, 6))) * (1 - 0.05 * np.exp(-t / 0.025))
        src = dsp.saw(f, n, s.sr) + 0.1 * r.standard_normal(n)
        x = dsp.formant(src, s.sr, dsp.VOWELS[vowel]) * dsp.env_adsr(n, s.sr, 0.012, 0.18, 0.7, s.sec(d), 0.05)
        if burst:
            nb = nsamp(0.018, s.sr)
            x[:nb] += 0.35 * dsp.highpass(r.standard_normal(nb), 1800, s.sr, 2) * np.exp(-np.arange(nb) / (0.005 * s.sr))
        return dsp.fade(x / (dsp.peak(x) + 1e-9), s.sr, 0.002, 0.02)
    return M.cached(("vox", m, round(s.sec(d), 3), s.sr, vowel, key, burst), mk) * v


def v_accordion(s, m, d, v=0.8):
    """Musette reeds: two detuned narrow pulses and a saw an octave up, through a reedy EQ."""
    def mk():
        n = nsamp(s.sec(d) + 0.06, s.sr)
        f = midi_hz(m)
        x = dsp.pulse(f * 2 ** (7 / 1200), n, s.sr, 0.3) + dsp.pulse(f * 2 ** (-7 / 1200), n, s.sr, 0.3, 0.2)
        x += 0.35 * dsp.saw(f * 2, n, s.sr, 0.5)
        x = dsp.lowpass(x, 4200, s.sr, 2)
        x = dsp.filt(x, "peak", 1100, s.sr, q=1.2, gain_db=4.0)
        x *= dsp.env_adsr(n, s.sr, 0.018, 0.2, 0.9, s.sec(d), 0.04)
        return dsp.fade(x / (dsp.peak(x) + 1e-9), s.sr, 0.002, 0.012)
    return M.cached(("acc", m, round(s.sec(d), 3), s.sr), mk) * v


def v_quack(s, m=62, d=0.2, v=0.8):
    """A cartoon duck: a nasal vowel with a falling pitch."""
    def mk():
        n = nsamp(0.22, s.sr)
        t = np.arange(n) / s.sr
        f = midi_hz(m) * (1.35 - 0.5 * np.clip(t / 0.2, 0, 1)) * (1 + 0.02 * np.sin(TAU * 38 * t))
        src = dsp.saw(f, n, s.sr) + 0.2 * dsp.rng("quack", m).standard_normal(n)
        x = dsp.formant(src, s.sr, dsp.VOWELS["a_alto"]) + 0.6 * dsp.formant(src, s.sr, dsp.VOWELS["e_open"])
        x *= dsp.env_adsr(n, s.sr, 0.008, 0.1, 0.5, 0.12, 0.08)
        return dsp.fade(x / (dsp.peak(x) + 1e-9), s.sr, 0.002, 0.03)
    return M.cached(("quack", m, s.sr), mk) * v


def v_tremolo(s, m, d, v=0.8, rate=0.125, bright=0.75):
    """Tremolo picking: the same string plucked every `rate` beats for the length of the note."""
    n_notes = max(1, int(round(d / rate)))
    out = np.zeros(nsamp(s.sec(d) + 0.5, s.sr))
    for i in range(n_notes):
        x = ins.guitar(m, s.sec(rate * 1.4), s.sr, bright=bright, t60=0.45, pick=0.1, mute=0.03, key=i % 2, damp=0.4)
        p = nsamp(s.sec(i * rate), s.sr)
        out[p: p + len(x)] += x[: len(out) - p] * (1.0 if i % 2 == 0 else 0.8)
    return out * v


def riser(s, beats=8, level=1.0, seed="riser"):
    """A noise riser that ends exactly at the loop point (the last `beats` beats)."""
    r = dsp.rng(s.id, seed)
    L = nsamp(s.sec(beats), s.sr)
    t = np.arange(L) / L
    x = dsp.sweep_filter(r.standard_normal(L), 300.0 * (7000.0 / 300.0) ** (t ** 1.5), s.sr, q=2.5, kind="bp")
    x *= t ** 2.2
    buf = s.zeros()
    s.add(buf, dsp.fade(x / dsp.peak(x), s.sr, 0.01, 0.004), s.beats - beats, level)
    return buf


def impact(s, midi=33, level=1.0, seed="impact"):
    """A sub boom on the downbeat of bar 1 that settles on `midi`."""
    r = dsp.rng(s.id, seed)
    n = nsamp(1.6, s.sr)
    tt = np.arange(n) / s.sr
    f0 = float(midi_hz(midi))
    boom = np.sin(TAU * np.cumsum(f0 * (1 + 0.9 * np.exp(-tt / 0.08))) / s.sr) * dsp.env_perc(n, s.sr, 1.3, 0.001)
    boom = dsp.highpass(boom, 40, s.sr, 4)
    boom += 0.3 * dsp.bandpass(r.standard_normal(n), 300, 3000, s.sr) * np.exp(-tt / 0.15)
    buf = s.zeros()
    s.add(buf, dsp.fade(dsp.drive(boom / dsp.peak(boom), 1.5), s.sr, 0.001, 0.2), 0, level)
    return buf


def gang(s, spots, voices=7, lo=105, hi=190, key="gang", level=1.0):
    """'Hey!' shouts of a crowd at (bar0, beat) spots."""
    buf = s.zeros()
    for i, (bar, bt) in enumerate(spots):
        s.add(buf, ins.crowd_hey(s.sr, f"{s.id}/{key}{i}", voices=voices, f_lo=lo, f_hi=hi), bar * 4 + bt, level,
              dt=-0.03)
    return buf


# ---------------------------------------------------------- lead voices

def mono(s, evs, kind="sax", swing=0.0, key="mono", grid=0.5, drive=9.0):
    """A legato single-note instrument over a tune [(beat, beats, midi, vel)] (loop-safe, wraps its tail)."""
    ev = [(sw(b, swing, grid) if swing else b, d, m, v) for b, d, m, v in evs]
    e = events(s, ev)
    if kind == "sax":
        src, env, onset = render_line(s, e, osc="saw", glide=0.02, legato_gap=0.01, attack=0.035, release=0.07,
                                      vib_rate=5.0, vib_depth=0.16, vib_delay=0.22, key=key)
        x = src * env
        x = dsp.sweep_filter(x, 700.0 + 2600.0 * np.clip(env, 0, 1), s.sr, q=0.8)
        x = dsp.filt(x, "peak", 520, s.sr, q=1.0, gain_db=4.0)
        x = dsp.filt(x, "peak", 1500, s.sr, q=1.4, gain_db=3.0)
        x = dsp.highpass(x, 140, s.sr, 2)
        x += 0.12 * ins.breath(len(x), s.sr, key, 1500, 5000) * env
        x = dsp.tube(x / (dsp.peak(x) + 1e-9), 1.3, s.sr, 0.1)
    elif kind == "trumpet":
        src, env, _ = render_line(s, e, osc="saw", glide=0.01, legato_gap=0.005, attack=0.02, release=0.06,
                                  vib_rate=5.6, vib_depth=0.08, vib_delay=0.2, scoop=0.3, key=key)
        x = src * env
        x = dsp.highpass(x, 550, s.sr, 2)
        x = dsp.filt(x, "peak", 1800, s.sr, q=1.6, gain_db=10.0)
        x = dsp.filt(x, "peak", 3200, s.sr, q=2.0, gain_db=4.0)
        x = dsp.lowpass(x, 5000, s.sr, 2)
    elif kind == "clarinet":
        src, env, _ = render_line(s, e, osc="pulse", pw=0.5, glide=0.008, legato_gap=0.004, attack=0.025,
                                  release=0.05, vib_rate=5.5, vib_depth=0.06, vib_delay=0.3, key=key)
        x = src * env
        x = dsp.sweep_filter(x, 900.0 + 2400.0 * np.clip(env, 0, 1), s.sr, q=0.7)
        x = dsp.filt(x, "peak", 1500, s.sr, q=1.0, gain_db=2.0)
        x += 0.06 * ins.breath(len(x), s.sr, key, 1800, 6000) * env
    elif kind == "flute":  # a pure tone with a breathy edge
        src, env, _ = render_line(s, e, osc="sine", glide=0.02, legato_gap=0.01, attack=0.05, release=0.08,
                                  vib_rate=5.2, vib_depth=0.12, vib_delay=0.25, key=key)
        x = src * env + 0.22 * ins.breath(len(src), s.sr, key, 2000, 6500) * env
        x = dsp.highpass(x, 250, s.sr, 2)
    elif kind == "piccolo":
        src, env, _ = render_line(s, e, osc="tri", glide=0.006, legato_gap=0.004, attack=0.012, release=0.03,
                                  vib_rate=5.8, vib_depth=0.05, vib_delay=0.15, key=key)
        x = src * env + 0.12 * ins.breath(len(src), s.sr, key, 2500, 7000) * env
        x = dsp.highpass(x, 500, s.sr, 2)
    elif kind == "lead":  # bright synth lead
        src, env, onset = render_line(s, e, osc="saw", detune=9.0, glide=0.02, legato_gap=0.004, attack=0.01,
                                      release=0.08, vib_rate=5.8, vib_depth=0.12, vib_delay=0.15, key=key)
        x = src * env
        x = dsp.sweep_filter(x, 1800.0 + 2500.0 * onset, s.sr, q=1.0)
        x = dsp.drive(x / (dsp.peak(x) + 1e-9) * 1.2, 1.3)
    elif kind == "bell":  # a soft sine lead (a singing, glassy tone)
        src, env, onset = render_line(s, e, osc="sine", glide=0.015, legato_gap=0.004, attack=0.02, release=0.12,
                                      vib_rate=5.4, vib_depth=0.18, vib_delay=0.3, key=key)
        x = src * env
    elif kind == "tuba":
        src, env, onset = render_line(s, e, osc="saw", glide=0.012, attack=0.012, release=0.05, vib_depth=0.0,
                                      key=key, legato_gap=0.0)
        x = src * env
        x = dsp.sweep_filter(x, 220.0 + 1300.0 * onset + 400.0 * env, s.sr, q=0.9)
        x = dsp.tube(x / (dsp.peak(x) + 1e-9) * 1.4, 1.6, s.sr, 0.1)
        x = dsp.filt(x, "peak", 400, s.sr, q=0.8, gain_db=3.0)
    elif kind == "guitar":  # distorted lead guitar
        src, env, onset = render_line(s, e, osc="saw", glide=0.006, legato_gap=0.004, attack=0.003, release=0.045,
                                      vib_rate=5.6, vib_depth=0.22, vib_delay=0.28, key=key)
        x = src * (env * (0.55 + 0.45 * np.clip(onset, 0, 1)))
        x = dsp.highpass(x, 250, s.sr, 2)
        x = ins.amp_sim(x / (dsp.peak(x) + 1e-9), s.sr, gain=drive, tone=4200, key_hz=1600)
        x = dsp.highpass(x, 140, s.sr, 2)
    else:
        raise ValueError(kind)
    return wrap(s, x / (dsp.peak(x) + 1e-9))


# ------------------------------------------------------------- extra kits

def pent_hz(f, tonic):
    """The frequency of the major-pentatonic note of `tonic` (degrees 1 2 3 5 6) nearest to f: pitched
    percussion is tuned to the key, so a tom or a bell never fights the harmony (or the match notes)."""
    pcs = {(tonic + i) % 12 for i in (0, 2, 4, 7, 9)}
    m0 = 69.0 + 12.0 * float(np.log2(f / 440.0))
    best = min((m for m in range(int(m0) - 7, int(m0) + 8) if m % 12 in pcs), key=lambda m: abs(m - m0))
    return float(midi_hz(best))


def kit2(name, sr, tonic=0):
    """Extra drum sets (cached): chip (8-bit), latin (samba / calypso percussion), march. Pitched parts are
    tuned to the pentatonic of `tonic`."""
    key = ("kit2", name, sr, tonic)
    if key in M._CACHE:
        return M._CACHE[key]
    k = {}
    p = lambda f: pent_hz(f, tonic)  # noqa: E731
    if name == "chip":
        def pitched(f0, f1, tau, t60, key_):
            n = nsamp(t60, sr)
            t = np.arange(n) / sr
            f = f1 + (f0 - f1) * np.exp(-t / tau)
            x = dsp.pulse(np.maximum(f, 20.0), n, sr, 0.5) * np.exp(-t / (t60 * 0.28))
            return dsp.fade(x, sr, 0.0005, 0.01)

        def noise(t60, lo, hi, key_, tone=0.0, f=180.0):
            n = nsamp(t60, sr)
            t = np.arange(n) / sr
            x = dsp.bandpass(dsp.rng("chipnoise", key_).standard_normal(n), lo, min(hi, 0.45 * sr), sr)
            x = np.round(x * 3.0) / 3.0  # 2-bit crunch
            x = x * np.exp(-t / (t60 * 0.3))
            if tone:
                x = x + tone * dsp.pulse(p(f) * (1 + 0.8 * np.exp(-t / 0.02)), n, sr, 0.25) * np.exp(-t / (t60 * 0.4))
            return dsp.fade(x, sr, 0.0005, 0.008)
        k["kick"] = [pitched(160, p(46), 0.03, 0.16, 0)]
        k["snare"] = [noise(0.13, 900, 6000, 1, tone=0.5), noise(0.12, 1200, 7000, 2, tone=0.5)]
        k["hat"] = [noise(0.035, 5000, 10000, 3), noise(0.03, 5500, 10000, 4)]
        k["ohat"] = [noise(0.16, 4500, 10000, 5) * 0.7]
        k["crash"] = [noise(0.7, 2500, 10000, 6) * 0.6]
    elif name == "latin":
        k["surdo"] = [ins.tom(sr, p(68), 0.7, key=1)]
        k["surdo_hi"] = [ins.tom(sr, p(90), 0.35, key=2)]
        k["conga_hi"] = [ins.tom(sr, p(250), 0.22, key=3), ins.tom(sr, p(250), 0.2, key=4)]
        k["conga_lo"] = [ins.tom(sr, p(175), 0.3, key=5), ins.tom(sr, p(175), 0.28, key=6)]
        k["bongo_hi"] = [ins.tom(sr, p(410), 0.16, key=7), ins.tom(sr, p(410), 0.15, key=8)]
        k["bongo_lo"] = [ins.tom(sr, p(300), 0.2, key=9), ins.tom(sr, p(300), 0.18, key=10)]
        k["tamborim"] = [ins.rim(sr, key=i, f=p(2300)) * 1.2 for i in range(3)]
        k["clave"] = [ins.woodblock(sr, f=p(2100), key=i, t=0.09) for i in range(2)]
        k["agogo_hi"] = [ins.cowbell(sr, key=1, f1=p(1175.0), f2=p(1760.0), t60=0.3)]
        k["agogo_lo"] = [ins.cowbell(sr, key=2, f1=p(880.0), f2=p(1318.0), t60=0.3)]
        k["shaker"] = [ins.shaker(sr, key=i) for i in range(3)]
        k["cabasa"] = [ins.shaker(sr, key=10 + i, dur=0.06, accent=0.9) for i in range(3)]
        k["rim"] = [ins.rim(sr, key=i, f=p(1750)) for i in range(2)]
        k["guiro"] = [guiro(sr, key=i) for i in range(2)]
        k["bell"] = [ins.cowbell(sr, key=3, f1=p(700.0), f2=p(1050.0), t60=0.5)]
    elif name == "march":
        k["snare"] = [ins.snare(sr, p(230), 0.07, 0.15, 1.0, 2000, 9000, key=200 + i) for i in range(4)]
        k["rim"] = [ins.rim(sr, key=20 + i, f=p(1900)) for i in range(2)]
        k["bass"] = [ins.kick(sr, 80, p(50), 0.05, 0.45, 0.2, 1.4, key=30 + i) for i in range(2)]
        k["cym"] = [ins.crash(sr, key=31, t60=1.1) * 0.7]
        k["crash"] = [ins.crash(sr, key=32, t60=2.0)]
        k["wood"] = [ins.woodblock(sr, f=p(1400), key=i) for i in range(2)]
    for v in k.values():
        for a in v:
            a.setflags(write=False)
    M._CACHE[key] = k
    return k


def guiro(sr, key=0, dur=0.22):
    """A scraped gourd: noise scratched at ~25 strokes per second."""
    n = nsamp(dur, sr)
    t = np.arange(n) / sr
    x = dsp.bandpass(dsp.rng("guiro", key).standard_normal(n), 2500, min(8000, 0.44 * sr), sr)
    x *= (0.55 + 0.45 * np.sin(TAU * 26 * t)) * np.sin(np.pi * np.clip(t / dur, 0, 1)) ** 0.7
    return dsp.fade(x, sr, 0.003, 0.02)


def kits(s, *names):
    """Union of drum kits for song s (later names win): the district kits of music.py and kit2's."""
    out = {}
    for n in names:
        out.update(kit2(n, s.sr, s.tonic) if n in ("chip", "latin", "march") else kit(n, s.sr))
    return out


# ------------------------------------------------------------ texture parts

def rain(s, level=1.0, seed="rain"):
    """Steady rain: band-passed noise with slow gusts (loop-safe)."""
    r = dsp.rng(s.id, seed)
    nz = r.standard_normal(s.n)
    x = dsp.loop_apply(nz, lambda z: dsp.bandpass(z, 2500, 9500, s.sr))
    x2 = dsp.loop_apply(r.standard_normal(s.n), lambda z: dsp.lowpass(z, 700, s.sr, 2)) * 0.5
    gust = 1.0 + 0.25 * s.lfo(0.19) + 0.12 * s.lfo(0.41, 0.3)
    return (x / np.std(x) + x2 / np.std(x2)) * gust * level


def soften(x, hz=7000.0, s=None, sr=None):
    return dsp.lowpass(x, hz, sr or s.sr, 1)


# =================================================================== CAFE (F)

def rainy_window(s):
    """72 BPM rainy-day lo-fi: warm e-piano with tape wow, a soft kit, a few celesta drops, rain and dust."""
    r = dsp.rng(s.id, "rain")
    t = s.tonic
    ch = s.chords
    k = kits(s, "lofi")
    # drums: lazy boom-bap, snare ghost notes, fill into the loop point
    d = s.zeros()
    hits(s, d, k["kick"], "X.....g...x.....", r, swing=0.4, gain=0.9)
    hits(s, d, k["snare"], ["....X.......X...", "....X.......X..g"], r, swing=0.4, gain=0.75)
    hits(s, d, k["hat"], "x.o.x.o.x.o.x.o.", r, swing=0.4, gain=0.55)
    hits(s, d, k["shaker"], "o.g.o.g.o.g.o.g.", r, swing=0.4, gain=0.5)
    hits(s, d, k["rim"], {7: "............g.og"}, r, gain=0.6)
    d = loop_eq(s, dsp.drive(d / dsp.peak(d) * 1.1, 1.2), "highshelf", 4500, 2.0)
    d = room(s, d, 0.12, 0.7, "drums", damp=6000)
    # e-piano: long chords, a late second hit on some bars, tape wow
    vo = voicing(ch, 55, 77, 66, no_root)
    rhy = lambda c, i: [(0, 3.7, 0.55), (2.5, 1.2, 0.4)] if i in (1, 5, 8) else [(0, 3.7 if c.dur > 2 else 1.8, 0.55)]
    keys = comp(s, ch, vo, rhy, v_epiano, spread=0.016, r=r, swing=0.4)
    keys = tape(s, loop_filter(s, keys, "hp", 90), 6.0, 0.4, 1.0)
    keys = room(s, dsp.drive(keys / dsp.peak(keys), 1.15), 0.22, 1.5, "keys", damp=5000)
    # bass: warm sub, root + an octave pickup
    bass = line(s, ch, lambda c, n, i: [(0, 2.6, root_of(c, 38, 33, 45), 0.9), (3.0, 0.8, root_of(c, 38, 33, 45) + 7, 0.6)]
                if c.dur > 2 else [(0, 1.8, root_of(c, 38, 33, 45), 0.9)], v_sub, r=r)
    bass = loop_filter(s, bass, "lp", 700)
    # celesta drops: a pentatonic motif that answers the chords from bar 3 on
    tn = tune("r:4 | r:4 | 5:1 3:.5 2:.5 1:2 | r:4 | 5:1 6:.5 5:.5 3:2 | r:4 | 3:.5 5:.5 6:1 5:1 3:1 | r:4", t, 5)
    cel = lay(s, v_celesta, tn, r=r, jit=0.004, swing=0.4)
    cel = room(s, echo(s, cel, 0.75, 0.3, 0.4, 3, 5000), 0.3, 1.6, "cel", damp=6000)
    # weather
    rn = rain(s, 1.0)
    dust = M.vinyl_crackle(s)
    return {"drums": d, "keys": keys, "bass": bass, "celesta": cel, "rain": rn, "dust": dust}


def pancake_sunday(s):
    """84 BPM brunch lo-fi: bouncy boom-bap, nylon guitar offbeats, a vibraphone tune, a walking bass."""
    r = dsp.rng(s.id, "pancake")
    t = s.tonic
    ch = s.chords
    k = kits(s, "lofi")
    d = s.zeros()
    hits(s, d, k["kick"], ["X.....x..x.o....", "X.....x...x..g.."], r, swing=0.45)
    hits(s, d, k["snare"], "....X.......X..g", r, swing=0.45, gain=0.9)
    hits(s, d, k["clap"], "....o.......o...", r, gain=0.5)
    hits(s, d, k["hat"], "x.o.x.o.x.o.x.ox", r, swing=0.45, gain=0.6)
    hits(s, d, k["ohat"], {3: "..............x.", 7: "......x.......x."}, r, gain=0.5)
    hits(s, d, k["shaker"], "ogogogogogogogog", r, swing=0.45, gain=0.45)
    d = loop_eq(s, dsp.drive(d / dsp.peak(d) * 1.2, 1.3), "highshelf", 5000, 2.5)
    d = room(s, d, 0.1, 0.6, "drums", damp=8000)
    vo = voicing(ch, 57, 76, 66, no_root)
    gtr = s.zeros()
    for i, c in enumerate(ch):
        for bt, du, v, up in ((0.5, 0.35, 0.8, False), (1.5, 0.35, 0.7, True), (2.5, 0.35, 0.8, False),
                              (3.25, 0.3, 0.6, True)):
            x = v_strum(s, vo[i], du, v, up=up, spread=0.011, bright=0.4, t60=1.0, mute=0.07, key=i % 3)
            s.add(gtr, x, sw(c.start + bt, 0.45), 1.0, dt=float(r.normal(0.004, 0.003)))
    gtr = room(s, loop_eq(s, loop_filter(s, gtr, "hp", 140), "peak", 2400, 2.0, 0.9), 0.15, 0.9, "gtr", damp=5000)

    def walk(c, n, i):
        R = root_of(c, 40, 33, 47)
        fifth = R + 7 if R + 7 <= 50 else R - 5
        nxt = root_of(n, R, 33, 47)
        return [(0, 0.9, R, 0.9), (1.0, 0.45, fifth, 0.7), (1.5, 0.45, R + 12 if R + 12 < 52 else R, 0.65),
                (2.0, 0.9, fifth, 0.8), (3.0, 0.45, nxt - 2 if nxt - 2 != R else nxt + 2, 0.7), (3.5, 0.45, nxt - 1, 0.7)]
    bass = line(s, ch, walk, v_upright, r=r, swing=0.45)
    bass = room(s, loop_filter(s, bass, "lp", 1100), 0.06, 0.6, "bass", damp=2500)
    tn = tune("r:2 3:.5 5:.5 6:1 | 5:.5 3:.5 2:1 1:2 | r:2 3:.5 5:.5 6:1 | 1+:1 7:.5 6:.5 5:2 |"
              " 6:1 5:.5 6:.5 1+:1.5 6:.5 | 5:.5 3:.5 5:1 2:2 | 3:1 2:.5 3:.5 5:1 6:1 | 5:3 r:1", t, 5)
    vib = lay(s, v_vibes, tn, r=r, jit=0.004, swing=0.45)
    vib = room(s, echo(s, vib, 0.75, 0.2, 0.35, 3, 4500), 0.22, 1.4, "vib", damp=6000)
    dust = M.vinyl_crackle(s)
    return {"drums": d, "guitar": gtr, "bass": bass, "vibes": vib, "dust": dust}


def pixel_cafe(s):
    """98 BPM chiptune lo-fi: pulse-wave arpeggios, a triangle bass, 8-bit drums with a swung pulse."""
    r = dsp.rng(s.id, "pixel")
    t = s.tonic
    ch = s.chords
    k = kits(s, "chip")
    d = s.zeros()
    hits(s, d, k["kick"], ["X.......X.x.....", "X.....x.X......."], r, swing=0.2, jit=0.0)
    hits(s, d, k["snare"], "....X.......X...", r, swing=0.2, jit=0.0)
    hits(s, d, k["hat"], "x.xoxoxox.xoxoxo", r, swing=0.2, gain=0.8, jit=0.0)
    hits(s, d, k["ohat"], {7: "..............x."}, r, gain=0.8, jit=0.0)
    hits(s, d, k["crash"], {0: "X...............", 4: "X..............."}, r, gain=0.6, jit=0.0)
    d = room(s, d, 0.08, 0.5, "drums", damp=7000)
    arp = s.zeros()
    for i, c in enumerate(ch):
        tones = chord_notes(c, 72, 91)[:4]
        seq = [tones[0], tones[1], tones[2], tones[1], tones[3 % len(tones)], tones[2], tones[1], tones[0]]
        for q in range(int(c.dur * 4)):
            m = seq[q % len(seq)]
            s.add(arp, v_chip(s, m, 0.22, 0.6 if q % 4 else 0.8, duty=0.25, dec=0.1), sw(c.start + q * 0.25, 0.2), 1.0)
    arp = room(s, echo(s, arp, 0.75, 0.22, 0.4, 3, 6000), 0.12, 0.8, "arp", damp=8000)
    bass = line(s, ch, lambda c, n, i: [(q * 0.5, 0.45, root_of(c, 41, 36, 48) + (12 if q in (3, 6) else 0), 0.9)
                                       for q in range(int(c.dur * 2))], v_tri, r=r, swing=0.2)
    tn = tune("r:4 | r:4 | 5:.5 5:.5 6:.5 5:.5 3:1 2:1 | 3:1 2:.5 1:.5 2:2 |"
              " 5:.5 5:.5 6:.5 1+:.5 6:1 5:1 | 3:.5 2:.5 3:.5 5:.5 2:2 | 5:.5 6:.5 1+:1 6:.5 5:.5 3:1 | 2:1 3:1 1:2", t, 5)
    lead = lay(s, lambda ss, m, du, v: v_chip(ss, m + 12, du, v, duty=0.5, vib=1.0, dec=0.5), tn, r=r, swing=0.2)
    lead = room(s, echo(s, lead, 0.5, 0.2, 0.35, 3, 6000), 0.12, 0.8, "lead", damp=8000)
    return {"drums": d, "arp": arp, "bass": bass, "lead": lead}


def sleepy_cat(s):
    """68 BPM lullaby: a music box tune, soft string pad, a purring sub and a slow heartbeat."""
    r = dsp.rng(s.id, "cat")
    t = s.tonic
    ch = s.chords
    vo = voicing(ch, 52, 70, 60, no_root)
    pad = s.zeros()
    for c, v in zip(ch, vo):
        for j, m in enumerate(v):
            s.add(pad, v_pad(s, m, c.dur * s.bs, 1.0, cutoff=1600, att=0.8, rel=1.0, k=j), c.start - 0.1)
    pad = room(s, tape(s, loop_filter(s, pad, "lp", 4500), 7.0, 0.3, 1.0), 0.3, 2.0, "pad", damp=4000)
    bass = line(s, ch, lambda c, n, i: [(0, 3.4, root_of(c, 38, 33, 44), 0.9)], v_sub, r=r)
    bass = loop_filter(s, bass, "lp", 500)
    hb = s.zeros()
    k = kits(s, "lofi")
    hits(s, hb, k["kick"], "X.......o.......", r, gain=0.5, jit=0.004)
    hits(s, hb, k["shaker"], "..o...o...o...o.", r, gain=0.35)
    hb = loop_filter(s, room(s, hb, 0.2, 1.2, "hb", damp=3000), "lp", 3500)
    tn = tune("5:1 3:1 5:1 3:1 | 5:1 3:.5 2:.5 1:2 | 4:1 2:1 4:1 2:1 | 5:1 2:.5 2:.5 5:2 |"
              " 5:1 3:1 5:1 3:1 | 6:1 5:.5 3:.5 5:2 | 6:1 4:1 6:1 4:1 | 5:3 r:1", t, 5)
    box = lay(s, lambda ss, m, du, v: v_celesta(ss, m, du, v * 0.9, t60=1.0), tn, r=r, jit=0.006)
    box = room(s, echo(s, box, 1.0, 0.25, 0.4, 3, 4500), 0.35, 2.2, "box", damp=5000)
    return {"box": box, "pad": pad, "bass": bass, "heart": hb}


def strum_comp(s, chords, voices_, rhythm, gain=1.0, swing=0.0, grid=0.25, r=None, jit=0.003, mask=None,
               bright=0.5, t60=1.2, mute=0.06, spread=0.010, alt=True):
    """Guitar strums: rhythm = [(beat in chord, beats, vel)] or fn(chord, i); down and up strokes alternate."""
    buf = s.zeros()
    k = 0
    for i, c in enumerate(chords):
        pat = rhythm(c, i) if callable(rhythm) else rhythm
        for bt, du, v in pat:
            beat = c.start + bt
            if mask is not None and int(beat // 4) % s.bars not in mask:
                continue
            x = v_strum(s, voices_[i], du, v, up=(k % 2 == 1) if alt else False, spread=spread, bright=bright,
                        t60=t60, mute=mute, key=k % 3)
            s.add(buf, x, sw(beat, swing, grid) if swing else beat, gain,
                  dt=float(r.normal(0, jit)) if r is not None else 0.0)
            k += 1
    return buf


def scat(s, evs, swing=0.33, grid=0.5, vowels=("u_alto", "i_tenor", "a_alto", "o_alto"), gain=1.0):
    """Syllables 'doo bee dah doh' sung on a tune."""
    buf = s.zeros()
    for i, (b, d, m, v) in enumerate(evs):
        s.add(buf, v_vox(s, m, min(d, 0.9), v, vowel=vowels[i % len(vowels)], key=i % 3), sw(b, swing, grid), gain)
    return buf


def pulse_steps(text, step=0.25):
    """'x.x.' -> [(beat, vel)] (X x o g as in hits)."""
    return [(i * step, GRID_VEL[ch]) for i, ch in enumerate(c for c in text if c not in " |") if ch in GRID_VEL]


# =================================================================== JAZZ (Bb)

def bossa_breeze(s):
    """112 BPM bossa nova: nylon guitar on the clave, cross-stick, shakers, a flute tune and soft vibes."""
    r = dsp.rng(s.id, "bossa")
    t = s.tonic
    ch = s.chords
    k = kits(s, "jazz", "latin")
    d = s.zeros()
    hits(s, d, k["feather"], "X.....x.X.....x.", r, gain=0.8)
    hits(s, d, k["rim"], ["x..x..x...x..x..", "..x..x...x..x..."], r, gain=0.7)
    hits(s, d, k["cabasa"], "x.o.x.o.x.o.x.o.", r, gain=0.55)
    hits(s, d, k["chick"], "....x.......x...", r, gain=0.4)
    d = room(s, d, 0.14, 0.9, "drums", damp=6000)
    vo = voicing(ch, 52, 72, 62, no_root)

    def clave(c, i):
        base = [(0, 0.9, 0.75), (1.5, 0.45, 0.62)]
        return base + ([(2.5, 0.45, 0.62), (3.5, 0.45, 0.62)] if c.dur >= 4 else [])
    gtr = strum_comp(s, ch, vo, clave, r=r, bright=0.3, t60=1.1, mute=0.1, spread=0.012)
    gtr = room(s, loop_eq(s, loop_filter(s, gtr, "hp", 130), "peak", 2200, 2.0, 0.9), 0.16, 1.0, "gtr", damp=5000)

    def bass(c, n, i):
        R = root_of(c, 40, 33, 47)
        F = R + 7 if R + 7 <= 50 else R - 5
        base = [(0, 1.4, R, 0.9), (1.5, 0.9, F, 0.75)]
        return base + ([(2.5, 0.9, R, 0.8), (3.5, 0.45, F, 0.6)] if c.dur >= 4 else [])
    bs_ = room(s, loop_filter(s, line(s, ch, bass, v_upright, r=r), "lp", 1200), 0.06, 0.6, "bass", damp=2500)
    tn = tune("r:.5 3:.5 5:1 3:.5 5:.5 7:1 | 6:1.5 4:.5 3:1 4:1 | 3:1 5:.5 7:.5 2+:2 | 1+:1.5 6:.5 5:1 3:1 |"
              " 4:.5 6:.5 1+:1 6:.5 4:.5 2:1 | 5:1 7:.5 2+:.5 4+:1.5 2+:.5 | 1+:1 7:.5 5:.5 3:1 5:1 | 2:1 4:1 5:1 7:1",
              t, 4)
    fl = mono(s, tn, "flute", key="flute")
    fl = room(s, echo(s, fl, 0.75, 0.15, 0.35, 2, 4000), 0.25, 1.4, "flute", damp=5000)
    vo2 = voicing(ch, 62, 82, 72, guide)
    vib = comp(s, ch, vo2, lambda c, i: [(0, 3.4 if c.dur >= 4 else 1.8, 0.5)], v_vibes, r=r)
    vib = room(s, vib, 0.25, 1.6, "vibes", damp=5000)
    return {"drums": d, "guitar": gtr, "bass": bs_, "lead": fl, "vibes": vib}


def moonlight_ballad(s):
    """66 BPM jazz ballad: brushes, an upright in two, rolling piano arpeggios, a singing sax and soft vibes."""
    r = dsp.rng(s.id, "moon")
    t = s.tonic
    ch = s.chords
    k = kits(s, "jazz")
    d = s.zeros()
    for bar in range(s.bars):
        for bt in range(4):
            s.add(d, ins.brush_swish(s.sr, s.sec(0.95), key=(bar * 4 + bt) % 5), bar * 4 + bt, 0.2)
    hits(s, d, k["tap"], "....x.......x...", r, gain=0.7)
    hits(s, d, k["feather"], "o...o...o...o...", r, gain=0.35)
    d = room(s, d, 0.16, 1.2, "brushes", damp=5500)
    bass = line(s, ch, lambda c, n, i: [(0, 1.8, root_of(c, 38, 33, 45), 0.85), (2, 1.8, root_of(c, 38, 33, 45) + 7, 0.7)]
                if c.dur >= 4 else [(0, 1.8, root_of(c, 38, 33, 45), 0.85)], v_upright, r=r)
    bass = room(s, loop_filter(s, bass, "lp", 1000), 0.08, 0.8, "bass", damp=2500)
    vo = voicing(ch, 53, 76, 64, no_root, span=14)
    pno = s.zeros()
    seq = [0, 1, 2, 3, 2, 1, 2, 3]
    for i, c in enumerate(ch):
        v = vo[i]
        for q in range(int(c.dur * 2)):
            m = v[seq[q % 8] % len(v)]
            s.add(pno, v_piano(s, m, 1.6, 0.5 if q % 2 else 0.6), sw(c.start + q * 0.5, 0.2, 0.5), 1.0,
                  dt=float(r.normal(0, 0.004)))
    pno = room(s, loop_eq(s, pno, "peak", 3000, 1.5, 0.8), 0.22, 1.7, "piano", damp=4500)
    tn = tune("r:1 5:1.5 6:.5 5:1 | 3:2 1:1.5 r:.5 | 2:1 4:1 6:1 1+:1 | 7:1.5 5:.5 4:2 |"
              " 3:1 5:1 1+:2 | 6:1.5 1+:.5 3+:1 1+:1 | 2+:1.5 1+:.5 6:2 | 5:2 7:1 5:1", t, 4)
    sax = mono(s, tn, "sax", key="sax")
    sax = room(s, echo(s, sax, 1.0 + 1 / 3, 0.1, 0.3, 2, 2500), 0.28, 1.8, "sax", damp=4000)
    vo2 = voicing(ch, 62, 82, 72, guide)
    vib = comp(s, ch, vo2, lambda c, i: [(0, 3.5 if c.dur >= 4 else 1.8, 0.4)], v_vibes, r=r)
    vib = room(s, vib, 0.3, 1.9, "vibes", damp=5000)
    return {"drums": d, "bass": bass, "keys": pno, "lead": sax, "vibes": vib}


def scat_parade(s):
    """152 BPM swing: ride, walking bass, Charleston piano, a scat singer and trumpet shouts."""
    r = dsp.rng(s.id, "scat")
    t = s.tonic
    ch = s.chords
    T = 2.0 / 3.0
    k = kits(s, "jazz")
    d = s.zeros()
    hits(s, d, k["ride"], "x..x.ox..x.o", r, gain=0.85)
    hits(s, d, k["chick"], "...x.....x..", r, gain=0.6)
    hits(s, d, k["feather"], "o..o..o..o..", r, gain=0.45)
    hits(s, d, k["snare"], {"*": "..o.........", 3: "......o.ox.x", 7: "......o.ox.x", 11: "...x.xx.xxxx"}, r, gain=0.55)
    hits(s, d, k["crash"], {0: "X...........", 4: "X...........", 8: "X..........."}, r, gain=0.5)
    d = room(s, d, 0.12, 0.9, "drums", damp=6000)
    line_ = walk(s, 33, 52, 38)
    bass = lay(s, v_upright, [(b, 0.9, m, v) for b, m, v in line_], r=r, jit=0.004)
    bass = room(s, loop_filter(s, bass, "lp", 1400), 0.06, 0.6, "bass", damp=2500)
    vo = voicing(ch, 53, 73, 62, no_root, span=12)

    def charleston(c, i):
        return [(0, 1.2, 0.62), (1 + T, 0.55, 0.55)] if c.dur >= 4 else [(0, 1.0, 0.6)]
    pno = comp(s, ch, vo, charleston, v_piano, r=r, spread=0.005)
    pno = room(s, loop_eq(s, pno, "peak", 3000, 1.5, 0.8), 0.16, 1.2, "piano", damp=4500)
    tn = tune("r:.5 1:.5 3:.5 5:.5 6:.5 5:.5 3:.5 1:.5 | 2:.5 4:.5 6:.5 1+:.5 6:1 5:1 |"
              " r:.5 1:.5 3:.5 5:.5 7:.5 5:.5 3:.5 1:.5 | 2:.5 4:.5 6:.5 1+:.5 7:1 5:1 |"
              " 6:1 4:.5 6:.5 1+:1 3+:1 | 2:.5 4:.5 6:1 5:.5 7:.5 2+:1 |"
              " 3:.5 5:.5 7:.5 2+:.5 6:.5 1+:.5 3+:1 | 4:.5 6:.5 1+:1 5:1 r:1 |"
              " r:.5 1:.5 3:.5 5:.5 6:.5 5:.5 3:.5 1:.5 | 2:.5 4:.5 6:.5 1+:.5 5:1 7:1 |"
              " 1+:1 7:.5 5:.5 3:1 1:1 | 2:.5 4:.5 6:.5 1+:.5 7:1 5:1", t, 3)
    voc = room(s, scat(s, tn), 0.18, 1.0, "scat", damp=5000)
    tp = tune("r:4 | r:4 | r:4 | r:4 | r:2 6:.5 1+:.5 3+:1 | 5+:1.5 3+:.5 1+:2 | r:4 | r:4 | r:4 | r:4 |"
              " r:2 1+:.5 3+:.5 5+:1 | 3+:2 r:2", t, 4)
    trp = room(s, mono(s, tp, "trumpet", swing=0.33, key="tpt"), 0.22, 1.4, "tpt", damp=4000)
    return {"drums": d, "bass": bass, "keys": pno, "voice": voc, "trumpet": trp}


def boogie_mouse(s):
    """132 BPM twelve-bar boogie-woogie: shuffle drums, a rolling left hand, a trilling right hand, sax stabs."""
    r = dsp.rng(s.id, "boogie")
    t = s.tonic
    ch = s.chords
    k = kits(s, "jazz", "lofi")
    d = s.zeros()
    hits(s, d, k["hat"], "x.xx.xx.xx.x", r, gain=0.6)
    hits(s, d, k["snare"], "...X.....X..", r, gain=0.8)
    hits(s, d, k["feather"], "X.....X.....", r, gain=0.9)
    hits(s, d, k["clap"], "...o.....o..", r, gain=0.5, mask=bs("5-12"))
    hits(s, d, k["crash"], {0: "X...........", 8: "X..........."}, r, gain=0.5)
    d = room(s, d, 0.1, 0.8, "drums", damp=6000)
    lh_int = [0, 4, 7, 9, 12, 9, 7, 4]

    def lefthand(c, n, i):
        R = root_of(c, 46, 40, 52)
        return [(q * 0.5, 0.45, R + lh_int[q], 0.8 if q % 2 == 0 else 0.62) for q in range(8)]
    lh = line(s, ch, lefthand, v_piano, r=r, swing=0.33, grid=0.5, jit=0.003)
    rh_tn = tune("3:.5 5:.5 6:.5 5:.5 3:.5 5:.5 6:.5 5:.5 | 3:.5 5:.5 6:.5 5:.5 3:.5 5:.5 6:.5 5:.5 |"
                 " 3:.5 5:.5 6:.5 5:.5 3:.5 5:.5 6:.5 5:.5 | 3:.5 5:.5 6:.5 5:.5 5:1 3:1 |"
                 " 4:.5 6:.5 1+:.5 6:.5 4:.5 6:.5 1+:.5 6:.5 | 4:.5 6:.5 1+:.5 6:.5 4:.5 6:.5 1+:.5 6:.5 |"
                 " 3:.5 5:.5 6:.5 5:.5 3:.5 5:.5 6:.5 5:.5 | 3:1 5:1 6:2 |"
                 " 5:.5 7:.5 2+:.5 7:.5 5:.5 7:.5 2+:.5 7:.5 | 4:.5 6:.5 1+:.5 6:.5 4:.5 6:.5 1+:.5 6:.5 |"
                 " 3:1 5:1 6:2 | 7:.5 5:.5 4:.5 2:.5 5:2", t, 4)
    rh = lay(s, lambda ss, m, du, v: v_piano(ss, m, du, v, bright=0.8), rh_tn, r=r, jit=0.003, swing=0.33, grid=0.5)
    pno = room(s, loop_eq(s, lh + rh, "peak", 2500, 2.0, 0.9), 0.14, 0.9, "piano", damp=5000)
    bass = line(s, ch, lambda c, n, i: [(q, 0.9, root_of(c, 40, 33, 47) + [0, 4, 7, 9][q], 0.85) for q in range(4)],
                v_upright, r=r)
    bass = room(s, loop_filter(s, bass, "lp", 1300), 0.05, 0.6, "bass", damp=2500)
    sx = tune("r:4 | r:4 | r:4 | r:4 | r:4 | r:4 | r:4 | r:4 | 5:.5 5:.5 r:.5 5:.5 3:1 5:1 |"
              " 6:.5 6:.5 r:.5 6:.5 1+:1 6:1 | 5:1 3:1 1:2 | 2:.5 4:.5 5:.5 7:.5 5:2", t, 4)
    sax = room(s, mono(s, sx, "sax", swing=0.33, key="boogie"), 0.18, 1.0, "sax", damp=4500)
    return {"drums": d, "keys": pno, "bass": bass, "sax": sax}


# =================================================================== SQUARE (G)

def carnival_samba(s):
    """100 BPM samba: surdo, tamborim, shakers, cavaquinho strums, a toy trumpet tune and brass hits."""
    r = dsp.rng(s.id, "samba")
    t = s.tonic
    ch = s.chords
    k = kits(s, "latin")
    d = s.zeros()
    hits(s, d, k["surdo"], "o...X...o...X...", r, gain=1.0)
    hits(s, d, k["tamborim"], "x.xx.x.xx.xx.x.x", r, gain=0.65)
    hits(s, d, k["shaker"], "xoxoxoxoxoxoxoxo", r, swing=0.1, gain=0.55)
    hits(s, d, k["agogo_hi"], "x..x..x...x.x...", r, gain=0.45)
    hits(s, d, k["agogo_lo"], "..x..x..x.....x.", r, gain=0.45)
    hits(s, d, k["rim"], "..g...g...g...g.", r, gain=0.5)
    ws = s.zeros()
    for bar in (3, 7):
        for bt, du, g in ((2.0, 0.2, 0.8), (2.5, 0.2, 0.8), (3.0, 0.7, 1.0)):
            s.add(ws, ins.whistle(s.sr, f=2349.3, dur=s.sec(du), key=bar * 10 + int(bt * 2)), bar * 4 + bt, 0.3 * g)
    d = room(s, d + ws, 0.14, 0.8, "perc", damp=6000)
    vo = voicing(ch, 62, 80, 70, no_root, span=12)
    cav = strum_comp(s, ch, vo, lambda c, i: [(q * 0.25, 0.2, 0.8 if q % 4 in (0, 3) else 0.55)
                                              for q in range(16) if q in (0, 2, 3, 5, 7, 8, 10, 11, 13, 15)
                                              and q * 0.25 < c.dur], r=r, bright=0.9, t60=0.5, mute=0.02,
                     spread=0.006, swing=0.1)
    cav = room(s, loop_filter(s, cav, "hp", 220), 0.12, 0.8, "cav", damp=6000)
    bass = line(s, ch, lambda c, n, i: [(0, 1.0, root_of(c, 40, 33, 47), 0.9), (1.5, 0.45, root_of(c, 40, 33, 47) + 7, 0.7),
                                        (2.0, 1.0, root_of(c, 40, 33, 47), 0.85), (3.5, 0.45, root_of(c, 40, 33, 47) + 7, 0.7)]
                if c.dur >= 4 else [(0, 1.0, root_of(c, 40, 33, 47), 0.9), (1.5, 0.45, root_of(c, 40, 33, 47) + 7, 0.7)],
                v_gbass, r=r)
    bass = loop_filter(s, bass, "lp", 2500)
    hits_br = comp(s, ch, voicing(ch, 58, 79, 68, no_root), lambda c, i: [(1.5, 0.3, 0.85), (3.5, 0.45, 0.95)],
                   v_brass, r=r, mask=bs("3-4,7-8"))
    hits_br = room(s, hits_br, 0.16, 1.0, "brass", damp=5000)
    tn = tune("r:.5 1:.5 3:.5 5:.5 3:1 1:1 | 6:.5 1+:.5 3+:.5 1+:.5 5:1 3:1 | 4:.5 6:.5 1+:.5 6:.5 4:1 2:1 |"
              " 5:.5 7:.5 2+:.5 4+:.5 2+:1 7:1 | 1+:1 3+:.5 1+:.5 6:1 5:1 | 4:.5 6:.5 1+:.5 3+:.5 1+:1 6:1 |"
              " 2:.5 4:.5 6:.5 4:.5 7:.5 5:.5 4:.5 2:.5 | 1+:3 r:1", t, 4)
    tp = room(s, mono(s, tn, "trumpet", swing=0.1, key="samba", grid=0.25), 0.18, 1.0, "tpt", damp=4500)
    return {"drums": d, "guitar": cav, "bass": bass, "brass": hits_br, "lead": tp}


def oompah_polka(s):
    """124 BPM polka: tuba oom, strummed pah, marching snare and a musette accordion tune."""
    r = dsp.rng(s.id, "polka")
    t = s.tonic
    ch = s.chords
    k = kits(s, "street", "march")
    d = s.zeros()
    hits(s, d, k["bass"], "X.......X.......", r, gain=0.85)
    hits(s, d, k["snare"], "....x.......x...", r, gain=0.7)
    hits(s, d, k["hat"], "x.x.x.x.x.x.x.x.", r, gain=0.5)
    hits(s, d, k["crash"], {0: "X...............", 4: "X...............", 8: "X..............."}, r, gain=0.45)
    d = room(s, d, 0.1, 0.8, "drums", damp=6000)
    tub = []
    for i, c in enumerate(ch):
        R = root_of(c, 43, 36, 50)
        tub += [(c.start, 0.45, R, 0.95), (c.start + 2, 0.45, R + 7 if R + 7 <= 52 else R - 5, 0.9)]
    tuba = room(s, mono(s, tub, "tuba", key="tuba"), 0.08, 0.7, "tuba", damp=3000)
    vo = voicing(ch, 60, 79, 68, no_root, span=12)
    pah = strum_comp(s, ch, vo, [(1, 0.22, 0.85), (3, 0.22, 0.85)], r=r, bright=0.85, t60=0.4, mute=0.02, spread=0.007)
    pah = room(s, loop_filter(s, pah, "hp", 250), 0.1, 0.8, "pah", damp=6000)
    tn = tune("1:.75 3:.25 5:.5 5:.5 1+:1 5:1 | 7:.5 5:.5 2+:1 4:1 5:1 | 1:.75 3:.25 5:.5 5:.5 1+:1 3+:1 |"
              " 2+:1 7:.5 5:.5 4:1 5:1 | 3+:1 1+:.5 5:.5 3:1 1:1 | 4:.75 6:.25 1+:.5 6:.5 4:1 1:1 |"
              " 5:.5 3:.5 5:.5 1+:.5 3+:2 | 2+:1 7:1 5:1 2:1 | 1:.75 3:.25 5:.5 5:.5 1+:1 5:1 |"
              " 4:.5 6:.5 1+:1 3+:1 1+:1 | 2+:1 7:.5 4:.5 5:2 | 1+:1 5:.5 3:.5 1:2", t, 4)
    acc = lay(s, v_accordion, tn, r=r, jit=0.004)
    acc = room(s, acc, 0.16, 1.0, "acc", damp=5000)
    return {"drums": d, "bass": tuba, "guitar": pah, "lead": acc}


def marching_ducks(s):
    """112 BPM toy marching band: snare cadence, piccolo tune, tuba, brass stabs and a duck or two."""
    r = dsp.rng(s.id, "duck")
    t = s.tonic
    ch = s.chords
    k = kits(s, "march")
    d = s.zeros()
    hits(s, d, k["snare"], ["X.x.xxX.x.x.xxx.", "X.x.xxX.x.xxXxxx", "X.x.xxX.x.x.xxx.", "X.x.xxX.x.xxxxxx"], r, gain=0.75)
    hits(s, d, k["bass"], "X.......X.......", r, gain=0.9)
    hits(s, d, k["wood"], "....x.......x...", r, gain=0.45, mask=bs("2-12"))
    hits(s, d, k["crash"], {0: "X...............", 4: "X...............", 8: "X..............."}, r, gain=0.5)
    for bar in (3, 7, 11):
        for j in range(8):
            hit(s, d, k["snare"], bar * 4 + 3 + j * 0.125, 0.3 + 0.08 * j, r, 0.002)
    d = room(s, d, 0.12, 0.8, "drums", damp=6000)
    tub = []
    for c in ch:
        R = root_of(c, 43, 36, 50)
        F = R + 7 if R + 7 <= 52 else R - 5
        tub += [(c.start, 0.45, R, 0.95), (c.start + 1, 0.45, F, 0.85), (c.start + 2, 0.45, R, 0.9), (c.start + 3, 0.45, F, 0.85)]
    tuba = room(s, mono(s, tub, "tuba", key="tuba"), 0.08, 0.7, "tuba", damp=3000)
    br = comp(s, ch, voicing(ch, 58, 79, 68, no_root), lambda c, i: [(0, 0.4, 0.85), (2, 0.4, 0.8)], v_brass, r=r,
              mask=bs("5-12"))
    br = room(s, br, 0.14, 0.9, "brass", damp=5000)
    tn = tune("1:.5 1:.5 3:.5 5:.5 1+:1 5:1 | 3+:.5 1+:.5 5:1 3:1 1:1 | 4:.5 4:.5 6:.5 1+:.5 4+:1 1+:1 | 5:.5 3:.5 1:1 5:1 1:1 |"
              " 1:.5 1:.5 3:.5 5:.5 1+:1 5:1 | 5:.5 5:.5 7:.5 2+:.5 5+:1 2+:1 | 1+:1 3+:.5 1+:.5 5:2 | 4+:1 1+:1 6:1 4:1 |"
              " 5:.5 7:.5 2+:.5 4+:.5 2+:1 7:1 | 5:1 1+:1 3+:2 | 2+:1 4+:.5 2+:.5 7:1 5:1 | 1+:2 5:1 1:1", t, 5)
    pic = room(s, mono(s, tn, "piccolo", key="piccolo"), 0.14, 0.9, "pic", damp=6000)
    qk = s.zeros()
    for bar in (2, 6, 10):
        s.add(qk, v_quack(s, 62, 0.2, 0.9), bar * 4 + 3.5, 1.0)
        s.add(qk, v_quack(s, 60, 0.2, 0.7), bar * 4 + 3.75, 1.0)
    qk = room(s, qk, 0.2, 0.9, "quack", damp=5000)
    return {"drums": d, "bass": tuba, "brass": br, "lead": pic, "quack": qk}


def calypso_sun(s):
    """108 BPM calypso: a steel-drum tune, ukulele offbeats, bongos, shakers and a bouncing bass."""
    r = dsp.rng(s.id, "calypso", 2)
    t = s.tonic
    ch = s.chords
    k = kits(s, "latin")
    d = s.zeros()
    hits(s, d, k["bongo_hi"], "x.xx..x.x.xx..x.", r, gain=0.7)
    hits(s, d, k["bongo_lo"], "..x..x..x.....x.", r, gain=0.7)
    hits(s, d, k["conga_lo"], "X.......x..x....", r, gain=0.6)
    hits(s, d, k["shaker"], "x.o.x.o.x.o.x.o.", r, gain=0.6)
    hits(s, d, k["agogo_hi"], "....x.......x...", r, gain=0.4)
    ws = s.zeros()
    for bar in (3, 7):
        for bt, du, g in ((3.0, 0.2, 0.8), (3.5, 0.45, 1.0)):
            s.add(ws, ins.whistle(s.sr, f=2637.0, dur=s.sec(du), key=bar * 7 + int(bt * 2)), bar * 4 + bt, 0.28 * g)
    d = room(s, d + ws, 0.12, 0.8, "perc", damp=6000)
    vo = voicing(ch, 62, 80, 70, no_root, span=12)
    uke = strum_comp(s, ch, vo, lambda c, i: [(0.5, 0.3, 0.7), (1.5, 0.3, 0.8), (2.5, 0.3, 0.7), (3.5, 0.3, 0.8)]
                     if c.dur >= 4 else [(0.5, 0.3, 0.7), (1.5, 0.3, 0.8)], r=r, bright=0.7, t60=0.7, mute=0.03, spread=0.007)
    uke = room(s, loop_filter(s, uke, "hp", 250), 0.12, 0.8, "uke", damp=6000)

    def bass(c, n, i):
        R = root_of(c, 40, 33, 47)
        F = R + 7 if R + 7 <= 50 else R - 5
        return ([(0, 0.9, R, 0.9), (1.5, 0.45, F, 0.7), (2.5, 0.9, R, 0.85), (3.5, 0.45, F, 0.7)] if c.dur >= 4
                else [(0, 0.9, R, 0.9), (1.5, 0.45, F, 0.7)])
    bs_ = loop_filter(s, line(s, ch, bass, v_gbass, r=r), "lp", 2500)
    tn = tune("3:.5 5:.5 3:.5 1+:.5 5:1 3:1 | 6:.5 4:.5 6:.5 1+:.5 4+:1 1+:1 | 3:.5 5:.5 1+:.5 3+:.5 5:1 3:1 |"
              " 2+:.5 7:.5 5:.5 2+:.5 5:2 | 5:.5 3+:.5 1+:.5 5:.5 3:1 5:1 | 6:.5 1+:.5 4+:.5 1+:.5 6:1 4:1 |"
              " 3:.5 5:.5 1+:.5 5:.5 7:.5 5:.5 4:.5 2:.5 | 1+:3 r:1", t, 4)
    st = lay(s, v_steel, tn, r=r, jit=0.004)
    st = room(s, echo(s, st, 0.75, 0.15, 0.3, 2, 5000), 0.2, 1.1, "steel", damp=6000)
    return {"drums": d, "guitar": uke, "bass": bs_, "lead": st}


# =================================================================== STADIUM (A)

def choir_pad(s, chords, lo=60, hi=79, center=69, vowel="a_sop", mask=None, level=1.0):
    """A sustained choir 'ah' on the chords (formants on the whole part, like the district choir stem)."""
    vo = voicing(chords, lo, hi, center, no_root, span=14)
    buf = s.zeros()
    for c, v in zip(chords, vo):
        if mask is not None and int(c.start // 4) % s.bars not in mask:
            continue
        for j, m in enumerate(v):
            s.add(buf, M.choir_src(m, s.sec(c.dur) + 0.1, s.sr, key=j), c.start - 0.05)
    x = dsp.loop_apply(buf, lambda z: dsp.formant(z, s.sr, dsp.VOWELS[vowel]))
    x = 0.8 * x / dsp.peak(x) + 0.15 * loop_filter(s, buf, "lp", 1500) / dsp.peak(buf)
    return room(s, x, 0.45, 2.4, "choir", damp=5000, predelay=0.03) * level


def neon_heartbeat(s):
    """124 BPM electro-pop: four on the floor, pumping bass and supersaw stabs, a glittering arp and a synth hook."""
    r = dsp.rng(s.id, "neon")
    t = s.tonic
    ch = s.chords
    k = kits(s, "dance")
    d = s.zeros()
    hits(s, d, k["kick"], "X...X...X...X...", r, jit=0.0)
    hits(s, d, k["clap"], "....X.......X...", r, gain=0.9, jit=0.0)
    hits(s, d, k["snare"], "....o.......o...", r, gain=0.5, jit=0.0)
    hits(s, d, k["ohat"], "..x...x...x...x.", r, gain=0.55, jit=0.0)
    hits(s, d, k["hat"], "o.o.o.o.o.o.o.o.", r, gain=0.35, jit=0.002)
    hits(s, d, k["crash"], {0: "X...............", 4: "X...............", 8: "X..............."}, r, gain=0.5, jit=0.0)
    for bar in (3, 7, 11):
        for j in range(8):
            hit(s, d, k["snare"], bar * 4 + 2 + j * 0.25, 0.3 + 0.07 * j, r, 0.0)
    d = room(s, dsp.drive(d / dsp.peak(d) * 1.3, 1.4), 0.1, 0.9, "drums", damp=7000)
    bass = line(s, ch, lambda c, n, i: [(q + 0.5, 0.42, root_of(c, 40, 35, 46), 1.0) for q in range(4)]
                + [(q + 0.75, 0.2, root_of(c, 40, 35, 46) + 12, 0.6) for q in (1, 3)], v_sbass, r=r, jit=0.0)
    bass = sidechain(s, bass, range(s.beats), 0.5, 0.1)
    vo = voicing(ch, 57, 78, 67, no_root)
    stabs = comp(s, ch, vo, [(0.5, 0.3, 0.9), (1.5, 0.3, 0.9), (2.5, 0.3, 0.9), (3.5, 0.3, 0.9)],
                 lambda ss, m, du, v: v_super(ss, m, du, v, att=0.004, rel=0.08), r=r, jit=0.0)
    stabs = sidechain(s, loop_eq(s, loop_filter(s, stabs, "lp", 6500), "highshelf", 3000, 2.0), range(s.beats), 0.65, 0.14)
    stabs = room(s, stabs, 0.18, 1.4, "stabs", damp=6000)
    arp = s.zeros()
    for c in ch:
        tones = chord_notes(c, 69, 93)[:5]
        seq = tones[:4] + [tones[-1]] + tones[1:4][::-1]
        for q in range(int(c.dur * 4)):
            m = seq[q % len(seq)]
            s.add(arp, v_pluck(s, m, 0.25, 0.9 if q % 4 == 0 else 0.6, cutoff=8000, decay=0.06), c.start + q * 0.25)
            if q % 4 == 0:
                s.add(arp, v_celesta(s, m + 12, 0.6, 0.5, t60=0.4), c.start + q * 0.25, 0.4)
    arp = room(s, sidechain(s, echo(s, loop_eq(s, arp, "highshelf", 4000, 3.0), 0.75, 0.3, 0.4, 3, 8000), range(s.beats), 0.3, 0.1),
               0.16, 1.2, "arp", damp=10000)
    tn = tune("r:4 | r:4 | r:4 | r:4 | r:.5 6:.5 1+:.5 3+:.5 1+:1 6:1 | 4:.5 6:.5 1+:1 6:.5 4:.5 6:1 |"
              " 3:.5 5:.5 1+:1 5:.5 3:.5 5:1 | 5:.5 7:.5 2+:1 7:.5 5:.5 2:1 |"
              " r:.5 6:.5 1+:.5 3+:.5 5+:1 3+:1 | 4+:.5 1+:.5 6:1 4:.5 6:.5 1+:1 | 5:.5 1+:.5 3+:1 5+:1 3+:1 | 2+:1 7:1 5:1 2:1", t, 4)
    lead = room(s, echo(s, mono(s, tn, "lead", key="hook"), 0.75, 0.22, 0.35, 3, 3500), 0.2, 1.4, "lead", damp=6000)
    chr_ = choir_pad(s, ch, mask=bs("5-12"))
    fx = riser(s, 8, 0.6) + impact(s, 33, 0.8)
    return {"drums": d, "bass": bass, "keys": stabs, "arp": arp, "lead": lead, "choir": chr_, "fx": room(s, fx, 0.25, 1.8, "fx", damp=6000)}


def idol_ballad(s):
    """70 BPM pop ballad: piano arpeggios, a string swell, a choir 'ah', a glassy singing lead and a late soft beat."""
    r = dsp.rng(s.id, "idol")
    t = s.tonic
    ch = s.chords
    k = kits(s, "dance", "lofi")
    vo = voicing(ch, 52, 78, 64, None, span=17)
    pno = s.zeros()
    seq = [0, 1, 2, 3, 2, 1, 2, 3]
    for i, c in enumerate(ch):
        v = vo[i]
        for q in range(int(c.dur * 2)):
            m = v[seq[q % 8] % len(v)]
            s.add(pno, v_piano(s, m, 1.4, 0.5 if q % 2 else 0.62), c.start + q * 0.5, 1.0, dt=float(r.normal(0, 0.004)))
    pno = room(s, loop_eq(s, pno, "peak", 3200, 1.5, 0.8), 0.25, 1.8, "piano", damp=5000)
    vo2 = voicing(ch, 55, 79, 67, no_root, span=14)
    strg = comp(s, ch, vo2, lambda c, i: [(0, c.dur - 0.05, 1.0)], lambda ss, m, du, v: v_strings(ss, m, du, v, k=m % 3), r=r,
                mask=bs("3-8"))
    strg = room(s, tape(s, strg, 6.0, 0.35, 1.0), 0.3, 2.0, "strings", damp=4000)
    chr_ = choir_pad(s, ch, mask=bs("5-8"), level=0.9)
    tn = tune("r:1 5:1.5 3:.5 5:1 | 7:1 5:1 2:2 | 6:1.5 1+:.5 3+:2 | 3+:2 2+:1 7:1 | 6:1 1+:1 4+:2 | 3+:1.5 1+:.5 5:1 3:1 |"
              " 4+:1 1+:1 6:1 4:1 | 5:1 7:1 2+:2", t, 4)
    lead = mono(s, tn, "bell", key="idol")
    lead = room(s, echo(s, lead, 1.0, 0.2, 0.35, 3, 4000), 0.3, 1.8, "lead", damp=5000)
    d = s.zeros()
    hits(s, d, k["kick"], "X.......X.......", r, gain=0.6, jit=0.002, mask=bs("5-8"))
    hits(s, d, k["clap"], "....o.......o...", r, gain=0.55, jit=0.003, mask=bs("5-8"))
    hits(s, d, k["hat"], "x.x.x.x.x.x.x.x.", r, gain=0.35, mask=bs("5-8"))
    hits(s, d, k["crash"], {4: "X..............."}, r, gain=0.45)
    d = room(s, d, 0.2, 1.2, "drums", damp=6000)
    bass = line(s, ch, lambda c, n, i: [(0, 3.8, root_of(c, 37, 33, 44), 0.9)], v_sub, r=r, mask=bs("3-8"))
    bass = loop_filter(s, bass, "lp", 500)
    return {"keys": pno, "strings": strg, "choir": chr_, "lead": lead, "drums": d, "bass": bass}


def candy_rush(s):
    """140 BPM kawaii future bass: chopped supersaws pumping against the kick, a bell-pluck hook, sugar-rush hats."""
    r = dsp.rng(s.id, "candy")
    t = s.tonic
    ch = s.chords
    k = kits(s, "dance")
    d = s.zeros()
    hits(s, d, k["kick"], "X.....x...x.....", r, jit=0.0)
    hits(s, d, k["clap"], "........X.......", r, gain=1.0, jit=0.0)
    hits(s, d, k["snare"], "........o.......", r, gain=0.6, jit=0.0)
    hits(s, d, k["hat"], "xoxoxoxoxoxoxoxo", r, gain=0.4, jit=0.0)
    hits(s, d, k["ohat"], "..x.......x.....", r, gain=0.45, jit=0.0)
    hits(s, d, k["crash"], {0: "X...............", 4: "X...............", 8: "X..............."}, r, gain=0.5, jit=0.0)
    for bar in (3, 7, 11):
        for j in range(8):
            hit(s, d, k["snare"], bar * 4 + 3 + j * 0.125, 0.3 + 0.08 * j, r, 0.0)
    d = room(s, dsp.drive(d / dsp.peak(d) * 1.3, 1.4), 0.1, 0.8, "drums", damp=7000)
    vo = voicing(ch, 57, 80, 68, no_root)
    chop = [(i * 0.25, 0.2, 0.9 if i % 4 == 0 else 0.75) for i, c_ in enumerate("x.xx.x.xx.x.xx..") if c_ == "x"]
    chops = comp(s, ch, vo, chop, lambda ss, m, du, v: v_super(ss, m, du, v, att=0.003, rel=0.06, k=m % 3), r=r, jit=0.0)
    chops = sidechain(s, loop_filter(s, chops, "lp", 7500), [q * 1.0 for q in range(s.beats)], 0.8, 0.13)
    chops = room(s, chops, 0.2, 1.3, "chops", damp=6500)
    bass = line(s, ch, lambda c, n, i: [(0, 1.9, root_of(c, 38, 33, 45), 1.0), (2.0, 1.4, root_of(c, 38, 33, 45), 0.9),
                                        (3.5, 0.45, root_of(c, 38, 33, 45) + 12, 0.7)], v_sub, r=r, jit=0.0)
    bass = sidechain(s, bass, [q * 1.0 for q in range(s.beats)], 0.7, 0.13)
    arp = s.zeros()
    for c in ch:
        tones = chord_notes(c, 69, 93)[:4]
        for q in range(int(c.dur * 4)):
            if q % 2 == 0:
                s.add(arp, v_pluck(s, tones[(q // 2) % len(tones)], 0.2, 0.7, cutoff=6000, decay=0.05), c.start + q * 0.25)
    arp = sidechain(s, echo(s, arp, 0.375, 0.25, 0.4, 3, 7000), [q * 1.0 for q in range(s.beats)], 0.4, 0.12)
    tn = tune("r:4 | r:4 | r:4 | r:4 | 6:.5 1+:.5 4+:.5 1+:.5 6:1 4:1 | 7:.5 2+:.5 5+:.5 2+:.5 7:1 5:1 |"
              " 5:.5 7:.5 3+:.5 7:.5 5:1 3:1 | 6:.5 1+:.5 3+:.5 1+:.5 6:2 |"
              " 6:.5 1+:.5 4+:.5 1+:.5 6:1 4:1 | 7:.5 2+:.5 5+:.5 2+:.5 7:1 5:1 | 5:.5 7:.5 3+:.5 7:.5 5:1 3:1 |"
              " 6:.5 1+:.5 3+:.5 1+:.5 6:2", t, 4)
    hook = lay(s, lambda ss, m, du, v: dsp.mix(v_pluck(ss, m, du, v, cutoff=5500, decay=0.12), 0.5 * v_celesta(ss, m + 12, du, v, t60=0.5)),
               tn, r=r, jit=0.0)
    hook = sidechain(s, room(s, echo(s, hook, 0.375, 0.25, 0.4, 3, 6000), 0.2, 1.2, "hook", damp=7000), [q * 1.0 for q in range(s.beats)], 0.3, 0.12)
    fx = riser(s, 8, 0.6) + impact(s, 33, 0.7)
    return {"drums": d, "keys": chops, "bass": bass, "arp": arp, "lead": hook, "fx": room(s, fx, 0.25, 1.8, "fx", damp=6000)}


def lightstick_wave(s):
    """96 BPM R&B-pop: finger snaps, a long 808 sub, syncopated e-piano and sung 'oh-ah' chops."""
    r = dsp.rng(s.id, "light")
    t = s.tonic
    ch = s.chords
    k = kits(s, "dance")
    snaps = [ins.snap(s.sr, key=i) for i in range(3)]
    d = s.zeros()
    hits(s, d, snaps, "....X.......X...", r, gain=0.95)
    hits(s, d, k["clap"], "....o.......o...", r, gain=0.6, mask=bs("5-8"))
    hits(s, d, k["kick"], ["X..x....x.x.....", "X.....x.x...x..."], r, gain=0.9, jit=0.002)
    hits(s, d, k["hat"], "x.xox.xox.xox.xo", r, swing=0.3, gain=0.5, jit=0.002)
    hits(s, d, k["ohat"], {3: "..............x.", 7: "......x.......x."}, r, gain=0.5)
    hits(s, d, k["crash"], {0: "X...............", 4: "X..............."}, r, gain=0.4)
    d = room(s, dsp.drive(d / dsp.peak(d) * 1.2, 1.3), 0.1, 0.9, "drums", damp=7000)

    def sub808(c, n, i):
        R = root_of(c, 38, 33, 45)
        return [(0, 1.4, R, 1.0), (2.5, 0.9, R, 0.85), (3.25, 0.5, R + 12, 0.6)]
    bass = loop_filter(s, line(s, ch, sub808, v_sub, r=r, jit=0.0), "lp", 600)
    vo = voicing(ch, 55, 77, 66, no_root)
    ep = comp(s, ch, vo, [(0, 0.9, 0.6), (1.5, 0.45, 0.5), (2.5, 0.9, 0.6), (3.5, 0.4, 0.45)], v_epiano, r=r, swing=0.3)
    ep = room(s, tape(s, ep, 5.0, 0.4, 1.0), 0.2, 1.3, "ep", damp=5500)
    chops = s.zeros()
    for i, c in enumerate(ch):
        tones = chord_notes(c, 69, 86, no_root(c))
        for j, (bt, du) in enumerate(((0.5, 0.25), (1.5, 0.25), (2.75, 0.25), (3.5, 0.4))):
            s.add(chops, v_vox(s, tones[(i + j) % len(tones)], du, 0.8, vowel="o_alto" if j % 2 == 0 else "a_alto", key=j),
                  sw(c.start + bt, 0.3), 1.0)
    chops = room(s, echo(s, chops, 0.75, 0.2, 0.35, 3, 4000), 0.25, 1.4, "chops", damp=5000)
    tn = tune("r:.5 3:.5 5:1 7:.5 5:.5 3:1 | 6:1 1+:1 3+:2 | 4+:1.5 1+:.5 6:1 4:1 | 5:1 2+:1 1+:1 r:1 |"
              " r:.5 3:.5 5:1 7:.5 5:.5 3:1 | 3+:1.5 2+:.5 7:1 5:1 | 6:1 1+:1 4+:1 3+:1 | 2+:2 1+:1 5:1", t, 4)
    lead = room(s, echo(s, mono(s, tn, "bell", key="light"), 0.75, 0.2, 0.35, 3, 4000), 0.25, 1.4, "lead", damp=5500)
    return {"drums": d, "bass": bass, "keys": ep, "chops": chops, "lead": lead}


# =================================================================== GARAGE (E)

def punk_guitar(s, chords, eighths, r, gain=1.0, amp=8.0, accent=(0,), open_len=1.9):
    """Palm-muted power chords on the 8ths with open accents, through the amp (like the garage theme)."""
    buf = s.zeros()
    for c in chords:
        R = nearest(c.root, 43, 40, 51)
        for q in range(int(c.dur * 2)):
            if q in eighths:
                kind = "o" if q in accent else "m"
                x = M.power_chord(R, s.sec(open_len if kind == "o" else 0.4), s.sr, muted=(kind == "m"), key=q % 2)
                s.add(buf, x, c.start + q * 0.5, 1.0 if kind == "o" else 0.8, dt=float(r.normal(0, 0.003)))
    buf = buf / dsp.peak(buf)
    buf = dsp.loop_apply(buf, lambda z: ins.amp_sim(z, s.sr, gain=amp, tone=4200))
    t = np.arange(s.n) / s.sr
    hum = 0.004 * (np.sin(TAU * midi_hz(28) * t) + 0.5 * np.sin(TAU * midi_hz(40) * t))
    return (buf / dsp.peak(buf) + hum) * gain


def surf_splash(s):
    """148 BPM surf rock: a tremolo-picked twangy lead in spring reverb, galloping toms, muted chugs and tambourine."""
    r = dsp.rng(s.id, "surf")
    t = s.tonic
    ch = s.chords
    k = kits(s, "rock")
    toms = {f: ins.tom(s.sr, f, 0.6, key=int(f)) for f in (210, 165, 125, 92)}
    d = s.zeros()
    hits(s, d, k["kick"], "X..x..x.X.x.....", r, gain=0.95)
    hits(s, d, k["snare"], "....X.......X...", r, gain=0.9)
    hits(s, d, k["hat"], "x.x.x.x.x.x.x.x.", r, gain=0.6)
    hits(s, d, k["crash"], {0: "X...............", 4: "X...............", 8: "X..............."}, r, gain=0.6)
    for bar in (3, 7, 11):
        for j, f in enumerate((210, 210, 165, 165, 125, 125, 92, 92)):
            s.add(d, toms[f], bar * 4 + 2 + j * 0.25, 0.6 + 0.05 * j, dt=float(r.normal(0, 0.003)))
    d = room(s, dsp.drive(d / dsp.peak(d) * 1.3, 1.4), 0.16, 0.8, "drums", damp=5000, predelay=0.008)
    tn = tune("5:.5 5:.5 1+:.5 5:.5 3+:1 1+:1 | 6:.5 6:.5 3+:.5 6:.5 1+:1 6:1 | 4+:.5 4+:.5 1+:.5 4+:.5 6+:1 4+:1 | 5+:.5 5+:.5 2+:.5 5+:.5 7+:1 5+:1 |"
              " 3+:.5 5+:.5 1+:1 5:1 3:1 | 3+:.5 6+:.5 3+:1 1+:1 6:1 | 4+:.5 1+:.5 6:1 4+:1 1+:1 | 7:.5 2+:.5 5+:1 2+:1 7:1 |"
              " 5:.5 5:.5 1+:.5 5:.5 3+:1 1+:1 | 6:.5 6:.5 3+:.5 6:.5 1+:1 6:1 | 4+:.5 4+:.5 1+:.5 4+:.5 6+:1 4+:1 | 5+:1 2+:1 7:1 5:1", t, 4)
    lead = s.zeros()
    for i, (b, du, m, v) in enumerate(tn):
        s.add(lead, v_tremolo(s, m, du, v, rate=0.125), b)
    lead = loop_filter(s, lead, "hp", 250)
    lead = room(s, lead / dsp.peak(lead), 0.45, 1.5, "spring", damp=9000, predelay=0.004, hp=400)
    rhy = punk_guitar(s, ch, set(range(8)), r, amp=7.0, accent=(0,), open_len=0.9)
    rhy = room(s, rhy, 0.14, 0.9, "rhythm", damp=4000)
    bass = line(s, ch, lambda c, n, i: [(q * 0.5, 0.46, root_of(c, 33, 28, 39), 1.0 if q % 2 == 0 else 0.8) for q in range(8)],
                v_gbass, r=r)
    bass = loop_filter(s, dsp.loop_apply(bass / dsp.peak(bass), lambda z: dsp.tube(z * 1.8, 1.2, s.sr, 0.1)), "lp", 3500)
    tamb = s.zeros()
    tb = [ins.tambourine(s.sr, key=i, hit=0.0) for i in range(4)]
    hits(s, tamb, tb, "x.o.x.o.x.o.x.o.", r, gain=0.55)
    return {"drums": d, "lead": lead, "guitar": rhy, "bass": bass, "tamb": room(s, tamb, 0.12, 0.8, "tamb", damp=6000)}


def skate_sprint(s):
    """168 BPM pop-punk: driving kick and snare, palm-muted chugs, a shouted-hook lead and gang shouts."""
    r = dsp.rng(s.id, "skate")
    t = s.tonic
    ch = s.chords
    k = kits(s, "rock")
    d = s.zeros()
    hits(s, d, k["kick"], "X.....x.X.....x.", r, gain=0.95)
    hits(s, d, k["snare"], "....X.......X...", r, gain=1.0)
    hits(s, d, k["hat"], "x.x.x.x.x.x.x.x.", r, gain=0.7)
    hits(s, d, k["crash"], {0: "X...............", 4: "X...............", 8: "X...............", 12: "X..............."}, r, gain=0.6)
    for bar in (3, 7, 11, 15):
        for j in range(8):
            hit(s, d, k["snare"], bar * 4 + 2 + j * 0.25, 0.4 + 0.07 * j, r, 0.002)
    d = room(s, dsp.drive(d / dsp.peak(d) * 1.4, 1.5), 0.16, 0.8, "drums", damp=5000, predelay=0.008)
    gtr = punk_guitar(s, ch, set(range(8)), r, amp=9.0, accent=(0, 4), open_len=1.7)
    gtr = room(s, gtr, 0.12, 0.8, "gtr", damp=4000)
    bass = line(s, ch, lambda c, n, i: [(q * 0.5, 0.46, root_of(c, 33, 28, 39), 1.0 if q % 2 == 0 else 0.8) for q in range(8)],
                v_gbass, r=r)
    bass = loop_filter(s, dsp.loop_apply(bass / dsp.peak(bass), lambda z: dsp.tube(z * 1.8, 1.2, s.sr, 0.1)), "lp", 3500)
    riff = ("3:.5 3:.5 5:.5 3:.5 1+:1 5:1 | 5:.5 5:.5 7:.5 5:.5 2+:1 7:1 | 6:.5 6:.5 1+:.5 6:.5 3+:1 1+:1 |"
            " 4:.5 4:.5 6:.5 4:.5 1+:1 6:1")
    tn = tune("r:4 | r:4 | r:4 | r:4 | " + riff + " | " + riff + " | " + riff + " | " + riff, t, 4)
    lead = room(s, mono(s, tn, "guitar", key="skate"), 0.14, 0.9, "lead", damp=4000)
    gg = gang(s, [(3, 3.0), (7, 3.0), (11, 3.0), (15, 3.0)], level=1.0)
    return {"drums": d, "guitar": gtr, "bass": bass, "lead": lead, "gang": room(s, gg, 0.25, 1.0, "gang", damp=4500)}


def sunrise_ballad(s):
    """72 BPM power ballad: clean arpeggios grow into strings, a full kit and a singing lead guitar."""
    r = dsp.rng(s.id, "sunrise")
    t = s.tonic
    ch = s.chords
    k = kits(s, "rock")
    vo = voicing(ch, 52, 76, 62, None, span=17)
    arp = s.zeros()
    seq = [0, 1, 2, 3, 2, 1, 2, 3]
    for i, c in enumerate(ch):
        v = vo[i]
        for q in range(int(c.dur * 2)):
            m = v[seq[q % 8] % len(v)]
            x = ins.guitar(m, s.sec(1.4), s.sr, bright=0.45, t60=1.8, pick=0.18, mute=0.1, key=q % 3, attack=0.002)
            s.add(arp, x, c.start + q * 0.5, 0.9 if q % 4 == 0 else 0.7, dt=float(r.normal(0, 0.004)))
    arp = room(s, loop_eq(s, arp, "peak", 2500, 2.0, 0.9), 0.22, 1.4, "arp", damp=5000)
    vo2 = voicing(ch, 55, 79, 67, no_root, span=14)
    strg = comp(s, ch, vo2, lambda c, i: [(0, c.dur - 0.05, 1.0)], lambda ss, m, du, v: v_strings(ss, m, du, v, k=m % 3), r=r,
                mask=bs("3-8"))
    strg = room(s, tape(s, strg, 6.0, 0.35, 1.0), 0.3, 2.0, "strings", damp=4000)
    org = comp(s, ch, voicing(ch, 52, 70, 60, no_root), lambda c, i: [(0, c.dur - 0.05, 0.7)],
               lambda ss, m, du, v: v_organ(ss, m, du, v, bars=(8, 5, 8, 4, 0, 3, 0, 0, 0), perc=0.0, att=0.3, rel=0.4), r=r,
               mask=bs("5-8"))
    org = room(s, leslie(s, org, 0.6, 0.25), 0.25, 1.6, "organ", damp=4000)
    d = s.zeros()
    hits(s, d, k["kick"], "X.......X.......", r, gain=0.8, mask=bs("5-8"))
    hits(s, d, k["snare"], "....X.......X...", r, gain=0.75, mask=bs("5-8"))
    hits(s, d, k["hat"], "x.x.x.x.x.x.x.x.", r, gain=0.45, mask=bs("5-8"))
    hits(s, d, k["crash"], {4: "X..............."}, r, gain=0.6)
    for j in range(4):
        hit(s, d, k["snare"], 3 * 4 + 3 + j * 0.25, 0.4 + 0.1 * j, r, 0.002)
    d = room(s, dsp.drive(d / dsp.peak(d) * 1.2, 1.3), 0.2, 1.1, "drums", damp=5000)
    bass = line(s, ch, lambda c, n, i: [(0, 1.9, root_of(c, 33, 28, 39), 0.9), (2, 1.9, root_of(c, 33, 28, 39), 0.85)],
                v_gbass, r=r, mask=bs("3-8"))
    bass = loop_filter(s, bass, "lp", 2500)
    tn = tune("r:4 | r:4 | 6:1 1+:1 3+:2 | 4+:2 1+:1 6:1 | 5:1 3+:1 1+:2 | 2+:1.5 7:.5 5:2 | 6:1 4+:1 1+:2 | 7:1 2+:1 5+:2", t, 4)
    lead = mono(s, tn, "guitar", key="sunrise", drive=3.5)
    lead = room(s, echo(s, lead, 0.75, 0.18, 0.35, 3, 3500), 0.28, 1.6, "lead", damp=4500)
    return {"keys": arp, "strings": strg, "organ": org, "drums": d, "bass": bass, "lead": lead}


def stomp_clap(s):
    """92 BPM glam stomp: boom, boom, CLAP; a fat riff, gang shouts and a jingling tambourine."""
    r = dsp.rng(s.id, "stomp")
    t = s.tonic
    ch = s.chords
    k = kits(s, "rock", "dance")
    stomp = [ins.kick(s.sr, 90, 45, 0.04, 0.5, 0.2, 1.8, key=40 + i) for i in range(2)]
    d = s.zeros()
    hits(s, d, stomp, "X...X...........", r, gain=1.0, jit=0.002)
    hits(s, d, k["clap"], "........X.......", r, gain=1.0, jit=0.003)
    hits(s, d, k["clap"], "........g.......", r, gain=0.7, jit=0.012)
    hits(s, d, k["snare"], {3: "..............o.", 7: "..............X."}, r, gain=0.6)
    hits(s, d, k["crash"], {0: "X...............", 4: "X..............."}, r, gain=0.5)
    d = room(s, dsp.drive(d / dsp.peak(d) * 1.3, 1.4), 0.2, 0.9, "drums", damp=5000, predelay=0.008)
    tb = [ins.tambourine(s.sr, key=i, hit=0.0) for i in range(4)]
    tm = s.zeros()
    hits(s, tm, tb, "x.o.x.o.x.o.x.o.", r, gain=0.6)
    gtr = s.zeros()
    for c in ch:
        R = nearest(c.root, 43, 40, 51)
        for bt, kind, du in ((0, "o", 0.95), (0.75, "m", 0.3), (1.5, "o", 0.4), (2.0, "m", 0.3), (2.5, "m", 0.3), (3.0, "o", 0.9)):
            x = M.power_chord(R, s.sec(du), s.sr, muted=(kind == "m"), key=int(bt * 2) % 2)
            s.add(gtr, x, c.start + bt, 1.0 if kind == "o" else 0.8, dt=float(r.normal(0, 0.003)))
    gtr = gtr / dsp.peak(gtr)
    gtr = dsp.loop_apply(gtr, lambda z: ins.amp_sim(z, s.sr, gain=9.0, tone=4200))
    gtr = room(s, gtr / dsp.peak(gtr), 0.16, 0.9, "gtr", damp=4000)
    bass = line(s, ch, lambda c, n, i: [(0, 0.9, root_of(c, 33, 28, 39), 1.0), (1.5, 0.45, root_of(c, 33, 28, 39), 0.8),
                                        (2.5, 0.45, root_of(c, 33, 28, 39) + 12, 0.7), (3.0, 0.9, root_of(c, 33, 28, 39), 0.9)],
                v_gbass, r=r)
    bass = loop_filter(s, dsp.loop_apply(bass / dsp.peak(bass), lambda z: dsp.tube(z * 1.8, 1.2, s.sr, 0.1)), "lp", 3500)
    org = comp(s, ch, voicing(ch, 52, 70, 60, no_root), lambda c, i: [(0, c.dur - 0.05, 0.7)],
               lambda ss, m, du, v: v_organ(ss, m, du, v, bars=(8, 6, 8, 6, 0, 4, 0, 0, 0), perc=0.2, att=0.02, rel=0.1), r=r,
               mask=bs("5-8"))
    org = room(s, leslie(s, org, 6.2, 0.25), 0.16, 1.0, "organ", damp=4000)
    tn = tune("r:4 | r:4 | r:4 | r:4 | 5:.5 5:.5 3:.5 5:.5 1+:1 5:1 | 6:.5 6:.5 4+:.5 6:.5 1+:1 4:1 | 7:.5 5:.5 2+:1 5:1 7:1 | 1+:3 r:1", t, 4)
    lead = room(s, mono(s, tn, "guitar", key="stomp", drive=7.0), 0.14, 0.9, "lead", damp=4000)
    gg = gang(s, [(1, 3.0), (3, 3.0), (5, 3.0), (7, 2.5), (7, 3.0)], level=1.0)
    return {"drums": d, "tamb": room(s, tm, 0.14, 0.9, "tamb", damp=6000), "guitar": gtr, "bass": bass, "organ": org,
            "lead": lead, "gang": room(s, gg, 0.25, 1.0, "gang", damp=4500)}


# =================================================================== BEACH (D)

def root_fifth(c):
    """The bass root of a chord and its fifth (above, or below when that leaves the bass range)."""
    R = root_of(c, 40, 33, 47)
    return R, (R + 7 if R + 7 <= 50 else R - 5)


def beach_morning_samba(s):
    """128 BPM morning samba: tamborim and agogo over a light kick, bright nylon strums in a two-bar partido-alto
    figure, upright bass, a busy clarinet tune (choro style) and marimba answers."""
    r = dsp.rng(s.id, "msamba")
    t = s.tonic
    ch = s.chords
    k = kits(s, "jazz", "beach", "latin")
    d = s.zeros()
    hits(s, d, k["feather"], "X..xX..xX..xX..x", r, gain=0.75)
    hits(s, d, k["tamborim"], ["x.x.xx.x.x.xx.x.", "x.xx.x.x.xx.x.xx"], r, gain=0.55)
    hits(s, d, k["shaker"], "xoXoxoXoxoXoxoXo", r, swing=0.08, gain=0.5)
    hits(s, d, k["agogo_hi"], ["x...x.x.....x...", "..x...x...x.x..."], r, gain=0.4)
    hits(s, d, k["agogo_lo"], ["..x.......x...x.", "x...x...x......."], r, gain=0.4)
    hits(s, d, k["slap"], {3: "............x.xx", 7: "..........x.x.xx", 11: "........x.xxx.xx"}, r, gain=0.5)
    d = room(s, d, 0.13, 0.8, "perc", damp=6000)
    vo = voicing(ch, 57, 76, 66, no_root, span=12)

    def partido(c, i):
        a = [(0, 0.4, 0.8), (0.75, 0.3, 0.6), (1.5, 0.4, 0.75), (2.5, 0.3, 0.6), (3.25, 0.4, 0.7)]
        b = [(0.5, 0.3, 0.65), (1.25, 0.4, 0.75), (2.0, 0.3, 0.6), (2.75, 0.4, 0.75), (3.5, 0.3, 0.6)]
        return [p for p in (a if int(c.start // 4) % 2 == 0 else b) if p[0] < c.dur]
    gtr = strum_comp(s, ch, vo, partido, r=r, bright=0.6, t60=0.7, mute=0.05, spread=0.008)
    gtr = room(s, loop_filter(s, gtr, "hp", 180), 0.13, 0.9, "gtr", damp=5500)

    def bass(c, n, i):
        R, F = root_fifth(c)
        return [(0, 0.9, R, 0.9), (1.5, 0.45, F, 0.72)] + ([(2.0, 0.9, R, 0.85), (3.5, 0.45, F, 0.7)] if c.dur >= 4 else [])
    bs_ = room(s, loop_filter(s, line(s, ch, bass, v_upright, r=r), "lp", 1400), 0.05, 0.6, "bass", damp=2500)
    tn = tune("r:.5 5:.5 6:.25 5:.5 3:.75 5:.5 1+:1 | 7:.5 6:.5 5:.25 6:.5 3:.75 r:.5 6:1 |"
              " r:.5 4:.5 6:.25 4:.5 2:.75 4:.5 1+:1 | 7:.75 2+:.75 7:.5 5:1 r:1 |"
              " r:.5 3:.5 5:.25 1+:.5 3+:.75 2+:.5 1+:1 | 6:.75 1+:.75 6:.5 4:.5 6:.5 3+:1 |"
              " 2+:.5 7:.5 5:.25 7:.5 3:.75 5:.5 7:1 | 6:.75 1+:.75 6:.5 3:2 |"
              " r:.5 2:.5 4:.25 6:.5 1+:.75 6:.5 4:1 | 5:.5 7:.5 2+:.25 4+:.5 2+:.75 7:.5 5:1 |"
              " 3+:.75 1+:.75 6:.5 5:1 3:1 | 2:.5 4:.5 6:.5 4:.5 5:.5 7:.5 2+:1", t, 4)
    cl = room(s, mono(s, tn, "clarinet", key="msamba", grid=0.25), 0.18, 1.0, "clar", damp=5000)
    # marimba: a light off-beat figure, and a run of answers in every fourth bar (where the clarinet holds or rests)
    mar = s.zeros()
    for c in ch:
        tones = chord_notes(c, 69, 86)
        bar, off = int(c.start // 4), c.start % 4
        busy = bar % 4 == 3
        for j, bt in enumerate((2.0, 2.5, 2.75, 3.25, 3.5) if busy else (1.75, 3.75)):
            if not off <= bt < off + c.dur:
                continue
            m = tones[(j * 2 + bar) % len(tones)]
            s.add(mar, v_marimba(s, m, 0.4, 0.75 if busy else 0.5), bar * 4 + bt, dt=float(r.normal(0, 0.003)))
    mar = room(s, mar, 0.2, 1.0, "marimba", damp=6000)
    return {"drums": d, "guitar": gtr, "bass": bs_, "lead": cl, "arp": mar}


def sunset_hammock(s):
    """100 BPM sunset bossa: finger-picked nylon guitar (clave dyads over a thumb line), cajon and cross-stick,
    upright bass, held e-piano chords and a slow tenor sax tune."""
    r = dsp.rng(s.id, "sunset")
    t = s.tonic
    ch = s.chords
    k = kits(s, "beach")
    d = s.zeros()
    hits(s, d, k["cajon"], "X.....x.X.....x.", r, gain=0.7)
    hits(s, d, k["rim"], ["x..x..x...x..x..", "..x..x...x..x..."], r, gain=0.55)
    hits(s, d, k["shaker"], "o.x.o.x.o.x.o.x.", r, gain=0.4)
    hits(s, d, k["maraca"], "....x.......x...", r, gain=0.35)
    d = room(s, d, 0.14, 0.9, "drums", damp=5500)
    vo = voicing(ch, 52, 72, 62, no_root)
    clave = ((0.0, 1.5, 3.0), (1.0, 2.5))
    gtr = s.zeros()
    for c, v in zip(ch, vo):
        v = sorted(v)
        for q in range(int(c.dur * 2)):
            beat = c.start + q * 0.5
            bar, pos = int(beat // 4), beat % 4
            jit = float(r.normal(0, 0.004))
            if pos in clave[bar % 2]:
                for j, m in enumerate(v[-2:]):
                    s.add(gtr, v_nylon(s, m, 1.0, 0.7), beat, dt=jit + j * 0.012)
            else:
                low = v[:-2] or v[:1]
                s.add(gtr, v_nylon(s, low[q % len(low)], 0.5, 0.45), beat, dt=jit)
    gtr = room(s, loop_filter(s, gtr, "hp", 130), 0.18, 1.1, "gtr", damp=5000)

    def bass(c, n, i):
        R, F = root_fifth(c)
        return [(0, 1.4, R, 0.9), (1.5, 0.9, F, 0.72)] + ([(2.5, 0.9, R, 0.8)] if c.dur >= 4 else [])
    bs_ = room(s, loop_filter(s, line(s, ch, bass, v_upright, r=r), "lp", 1100), 0.06, 0.6, "bass", damp=2500)
    ep = comp(s, ch, voicing(ch, 57, 77, 67, guide), lambda c, i: [(0, c.dur * 0.9, 0.5)],
              lambda ss, m, du, v: v_epiano(ss, m, du, v, bright=0.5, rel=0.5), r=r, spread=0.02)
    ep = room(s, loop_filter(s, ep, "lp", 3500), 0.28, 1.6, "keys", damp=4500)
    tn = tune("r:1 3:.5 5:.5 7:1.5 6:.5 | 5:2.5 3:.5 2:1 | r:.5 4:.5 6:.5 1+:.5 7:1.5 6:.5 | 5:2 r:.5 2:.5 4:.5 5:.5 |"
              " 6:1.5 1+:.5 3+:1.5 2+:.5 | 1+:1 6:.5 4:.5 3:2 | r:.5 6:.5 7:.5 1+:.5 2+:1.5 1+:.5 | 1+:.5 6:2.5 r:1",
              t, 4)
    sax = mono(s, tn, "sax", key="sunset")
    sax = room(s, echo(s, loop_filter(s, sax, "lp", 4200), 0.75, 0.12, 0.3, 2, 3500), 0.26, 1.5, "sax", damp=4500)
    return {"drums": d, "guitar": gtr, "bass": bs_, "keys": ep, "lead": sax}


def night_tide(s):
    """88 BPM lullaby-bossa by the night sea: slow soft nylon strums, long upright notes, a celesta tune, vibraphone
    chords, a hummed second voice in the second half, a quiet shaker and the wash of a wave every two bars."""
    r = dsp.rng(s.id, "tide")
    t = s.tonic
    ch = s.chords
    k = kits(s, "beach")
    d = s.zeros()
    hits(s, d, k["shaker"], "o...o.g.o...o.g.", r, gain=0.45)
    hits(s, d, k["rim"], "............o...", r, gain=0.35)
    hits(s, d, k["cajon"], "x...............", r, gain=0.5)
    d = room(s, d, 0.2, 1.2, "drums", damp=4500)
    # waves: one slow swell of band-passed noise every two bars (periodic over the loop)
    nz = dsp.loop_apply(dsp.rng(s.id, "waves").standard_normal(s.n), lambda z: dsp.bandpass(z, 300, 3200, s.sr))
    ph = np.arange(s.n) / s.n * (s.bars / 2.0)
    sea = nz / np.std(nz) * (0.08 + (0.5 - 0.5 * np.cos(TAU * (ph - 0.3))) ** 3)
    vo = voicing(ch, 52, 71, 61, no_root)
    gtr = strum_comp(s, ch, vo,
                     lambda c, i: [(0, 1.4, 0.7), (1.5, 0.45, 0.45)] + ([(2.5, 1.2, 0.55)] if c.dur >= 4 else []),
                     r=r, bright=0.2, t60=1.6, mute=0.04, spread=0.022, alt=False)
    gtr = room(s, loop_filter(s, loop_filter(s, gtr, "hp", 120), "lp", 3800), 0.22, 1.5, "gtr", damp=4000)

    def bass(c, n, i):
        R, F = root_fifth(c)
        return [(0, min(c.dur, 2.4), R, 0.85)] + ([(2.5, 1.2, F, 0.6)] if c.dur >= 4 else [])
    bs_ = room(s, loop_filter(s, line(s, ch, bass, v_upright, r=r), "lp", 900), 0.06, 0.6, "bass", damp=2500)
    tn = tune("3:1.5 5:.5 3:1 1:1 | 6:1.5 1+:.5 6:2 | 5:1.5 6:.5 5:1 3:1 | 2:1 3:1 1:2 |"
              " 4:1.5 6:.5 4:1 2:1 | 5:1.5 4:.5 2:2 | 6:1 1+:1 7:1 5:1 | 4:1 2:1 7-:1 2:1", t, 5)
    cel = lay(s, lambda ss, m, du, v: v_celesta(ss, m, du, v * 0.8, t60=1.1), tn, r=r, jit=0.005)
    cel = room(s, echo(s, cel, 1.5, 0.12, 0.3, 2, 4000), 0.3, 1.8, "celesta", damp=5000)
    vib = comp(s, ch, voicing(ch, 60, 79, 69, guide), lambda c, i: [(0, c.dur * 0.85, 0.45)], v_vibes, r=r,
               spread=0.03)
    vib = room(s, vib, 0.28, 1.8, "vibes", damp=4500)
    hum_tn = [(b + 16.0, du, m, v) for b, du, m, v in tune("6:4 | 5:4 | 6:2 5:2 | 4:2 5:2", t, 4)]
    hum = lay(s, lambda ss, m, du, v: v_vox(ss, m, du * 0.92, v, vowel="u_alto", key=m % 3, burst=False), hum_tn)
    hum = room(s, loop_filter(s, hum, "lp", 2400), 0.35, 2.0, "hum", damp=3500)
    return {"drums": d, "fx": sea, "guitar": gtr, "bass": bs_, "lead": cel, "vibes": vib, "voice": hum}


def coconut_cha_cha(s):
    """120 BPM beach-party cha-cha-cha: guiro, cowbell on the beat, conga tumbao, piano stabs, a bouncing bass and
    a marimba tune in thirds that ends its phrases with the three 'cha-cha-cha' hits."""
    r = dsp.rng(s.id, "chacha")
    t = s.tonic
    ch = s.chords
    k = kits(s, "jazz", "beach", "latin")
    d = s.zeros()
    hits(s, d, k["guiro"], "x...x.x.x...x.x.", r, gain=0.5)
    hits(s, d, k["bell"], "x...o...x...o...", r, gain=0.4)
    hits(s, d, k["conga_hi"], "g.g.X.g.g.g.....", r, gain=0.6)
    hits(s, d, k["conga_lo"], "............x.x.", r, gain=0.7)
    hits(s, d, k["feather"], "X.......x.......", r, gain=0.8)
    hits(s, d, k["slap"], "........X.X.X...", r, gain=0.6, mask=bs("4,8,12"))
    hits(s, d, k["maraca"], "..x...x...x...x.", r, gain=0.3)
    d = room(s, d, 0.13, 0.8, "perc", damp=6000)
    vo = voicing(ch, 57, 77, 67, no_root, span=12)
    pno = comp(s, ch, vo, lambda c, i: [p for p in ((0, 0.4, 0.7), (1.5, 0.4, 0.6), (2.0, 0.4, 0.75), (3.5, 0.4, 0.6))
                                        if p[0] < c.dur],
               lambda ss, m, du, v: v_piano(ss, m, du, v, bright=0.7, rel=0.1), r=r, spread=0.004)
    pno = room(s, loop_filter(s, pno, "hp", 200), 0.14, 0.9, "piano", damp=5500)

    def bass(c, n, i):
        R, F = root_fifth(c)
        return [(0, 1.4, R, 0.9)] + ([(2.0, 0.9, F, 0.8), (3.0, 0.9, R, 0.85)] if c.dur >= 4 else [(1.0, 0.9, F, 0.75)])
    bs_ = room(s, loop_filter(s, line(s, ch, bass, v_upright, r=r), "lp", 1500), 0.05, 0.6, "bass", damp=2500)
    tn = tune("1:.5 3:.5 5:1 3:.5 5:.5 1+:1 | 6:.5 1+:.5 6:1 4:.5 6:.5 4:1 | 5:.5 7:.5 2+:1 7:.5 2+:.5 4+:1 |"
              " 3+:1 1+:1 3+!:.5 3+!:.5 3+!:1 | 3+:.5 1+:.5 6:1 1+:.5 3+:.5 6:1 | 4:.5 6:.5 1+:1 6:.5 4:.5 2:1 |"
              " 5:.5 4:.5 2:1 4:.5 5:.5 7:1 | 1+:1 5:1 1+!:.5 1+!:.5 1+!:1 | 6:1 1+:.5 3+:.5 1+:1 6:1 |"
              " 5:1 6:.5 1+:.5 6:1 5:1 | 4:.5 6:.5 4:.5 2:.5 5:.5 7:.5 2+:.5 4+:.5 | 3+:1 r:1 1+!:.5 1+!:.5 1+!:1", t, 4)
    mar = s.zeros()
    for b, du, m, v in tn:
        j = float(r.normal(0, 0.003))
        s.add(mar, v_marimba(s, m, du, v), b, dt=j)
        s.add(mar, v_marimba(s, scale_step(t, scale_step(t, m, False), False), du, v * 0.6), b, dt=j + 0.004)
    mar = room(s, mar, 0.18, 1.0, "marimba", damp=6000)
    return {"drums": d, "keys": pno, "bass": bs_, "lead": mar}


# ================================================================ CARNIVAL (C)

def v_baby(s, m, d, v=0.8):
    """The baby bass of the carnival theme (music.baby_bass)."""
    return M.baby_bass(m, s.sec(min(d, 2.5)), s.sr, key=m % 3) * v


def tumbao(c, n, i):
    """Salsa bass for line(): nothing on beat 1; the fifth (or the next chord's root) on the and of 2 and the root
    of the next bar on beat 4, tied over the bar line."""
    R, F = root_fifth(c)
    N = root_of(n, 40, 33, 47)
    if c.dur >= 4:
        return [(1.5, 1.4, F, 0.85), (3.0, 2.3, N, 0.95)]
    return [(1.5, 1.4, N, 0.85)] if c.start % 4 == 0 else [(1.0, 2.3, N, 0.95)]


def conga_tumbao(s, d, k, r, gain=1.0, mask=None):
    """The conga pattern of the theme on a grid of 8ths, in 2-3: heel-toe-slap-toe, two open tones on beat 4, the
    low drum on beat 3 of every second bar."""
    hits(s, d, k["heel"], "o...o...", r, gain=0.7 * gain, mask=mask)
    hits(s, d, k["toe"], ".g.g.g..", r, gain=0.8 * gain, mask=mask)
    hits(s, d, k["slap"], "..X.....", r, gain=0.8 * gain, mask=mask)
    hits(s, d, k["open"], "......Xx", r, gain=0.9 * gain, mask=mask)
    hits(s, d, k["tumba"], ["........", "....Xx.."], r, gain=0.85 * gain, mask=mask)


def second_voice(s, evs, gain=0.7):
    """The second voice of a duo: under every note of the tune, the nearest note of the chord that is at least
    a minor third lower (thirds and fourths that always belong to the harmony)."""
    out = []
    for b, d, m, v in evs:
        pcs = set(chord_at(s, b).pcs())
        out.append((b, d, max(x for x in range(m - 9, m - 2) if x % 12 in pcs), v * gain))
    return out


def salsa_confetti(s):
    """180 BPM salsa dura on a grid of 8ths, 2-3 clave: cascara on the timbale shells (the bell in the second
    half), congas and maracas, an arpeggiated piano guajeo in octaves, the anticipated baby bass, a trumpet
    tune and a brass section that answers it at the end of every four bars."""
    r = dsp.rng(s.id, "confetti")
    t = s.tonic
    ch = s.chords
    k = kits(s, "latin", "carnival")
    d = s.zeros()
    hits(s, d, k["clave"], ["..x.x...", "x..x..x."], r, gain=0.5)
    hits(s, d, k["rim"], ["x.x.xx.x", "x.xx.x.x"], r, gain=0.55, mask=bs("1-8"))
    hits(s, d, k["bell"], ["X.xxX.xx", "X.x.X.xx"], r, gain=0.45, mask=bs("9-16"))
    conga_tumbao(s, d, k, r)
    hits(s, d, k["maraca"], "xoxoxoxo", r, gain=0.4)
    hits(s, d, k["kick"], "x.......", r, gain=0.6)
    hits(s, d, k["bongo_hi"], {7: "....x.xxx.x.....", 15: "....x.xxx.xx...."}, r, gain=0.7)
    hits(s, d, k["bongo_lo"], {7: "...........x.xX.", 15: "............x.XX"}, r, gain=0.8)
    d = room(s, d, 0.11, 0.7, "perc", damp=6000)
    # guajeo: single chord tones in octaves on the montuno rhythm (on the beat in the two-side bar, off-beats in
    # the three-side bar); the last 8th of a bar already plays the next chord
    pno = s.zeros()
    for bar in range(s.bars):
        steps = ((0.0, 1), (1.0, 2), (1.5, 3), (2.5, 2), (3.5, 1)) if bar % 2 == 0 else \
            ((0.5, 2), (1.5, 3), (2.5, 2), (3.5, 1))
        for bt, i in steps:
            c = chord_at(s, bar * 4 + bt + (0.5 if bt == 3.5 else 0.0))
            R = nearest(c.root, 62, 57, 68)
            m = [R, R + (3 if 3 in c.tones else 4), R + 7, R + (9 if 9 in c.tones else 10)][i]
            du = 0.9 if bt in (1.5, 3.5) else 0.45
            j = float(r.normal(0.003, 0.003))
            for mm, g in ((m, 0.8), (m + 12, 1.0)):
                s.add(pno, v_piano(s, mm, du, 0.75, bright=1.0, rel=0.1), bar * 4 + bt, g, dt=j)
    pno = room(s, loop_filter(s, pno, "hp", 200), 0.11, 0.8, "piano", damp=5500)
    bs_ = room(s, loop_filter(s, line(s, ch, tumbao, v_baby, r=r), "lp", 1500), 0.05, 0.6, "bass", damp=2500)
    tn = tune("1:1.5 3:.5 5:1 3:1 | 6:1.5 5:.5 3:2 | 2:1.5 4:.5 6:1 4:1 | 5:1.5 4:.5 2:2 |"
              " r:1 4:1 6:1 1+:1 | 7:1.5 6:.5 5:1 4:1 | 3:3 5:1 | 1+:2 r:2 |"
              " r:1 6:1 1+:1 6:1 | 4:1.5 6:.5 1+:2 | r:1 5:1 1+:1 5:1 | 3:1.5 5:.5 1+:2 |"
              " 2+:1 1+:1 6:1 4:1 | 7:1 6:1 5:1 7:1 | 1+:4 | r:1 5-:1 6-:1 7-:1", t, 5)
    tp = room(s, mono(s, tn, "trumpet", key="confetti"), 0.16, 1.0, "tpt", damp=4500)
    stabs = {3: [(2.5, 0.4, 0.85), (3.5, 0.45, 0.95)], 7: [(2.0, 0.4, 0.9), (3.0, 0.4, 0.85), (3.5, 0.45, 0.95)],
             11: [(2.5, 0.4, 0.85), (3.5, 0.45, 0.95)], 14: [(0.5, 0.4, 0.8), (1.5, 0.4, 0.85), (2.5, 1.2, 0.95)]}
    br = comp(s, ch, voicing(ch, 58, 77, 67, no_root), lambda c, i: stabs.get(int(c.start // 4), []), v_brass, r=r)
    br = room(s, br, 0.15, 0.9, "brass", damp=5000)
    return {"drums": d, "keys": pno, "bass": bs_, "lead": tp, "brass": br}


def moonlit_cumbia(s):
    """96 BPM cumbia: the low drum on 1 and 3 and the high drum on every off-beat, maracas and a guiro, the
    'chk-a' of a nylon guitar after each beat, an upright bass that climbs root-third-fifth, two cane flutes
    in thirds and a marimba that answers them at the end of each phrase."""
    r = dsp.rng(s.id, "mcumbia")
    t = s.tonic
    ch = s.chords
    k = kits(s, "latin", "carnival")
    d = s.zeros()
    hits(s, d, k["kick"], "X.......X.......", r, gain=0.8)
    hits(s, d, k["tumba"], "......x....x..x.", r, gain=0.6)
    hits(s, d, k["open"], "..x...x...x...x.", r, gain=0.55)
    hits(s, d, k["maraca"], "o.X.o.X.o.X.o.X.", r, gain=0.4)
    hits(s, d, k["guiro"], "x.......x.......", r, gain=0.3)
    hits(s, d, k["guiro_short"], "....x.x.....x.x.", r, gain=0.26)
    hits(s, d, k["bongo_hi"], {3: "..........x.xx..", 7: "........x.xxx.x."}, r, gain=0.5)
    d = room(s, d, 0.13, 0.8, "perc", damp=6000)
    gtr = strum_comp(s, ch, voicing(ch, 60, 79, 69, no_root, span=12),
                     [(b + o, du, v) for b in range(4) for o, du, v in ((0.5, 0.2, 0.75), (0.75, 0.15, 0.45))],
                     r=r, bright=0.6, t60=0.5, mute=0.04, spread=0.007)
    gtr = room(s, loop_filter(s, gtr, "hp", 200), 0.13, 0.9, "gtr", damp=5500)

    def bass(c, n, i):
        R = root_of(c, 40, 33, 45)
        return [(0, 1.8, R, 0.9), (2.0, 0.9, R + (3 if 3 in c.tones else 4), 0.75), (3.0, 0.9, R + 7, 0.8)]
    bs_ = room(s, loop_filter(s, line(s, ch, bass, v_upright, r=r), "lp", 1400), 0.05, 0.6, "bass", damp=2500)
    tn = tune("5:1 3:.5 5:.5 1+:1.5 5:.5 | 4:.5 5:.5 4:.5 2:.5 7-:1 2:1 | 4:1 2:.5 4:.5 5:1.5 4:.5 |"
              " 3:.5 4:.5 3:.5 2:.5 1:2 | 6:1 4:.5 6:.5 1+:1.5 6:.5 | 5:.5 6:.5 5:.5 3:.5 1:1 3:1 |"
              " 2:.5 4:.5 5:.5 7:.5 2+:1 7:1 | 1+:3 r:1", t, 5)
    fl = room(s, mono(s, tn, "flute", key="mcumbia", grid=0.25), 0.2, 1.1, "flute", damp=5500)
    fl2 = room(s, mono(s, second_voice(s, tn), "flute", key="mcumbia2", grid=0.25), 0.2, 1.1, "flute2", damp=5000)
    mar = s.zeros()
    for bar, notes in ((3, ((2.0, 79), (2.5, 76), (3.0, 72), (3.5, 74))), (7, ((2.0, 84), (2.5, 79), (3.0, 76), (3.5, 79)))):
        for i, (bt, m) in enumerate(notes):
            j = float(r.normal(0, 0.003))
            s.add(mar, v_marimba(s, m, 0.5, 0.75), bar * 4 + bt, dt=j)
            s.add(mar, v_marimba(s, m - 12, 0.5, 0.5), bar * 4 + bt, dt=j + 0.004)
    mar = room(s, mar, 0.2, 1.0, "marimba", damp=6000)
    return {"drums": d, "guitar": gtr, "bass": bs_, "lead": fl, "flute2": fl2, "arp": mar}


def candlelight_bolero(s):
    """80 BPM bolero for a guitar trio: the requinto sings the tune in thirds (and trembles on its long notes),
    a second nylon guitar rolls the chords in 8ths over the thumb, an upright bass plays the bolero figure
    (long, short, long), bongos and maracas whisper the 8ths and strings hold the harmony."""
    r = dsp.rng(s.id, "bolero")
    t = s.tonic
    ch = s.chords
    k = kits(s, "latin", "carnival")
    d = s.zeros()
    hits(s, d, k["bongo_hi"], "o.g.x.g.o.g.x...", r, gain=0.5)
    hits(s, d, k["bongo_lo"], "..............x.", r, gain=0.55)
    hits(s, d, k["maraca"], "x.o.x.o.x.o.x.o.", r, gain=0.22)
    hits(s, d, k["tumba"], "............o...", r, gain=0.4)
    d = room(s, d, 0.18, 1.1, "perc", damp=5000)
    gtr = s.zeros()
    for c, v in zip(ch, voicing(ch, 55, 72, 63)):
        v = sorted(v)
        for q in range(int(c.dur * 2)):
            j = float(r.normal(0, 0.004))
            if q % 8 == 0:
                s.add(gtr, v_nylon(s, root_of(c, 47, 40, 52), 1.6, 0.7), c.start, dt=j)
            else:
                m = v[(0, 1, 2, 1, 0, 1, 2)[(q - 1) % 7] % len(v)]
                s.add(gtr, v_nylon(s, m, 0.9, 0.5 if q % 2 else 0.6), c.start + q * 0.5, dt=j)
    gtr = room(s, loop_filter(s, gtr, "hp", 110), 0.2, 1.3, "gtr", damp=4500)

    def bass(c, n, i):
        R, F = root_fifth(c)
        return [(0, 1.4, R, 0.9), (1.5, 0.45, R, 0.6)] + ([(2.0, 1.8, F, 0.8)] if c.dur >= 4 else [])
    bs_ = room(s, loop_filter(s, line(s, ch, bass, v_upright, r=r), "lp", 1000), 0.06, 0.6, "bass", damp=2500)
    tn = tune("r:.5 3:.5 5:.5 1+:.5 7:1.5 5:.5 | 6:2.5 5:.5 3:1 | r:.5 2:.5 4:.5 6:.5 5:1.5 4:.5 |"
              " 2:2 r:.5 5-:.5 7-:.5 2:.5 | 5:1.5 7:.5 2+:1.5 7:.5 | 1+:2 6:1 3:1 |"
              " 4:1 6:.5 2+:.5 7:1 5:.5 7:.5 | 1+:2.5 r:1.5", t, 5)

    def requinto(ss, m, du, v):
        """A small bright nylon guitar; a note of two beats or more is kept alive with a tremolo of 16ths."""
        if du < 2.0:
            return ins.guitar(m, ss.sec(du), ss.sr, bright=0.5, t60=1.4, pick=0.15, mute=0.08, key=m % 3,
                              attack=0.002) * v
        out = np.zeros(nsamp(ss.sec(du) + 0.6, ss.sr))
        for i in range(int(round(du / 0.25))):
            x = ins.guitar(m, ss.sec(0.4), ss.sr, bright=0.5, t60=0.9, pick=0.15, mute=0.06, key=i % 3, attack=0.002)
            p0 = nsamp(ss.sec(i * 0.25), ss.sr)
            out[p0: p0 + len(x)] += x[: len(out) - p0] * (1.0 if i == 0 else 0.62 - 0.02 * min(i, 8))
        return out * v
    req = lay(s, requinto, tn, r=r, jit=0.004) + lay(s, requinto, second_voice(s, tn, 0.6), r=r, jit=0.004, dt=0.006)
    req = dsp.drive(req / dsp.peak(req) * 1.3, 1.4)  # rounds the pick transients (the limiter then has little to do)
    req = room(s, echo(s, loop_filter(s, req, "hp", 180), 0.75, 0.08, 0.3, 2, 3500), 0.24, 1.5, "requinto", damp=5000)
    st = comp(s, ch, voicing(ch, 55, 74, 64, lambda c: c.tones[:3]), lambda c, i: [(0, c.dur * 0.95, 0.5)], v_strings,
              r=r)
    st = room(s, loop_filter(s, st, "lp", 3200), 0.25, 1.6, "strings", damp=4000)
    return {"drums": d, "guitar": gtr, "bass": bs_, "lead": req, "strings": st}


def mambo_fireworks(s):
    """156 BPM big-band mambo on a grid of 8ths: two saxophones riff on the chord tones (root, third, fifth,
    sixth), the trumpets answer with off-beat stabs and take the tune in the bridge, the mambo bell rings the
    beats over congas, and the band shouts in the two breaks."""
    r = dsp.rng(s.id, "mambo")
    t = s.tonic
    ch = s.chords
    k = kits(s, "dance", "latin", "carnival")
    brk = (7, 15)  # the bars where the riff stops (0-based)
    play = set(range(s.bars)) - set(brk)
    d = s.zeros()
    hits(s, d, k["bell"], ["X.xxX.xx", "X.x.X.xx"], r, gain=0.6, mask=play)
    hits(s, d, k["clave"], ["..x.x...", "x..x..x."], r, gain=0.4)
    conga_tumbao(s, d, k, r, mask=play)
    hits(s, d, k["maraca"], "xoxoxoxo", r, gain=0.4)
    hits(s, d, k["kick"], "X...x...", r, gain=0.5, mask=play)
    hits(s, d, k["crash"], {0: "x.......", 8: "x......."}, r, gain=0.35, jit=0.0)
    hits(s, d, k["bongo_hi"], {7: "x.xx.x.x........", 15: "x.xx.x.x........"}, r, gain=0.75)
    hits(s, d, k["surdo_hi"], {7: "........x.......", 15: "........x......."}, r, gain=0.9)
    hits(s, d, k["bongo_lo"], {7: "............x.xx", 15: "............xxxx"}, r, gain=0.8)
    d = room(s, d, 0.12, 0.7, "perc", damp=6000)

    def chord_run(c):
        R = nearest(c.root, 60, 55, 66)
        return [R, R + (3 if 3 in c.tones else 4), R + 7, R + (9 if 9 in c.tones else 10), R + 12]
    low, high = [], []
    for bar in sorted(play):
        for bt, du, i, v in ((0, 0.5, 0, 0.9), (0.5, 0.5, 1, 0.7), (1.0, 1.0, 2, 0.85), (2.0, 0.5, 3, 0.9),
                             (2.5, 1.0, 2, 0.8), (3.5, 0.5, 1, 0.7)):
            run = chord_run(chord_at(s, bar * 4 + bt))
            low.append((bar * 4 + bt, du, run[i], v))
            high.append((bar * 4 + bt, du, run[i + 1], v))
    sax = mono(s, low, "sax", key="mambo_tenor") + 0.75 * mono(s, high, "sax", key="mambo_alto")
    sax = room(s, loop_filter(s, sax, "lp", 6000), 0.14, 0.9, "sax", damp=4500)

    def stab(c, i):
        bar = int(c.start // 4)
        if bar in brk:
            return [(0, 0.4, 0.95)] if c.start % 4 == 0 else []
        if bar < 8:
            return [(1.5, 0.3, 0.85), (2.5, 0.3, 0.8), (3.5, 0.45, 0.95)] if bar % 2 == 1 else []
        return [(1.5, 0.3, 0.7)] if c.dur >= 4 else []
    br = room(s, comp(s, ch, voicing(ch, 62, 81, 71, no_root), stab, v_brass, r=r), 0.15, 0.9, "brass", damp=5000)
    tn = tune("r:4 | r:4 | r:4 | r:4 | r:4 | r:4 | r:4 | r:4 |"
              " 6:1.5 1+:.5 6:2 | 5:1.5 1+:.5 5:2 | 4:1 5:1 7:1 2+:1 | 1+:3 r:1 |"
              " 6:1.5 1+:.5 2+:2 | 1+:1.5 5:.5 3:2 | 4:1 6:1 5:1 7:1 | 1+:1 r:3", t, 5)
    tp = room(s, mono(s, tn, "trumpet", key="mambo"), 0.16, 1.0, "tpt", damp=4500)

    def bass(c, n, i):
        R, F = root_fifth(c)
        N = root_of(n, 40, 33, 47)
        if c.dur < 4:
            return [(0, 0.9, R, 0.9), (1.0, 0.9, N, 0.8)]
        return [(0, 0.9, R, 0.95), (1.5, 1.4, F, 0.8), (3.0, 0.9, N, 0.85)]
    bs_ = room(s, loop_filter(s, line(s, ch, bass, v_baby, r=r), "lp", 1500), 0.05, 0.6, "bass", damp=2500)
    pno = comp(s, ch, voicing(ch, 57, 76, 66, no_root), [(1.0, 0.3, 0.6), (2.5, 0.3, 0.6)],
               lambda ss, m, du, v: v_piano(ss, m, du, v, bright=0.8, rel=0.1), r=r, spread=0.004, mask=play)
    pno = room(s, loop_filter(s, pno, "hp", 200), 0.12, 0.8, "piano", damp=5500)
    shout = gang(s, [(b, 2.0) for b in brk], voices=7, lo=110, hi=200, key="uh")
    return {"drums": d, "sax": sax, "brass": br, "lead": tp, "bass": bs_, "keys": pno,
            "gang": room(s, shout, 0.2, 1.0, "gang", damp=5000)}


# ================================================================== CINEMA (Eb)
# A small film orchestra (the voices of the district theme in music.py: bowed and plucked strings, french horns,
# harp, timpani). The genre "cinematic" of songs_ambient.py is another thing: string pads under a brass tune.

def v_bow(s, m, d, v=0.8, k=0, att=0.07, vib=1.0, cutoff=2600.0, rel=0.2):
    return M.bowed(m, s.sec(d), s.sr, key=k, attack=att, release=rel, vib=vib, cutoff=cutoff) * v


def v_horn(s, m, d, v=0.8, k=0):
    return M.horn(m, s.sec(d), s.sr, vel=v, key=k)


def v_harp(s, m, d=1.0, v=0.7):
    return M.harp(m, s.sr, key=m % 2) * v


def v_opizz(s, m, d=0.3, v=0.8):
    return M.pizz(m, s.sr, key=m % 3) * v


def v_timp(s, m, v=0.8):
    return M.timpani(m, s.sr, hard=round(0.3 + 0.7 * v, 1)) * v


def timp_roll(s, buf, end_beat, m, beats=2.0, lo=0.2, hi=0.8):
    """A timpani roll on `m` (eight strokes a beat) that swells up to `end_beat`."""
    n = int(round(beats * 8))
    for i in range(n):
        s.add(buf, v_timp(s, m, lo + (hi - lo) * i / n), end_beat - beats + i / 8.0)


def harp_gliss(s, buf, end_beat, top, n=12, beats=1.0, gain=1.0):
    """A harp glissando up the scale of the key: `n` strings in `beats` beats, landing on `top` at `end_beat`."""
    run = [m for m in range(48, top + 1) if (m - s.tonic) % 12 in MAJOR][-(n + 1):]
    for i, m in enumerate(run[:-1]):
        s.add(buf, M.harp(m, s.sr, key=2, dur=0.6), end_beat - beats + i * beats / n, gain * (0.3 + 0.5 * i / n))
    s.add(buf, M.harp(run[-1], s.sr, key=3), end_beat, gain)


def choir_even(s, chords, lo=60, hi=79, center=69):
    """A sustained choir "ah" on the chords like choir_pad, but sung note by note (music.choir_ah): every note
    has the same level, whichever formant it sits on."""
    buf = s.zeros()
    for c, v in zip(chords, voicing(chords, lo, hi, center, no_root, span=14)):
        for j, m in enumerate(v):
            s.add(buf, M.choir_ah(m, s.sec(c.dur) + 0.1, s.sr, key=j), c.start - 0.05)
    return room(s, loop_filter(s, buf, "hp", 150), 0.45, 2.4, "choir", damp=5000, predelay=0.03)


def adventure_overture(s):
    """132 BPM overture: violins gallop on the chords (an 8th and two 16ths a beat), a trumpet plays the fanfare
    tune, french horns answer it and hold the middle section, timpani on root and fifth, a soft snare gallop,
    the bass drum and two cymbal crashes; a timpani roll leads back to the top."""
    r = dsp.rng(s.id, "overture")
    t, ch = s.tonic, s.chords
    k = kits(s, "march", "cinema")
    d = s.zeros()
    hits(s, d, k["snare"], ["x.ogx.ogx.ogx.oo", "x.ogx.ogx.ogxooo"], r, gain=0.5)
    hits(s, d, k["bd"], "X.......x.......", r, gain=0.45)
    hits(s, d, k["crash"], {0: "X...............", 8: "X..............."}, r, gain=0.5, jit=0.0)
    d = room(s, d, 0.16, 1.2, "drums", damp=6000)
    tp = s.zeros()
    for i, c in enumerate(ch):
        R = root_of(c, 44, 39, 50)
        F = R + 7 if R + 7 <= 50 else R - 5
        for bt, m, v in ((0, R, 0.95), (2, F, 0.7), (3, F, 0.5), (3.5, R, 0.6)):
            if i < len(ch) - 1 or bt < 2:
                s.add(tp, v_timp(s, m, v), c.start + bt, dt=float(r.normal(0.002, 0.002)))
    timp_roll(s, tp, s.beats, root_of(ch[-1], 44, 39, 50))
    tp = room(s, loop_filter(s, tp, "hp", 45), 0.18, 1.4, "timp", damp=4000)
    st = s.zeros()
    for c, v in zip(ch, voicing(ch, 60, 77, 68)):
        for q in range(int(c.dur)):
            for bt, du, vel in ((0.0, 0.4, 0.85), (0.5, 0.2, 0.55), (0.75, 0.2, 0.65)):
                for j, m in enumerate(v):
                    s.add(st, v_bow(s, m, du, vel, k=j, att=0.012, vib=0.0, cutoff=3000.0, rel=0.06), c.start + q + bt,
                          dt=float(r.normal(0.003, 0.002)))
    st = room(s, loop_filter(s, st, "hp", 200), 0.2, 1.4, "strings", damp=5000)

    def bass(c, n, i):
        R = root_of(c, 46, 41, 52)
        return [(0, 1.6, R, 0.9), (2, 0.9, R, 0.75), (3, 0.9, R + 7 if R + 7 <= 53 else R - 5, 0.8)]
    bs_ = line(s, ch, bass, lambda ss, m, du, v: v_bow(ss, m, du, v, k=5, att=0.03, vib=0.0, cutoff=1200.0, rel=0.1),
               r=r)
    bs_ = room(s, loop_filter(s, bs_, "lp", 1200), 0.1, 1.0, "bass", damp=2500)
    tn = tune("5:.5 5:.25 5:.25 1+:1 5:1 1+:1 | 3+:1.5 2+:.5 1+:2 | 6:.5 6:.25 6:.25 1+:1 4+:1.5 3+:.5 |"
              " 2+:1 1+:1 5:1 r:1 | 3+:1.5 1+:.5 6:2 | 4+:1.5 2+:.5 6:2 | 5:1 7:1 2+:1 4+:1 | 5+:2.5 r:.5 5:.5 5:.5 |"
              " 5:.5 5:.25 5:.25 1+:1 5:1 1+:1 | 3+:1.5 2+:.5 1+:2 | 6:.5 6:.25 6:.25 1+:1 4+:1.5 3+:.5 |"
              " 3+:1 5+:1 3+:1 r:1 | 4+:1.5 3+:.5 4+:1 6:1 | 5+:1.5 4+:.5 2+:1 7:1 | 1+:3 r:1 | r:4", t, 4)
    tr = room(s, mono(s, tn, "trumpet", key="overture"), 0.18, 1.3, "tpt", damp=4500)

    def call(c, i):
        bar = int(c.start // 4)
        if bar in (4, 5, 6, 7, 12, 13, 14):
            return [(0, 3.6, 0.75)]
        if bar == 15:  # the horns alone turn the tune round: long, short-short-long
            return [(0, 1.4, 0.8), (2, 0.4, 0.8), (2.75, 0.2, 0.7), (3, 0.9, 0.9)]
        return [(0, 0.5, 0.8)] + ([(2.5, 0.4, 0.7), (3, 0.9, 0.85)] if bar in (3, 11) else [])
    hn = room(s, comp(s, ch, voicing(ch, 55, 70, 63), call, v_horn, r=r), 0.22, 1.5, "horns", damp=4500)
    return {"drums": d, "timp": tp, "strings": st, "bass": bs_, "lead": tr, "brass": hn}


def balcony_waltz(s):
    """112 BPM love theme, a waltz (three beats a bar, sixteen bars): a solo violin sings over a harp that plays
    the bass on one and the chord on two and three, a clarinet joins a third or a sixth below in the second half
    and answers alone in the last bar, cellos hold the roots, strings the chords, a celesta echoes every fourth
    bar. No percussion."""
    r = dsp.rng(s.id, "waltz")
    t, ch = s.tonic, s.chords
    hp = s.zeros()
    for c, v in zip(ch, voicing(ch, 58, 74, 66, no_root)):
        for w in range(int(c.dur // 3)):
            o = c.start + w * 3
            R = root_of(c, 44, 39, 50)
            s.add(hp, v_harp(s, R if w == 0 else R + 7, 1.0, 0.9), o, dt=float(r.normal(0.003, 0.003)))
            for bt, vel in ((1, 0.55), (2, 0.5)):
                for j, m in enumerate(v):
                    s.add(hp, v_harp(s, m, 1.0, vel), o + bt, dt=j * 0.012 + float(r.normal(0.003, 0.003)))
    hp = room(s, loop_filter(s, hp, "hp", 70), 0.24, 1.7, "harp", damp=6000)
    tn = tune("5:2 3+:1 | 3+:1.5 2+:.5 1+:1 | 6:1 2+:1 4+:1 | 4+:1.5 3+:.5 2+:1 |"
              " 5:2 3+:1 | 5+:1.5 3+:.5 1+:1 | 4+:2 1+:1 | 2+:2 5:1 |"
              " 7:1 3+:1 5+:1 | 5+:2 3+:1 | 4+:1 2+:1 6:1 | 7:1.5 1+:.5 2+:1 |"
              " 4+:1.5 3+:.5 1+:1 | 2+:1 7:1 2+:1 | 1+:3 | r:3", t, 4, bar=3.0)
    vn = lay(s, lambda ss, m, du, v: v_bow(ss, m, du, v, k=3, att=0.06, vib=1.3, cutoff=3400.0, rel=0.22), tn, r=r,
             jit=0.006)
    vn = room(s, loop_filter(s, vn, "hp", 180), 0.3, 1.9, "violin", damp=5000, predelay=0.025)
    cl = second_voice(s, [e for e in tn if e[0] >= 24], 0.9) + [(45.0, 1.0, 58, 0.7), (46.0, 1.0, 63, 0.75),
                                                                  (47.0, 1.0, 67, 0.8)]
    cl = room(s, mono(s, cl, "clarinet", key="waltz"), 0.28, 1.8, "clar", damp=5000)

    def roots(c, n, i):
        return [(0, c.dur * 0.97, root_of(c, 44, 39, 50), 0.85)]
    vc = line(s, ch, roots, lambda ss, m, du, v: v_bow(ss, m, du, v, k=6, att=0.12, vib=0.8, cutoff=1300.0, rel=0.3),
              r=r)
    vc = room(s, loop_filter(s, vc, "lp", 1300), 0.15, 1.5, "cellos", damp=3000)
    st = comp(s, ch, voicing(ch, 55, 72, 63), lambda c, i: [(0, c.dur * 0.97, 0.6)], v_strings, r=r)
    st = room(s, loop_filter(s, st, "lp", 3000), 0.3, 1.9, "strings", damp=4000)
    ce = s.zeros()
    for w in (3, 7, 11):  # the dominant bars
        ns = chord_notes(chord_at(s, w * 3), 82, 95)
        for i, bt in enumerate((1.0, 1.5, 2.0)):
            s.add(ce, v_celesta(s, ns[(2 - i) % len(ns)], 0.8, 0.5), w * 3 + bt, dt=float(r.normal(0.003, 0.002)))
    ce = room(s, ce, 0.3, 1.6, "celesta", damp=7000)
    return {"arp": hp, "lead": vn, "clarinet": cl, "bass": vc, "strings": st, "celesta": ce}


def popcorn_chase(s):
    """152 BPM chase scherzo: a xylophone runs up and down the chords in staccato 8ths, a piccolo chirps in its
    rests and races up the scale before the repeat, pizzicato strings play the off-beats, a tuba hops between
    root and fifth (high, like a bassoon), muted brass pokes at the bars that wait on the dominant; two temple
    blocks, a light snare and the bass drum."""
    r = dsp.rng(s.id, "chase")
    t, ch = s.tonic, s.chords
    k = kits(s, "march", "cinema")
    d = s.zeros()
    # two temple blocks on the tonic and the fifth (Eb6 on the beats, Bb5 between them): tick-tock
    for f, pat in ((87, "x...x...x...x..."), (82, "..o...o...o...o.")):
        hits(s, d, [ins.woodblock(s.sr, f=float(midi_hz(f)), key=i) for i in range(2)], pat, r, gain=0.5)
    hits(s, d, k["snare"], ["....x.......x...", "....x.......x.oo"], r, gain=0.6)
    hits(s, d, k["bd"], "X.......x.......", r, gain=0.4)
    hits(s, d, k["cym"], {0: "X...............", 8: "X..............."}, r, gain=0.4, jit=0.0)
    d = room(s, d, 0.12, 0.9, "drums", damp=6000)
    tub = []
    for c in ch:
        R = root_of(c, 46, 43, 54)
        tub += [(c.start, 0.45, R, 0.95), (c.start + 2, 0.45, R + 7 if R + 7 <= 55 else R - 5, 0.85)]
    tuba = room(s, mono(s, tub, "tuba", key="chase"), 0.08, 0.7, "tuba", damp=3000)
    pz = comp(s, ch, voicing(ch, 58, 75, 66, no_root), [(1, 0.3, 0.75), (3, 0.3, 0.75), (3.5, 0.3, 0.5)], v_opizz,
              spread=0.006, r=r)
    pz = room(s, loop_filter(s, pz, "hp", 180), 0.12, 0.9, "pizz", damp=6000)
    tn = tune("1:.5 3:.5 5:.5 3:.5 1+:.5 5:.5 3:.5 5:.5 | 1:.5 3:.5 5:.5 3:.5 1+:1 r:1 |"
              " 7-:.5 2:.5 4:.5 2:.5 5:.5 4:.5 2:.5 4:.5 | 7-:.5 2:.5 4:.5 2:.5 5:1 r:1 |"
              " 4:.5 6:.5 1+:.5 6:.5 2+:.5 1+:.5 6:.5 4:.5 | 2:.5 4:.5 5:.5 7:.5 2+:1 r:1 |"
              " 1+:.5 5:.5 3:.5 5:.5 1+:.5 5:.5 3:.5 1:.5 | 3:.5 1:.5 5-:.5 1:.5 3:1 r:1 |"
              " 4:.5 6:.5 1+:.5 6:.5 1+:.5 6:.5 4:.5 6:.5 | 4:.5 6:.5 1+:.5 6:.5 4:1 r:1 |"
              " 3:.5 5:.5 1+:.5 5:.5 3+:.5 1+:.5 5:.5 1+:.5 | 6:.5 1+:.5 3+:.5 1+:.5 6:1 r:1 |"
              " 2:.5 4:.5 6:.5 4:.5 2+:.5 6:.5 4:.5 6:.5 | 5:.5 4:.5 2:.5 7-:.5 5-:.5 7-:.5 2:.5 4:.5 |"
              " 3:.5 5:.5 1+:1 5:.5 3:.5 1:1 | r:4", t, 5)
    xy = lay(s, lambda ss, m, du, v: ins.marimba(m, ss.sr, vel=v, dur=0.3, pan_sheen=0.05), tn, r=r, jit=0.003)
    xy = room(s, loop_eq(s, loop_filter(s, xy, "hp", 300), "highshelf", 3000, 3.0), 0.14, 1.0, "xylo", damp=7000)
    pc = []
    for bar in (1, 3, 5, 7, 9, 11):  # a chirp where the xylophone breathes
        ns = chord_notes(chord_at(s, bar * 4), 82, 94)
        pc += [(bar * 4 + 3.0, 0.25, ns[1], 0.8), (bar * 4 + 3.25, 0.25, ns[0], 0.7), (bar * 4 + 3.5, 0.4, ns[1], 0.85)]
    pc += [(60.0 + b, du, m, v) for b, du, m, v in tune("5-:.5 6-:.5 7-:.5 1:.5 2:.5 3:.5 4:.5 5:.5", t, 6)]
    pic = room(s, mono(s, pc, "piccolo", key="chase"), 0.14, 0.9, "pic", damp=6000)

    def poke(c, i):
        return [(1.5, 0.2, 0.8), (2.5, 0.2, 0.7)] if int(c.start // 4) in (2, 3, 4, 5, 13) else []
    br = comp(s, ch, voicing(ch, 60, 77, 68, no_root), poke, v_brass, r=r)
    br = room(s, loop_filter(s, loop_filter(s, br, "hp", 500), "lp", 2600), 0.1, 0.8, "mute", damp=4000)
    return {"drums": d, "bass": tuba, "guitar": pz, "lead": xy, "piccolo": pic, "brass": br}


def closing_credits(s):
    """88 BPM end credits, broad and slow: the violins sing the tune in octaves, french horns hold the chords in
    a noble rhythm, a wordless choir and the inner strings fill the hall, basses bow the roots, the timpani mark
    every chord and roll with a soft snare into bars 5, 9 and the repeat, where a cymbal crash, the bass drum and
    a harp glissando land together."""
    r = dsp.rng(s.id, "credits")
    t, ch = s.tonic, s.chords
    k = kits(s, "cinema")
    peaks = (0, 16, 32)  # the downbeats of bars 1, 5 and 9
    d = s.zeros()
    for b in peaks:
        s.add(d, k["crash"][0], b, 0.6)
        s.add(d, k["bd"][0], b, 1.0)
        for i in range(24):  # a soft snare roll through the two beats before
            hit(s, d, k["snare"], (b - 2.0 + i / 12.0) % s.beats, 0.1 + 0.02 * i, r, 0.006)
    d = room(s, d, 0.25, 1.8, "drums", damp=6000)
    tp = s.zeros()
    for c in ch:
        s.add(tp, v_timp(s, root_of(c, 44, 39, 50), 0.9 if c.dur >= 4 else 0.7), c.start,
              dt=float(r.normal(0.002, 0.002)))
    for b in peaks:
        timp_roll(s, tp, b if b else s.beats, 46, hi=0.7)
    tp = room(s, loop_filter(s, tp, "hp", 45), 0.2, 1.6, "timp", damp=4000)
    tn = tune("3:1.5 4:.5 5:2 | 7:1.5 1+:.5 2+:2 | 3+:1.5 1+:.5 6:2 | 7:1.5 2+:.5 5+:2 | 5+:1.5 3+:.5 1+:2 |"
              " 4+:1.5 3+:.5 1+:1 6:1 | 4:1 6:1 2+:1 4+:1 | 3+:3 5:1 | 4+:1.5 1+:.5 6:1 1+:1 | 1+:3.5 r:.5", t, 4)
    vn = s.zeros()
    for b, du, m, v in tn:
        j = float(r.normal(0.004, 0.004))
        s.add(vn, v_bow(s, m + 12, du, v, k=1, att=0.08, vib=1.2, cutoff=3600.0, rel=0.25), b, 1.0, dt=j)
        s.add(vn, v_bow(s, m, du, v, k=2, att=0.08, vib=1.0, cutoff=3000.0, rel=0.25), b, 0.8, dt=j + 0.006)
    vn = room(s, loop_filter(s, vn, "hp", 180), 0.32, 2.2, "violins", damp=5000, predelay=0.03)

    def noble(c, i):
        if c.dur < 4:
            return [(0, c.dur - 0.15, 0.8)]
        return [(0.0, 2.4, 0.85), (2.5, 0.45, 0.6), (3.0, 0.95, 0.8)] if i < len(ch) - 1 else [(0, 3.5, 0.85)]
    hn = room(s, comp(s, ch, voicing(ch, 55, 70, 63, lambda c: c.tones[:3]), noble, v_horn, r=r), 0.28, 1.9, "horns",
              damp=4500)
    st = comp(s, ch, voicing(ch, 58, 75, 67), lambda c, i: [(0, c.dur * 0.97, 0.6)], v_strings, r=r)
    st = room(s, loop_filter(s, st, "lp", 3200), 0.3, 2.0, "strings", damp=4000)
    bs_ = line(s, ch, lambda c, n, i: [(0, c.dur * 0.96, root_of(c, 39, 34, 45), 0.9)],
               lambda ss, m, du, v: v_bow(ss, m, du, v, k=5, att=0.1, vib=0.0, cutoff=1100.0, rel=0.25), r=r)
    bs_ = room(s, loop_filter(s, bs_, "lp", 1100), 0.12, 1.4, "bass", damp=2500)
    hp = s.zeros()
    for c in ch:  # a rolled chord on every change
        for j, m in enumerate(chord_notes(c, 51, 82, c.tones[:3])[:7]):
            s.add(hp, v_harp(s, m, 1.0, 0.5 + 0.04 * j), c.start, dt=0.028 * j)
    for b, top in zip(peaks, (87, 82, 87)):
        harp_gliss(s, hp, b if b else s.beats, top)
    hp = room(s, loop_filter(s, hp, "hp", 120), 0.26, 1.8, "harp", damp=7000)
    return {"drums": d, "timp": tp, "lead": vn, "brass": hn, "choir": choir_even(s, ch), "strings": st, "bass": bs_,
            "arp": hp}


# ================================================================== BAZAAR (G)
# The band of the district theme in music.py (goblet drum, frame drum, finger cymbals, oud, qanun, ney, strings in
# unison) and a shawm for the loud dances. Everything stays on the major scale of G; each song leans on another
# note of it: G (spice_market_dance), E (caravan_bells), A (desert_starlight), D (wedding_drums). The genre
# "eastern" of songs_latin.py is another thing: pentatonic tunes in D on plain plucks over a pad.

def v_boud(s, m, d, v=0.8):
    return M.oud(m, min(s.sec(d), 0.9), s.sr, key=m % 3) * v


def v_oud_trem(s, m, d, v=0.8):
    """The oud as it plays a tune: one stroke for a short note, the quill trembling (eight strokes a beat) on a
    note of a beat or more."""
    if d < 1.0:
        return v_boud(s, m, d, v)
    n = int(round(d * 8))
    out = np.zeros(nsamp(s.sec(d) + 1.0, s.sr))
    for i in range(n):
        x = M.oud(m, s.sec(0.2), s.sr, key=i % 2)
        p = nsamp(s.sec(i / 8.0), s.sr)
        out[p: p + len(x)] += x * ((1.0 if i == 0 else 0.6 + 0.2 * i / n) * (1.0 if i % 2 == 0 else 0.82))
    return out * v


def v_qanun(s, m, d=1.0, v=0.7):
    return M.qanun(m, s.sr, key=m % 2) * v


def slides(s, evs, least=1.5):
    """Ornaments for the ney: every note of `least` beats or more is reached with a slide from the note of the
    scale below it."""
    out = []
    for b, d, m, v in evs:
        o = {"bend": float(m - scale_step(s.tonic, m, False)), "bend_t": 0.14} if d >= least else {}
        out.append((b, d, m, v, o))
    return out


def shawm(s, evs, key="shawm"):
    """A shawm (mizmar, zurna): a loud double reed. A narrow pulse through two nasal peaks, a hard start from a
    little under the note, hardly any vibrato. Returns the loop."""
    src, env, onset = render_line(s, events(s, evs), osc="pulse", pw=0.22, glide=0.012, legato_gap=0.008,
                                  attack=0.012, release=0.04, vib_rate=6.2, vib_depth=0.07, vib_delay=0.25, scoop=0.4,
                                  key=key)
    x = src * env
    x = dsp.highpass(x, 400, s.sr, 2)
    x = dsp.filt(x, "peak", 1250, s.sr, q=1.6, gain_db=8.0)
    x = dsp.filt(x, "peak", 2700, s.sr, q=2.0, gain_db=5.0)
    x = dsp.lowpass(x, 5200, s.sr, 2)
    x = x * (0.85 + 0.15 * np.clip(onset, 0, 1))
    return wrap(s, x / (dsp.peak(x) + 1e-9))


def bell(s, m, v=0.7, t60=0.7):
    """A small brass bell on the harness of a camel: the note, its octave and a twelfth that die quickly."""
    def mk():
        n = nsamp(t60 + 0.05, s.sr)
        t = np.arange(n) / s.sr
        f = float(midi_hz(m))
        x = np.sin(TAU * f * t) + 0.45 * np.sin(TAU * 3.0 * f * t + 0.5) * np.exp(-t / (t60 * 0.25))
        x += 0.3 * np.sin(TAU * 2.0 * f * t + 1.0) * np.exp(-t / (t60 * 0.4))
        x *= dsp.env_perc(n, s.sr, t60, 0.0008)
        return dsp.fade(x / dsp.peak(x), s.sr, 0.0005, 0.02)
    return M.cached(("camelbell", m, s.sr, t60), mk) * v


def hand_drums(s, d, k, r, dum, tek, ka=None, gain=1.0):
    """Darbuka patterns (bar strings like hits): dums, teks and the soft ka fills of the left hand."""
    hits(s, d, k["dum"], dum, r, gain=gain)
    hits(s, d, k["tek"], tek, r, gain=0.7 * gain)
    if ka:
        hits(s, d, k["ka"], ka, r, gain=0.45 * gain)


def spice_market_dance(s):
    """126 BPM market dance in G: the darbuka plays a quick three-three-two (dum - - tek - - tek -) with a riq and
    claps, the oud plays the tune (trembling on the long notes), the qanun answers in its rests and doubles it an
    octave up the second time; in bars 9-10 the strings join for the falling figure of the district theme (B D C
    B / A C B A / G B A G / F# A G F#) and the last bar is a drum break."""
    r = dsp.rng(s.id, "spice")
    t, ch = s.tonic, s.chords
    k = kits(s, "bazaar")
    d = s.zeros()
    hand_drums(s, d, k, r, {"*": "X.....x.X.......", 11: "X..X..X.X.X.X..."},
               {"*": "...x..x....x..x.", 11: "..........x.xxxx"}, {"*": ".o..o...oo..o..o", 11: ".o..o..........."})
    hits(s, d, k["frame"], "X.......x.......", r, gain=0.6)
    d = room(s, d, 0.12, 0.7, "drums", damp=6000)
    tb = s.zeros()
    hits(s, tb, k["riq"], "x.o.x.o.x.o.x.oo", r, gain=0.6)
    hits(s, tb, kit("dance", s.sr)["clap"], "....x.......x...", r, gain=0.7, mask=bs("5-11"))
    hits(s, tb, k["zill"], {3: "............x.x.", 7: "............x.x.", 11: "x...x...x.x.x..."}, r, gain=0.5)
    tb = room(s, tb, 0.14, 0.8, "tamb", damp=7000)
    tn = tune("1:.5 2:.5 3:.5 4:.5 5:1 3:.5 5:.5 | 4:.5 3:.5 2:.5 3:.5 1:1 r:1 |"
              " 4:.5 5:.5 6:.5 5:.5 4:1 6:.5 4:.5 | 5:.5 4:.5 3:.5 2:.5 2:1 r:1 |"
              " 1:.5 2:.5 3:.5 4:.5 5:1 6:.5 5:.5 | 1+:1 7:.5 1+:.5 5:1 r:1 |"
              " 6:.5 5:.5 4:.5 5:.5 6:1 1+:.5 6:.5 | 7:.5 6:.5 5:.5 6:.5 7:1 2+:1 |"
              " 3+:.5 5+:.5 4+:.5 3+:.5 2+:.5 4+:.5 3+:.5 2+:.5 | 1+:.5 3+:.5 2+:.5 1+:.5 7:.5 2+:.5 1+:.5 7:.5 |"
              " 6:.5 1+:.5 6:.5 5:.5 7:.5 6:.5 7:.5 2+:.5 | 1+:2 r:2", t, 4)
    od = room(s, loop_filter(s, lay(s, v_oud_trem, tn, r=r, jit=0.004), "hp", 120), 0.14, 0.9, "oud", damp=5000)
    # the qanun: a run down the chord where the oud rests, the tune an octave higher in bars 5-8, a rolled chord
    # on the first beat of the other bars
    qn = s.zeros()
    for bar in (1, 3, 5):
        ns = chord_notes(chord_at(s, bar * 4 + 3), 74, 91)[-4:]
        for i, m in enumerate(reversed(ns)):
            s.add(qn, v_qanun(s, m, 1.0, 0.7), bar * 4 + 3 + i * 0.25, dt=float(r.normal(0.003, 0.002)))
    for b, du, m, v in tn:
        if 16 <= b < 32:
            s.add(qn, v_qanun(s, m + 12, du, v * 0.8), b, dt=0.008 + float(r.normal(0.003, 0.002)))
    for c in ch:
        if int(c.start // 4) not in (4, 5, 6, 7):
            for j, m in enumerate(chord_notes(c, 67, 84)[:5]):
                s.add(qn, v_qanun(s, m, 1.0, 0.45 + 0.05 * j), c.start, dt=0.022 * j)
    qn = room(s, loop_filter(s, qn, "hp", 250), 0.2, 1.3, "qanun", damp=7000)
    st = M.unison_strings(s, [e for e in tn if 32 <= e[0] < 46], key="spice")
    st = room(s, st, 0.26, 1.6, "strings", damp=4500)

    def bass(c, n, i):
        R = root_of(c, 43, 38, 49)
        F = R + 7 if R + 7 <= 50 else R - 5
        if c.dur < 4:
            return [(0, 0.7, R, 0.9), (1.5, 0.45, R, 0.75)]
        return [(0, 0.7, R, 0.9), (1.5, 0.45, R, 0.7), (2, 0.7, F, 0.85), (3.5, 0.45, F, 0.65)]
    b = room(s, loop_filter(s, line(s, ch, bass, v_baby, r=r), "lp", 1200), 0.06, 0.7, "bass", damp=2500)
    return {"drums": d, "tamb": tb, "lead": od, "arp": qn, "strings": st, "bass": b}


def caravan_bells(s):
    """92 BPM caravan march that leans on E (the sixth of the key: a minor colour, with the step C - B at every
    cadence): a heavy slow walk on the hand drums (dum dum - tek dum - tek -), two camel bells that swing on E
    and B, the oud walking in the bass register, a shawm with the tune and the low strings answering it in
    unison over a drone."""
    r = dsp.rng(s.id, "caravan")
    t, ch = s.tonic, s.chords
    k = kits(s, "bazaar")
    d = s.zeros()
    hand_drums(s, d, k, r, ["X.x.....X.......", "X.x.....X.....x."], ["......x.....x...", "......x.....x.x."],
               "....o.....o....o", gain=0.9)
    hits(s, d, k["frame"], "X...o...x...o...", r, gain=0.7)
    d = room(s, d, 0.16, 1.0, "drums", damp=5500)
    bl = s.zeros()
    for beat in range(s.beats):  # ding - dong, the second a little late: nobody rings them, they hang
        m, v = ((88, 0.7), (83, 0.55))[beat % 2]
        s.add(bl, bell(s, m, v), beat, dt=0.012 * (beat % 2) + float(r.normal(0.004, 0.004)))
    bl = room(s, bl, 0.25, 1.4, "bells", damp=7000)
    tn = tune("6:1.5 7:.5 1+:1 7:.5 6:.5 | 3+:1.5 1+:.5 2+:1 1+:.5 7:.5 | 1+:1 6:.5 1+:.5 3+:1 2+:.5 1+:.5 | 7:2 r:2 |"
              " 6:1.5 7:.5 1+:1 2+:.5 3+:.5 | 5+:1.5 3+:.5 4+:1 3+:1 | 2+:1 4+:.5 2+:.5 7:1 2+:1 | 3+:2 r:2 |"
              " 4+:.5 3+:.5 1+:1 3+:.5 2+:.5 7:1 | 6:3 r:1", t, 4)
    ld = room(s, shawm(s, tn, key="caravan"), 0.2, 1.3, "shawm", damp=4500)
    ans = tune("r:4 | r:4 | r:4 | r:2 3:.5 2:.5 1:.5 7-:.5 | r:4 | r:4 | r:4 | r:2 3:.5 5:.5 4:.5 3:.5 | r:4 |"
               " r:3 3:.5 5:.5", t, 4)
    st = room(s, M.unison_strings(s, ans, key="caravan"), 0.28, 1.7, "strings", damp=4500)

    def walk_oud(c, n, i):
        R = root_of(c, 52, 47, 58)
        if c.dur < 4:
            return [(0, 0.7, R, 0.9), (1, 0.45, R + 7, 0.65), (1.5, 0.45, R + 12, 0.6)]
        return [(0, 0.9, R, 0.9), (1, 0.45, R + 7, 0.65), (1.5, 0.45, R + 12, 0.6), (2, 0.9, R + 7, 0.8),
                (3, 0.45, R + 12, 0.65), (3.5, 0.45, R + 7, 0.55)]
    od = room(s, loop_filter(s, line(s, ch, walk_oud, v_boud, r=r), "hp", 100), 0.14, 0.9, "oud", damp=5000)

    def bass(c, n, i):
        R = root_of(c, 40, 36, 47)
        return [(0, 1.4, R, 0.9)] + ([(2, 1.4, R, 0.75)] if c.dur >= 4 else [])
    b = room(s, loop_filter(s, line(s, ch, bass, v_baby, r=r), "lp", 1100), 0.06, 0.7, "bass", damp=2500)
    dr = s.zeros()
    for m, g in ((52, 1.0), (59, 0.6)):  # E3 and B3 all the way round
        at(s, dr, v_pad(s, m, s.beats - 1.0, g, 1000.0, 1.2, 1.2, k=m), 0.0)
    return {"drums": d, "celesta": bl, "lead": ld, "strings": st, "guitar": od, "bass": b,
            "pad": loop_filter(s, dr, "hp", 120)}


def desert_starlight(s):
    """72 BPM night in the desert that leans on A (the second of the key, with the F# above it: a soft, open
    minor): the ney alone with the tune, slow, sliding into its long notes; the qanun rolls one chord a bar and
    lets it ring, a drone on A and E, a quiet heartbeat on the frame drum and a few high notes like stars."""
    r = dsp.rng(s.id, "starlight")
    t, ch = s.tonic, s.chords
    k = kits(s, "bazaar")
    d = s.zeros()
    hits(s, d, k["frame"], ["X.........o.....", "X.........o...o."], r, gain=0.8)
    d = room(s, loop_filter(s, d, "lp", 2500), 0.3, 1.8, "drums", damp=4000)
    tn = tune("2:2 3:.5 4:.5 5:1 | 6:2.5 5:.5 4:.5 5:.5 | 5:1.5 7:.5 6:1 5:1 | 4:.5 3:.5 2:2 r:1 |"
              " 4:1 6:.5 1+:.5 6:2 | 3+:1.5 2+:.5 1+:1 6:1 | 7:1 6:.5 5:.5 4:1 3:1 | 2:3 r:1", t, 4)
    ny = M.ney_line(s, slides(s, tn), key="starlight")
    ny = room(s, echo(s, ny, 1.5, 0.14, 0.3, 2, 3000), 0.34, 2.2, "ney", damp=4500, predelay=0.03)
    qn = s.zeros()
    for c in ch:
        ns = chord_notes(c, 57, 81)
        for j, m in enumerate(ns[:7]):  # one slow roll up the chord
            s.add(qn, v_qanun(s, m, 1.0, 0.5 + 0.04 * j), c.start, dt=0.05 * j + float(r.normal(0.004, 0.003)))
        for bt, m in ((2.5, ns[-1]), (3.0, ns[-2])):  # and two strings touched again
            s.add(qn, v_qanun(s, m, 1.0, 0.4), c.start + bt, dt=float(r.normal(0.004, 0.003)))
    qn = room(s, loop_filter(s, qn, "hp", 150), 0.3, 2.0, "qanun", damp=6000, predelay=0.02)
    pad = comp(s, ch, voicing(ch, 55, 72, 64), lambda c, i: [(0, c.dur * 0.97, 0.5)], v_strings, r=r)
    pad = loop_filter(s, pad, "lp", 2400)
    for m, g in ((57, 0.9), (64, 0.5)):  # A3 and E4 all the way round
        at(s, pad, v_pad(s, m, s.beats - 1.0, g, 1000.0, 1.5, 1.5, k=m), 0.0)
    pad = room(s, pad, 0.3, 2.2, "pad", damp=3500)
    stars = s.zeros()
    for i, c in enumerate(ch):
        ns = chord_notes(c, 86, 98)
        for bt, j in (((1.5, 0), (3.5, 1)) if i % 2 == 0 else ((2.0, 2),)):
            s.add(stars, v_celesta(s, ns[j % len(ns)], 1.0, 0.45), c.start + bt, dt=float(r.normal(0.006, 0.004)))
    stars = room(s, echo(s, stars, 0.75, 0.25, 0.35, 3, 6000), 0.35, 2.2, "stars", damp=7000)
    b = line(s, ch, lambda c, n, i: [(0, c.dur * 0.9, root_of(c, 45, 40, 51), 0.8)], v_sub, r=r)
    return {"drums": d, "lead": ny, "arp": qn, "pad": pad, "celesta": stars, "bass": loop_filter(s, b, "lp", 700)}


def wedding_drums(s):
    """138 BPM wedding dance that leans on D (the fifth of the key: D - C - D, a bright dance mode with a low
    seventh): the big drum and the darbuka play dum tek - dum dum - tek -, claps on two and four, finger cymbals
    on the 8ths, a shawm calls the tune and the strings answer in its rests and join it for the last four bars,
    the oud strums the chords on the accents of the drum, the guests shout at the end of every phrase."""
    r = dsp.rng(s.id, "wedding")
    t, ch = s.tonic, s.chords
    k = kits(s, "bazaar")
    d = s.zeros()
    dums = {"*": "X.....x.X.......", 15: "X.....x.X.x.x.x."}
    hits(s, d, kits(s, "march")["bass"], dums, r, gain=0.9)  # the big two-headed drum of the procession
    hand_drums(s, d, k, r, dums, {"*": "..x.........x...", 3: "..x.........xxxx", 7: "..x.........xxxx",
                                  11: "..x.........xxxx", 15: "..x........x.x.x"}, "....o.....o...oo", gain=0.8)
    d = room(s, d, 0.12, 0.8, "drums", damp=6000)
    tb = s.zeros()
    hits(s, tb, kit("dance", s.sr)["clap"], "....x.......x...", r, gain=0.8)
    hits(s, tb, k["zill"], "x.o.x.o.x.o.x.o.", r, gain=0.45)
    hits(s, tb, k["riq"], "..o...o...o...o.", r, gain=0.5, mask=bs("9-16"))
    tb = room(s, tb, 0.14, 0.8, "tamb", damp=7000)
    tn = tune("5:.5 5:.5 7:.5 2+:.5 2+:1 7:.5 2+:.5 | 1+:.5 7:.5 6:.5 7:.5 5:1 r:1 |"
              " 4+:.5 4+:.5 3+:.5 2+:.5 1+:1 6:.5 1+:.5 | 2+:.5 1+:.5 7:.5 6:.5 5:1 r:1 |"
              " 2+:.5 2+:.5 4+:.5 5+:.5 5+:1 4+:.5 5+:.5 | 4+:.5 3+:.5 2+:.5 3+:.5 2+:1 r:1 |"
              " 1+:.5 1+:.5 3+:.5 4+:.5 3+:1 1+:.5 6:.5 | 7:.5 6:.5 7:.5 2+:.5 5:1 r:1 |"
              " 3+:1 3+:.5 2+:.5 1+:1 3+:1 | 5+:1 5+:.5 4+:.5 3+:1 r:1 | 2+:1 2+:.5 1+:.5 7:1 2+:1 |"
              " 4+:1 3+:.5 2+:.5 2+:1 r:1 | 4+:.5 3+:.5 4+:.5 5+:.5 4+:.5 3+:.5 1+:1 |"
              " 3+:.5 1+:.5 3+:.5 4+:.5 3+:.5 1+:.5 6:1 | 7:.5 6:.5 7:.5 2+:.5 4+:.5 2+:.5 7:.5 2+:.5 | 5+:2 r:2", t, 4)
    ld = room(s, shawm(s, tn, key="wedding"), 0.16, 1.1, "shawm", damp=4500)
    ans = tune("r:4 | r:3 5:.5 7:.5 | r:4 | r:3 5:.5 7:.5 | r:4 | r:3 2+:.5 4+:.5 | r:4 | r:3 5:.5 7:.5 |"
               " r:4 | r:3 1+:.5 3+:.5 | r:4 | r:3 2+:.5 4+:.5", t, 4)
    st = room(s, M.unison_strings(s, ans + [e for e in tn if e[0] >= 48], key="wedding"), 0.22, 1.4, "strings",
              damp=4500)
    od = comp(s, ch, voicing(ch, 55, 71, 63), [(0.0, 0.4, 0.9), (0.5, 0.3, 0.6), (1.5, 0.4, 0.8), (2.0, 0.4, 0.85),
                                               (3.0, 0.4, 0.7)], v_boud, spread=0.008, r=r)
    od = room(s, loop_filter(s, od, "hp", 140), 0.12, 0.8, "oud", damp=5000)

    def bass(c, n, i):
        R = root_of(c, 43, 38, 49)
        F = R + 7 if R + 7 <= 50 else R - 5
        return [(0, 0.7, R, 0.9), (1.5, 0.45, R, 0.75), (2, 0.7, R, 0.85), (3, 0.7, F, 0.75)]
    b = room(s, loop_filter(s, line(s, ch, bass, v_baby, r=r), "lp", 1200), 0.06, 0.7, "bass", damp=2500)
    hey = gang(s, [(3, 3.0), (7, 3.0), (11, 3.0), (15, 2.0), (15, 3.0)], voices=6, lo=180, hi=330, key="wedding")
    return {"drums": d, "tamb": tb, "lead": ld, "strings": st, "guitar": od, "bass": b,
            "gang": room(s, hey, 0.2, 1.0, "hey", damp=5000)}


# ================================================================ SKY CLUB (Ab)
# The club on the roof: the kit, the rubber bass and the pluck of the district theme in music.py. Every song starts
# from a major chord (the songs of the genre "edm" of songs_pop.py, also in Ab, all start on vi and are built on a
# build-up and a drop): rooftop_sunrise opens its filter bar by bar under a piano, cloud_bounce is half-time with
# chords that wobble and a tune of vocal chops, mirrorball_groove is disco (octave bass, scratch guitar, strings),
# afterglow_lounge is what plays when the dance floor is empty.

def duck(s, x, depth=0.6, rel=0.12):
    """Ducks x under a kick on every beat."""
    return sidechain(s, x, range(s.beats), depth, rel)


def v_cbass(s, m, d, v=0.8):
    return M.club_bass(m, s.sec(d), s.sr) * v


def wobble(s, x, rates=(2, 2, 3, 4), depth=0.85):
    """The chords of future bass: the level falls and jumps back rates[beat] times in every beat of the bar
    (8ths, 8ths, triplets, 16ths), the same in every bar, so the loop stays a loop."""
    pos = np.arange(s.n) / s.n * s.beats
    u = ((pos % 1.0) * np.asarray(rates)[np.floor(pos).astype(int) % 4]) % 1.0
    g = dsp.loop_apply(1.0 - depth * u ** 0.7, lambda z: dsp.onepole_lp(z, 70.0, s.sr))
    return x * g


def rooftop_sunrise(s):
    """124 BPM progressive house, IV - I - V - vi: plucked chords in three-three-two behind a filter that opens
    a little more in every bar (the sun comes up), a long bass note under every chord that pumps with the kick, a
    warm pad; the piano brings the tune in bar 5 and doubles it an octave higher from bar 9 under a few high
    bells; a riser leads round to bar 1."""
    r = dsp.rng(s.id, "sunrise")
    t, ch = s.tonic, s.chords
    k = kits(s, "skyclub")
    d = s.zeros()
    hits(s, d, k["kick"], "X...X...X...X...", r, jit=0.0)
    hits(s, d, k["clap"], "....x.......x...", r, gain=0.8, jit=0.0, mask=bs("5-12"))
    hits(s, d, k["clap"], {11: "............o.xx"}, r, gain=0.6, jit=0.0)
    hits(s, d, k["ohat"], "..x...x...x...x.", r, gain=0.6, jit=0.0, mask=bs("3-12"))
    hits(s, d, k["hat"], ".g.o.g.o.g.o.g.o", r, gain=0.45, jit=0.002, mask=bs("5-12"))
    d = room(s, dsp.drive(d / dsp.peak(d) * 1.2, 1.3), 0.08, 0.7, "drums", damp=6000)
    bass = line(s, ch, lambda c, n, i: [(0, c.dur * 0.96, root_of(c, 41, 36, 47), 0.9)], v_cbass, r=r, jit=0.0)
    bass = duck(s, loop_filter(s, bass, "lp", 1500), 0.75, 0.16)
    vo = voicing(ch, 60, 79, 69, no_root)
    ky = s.zeros()
    for i, c in enumerate(ch):
        cut = 1200.0 + 450.0 * int(c.start // 4)
        for bt, v in ((0, 0.9), (0.75, 0.7), (1.5, 0.8), (2.25, 0.6), (3.0, 0.8), (3.5, 0.6)):
            for j, m in enumerate(vo[i]):
                s.add(ky, M.sky_pluck(m, s.sr, dur=0.3, key=j % 2, cutoff=cut), c.start + bt, v)
    ky = room(s, duck(s, echo(s, ky, 0.75, 0.25, 0.4, 3, 5000), 0.4, 0.1), 0.2, 1.5, "keys", damp=6000)
    pad = comp(s, ch, voicing(ch, 55, 74, 64, no_root), lambda c, i: [(0, c.dur * 0.97, 0.6)],
               lambda ss, m, du, v: v_pad(ss, m, du, v, 1500.0, 0.4, 0.6, k=m % 3), r=r)
    pad = room(s, duck(s, pad, 0.6, 0.16), 0.25, 1.8, "pad", damp=4500)
    tn = tune("r:4 | r:4 | r:4 | r:4 | 6:1.5 1+:.5 3+:1 1+:1 | 5:1.5 1+:.5 3+:1 2+:1 | 2+:1.5 7:.5 5:1 7:1 |"
              " 1+:2 6:1 5:.5 6:.5 | 6:1 1+:.5 3+:.5 4+:1.5 3+:.5 | 2+:1 5+:1 4+:.5 3+:.5 2+:1 | 3+:1.5 2+:.5 1+:2 |"
              " 5:.5 6:.5 1+:3", t, 4)
    pno = lay(s, lambda ss, m, du, v: v_piano(ss, m, du, v, 0.85, 0.25), tn, r=r, jit=0.003)
    pno += lay(s, lambda ss, m, du, v: v_piano(ss, m + 12, du, v * 0.6, 0.85, 0.25), [e for e in tn if e[0] >= 32],
               r=r, jit=0.003, dt=0.006)
    pno = room(s, echo(s, pno, 0.75, 0.18, 0.35, 3, 4000), 0.24, 1.7, "piano", damp=5500)
    bl = s.zeros()
    for c in ch:
        if c.start >= 32:
            ns = chord_notes(c, 80, 96)
            for q in range(8):
                s.add(bl, v_celesta(s, ns[(0, 2, 1, 3, 2, 4, 3, 1)[q] % len(ns)], 0.5, 0.5, t60=0.5), c.start + q * 0.5)
    bl = room(s, echo(s, bl, 0.75, 0.25, 0.35, 3, 6000), 0.25, 1.6, "bells", damp=7000)
    return {"drums": d, "bass": bass, "keys": ky, "pad": pad, "lead": pno, "celesta": bl,
            "fx": room(s, riser(s, 8, 0.6), 0.2, 1.6, "fx", damp=5000)}


def cloud_bounce(s):
    """100 BPM future bass in half time (the clap on beat 3): seventh and ninth chords on supersaws whose level
    wobbles in 8ths, triplets and 16ths, a sub under them that wobbles too, a tune of chopped voices (ah - oh -
    eh) with bells two octaves above it, hats that roll into bars 5 and 1, a run of plucks up the chord before
    them."""
    r = dsp.rng(s.id, "bounce")
    t, ch = s.tonic, s.chords
    k = kits(s, "skyclub")
    d = s.zeros()
    hits(s, d, k["kick"], ["X.....x.....x...", "X..x..x......x.."], r, jit=0.0)
    hits(s, d, k["clap"], "........X.......", r, gain=1.0, jit=0.0)
    hits(s, d, k["hat"], ["x.o.x.oox.o.x.o.", "x.o.xoo.x.o.x.oo"], r, gain=0.45, jit=0.002)
    hits(s, d, k["ohat"], "......x.......x.", r, gain=0.5, jit=0.0)
    hits(s, d, k["crash"], {0: "X..............."}, r, gain=0.35, jit=0.0)
    for bar in (3, 7):
        for j in range(8):
            hit(s, d, k["hat"], bar * 4 + 3 + j * 0.125, 0.25 + 0.07 * j, r, 0.0)
    d = room(s, dsp.drive(d / dsp.peak(d) * 1.2, 1.3), 0.1, 0.8, "drums", damp=6000)
    saw = comp(s, ch, voicing(ch, 58, 80, 69, no_root), lambda c, i: [(0, c.dur * 0.98, 0.9)],
               lambda ss, m, du, v: v_super(ss, m, du, v, att=0.01, rel=0.1, k=m % 3), r=r, jit=0.0)
    saw = room(s, wobble(s, loop_filter(s, saw, "lp", 6000)), 0.2, 1.3, "saw", damp=6000)
    bass = line(s, ch, lambda c, n, i: [(0, c.dur * 0.95, root_of(c, 41, 36, 47), 0.9)], v_sub, r=r, jit=0.0)
    bass = wobble(s, loop_filter(s, bass, "lp", 700), depth=0.5)
    tn = tune("3+:.75 5+:.75 3+:.5 2+:.5 1+:.5 r:1 | 2+:.75 5:.75 7:.5 2+:.5 3+:.5 r:1 |"
              " 3+:.75 6:.75 1+:.5 3+:.5 5+:.5 r:1 | 4+:.75 2+:.75 1+:.5 2+:1 r:1 |"
              " 3+:.75 5+:.75 3+:.5 1+:.5 6:.5 r:1 | 2+:.75 5:.75 7:.5 2+:.5 5+:.5 r:1 |"
              " 6+:.75 5+:.75 3+:.5 4+:.5 2+:.5 5+:1 | 5+:.75 3+:.75 1+:2.5", t, 3)
    vx = s.zeros()
    for i, (b, du, m, v) in enumerate(tn):
        s.add(vx, v_vox(s, m, min(du, 0.75) * 0.9, v, vowel=("a_alto", "o_alto", "e_open", "a_alto")[i % 4], key=i % 3), b)
    vx = room(s, echo(s, loop_filter(s, vx, "hp", 250), 0.75, 0.22, 0.4, 3, 4000), 0.22, 1.4, "chops", damp=5000)
    bl = lay(s, lambda ss, m, du, v: v_celesta(ss, m + 24, du, v, t60=0.5), tn)
    bl = room(s, echo(s, bl, 0.75, 0.2, 0.35, 2, 6000), 0.22, 1.4, "bells", damp=7000)
    run = s.zeros()
    for bar in (3, 7):
        ns = chord_notes(chord_at(s, bar * 4 + 2), 68, 96)
        for j in range(8):
            s.add(run, M.sky_pluck(ns[j % len(ns)], s.sr, dur=0.22, key=j % 2), bar * 4 + 2 + j * 0.25, 0.4 + 0.07 * j)
    run = room(s, echo(s, run, 0.75, 0.25, 0.4, 2, 6000), 0.2, 1.3, "run", damp=7000)
    return {"drums": d, "keys": saw, "bass": bass, "chops": vx, "celesta": bl, "arp": run,
            "fx": room(s, riser(s, 4, 0.6), 0.2, 1.6, "fx", damp=5000)}


def mirrorball_groove(s):
    """120 BPM disco house, I - vi - ii - V: four on the floor with an open hat on every off-beat and a
    tambourine, a bass that jumps the octave on every 8th and walks into the next chord, a muted scratch guitar
    in 16ths, an electric piano, the strings in unison with the tune (a run up and a long note, as on a disco
    record) and brass stabs in the last four bars."""
    r = dsp.rng(s.id, "mirror")
    t, ch = s.tonic, s.chords
    k = kits(s, "dance", "skyclub")
    d = s.zeros()
    hits(s, d, k["kick"], "X...X...X...X...", r, jit=0.0)
    hits(s, d, k["clap"], "....X.......X...", r, gain=0.9, jit=0.0)
    hits(s, d, k["snare"], {"*": "....o.......o...", 3: "....o.......o.xx", 7: "....o.......o.xx",
                            11: "....o.....o.xxxx"}, r, gain=0.45, jit=0.0)
    hits(s, d, k["ohat"], "..x...x...x...x.", r, gain=0.75, jit=0.0)
    hits(s, d, k["hat"], ".o.g.o.g.o.g.o.g", r, gain=0.4, jit=0.002)
    hits(s, d, k["crash"], {0: "X...............", 8: "X..............."}, r, gain=0.35, jit=0.0)
    d = room(s, dsp.drive(d / dsp.peak(d) * 1.2, 1.3), 0.1, 0.8, "drums", damp=6500)
    tb = s.zeros()
    hits(s, tb, [ins.tambourine(s.sr, key=60 + i, dur=0.08) for i in range(3)], "o.x.o.x.o.x.o.x.", r, gain=0.6,
         mask=bs("5-12"))
    tb = room(s, loop_filter(s, tb, "lp", 9000), 0.12, 0.8, "tamb", damp=7000)

    def octaves(c, n, i):
        R = root_of(c, 41, 36, 47)
        ap = scale_step(t, root_of(n, 41, 36, 47), False)
        return [(0, 0.4, R, 0.95), (0.5, 0.3, R + 12, 0.7), (1, 0.4, R, 0.9), (1.5, 0.3, R + 12, 0.7),
                (2, 0.4, R, 0.9), (2.5, 0.3, R + 12, 0.7), (3, 0.4, R + 7, 0.85), (3.5, 0.3, ap, 0.75)]
    bass = line(s, ch, octaves, lambda ss, m, du, v: v_gbass(ss, m, du, v, 0.5, 0.05, m % 3), r=r, jit=0.002)
    bass = duck(s, loop_filter(s, bass, "lp", 2500), 0.3, 0.1)
    vo = voicing(ch, 60, 76, 68, no_root)
    gtr = s.zeros()
    for i, c in enumerate(ch):
        for q, mark in enumerate("..x.x..x..x.x.x."):
            if mark == "x":
                s.add(gtr, v_strum(s, vo[i], 0.2, 0.75 if q % 4 == 2 else 0.6, up=q % 4 != 2, spread=0.006, bright=0.6,
                                   t60=0.25, mute=0.03, key=q % 3), c.start + q * 0.25, dt=float(r.normal(0.002, 0.002)))
    gtr = room(s, loop_filter(s, gtr, "hp", 300), 0.12, 0.8, "guitar", damp=6000)
    ep = comp(s, ch, voicing(ch, 55, 74, 65, no_root), [(0, 1.2, 0.7), (1.5, 0.5, 0.55), (2.5, 1.2, 0.65)], v_epiano, r=r)
    ep = room(s, ep, 0.18, 1.2, "ep", damp=5500)
    tn = tune("r:2 5:.5 6:.5 1+:.5 2+:.5 | 3+:2 1+:1 6:1 | r:2 4:.5 6:.5 1+:.5 2+:.5 | 4+:1.5 2+:.5 7:1 5:1 |"
              " r:2 5:.5 6:.5 1+:.5 3+:.5 | 5+:2 3+:1 1+:1 | r:2 6:.5 1+:.5 2+:.5 4+:.5 | 5+:1 4+:1 2+:1 7:1 |"
              " 1+:1 3+:.5 4+:.5 6+:2 | 5+:1.5 3+:.5 2+:2 | 1+:1 2+:.5 4+:.5 6+:1 4+:1 | 5+:1 4+:.5 2+:.5 7:1 2+:1", t, 4)
    st = room(s, M.unison_strings(s, tn, key="mirror"), 0.25, 1.6, "strings", damp=5000)
    br = comp(s, ch, voicing(ch, 62, 80, 71, no_root), [(0, 0.3, 0.9), (1.5, 0.3, 0.8)],
              lambda ss, m, du, v: v_brass(ss, m, du, v, k=m % 3), r=r, mask=bs("9-12"))
    br = room(s, br, 0.15, 1.0, "brass", damp=5500)
    return {"drums": d, "tamb": tb, "bass": bass, "guitar": gtr, "keys": ep, "lead": st, "brass": br}


def afterglow_lounge(s):
    """88 BPM chill-out for the empty dance floor: an electric piano that rolls one chord a bar on tape, a slow
    pad, a soft sine voice with a long echo for the tune, a few high bells, a round sub and a very quiet beat
    (a soft kick, a rim click on 2 and 4, a shaker)."""
    r = dsp.rng(s.id, "afterglow")
    t, ch = s.tonic, s.chords
    k = kits(s, "lofi")
    d = s.zeros()
    hits(s, d, k["kick"], ["X.........x.....", "X.....x...x....."], r, gain=0.7, jit=0.003)
    hits(s, d, k["rim"], "....x.......x...", r, gain=0.6, jit=0.004)
    hits(s, d, k["shaker"], "o.g.o.g.o.g.o.g.", r, gain=0.4, jit=0.004)
    d = room(s, loop_filter(s, d, "lp", 6000), 0.25, 1.5, "drums", damp=4500)
    ep = comp(s, ch, voicing(ch, 55, 76, 65, None, span=15),
              lambda c, i: [(0, c.dur * 0.9, 0.6)] + ([(2.5, 1.2, 0.4)] if c.dur >= 4 else []), v_epiano, spread=0.035, r=r)
    ep = room(s, tape(s, echo(s, ep, 1.5, 0.15, 0.3, 2, 3000), 6.0, 0.3), 0.3, 2.0, "ep", damp=4500)
    pad = comp(s, ch, voicing(ch, 60, 79, 70, no_root), lambda c, i: [(0, c.dur * 0.97, 0.5)],
               lambda ss, m, du, v: v_pad(ss, m, du, v, 1300.0, 0.8, 1.0, k=m % 3), r=r)
    pad = room(s, pad, 0.3, 2.2, "pad", damp=3500)
    tn = tune("5:2 3:1 5:1 | 6:1.5 1+:.5 5:2 | 6:2 4:1 6:1 | 5:1.5 4:.5 2:2 |"
              " 5:1 7:1 2+:1.5 1+:.5 | 7:2 5:1 3:1 | 4:1 6:1 4:1 2:1 | 1:3 r:1", t, 4)
    ld = room(s, echo(s, mono(s, tn, "bell", key="afterglow"), 1.5, 0.25, 0.4, 3, 3500), 0.35, 2.4, "lead", damp=5000,
              predelay=0.03)
    st = s.zeros()
    for i, c in enumerate(ch):
        ns = chord_notes(c, 84, 96)
        for bt, j in (((1.5, 0), (3.25, 2)) if i % 2 == 0 else ((2.0, 1),)):
            if bt < c.dur:
                s.add(st, v_celesta(s, ns[(i + j) % len(ns)], 1.0, 0.45), c.start + bt, dt=float(r.normal(0.006, 0.004)))
    st = room(s, echo(s, st, 0.75, 0.3, 0.4, 3, 6000), 0.35, 2.2, "stars", damp=7000)
    bass = line(s, ch, lambda c, n, i: [(0, c.dur * 0.9, root_of(c, 44, 39, 50), 0.8)], v_sub, r=r)
    return {"drums": d, "keys": ep, "pad": pad, "lead": ld, "celesta": st, "bass": loop_filter(s, bass, "lp", 600)}


# ============================================================ HIP-HOP BLOCK (Bb)
# The block in the sun: the boom-bap kit, the scratches and the cowbell of the district theme in music.py. All four
# start from a major chord and come home to Bb (the three songs of the genre "hiphop" of songs_pop.py, in Eb, all
# start on vi and are built on an e-piano or pluck loop with a vibes, bell or pluck tune): block_party_jam is an
# old-school party break with a horn riff, a cowbell and shouts, stoop_sunset a slow jazzy head-nodder with a
# nylon guitar, a flute and a muted trumpet, hopscotch_bounce a playground beat on a marimba with an octave bass,
# we_made_it an anthem with a fanfare, strings and a choir.

def scratches(s, spots):
    """The DJ's cuts: (bar0, beat, strokes) -> a loop of vinyl scratches (music.scratch)."""
    buf = s.zeros()
    for i, (bar, bt, strokes) in enumerate(spots):
        s.add(buf, M.scratch(s.sr, strokes, key=100 + i), bar * 4 + bt)
    return loop_filter(s, buf, "hp", 300)


def within(c, pat):
    """The events of a bar pattern that fit into chord c (a chord of two beats takes the first half)."""
    return [e for e in pat if e[0] < c.dur - 1e-9]


def block_party_jam(s):
    """104 BPM old-school block party: a funky break (kick pushes, snare on 2 and 4, open hat), a cowbell, a
    synth bass that jumps the octave, clavinet-like stabs, an organ under them, a horn riff in call and answer,
    the friends shouting 'hey!' and the DJ's scratches at the end of every phrase."""
    r = dsp.rng(s.id, "jam")
    t, ch = s.tonic, s.chords
    k = kits(s, "block")
    d = s.zeros()
    hits(s, d, k["kick"], ["X.....x.x.x.....", "X..x..x...x....."], r, swing=0.12, jit=0.002)
    hits(s, d, k["snare"], {"*": "....X.......X...", 3: "....X.......X.xx", 7: "....X.......X.xx",
                            11: "....X.....x.X.xx"}, r, jit=0.002)
    hits(s, d, k["ghost"], ".......g.g......", r, gain=0.6, swing=0.12, jit=0.003)
    hits(s, d, k["hat"], "x.o.x.o.x.o.x.o.", r, gain=0.5, jit=0.003)
    hits(s, d, k["ohat"], ["..............x.", ""], r, gain=0.5, jit=0.0)
    hits(s, d, k["clap"], "....x.......x...", r, gain=0.5, jit=0.004, mask=bs("5-12"))
    hits(s, d, k["crash"], {0: "X...............", 8: "X..............."}, r, gain=0.3, jit=0.0)
    d = room(s, dsp.drive(d / dsp.peak(d) * 1.3, 1.5), 0.1, 0.6, "drums", damp=6000)
    bell = s.zeros()
    hits(s, bell, [M.BLOCK_BELL(s.sr)], "x.o.x.oox.o.x.o.", r, gain=0.7, swing=0.12, jit=0.003, mask=bs("3-12"))
    bell = room(s, bell, 0.12, 0.7, "bell", damp=6000)

    def funk(c, n, i):
        R = root_of(c, 46, 41, 52)
        ap = scale_step(t, root_of(n, 46, 41, 52), False)
        return within(c, [(0, 0.4, R, 1.0), (0.75, 0.2, R, 0.7), (1.5, 0.35, R + 12, 0.8)]) + (
            [(2.0, 0.4, R, 0.9), (2.75, 0.2, R + 12, 0.7), (3.5, 0.4, ap, 0.75)] if c.dur >= 4 else [(1.5, 0.4, ap, 0.75)])
    bass = line(s, ch, funk, lambda ss, m, du, v: v_sbass(ss, m, du, v, cutoff=1100.0, decay=0.08), r=r, jit=0.002)
    bass = loop_filter(s, bass, "lp", 1800)
    vo = voicing(ch, 58, 77, 67)  # with the root: Bb6 without it is a plain Gm
    stab = [(0, 0.2, 0.85), (0.75, 0.2, 0.6), (1.5, 0.2, 0.8), (2.5, 0.2, 0.7), (3.25, 0.2, 0.6)]
    clav = comp(s, ch, vo, lambda c, i: within(c, stab),
                lambda ss, m, du, v: v_pluck(ss, m, du, v, cutoff=3000.0, decay=0.07), r=r, jit=0.003, swing=0.12)
    clav = room(s, loop_filter(s, clav, "hp", 200), 0.1, 0.6, "clav", damp=6000)
    org = comp(s, ch, voicing(ch, 53, 70, 62, lambda c: [0] + guide(c)[:1]), lambda c, i: [(0, c.dur * 0.95, 0.7)],
               lambda ss, m, du, v: v_organ(ss, m, du, v, bars=(6, 8, 4, 2, 0, 0, 0, 0, 0), perc=0.0), r=r)
    org = room(s, M.leslie(s, org, 0.75, 0.3), 0.15, 0.9, "organ", damp=4500)
    A = "1:.5 3:.5 5:.5 6:.5 r:.5 5:.5 r:1 | r:2.5 3:.5 2:.5 1:.5"
    tn = tune(A + " | 4:.5 6:.5 1+:.5 2+:.5 r:.5 1+:.5 r:1 | 5:.5 1+:.5 2+:1 r:2 | " + A
              + " | 2:.5 4:.5 6:.5 1+:.5 r:.5 6:.5 r:1 | 5:.5 7:.5 2+:.5 4+:.5 r:.5 2+:.5 r:1 |"
              " 6:1 1+:.5 6:.5 r:.5 4:.5 r:1 | 5:1 7:.5 5:.5 r:.5 3:.5 r:1 | 4:.5 6:.5 1+:1 2+:.5 1+:.5 2+:1 |"
              " 1+:2.5 r:1.5", t, 4)
    horns = lay(s, lambda ss, m, du, v: v_brass(ss, m, min(du, 0.8) * 0.9, v, k=0), tn, r=r, jit=0.003)
    horns += lay(s, lambda ss, m, du, v: v_brass(ss, m - 12, min(du, 0.8) * 0.9, v * 0.7, k=1), tn, r=r, jit=0.003)
    horns = room(s, horns, 0.15, 0.9, "horns", damp=5500)
    hey = gang(s, [(1, 1.0), (3, 3.0), (5, 1.0), (7, 3.0), (9, 3.0), (11, 2.0), (11, 3.0)], voices=6, lo=150, hi=260,
               level=0.9)
    fx = scratches(s, [(3, 3.5, M.WICKA), (7, 3.0, M.WICKA), (7, 3.5, ((0.06, 1), (0.06, -1), (0.1, 1))),
                       (11, 2.5, M.WICKA), (11, 3.5, ((0.07, 1), (0.12, -1)))])
    return {"drums": d, "tamb": bell, "bass": bass, "keys": clav, "organ": org, "brass": horns,
            "gang": room(s, hey, 0.18, 0.9, "hey", damp=5000), "fx": room(s, fx, 0.12, 0.8, "fx", damp=6000)}


def stoop_sunset(s):
    """84 BPM jazzy head-nodder for the evening on the front steps: a soft swung beat with a rim click, a nylon
    guitar that comps ninth chords, a quiet electric piano under it, a round bass that walks into every chord,
    a flute that sings the first four bars and a muted trumpet that answers in the last four, vinyl dust."""
    r = dsp.rng(s.id, "stoop")
    t, ch = s.tonic, s.chords
    k = kits(s, "lofi")
    d = s.zeros()
    hits(s, d, k["kick"], ["X.....x...x.....", "X.....x..xx....."], r, gain=0.8, swing=0.3, jit=0.004)
    hits(s, d, k["rim"], "....x.......x...", r, gain=0.8, jit=0.004)
    hits(s, d, k["snare"], {3: "..............gx", 7: "............g.gx"}, r, gain=0.5, swing=0.3, jit=0.004)
    hits(s, d, k["hat"], "x.o.x.oox.o.x.o.", r, gain=0.4, swing=0.3, jit=0.005)
    d = room(s, loop_filter(s, d, "lp", 7000), 0.15, 0.9, "drums", damp=5000)
    vo = voicing(ch, 55, 74, 64, no_root)
    strum = [(0, 1.2, 0.75), (1.75, 0.35, 0.5), (2.5, 1.1, 0.65)]
    gtr = comp(s, ch, vo, lambda c, i: within(c, strum), v_nylon, spread=0.022, r=r, jit=0.005, swing=0.3)
    gtr = room(s, loop_filter(s, gtr, "hp", 110), 0.2, 1.2, "guitar", damp=5000)
    ep = comp(s, ch, voicing(ch, 60, 79, 70, guide), lambda c, i: [(0, c.dur * 0.9, 0.5)],
              lambda ss, m, du, v: v_epiano(ss, m, du, v, 0.6, 0.4), r=r)
    ep = room(s, tape(s, ep, 5.0, 0.35), 0.25, 1.6, "ep", damp=4500)

    def walkin(c, n, i):
        R = root_of(c, 46, 41, 52)
        ap = scale_step(t, root_of(n, 46, 41, 52), True)
        return [(0, 1.4, R, 0.9)] + ([(2.5, 0.9, R, 0.8), (3.5, 0.4, ap, 0.7)] if c.dur >= 4 else [(1.5, 0.4, ap, 0.7)])
    bass = loop_filter(s, line(s, ch, walkin, v_sub, r=r, jit=0.003, swing=0.3), "lp", 900)
    fl = tune("5:1.5 3:.5 2:1 1:1 | r:.5 1:.5 2:.5 5:.5 3:2 | 4:1.5 2:.5 1:1 6-:1 | r:.5 6-:.5 1:.5 2:.5 1:2 |"
              " r:4 | r:4 | r:4 | r:4", t, 5)
    flute = room(s, echo(s, mono(s, fl, "flute", key="stoop"), 0.75, 0.2, 0.35, 3, 3500), 0.28, 1.8, "flute", damp=5000,
                 predelay=0.02)
    tp = tune("r:4 | r:4 | r:4 | r:4 | 3:1 5:.5 7:.5 1+:2 | 7:1 5:.5 2:.5 3:2 | 6:.5 1+:.5 6:.5 4:.5 5:.5 1+:.5 2+:1 |"
              " 1+:3 r:1", t, 4)
    trp = mono(s, tp, "trumpet", key="stoop")
    trp = loop_filter(s, loop_eq(s, trp, "peak", 1500, 6.0, 2.0), "lp", 3200)  # the mute: nasal and soft
    trp = room(s, echo(s, trp, 0.75, 0.18, 0.35, 3, 3000), 0.28, 1.8, "trumpet", damp=4500, predelay=0.02)
    return {"drums": d, "guitar": gtr, "keys": ep, "bass": bass, "lead": flute, "trumpet": trp,
            "dust": M.vinyl_crackle(s)}


def hopscotch_bounce(s):
    """96 BPM playground beat: a bouncing kick and a double clap, woodblocks, a staccato bass that hops between
    the octaves on every 8th, piano chords on the off-beats, a marimba tune like a counting rhyme that a bell
    doubles two octaves up the second time round, and the DJ's scratches into the repeats."""
    r = dsp.rng(s.id, "hopscotch")
    t, ch = s.tonic, s.chords
    k = kits(s, "march", "block")
    d = s.zeros()
    hits(s, d, k["kick"], ["X..x....X.x.....", "X..x....X.x...x."], r, swing=0.25, jit=0.002)
    hits(s, d, k["snare"], "....x.......x...", r, gain=0.7, jit=0.002)
    hits(s, d, k["clap"], ["....X.......X...", "....X.......X.X."], r, gain=0.8, jit=0.004)
    hits(s, d, k["hat"], "x.x.x.x.x.x.x.x.", r, gain=0.4, jit=0.003)
    hits(s, d, k["wood"], ["..x...x...x..xx.", "..x...x..x..x.x."], r, gain=0.45, swing=0.25, jit=0.003)
    d = room(s, dsp.drive(d / dsp.peak(d) * 1.2, 1.3), 0.1, 0.6, "drums", damp=6000)

    def hop(c, n, i):
        R = root_of(c, 43, 38, 49)
        return [(q * 0.5, 0.28, R + (12 if q % 2 else 0), 0.9 if q % 2 == 0 else 0.7) for q in range(int(c.dur * 2))]
    bass = line(s, ch, hop, lambda ss, m, du, v: v_sbass(ss, m, du, v, cutoff=900.0, decay=0.07), r=r, jit=0.002)
    bass = loop_filter(s, bass, "lp", 1500)
    pno = comp(s, ch, voicing(ch, 58, 76, 67), lambda c, i: [(q + 0.5, 0.25, 0.7) for q in range(int(c.dur))],
               lambda ss, m, du, v: v_piano(ss, m, du, v, 0.8, 0.1), r=r, jit=0.003)
    pno = room(s, loop_filter(s, pno, "hp", 180), 0.14, 0.8, "piano", damp=6000)
    tn = tune("1:.5 1:.5 3:.5 5:.5 6:.5 5:.5 3:1 | 4:.5 4:.5 6:.5 1+:.5 2+:.5 1+:.5 6:1 | 5:.5 5:.5 3:.5 5:.5 1+:1 5:1 |"
              " 2:.5 2:.5 5:.5 7:.5 2+:1 r:1 | 1:.5 1:.5 3:.5 5:.5 6:.5 5:.5 1+:1 |"
              " 4:.5 4:.5 6:.5 1+:.5 4+:.5 2+:.5 1+:1 | 2+:.5 1+:.5 6:.5 4:.5 5:.5 7:.5 2+:1 | 1+:1 5:.5 3:.5 1:1 r:1", t, 4)
    mar = room(s, lay(s, v_marimba, tn, r=r, jit=0.003), 0.16, 0.9, "marimba", damp=6000)
    bl = lay(s, lambda ss, m, du, v: v_celesta(ss, m + 24, du, v * 0.8, t60=0.5), [e for e in tn if e[0] >= 16])
    bl = room(s, echo(s, bl, 0.75, 0.2, 0.35, 2, 6000), 0.2, 1.2, "bells", damp=7000)
    fx = scratches(s, [(3, 3.0, M.WICKA), (3, 3.5, M.WICKA), (7, 3.0, ((0.07, 1), (0.07, -1), (0.12, 1)))])
    return {"drums": d, "bass": bass, "keys": pno, "lead": mar, "celesta": bl,
            "fx": room(s, fx, 0.12, 0.8, "fx", damp=6000)}


def we_made_it(s):
    """86 BPM anthem, IV - V - iii - vi and home: a big slow beat with claps on the snare and a roll into the
    last line, a deep bass, a piano that marks every beat, strings and a choir that hold the chords, a brass
    fanfare that climbs to the high Bb and bells over the last two bars."""
    r = dsp.rng(s.id, "madeit")
    t, ch = s.tonic, s.chords
    k = kits(s, "block")
    d = s.zeros()
    hits(s, d, k["kick"], ["X.....x...X..x..", "X.....x...X....."], r, swing=0.2, jit=0.002)
    hits(s, d, k["snare"], {"*": "....X.......X...", 5: "....X.....ggxxxX"}, r, jit=0.002)
    hits(s, d, k["clap"], "....X.......X...", r, gain=0.6, jit=0.005)
    hits(s, d, k["hat"], "x.o.x.o.x.o.x.oo", r, gain=0.4, swing=0.2, jit=0.003)
    hits(s, d, k["crash"], {0: "X...............", 6: "X..............."}, r, gain=0.4, jit=0.0)
    d = room(s, dsp.drive(d / dsp.peak(d) * 1.3, 1.5), 0.14, 0.9, "drums", damp=6000)

    def deep(c, n, i):
        R = root_of(c, 46, 41, 52)
        return [(0, 2.3, R, 0.9), (2.5, 0.9, R, 0.8), (3.5, 0.4, R + 12, 0.6)]
    bass = loop_filter(s, line(s, ch, deep, v_sub, r=r, jit=0.002), "lp", 900)
    pno = comp(s, ch, voicing(ch, 55, 76, 66), [(0, 0.95, 0.85), (1, 0.95, 0.6), (2, 0.95, 0.75), (3, 0.95, 0.6)],
               lambda ss, m, du, v: v_piano(ss, m, du, v, 0.75, 0.25), r=r, jit=0.004)
    pno = room(s, pno, 0.2, 1.4, "piano", damp=5500)
    st = comp(s, ch, voicing(ch, 60, 81, 71), lambda c, i: [(0, c.dur * 0.98, 0.7)],
              lambda ss, m, du, v: v_strings(ss, m, du, v, k=m % 3), r=r)
    st = room(s, loop_filter(s, st, "hp", 200), 0.3, 2.0, "strings", damp=5000)
    chr_ = room(s, choir_pad(s, ch, 60, 79, 69, "a_sop", mask=bs("5-8")), 0.3, 2.2, "choir", damp=5000)
    tn = tune("6:1 1+:.5 3+:.5 5+:1.5 3+:.5 | 2+:1 7:.5 2+:.5 5+:2 | 5+:1 3+:.5 2+:.5 3+:1.5 5:.5 | 1+:1 6:.5 1+:.5 3+:2 |"
              " 6:1 1+:.5 3+:.5 6+:1.5 5+:.5 | 4+:1 2+:.5 4+:.5 5+:1 6+:.5 7+:.5 | 1++:3 5+:.5 6+:.5 | 1++:2.5 r:1.5", t, 3)
    fan = lay(s, lambda ss, m, du, v: v_brass(ss, m, du * 0.92, v, k=0), tn, r=r, jit=0.003)
    fan += lay(s, lambda ss, m, du, v: v_brass(ss, m - 12, du * 0.92, v * 0.6, k=1), tn, r=r, jit=0.003)
    fan = room(s, fan, 0.22, 1.5, "fanfare", damp=5500)
    bl = s.zeros()
    for c in ch:
        if c.start >= 24:
            ns = chord_notes(c, 82, 98)
            for q in range(8):
                s.add(bl, v_celesta(s, ns[(0, 2, 1, 3, 2, 4, 3, 1)[q] % len(ns)], 0.5, 0.5, t60=0.5), c.start + q * 0.5)
    bl = room(s, echo(s, bl, 0.75, 0.22, 0.35, 3, 6000), 0.25, 1.6, "bells", damp=7000)
    return {"drums": d, "bass": bass, "keys": pno, "strings": st, "choir": chr_, "brass": fan, "celesta": bl}


# ============================================================ REGGAE ISLAND (A)
# The island beyond its one-drop theme (music.py: the kit, the steel pan). Four other rhythms of the Caribbean,
# none of them the roots reggae of the theme or of the genre "reggae" of songs_rnb.py (in Bb: a skank with an
# e-piano tune, a one drop with a melodica, a one-drop dub with a spring snare): sunny_side_ska is fast ska with a
# walking bass and a horn tune, palm_shade_sway slow rocksteady with the rim on two and four, a tenor sax and
# 'ooh' voices, echo_cove_dub a 'steppers' dub (the kick on every beat) where a flute, the pan and the chords
# fall into long echoes and the drums drop out, steelpan_parade a carnival calypso played by a steel band.

def offbeat(du=0.2, v=0.8):
    """The 'and' of every beat of a chord: [(beat, beats, vel)]."""
    return lambda c, i: [(q + 0.5, du, v) for q in range(int(c.dur))]


def triad(c):
    return c.tones[:3]


def pan(s, m, d, v=0.8, k=0):
    return M.steel_pan(m, s.sr, round(v, 2), round(max(0.3, min(s.sec(d), 1.0)), 3), key=k) * v


def thirds_below(evs, tonic, gain=0.6):
    """The second voice of a tune: every note two scale steps lower (a diatonic third), quieter."""
    return [(b, d, scale_step(tonic, scale_step(tonic, m, False), False), v * gain) for b, d, m, v in evs]


def sunny_side_ska(s):
    """132 BPM ska: the kick on every beat, the snare on two and four, an open hat and a bright guitar chop on
    every off-beat with a piano 'bang' on top, an upright bass that walks in quarter notes, and a horn section
    (trumpet and trombone in octaves) with a tune that skips."""
    r = dsp.rng(s.id, "ska")
    t, ch = s.tonic, s.chords
    k = kits(s, "march", "island")
    d = s.zeros()
    hits(s, d, k["kick"], "X...x...X...x...", r, gain=0.8, jit=0.002)
    hits(s, d, k["snare"], {"*": "....X.......X...", 3: "....X.......X.xx", 7: "....X.......X.xx",
                            9: "....X.....x.x.xX"}, r, gain=0.8, jit=0.002)
    hits(s, d, k["hat"], "x...x...x...x...", r, gain=0.3, jit=0.003)
    hits(s, d, k["ohat"], "..x...x...x...x.", r, gain=0.45, jit=0.003)
    hits(s, d, k["crash"], {0: "X...............", 4: "X..............."}, r, gain=0.3, jit=0.0)
    d = room(s, dsp.drive(d / dsp.peak(d) * 1.2, 1.3), 0.1, 0.6, "drums", damp=6000)
    gtr = strum_comp(s, ch, voicing(ch, 62, 79, 70, triad, span=12), offbeat(0.18, 0.8), r=r, bright=0.7, t60=0.4,
                     mute=0.02, spread=0.005, alt=False)
    gtr = room(s, loop_filter(s, gtr, "hp", 260), 0.1, 0.6, "gtr", damp=6000)
    pno = comp(s, ch, voicing(ch, 69, 86, 77, triad, span=12), offbeat(0.2, 0.7),
               lambda ss, m, du, v: v_piano(ss, m, du, v, 0.85, 0.08), r=r, jit=0.003)
    pno = room(s, loop_filter(s, pno, "hp", 300), 0.12, 0.7, "piano", damp=6000)

    def walking(c, n, i):
        R = root_of(c, 45, 40, 51)
        ap = scale_step(t, root_of(n, 45, 40, 51), i % 2 == 0)
        if c.dur < 4:
            return [(0, 0.9, R, 0.9), (1, 0.9, ap, 0.8)]
        return [(0, 0.9, R, 0.9), (1, 0.9, R + (3 if 3 in c.tones else 4), 0.8), (2, 0.9, R + 7, 0.85),
                (3, 0.9, ap, 0.8)]
    bass = loop_filter(s, line(s, ch, walking, v_upright, r=r, jit=0.003), "lp", 1800)
    tn = tune("5:.5 5:.5 6:.5 5:.5 r:.5 1+:.5 r:1 | 3:.5 3:.5 5:.5 3:.5 r:.5 6:.5 r:1 |"
              " 4:.5 4:.5 6:.5 4:.5 r:.5 1+:.5 r:1 | 5:.5 7:.5 2+:.5 4+:.5 r:.5 2+:.5 7:1 |"
              " 1+:1 5:.5 3:.5 5:1 1+:1 | 1+:1 6:.5 3:.5 6:1 1+:1 | 2+:.5 1+:.5 6:.5 4:.5 6:1 1+:1 |"
              " 7:.5 2+:.5 7:.5 5:.5 7:1 2+:1 | 4+:.5 2+:.5 1+:.5 6:.5 7:.5 2+:.5 4+:.5 2+:.5 | 1+:1.5 5:.5 1+:1 r:1",
              t, 4)
    horns = lay(s, lambda ss, m, du, v: v_brass(ss, m, min(du, 0.8) * 0.85, v, k=0), tn, r=r, jit=0.003)
    horns += lay(s, lambda ss, m, du, v: v_brass(ss, m - 12, min(du, 0.8) * 0.85, v * 0.7, k=1), tn, r=r, jit=0.003)
    horns = room(s, loop_filter(s, horns, "lp", 6000), 0.15, 0.9, "horns", damp=5500)
    return {"drums": d, "guitar": gtr, "keys": pno, "bass": bass, "brass": horns}


def palm_shade_sway(s):
    """88 BPM rocksteady: the kick and the rim together on two and four, lazy hats, a round bass with a tune of
    its own, a guitar and a piano on the off-beats, a soft held organ, a tenor sax that sings (with a short echo)
    and voices that hum 'ooh' in the second half."""
    r = dsp.rng(s.id, "sway")
    t, ch = s.tonic, s.chords
    k = kits(s, "island")
    d = s.zeros()
    hits(s, d, k["kick"], "....X.......X...", r, gain=0.9, jit=0.002)
    hits(s, d, k["rim"], {"*": "....X.......X...", 3: "....X.......X..o", 7: "....X.....o.X.o."}, r, gain=0.8, jit=0.002)
    hits(s, d, k["hat"], "x.x.x.x.x.x.x.x.", r, gain=0.3, jit=0.004)
    hits(s, d, k["hat"], ".......o.......o", r, gain=0.3, swing=0.25, jit=0.004)
    hits(s, d, k["bongo_hi"], {3: "..........x.x...", 7: "........x.xx...."}, r, gain=0.5, jit=0.004)
    hits(s, d, k["bongo_lo"], {3: "..............xx", 7: "............x.xx"}, r, gain=0.5, jit=0.004)
    d = room(s, d, 0.14, 0.9, "drums", damp=5500)

    def riff(c, n, i):
        R = root_of(c, 45, 40, 51)
        ap = scale_step(t, root_of(n, 45, 40, 51), False)
        if c.dur < 4:
            return [(0, 1.0, R, 0.9), (1.5, 0.45, ap, 0.75)]
        return [(0, 1.0, R, 0.9), (1.5, 0.45, R + 7, 0.75), (2.0, 0.45, R + (3 if 3 in c.tones else 4), 0.8),
                (2.5, 0.7, R + 7, 0.8), (3.5, 0.45, ap, 0.75)]
    bass = line(s, ch, riff, lambda ss, m, du, v: v_gbass(ss, m, du, v, bright=0.25, mute=0.06), r=r, jit=0.003)
    bass = loop_filter(s, bass, "lp", 1200)
    gtr = strum_comp(s, ch, voicing(ch, 60, 77, 68, no_root, span=12), offbeat(0.2, 0.75), r=r, bright=0.5, t60=0.45,
                     mute=0.025, spread=0.007, alt=False)
    gtr = room(s, loop_filter(s, gtr, "hp", 240), 0.12, 0.8, "gtr", damp=5000)
    pno = comp(s, ch, voicing(ch, 57, 74, 65, guide), offbeat(0.22, 0.6),
               lambda ss, m, du, v: v_piano(ss, m, du, v, 0.6, 0.1), r=r, jit=0.004)
    pno = room(s, pno, 0.12, 0.8, "piano", damp=5000)
    org = comp(s, ch, voicing(ch, 55, 71, 63, lambda c: [0] + guide(c)[:1]), lambda c, i: [(0, c.dur * 0.95, 0.7)],
               lambda ss, m, du, v: v_organ(ss, m, du, v, bars=(6, 4, 8, 3, 0, 0, 0, 0, 0), perc=0.0, att=0.04, rel=0.15),
               r=r)
    org = room(s, leslie(s, org, 0.9, 0.3), 0.18, 1.1, "organ", damp=4500)
    tn = tune("r:.5 3:.5 5:.5 6:.5 5:1.5 3:.5 | r:.5 1:.5 3:.5 5:.5 3:2 | r:.5 2:.5 4:.5 6:.5 4:1.5 2:.5 |"
              " r:.5 7-:.5 2:.5 4:.5 2:2 | 5:1 6:.5 1+:.5 1+:1.5 6:.5 | 5:1 3:.5 1:.5 3:2 |"
              " 4:.5 6:.5 4:.5 2:.5 7-:.5 2:.5 4:.5 2:.5 | 1:3 r:1", t, 4)
    sax = mono(s, tn, "sax", key="sway")
    sax = room(s, echo(s, sax, 0.75, 0.14, 0.3, 2, 3000), 0.22, 1.4, "sax", damp=5000, predelay=0.02)
    ooh = choir_pad(s, ch, 62, 78, 69, "u_alto", mask=bs("5-8"))
    return {"drums": d, "bass": bass, "guitar": gtr, "keys": pno, "organ": org, "sax": sax, "choir": ooh}


def surf(s, spots, seed="surf"):
    """Waves on the shore: (beat, beats) -> slow swells of soft noise that rise and break."""
    buf = s.zeros()
    for i, (beat, beats) in enumerate(spots):
        n = nsamp(s.sec(beats), s.sr)
        u = np.arange(n) / n
        x = dsp.bandpass(dsp.rng(s.id, seed, i).standard_normal(n), 500, 4500, s.sr)
        x = dsp.sweep_filter(x, 800.0 + 3200.0 * u ** 2, s.sr, q=0.7)
        s.add(buf, dsp.fade(x * np.sin(np.pi * u ** 1.6) ** 2, s.sr, 0.05, 0.3), beat)
    return buf


def echo_cove_dub(s):
    """84 BPM steppers dub: the kick on every beat, a rim shot on three that flies off into a dotted echo, a
    heavy bass riff with holes in it, guitar chops and an organ stab that are thrown into the echo and left to
    fade, a flute and a steel pan that call across the bay; in bars 4 and 8 the drums drop out and a wave
    comes in."""
    r = dsp.rng(s.id, "cove")
    t, ch = s.tonic, s.chords
    k = kits(s, "island")
    on = bs("1-3,5-7")
    d = s.zeros()
    hits(s, d, k["kick"], "X...X...X...X...", r, gain=0.9, jit=0.002, mask=on)
    hits(s, d, k["kick"], "X...............", r, gain=0.9, jit=0.002, mask=bs("4,8"))
    hits(s, d, k["hat"], "..x...x...x...xo", r, gain=0.3, jit=0.004)
    d = room(s, d, 0.1, 0.8, "drums", damp=4500)
    sn = s.zeros()
    hits(s, sn, k["rim"], "........X.......", r, gain=0.9, jit=0.002)
    hits(s, sn, k["timbale"], {3: "....X.....x.....", 7: "....X..x..x....."}, r, gain=0.7, jit=0.003)
    sn = room(s, echo(s, sn, 0.75, 0.5, 0.55, 5, 2600), 0.3, 1.6, "rim", damp=3200)
    d = loop_filter(s, d + 0.8 * sn, "lp", 5000)

    def heavy(c, n, i):
        R = root_of(c, 45, 40, 51)
        hi = R + 12 if R <= 44 else R
        if i % 4 == 3:  # the bass drops out with the drums and climbs back in
            return [(0, 1.4, R, 1.0), (3.0, 0.45, R + 7, 0.7), (3.5, 0.45, scale_step(t, root_of(n, 45, 40, 51), False), 0.7)]
        return [(0, 0.9, R, 1.0), (1.0, 0.4, R, 0.8), (1.5, 0.4, R + 7, 0.75), (2.5, 0.9, hi, 0.85), (3.5, 0.4, R + 7, 0.7)]
    bass = loop_filter(s, line(s, ch, heavy, v_sub, r=r, jit=0.002), "lp", 700)
    gtr = strum_comp(s, ch, voicing(ch, 60, 77, 68, no_root, span=12), [(0.5, 0.2, 0.8), (2.5, 0.2, 0.8)], r=r,
                     bright=0.5, t60=0.35, mute=0.02, spread=0.005, alt=False, mask=bs("1,2,5,6"))
    gtr = room(s, echo(s, loop_filter(s, gtr, "hp", 250), 0.75, 0.5, 0.55, 5, 2400), 0.2, 1.3, "gtr", damp=4000)
    stab = comp(s, ch, voicing(ch, 55, 72, 63, triad), [(1.5, 0.25, 0.8)],
                lambda ss, m, du, v: v_organ(ss, m, du, v, bars=(8, 5, 8, 4, 0, 0, 0, 0, 0), perc=0.0, att=0.004, rel=0.05),
                r=r, mask=bs("1,3,4,5,7,8"))
    stab = room(s, echo(s, stab, 1.5, 0.6, 0.6, 4, 2000), 0.25, 1.6, "stab", damp=3500)
    tn = tune("r:4 | r:2 4:1 6:1 | 1+:3 r:1 | r:2 6:.5 5:.5 4:1 | 6:2 4:1 6:1 | 5:3 r:1 | r:2 4:1 2:1 | 1:3 r:1", t, 4)
    fl = mono(s, tn, "flute", key="cove")
    fl = room(s, echo(s, fl, 1.5, 0.45, 0.55, 4, 2800), 0.3, 1.9, "flute", damp=4200, predelay=0.02)
    pn = s.zeros()
    for bar, order in ((0, (0, 1, 2)), (3, (2, 1, 0, 1)), (4, (0, 2, 1)), (7, (0, 1, 2, 3))):
        ns = chord_notes(chord_at(s, bar * 4), 69, 88)
        for q, j in enumerate(order):
            s.add(pn, pan(s, ns[j % len(ns)], 0.8, 0.8 - 0.08 * q, q % 2), bar * 4 + (2.0 if bar in (3, 7) else 0.0) + q * 0.5)
    pn = room(s, echo(s, pn, 0.75, 0.55, 0.6, 5, 3200), 0.3, 1.8, "pan", damp=4500)
    waves = room(s, surf(s, [(12, 5.0), (28, 5.0)]), 0.3, 2.0, "surf", damp=4000)
    return {"drums": d, "bass": bass, "guitar": gtr, "organ": stab, "lead": fl, "vibes": pn, "fx": waves}


def steelpan_parade(s):
    """116 BPM carnival calypso played by a steel band: lead pans sing the tune in thirds, a second row of pans
    strums the chords in the calypso rhythm, the bass moves three-three-two, the 'engine room' (the iron, congas
    and bongos, a shaker, a kick on every beat) drives it and the horns punch the ends of the phrases."""
    r = dsp.rng(s.id, "parade")
    t, ch = s.tonic, s.chords
    k = kits(s, "latin", "island")
    d = s.zeros()
    hits(s, d, k["kick"], "X...X...X...X...", r, gain=0.7, jit=0.002)
    hits(s, d, k["agogo_hi"], "x.xx.xx.x.xx.xx.", r, gain=0.3, jit=0.003)
    hits(s, d, k["shaker"], "xoxoxoxoxoxoxoxo", r, gain=0.3, jit=0.003)
    hits(s, d, k["conga_hi"], ["..x..x....x..x..", "..x..x....x.xx.."], r, gain=0.55, jit=0.004)
    hits(s, d, k["conga_lo"], ["......x.......x.", "......xx......x."], r, gain=0.55, jit=0.004)
    hits(s, d, k["timbale"], {3: "............x.xx", 7: "..........x.xxxx", 9: "........x.x.X..."}, r, gain=0.6, jit=0.003)
    hits(s, d, k["crash"], {0: "X...............", 4: "X..............."}, r, gain=0.25, jit=0.0)
    d = room(s, d, 0.12, 0.8, "perc", damp=6000)
    tn = tune("5:.5 1+:.5 3+:.5 1+:.5 5:.5 1+:.5 3+:1 | 6:.5 1+:.5 4+:.5 1+:.5 6:.5 1+:.5 4+:1 |"
              " 7:.5 2+:.5 4+:.5 2+:.5 5+:.5 4+:.5 2+:1 | 3+:1 1+:.5 5:.5 1+:1 r:1 |"
              " 3+:.5 3+:.5 2+:.5 1+:.5 2+:.5 3+:.5 5+:1 | 4+:.5 4+:.5 3+:.5 2+:.5 1+:.5 6:.5 1+:1 |"
              " 7:.5 7:.5 2+:.5 4+:.5 5+:.5 4+:.5 2+:1 | 1+:1 3+:.5 5+:.5 3+:1 r:1 |"
              " 6:.5 1+:.5 4+:.5 6+:.5 5+:.5 4+:.5 2+:.5 7:.5 | 1+:.5 5:.5 3:.5 5:.5 1+:1 r:1", t, 4)
    lead = lay(s, pan, tn, r=r, jit=0.004) + lay(s, lambda ss, m, du, v: pan(ss, m, du, v, 1), thirds_below(tn, t),
                                                 r=r, jit=0.005, dt=0.005)
    lead = room(s, echo(s, loop_filter(s, lead, "hp", 250), 0.75, 0.12, 0.3, 2, 5000), 0.2, 1.1, "pans", damp=6000)
    strum = [(0, 0.3, 0.8), (0.75, 0.2, 0.55), (1.5, 0.3, 0.8), (2.5, 0.3, 0.7), (3.0, 0.2, 0.55), (3.5, 0.3, 0.7)]
    row = comp(s, ch, voicing(ch, 57, 74, 65, triad, span=12), lambda c, i: within(c, strum),
               lambda ss, m, du, v: pan(ss, m, du, v, 1), spread=0.012, r=r, jit=0.004)
    row = room(s, loop_filter(s, row, "hp", 200), 0.18, 1.0, "row", damp=5500)

    def three_three_two(c, n, i):
        R = root_of(c, 45, 40, 51)
        F = R + 7 if R + 7 <= 52 else R - 5
        if c.dur < 4:
            return [(0, 1.3, R, 0.9), (1.5, 0.45, F, 0.75)]
        return [(0, 1.3, R, 0.9), (1.5, 1.3, F, 0.8), (3.0, 0.9, R + (3 if 3 in c.tones else 4), 0.8)]
    bass = loop_filter(s, line(s, ch, three_three_two, v_gbass, r=r, jit=0.003), "lp", 2200)
    hn = tune("r:4 | r:4 | r:4 | r:3 5:.5 5:.5 | r:4 | r:4 | r:4 | r:3 5:.5 3:.5 | r:4 | r:2 5:.5 5:.5 1+:1", t, 4)
    horns = lay(s, lambda ss, m, du, v: v_brass(ss, m, du * 0.8, v, k=0), hn, r=r, jit=0.003)
    horns += lay(s, lambda ss, m, du, v: v_brass(ss, m, du * 0.8, v * 0.7, k=1), thirds_below(hn, t, 1.0), r=r, jit=0.003)
    horns = room(s, horns, 0.16, 1.0, "horns", damp=5500)
    return {"drums": d, "lead": lead, "vibes": row, "bass": bass, "brass": horns}


# ============================================================ COUNTRY RANCH (G)
# The ranch beyond its train-beat theme (music.py: the jug-band kit, the banjo, the fiddle, the harmonica, the tub
# bass). Four other kinds of country music, none of them the hoedown of the theme or a song of the genre "country"
# of songs_rnb.py (in D: a porch strum with a banjo-like pluck at 112, a twangy electric guitar with slide fills, a
# barn-dance two-step at 128): haystack_breakdown is a fast bluegrass breakdown without drums (the banjo carries
# the tune inside its rolls, then hands it to the fiddle, a mandolin chops the off-beats), campfire_waltz a slow
# waltz for a harmonica and a fiddle over a finger-picked guitar and a crackling fire, tumbleweed_swing a western
# swing shuffle (a lap steel guitar, twin fiddles, a walking bass, brushes), barn_piano_romp a honky-tonk piano
# with a stride left hand over washboard, spoons and tub bass.

def v_banjo(s, m, d, v=0.8):
    return M.banjo_note(m, round(min(0.34, max(0.12, s.sec(d))), 3), s.sr, round(v, 2), key=m % 2)


def v_fid(s, m, d, v=0.8, slide=0.0, vib=None, k=0):
    """The fiddle of the ranch: one bow stroke per note, vibrato only on the notes that are held."""
    vib = (1.0 if d >= 1.0 else 0.3) if vib is None else vib
    return M.fiddle_note(m, round(s.sec(d) * 0.94, 3), s.sr, round(v, 2), key=k, slide=slide, vib=vib)


def v_mouth_harp(s, m, d, v=0.8, k=0, bend=None):
    bend = (0.7 if d >= 0.5 else 0.3) if bend is None else bend
    return M.harmonica_note(m, round(s.sec(d) * 0.95, 3), s.sr, round(v, 2), key=k, bend=bend)


def v_tub(s, m, d, v=0.8):
    return M.tub_bass(m, s.sr, round(v, 2), key=m % 2)


def v_tonk(s, m, d, v=0.8, rel=0.1):
    """A honky-tonk piano: every note is two strings a sixth of a semitone apart (the piano nobody has tuned since
    the barn was built), bright and short."""
    du = round(s.sec(d), 3)
    a = ins.piano(m - 0.07, du, s.sr, vel=round(v, 2), bright=1.0, release=rel, key=0)
    b = ins.piano(m + 0.09, du, s.sr, vel=round(v, 2), bright=1.0, release=rel, key=1)
    return a + 0.8 * b


def banjo_roll(s, chords, tn, r, lead=True, mask=None):
    """Three-finger picking on a 16th grid: where the tune `tn` has a note the thumb plays it (louder); every
    other 16th is a fill, the top strings of the chord and the short high G string in turn. With lead=False
    only the fills are played (a 'back-up' roll)."""
    buf = s.zeros()
    at_ = {int(round(b * 4)): (m, v) for b, d, m, v in tn}
    fill = (1, 5, 2, 1, 5, 2, 1, 5)
    for q in range(int(s.beats * 4)):
        if mask is not None and (q // 16) % s.bars not in mask:
            continue
        beat = q * 0.25
        c = chord_at(s, beat)
        top = chord_notes(c, 55, 66, triad(c))[:2]  # the two strings the fingers rest on
        if lead and q in at_:
            m, v = at_[q]
            x = v_banjo(s, m, 0.3, min(1.0, v + 0.12))
        else:
            if lead and (q - 1) in at_ and q % 2 == 1:
                continue  # a breath after a note of the tune: the roll does not cover it
            st = fill[q % 8]
            m = 67 if st == 5 else top[st % len(top)]
            x = v_banjo(s, m, 0.25, 0.5 if st == 5 else 0.6)
        s.add(buf, x, beat, 1.0, dt=float(r.normal(0, 0.003)))
    return buf


def haystack_breakdown(s):
    """152 BPM bluegrass breakdown, no drums: the banjo plays the tune inside its rolls for eight bars, then the
    fiddle takes it (short bows, double stops on the long notes) while the banjo rolls behind; a mandolin chops
    the off-beats like a snare, a guitar plays bass notes and brushes and a run into each half, an upright bass
    sits on one and three."""
    r = dsp.rng(s.id, "breakdown")
    t, ch = s.tonic, s.chords
    tn = tune("3:.5 5:.5 1+:1 1+:.5 6:.5 5:1 | 3:.5 5:.5 6:.5 5:.5 3:1 1:1 | 4:.5 6:.5 1+:1 1+:.5 6:.5 4:1 |"
              " 5:.5 6:.5 5:.5 3:.5 1:2 | 3:.5 5:.5 1+:1 2+:.5 1+:.5 6:1 | 6:.5 1+:.5 4+:.5 1+:.5 6:1 4:1 |"
              " 2+:1 7:.5 5:.5 7:1 2+:1 | 2+:.5 7:.5 2+:.5 4+:.5 2+:2 |"
              " 3+:1 1+:.5 5:.5 3+:1 1+:1 | 3+:.5 2+:.5 1+:.5 6:.5 5:1 3:1 | 4:.5 6:.5 1+:.5 6:.5 4+:1 1+:1 |"
              " 3+:.5 2+:.5 1+:.5 6:.5 1+:2 | 3:.5 5:.5 1+:.5 5:.5 3+:1 1+:1 | 2+:.5 7:.5 5:.5 7:.5 2+:.5 4+:.5 2+:1 |"
              " 1+:.5 6:.5 5:.5 3:.5 2:.5 3:.5 1:1 | 1:2 r:2", t, 4)
    first, second = bs("1-8"), bs("9-16")
    bj = banjo_roll(s, ch, [e for e in tn if e[0] < 32], r, lead=True, mask=first)
    bj += 0.7 * banjo_roll(s, ch, [], r, lead=False, mask=second)
    bj = room(s, bj, 0.1, 0.7, "banjo", damp=6500)
    fd = s.zeros()
    for b, d, m, v in tn:
        if b < 32:
            continue
        s.add(fd, v_fid(s, m, d, v, slide=0.7 if (b % 1 == 0 and d >= 1.0) else 0.0), b, dt=float(r.normal(0, 0.003)))
        if d >= 1.0:  # a double stop: the chord tone under the note, on the next string
            pcs = set(chord_at(s, b).pcs())
            under = [x for x in range(m - 9, m - 2) if x % 12 in pcs]
            if under:
                s.add(fd, v_fid(s, under[-1], d, v * 0.55, vib=0.0, k=1), b, dt=0.004)
    fd = room(s, loop_filter(s, fd, "hp", 200), 0.14, 0.9, "fiddle", damp=6000)
    mando = strum_comp(s, ch, voicing(ch, 67, 83, 74, triad, span=12), lambda c, i: [(q + 1.0, 0.1, 0.85) for q in range(0, int(c.dur), 2)],
                       r=r, bright=0.85, t60=0.25, mute=0.012, spread=0.004, alt=False)
    mando = room(s, loop_filter(s, mando, "hp", 400), 0.08, 0.6, "mando", damp=6500)

    def boom(c, n, i):
        R = root_of(c, 43, 38, 49)
        F = R + 7 if R + 7 <= 50 else R - 5
        if i == 7:  # the run into the second half: D E F# and home
            return [(0, 0.9, R, 0.9), (2, 0.5, 50, 0.8), (2.5, 0.5, 52, 0.8), (3, 0.5, 54, 0.85), (3.5, 0.5, 50, 0.7)]
        if i == 15:  # the 'G run' that ends a breakdown
            return [(0, 0.9, R, 0.9), (1.5, 0.5, 43, 0.8), (2, 0.5, 45, 0.8), (2.5, 0.5, 47, 0.85), (3, 0.25, 50, 0.8),
                    (3.25, 0.25, 52, 0.8), (3.5, 0.5, 55, 0.9)]
        return [(0, 0.9, R, 0.9), (2, 0.9, R if i % 2 == 0 else F, 0.8)]
    gb = line(s, ch, boom, lambda ss, m, du, v: ins.guitar(m, ss.sec(du), ss.sr, bright=0.55, t60=1.2, pick=0.16, mute=0.05,
                                                            key=m % 2, damp=0.4) * v, r=r, jit=0.003)
    gs = strum_comp(s, ch, voicing(ch, 55, 69, 62, triad, span=12), lambda c, i: [(q + 1.0, 0.3, 0.7) for q in range(0, int(c.dur), 2)],
                    r=r, bright=0.6, t60=0.8, mute=0.03, spread=0.008, alt=False)
    gtr = room(s, loop_filter(s, gb + 0.8 * gs, "hp", 75), 0.1, 0.7, "gtr", damp=6000)

    def two(c, n, i):
        R = root_of(c, 40, 36, 47)
        F = R + 7 if R + 7 <= 47 else R - 5
        return [(0, 0.9, R, 0.95), (2, 0.9, F if i % 2 == 0 else R, 0.85)]
    bass = loop_filter(s, line(s, ch, two, v_upright, r=r, jit=0.003), "lp", 1600)
    return {"lead": bj, "fiddle": fd, "chops": mando, "guitar": gtr, "bass": bass}


def embers(s, seed="embers", per_beat=1.6):
    """A camp fire: sparks that crack (tiny bursts of noise at random moments, a few of them loud) over the soft
    breath of the flames. The moments are drawn on the loop itself, so the fire loops with the song."""
    r = dsp.rng(s.id, seed)
    buf = s.zeros()
    for _ in range(int(s.beats * per_beat)):
        n = nsamp(float(r.uniform(0.004, 0.02)), s.sr)
        x = dsp.highpass(r.standard_normal(n), float(r.uniform(900, 3000)), s.sr, 2) * np.exp(-np.arange(n) / (0.25 * n))
        s.add(buf, x, float(r.uniform(0, s.beats)), float(r.uniform(0.1, 1.0)) ** 2.5)
    hiss = dsp.loop_apply(r.standard_normal(s.n), lambda z: dsp.bandpass(z, 300, 2500, s.sr))
    flame = 0.6 + 0.4 * s.lfo(1.0 / (s.n / s.sr) * 5, 0.1) * s.lfo(1.0 / (s.n / s.sr) * 13, 0.4)
    return buf / dsp.peak(buf) + 0.05 * hiss / dsp.peak(hiss) * flame


def campfire_waltz(s):
    """96 BPM waltz (three beats a bar, sixteen bars) by the fire: a guitar picks the bass on one and two soft
    strings on two and three, a harmonica sings the tune, in the second half a fiddle takes it and the
    harmonica moves a third or a fourth under it, an upright bass marks the bars, the fire crackles."""
    r = dsp.rng(s.id, "campfire")
    t, ch = s.tonic, s.chords
    gt = s.zeros()
    for c, v in zip(ch, voicing(ch, 55, 69, 62, no_root, span=12)):
        for w in range(int(c.dur // 3)):
            o = c.start + w * 3
            R = root_of(c, 43, 38, 49)
            s.add(gt, v_nylon(s, R if w % 2 == 0 else (R + 7 if R + 7 <= 50 else R - 5), 2.6, 0.9), o,
                  dt=float(r.normal(0.003, 0.003)))
            for bt, vel in ((1, 0.55), (2, 0.5)):
                for j, m in enumerate(v[-2:]):
                    s.add(gt, v_nylon(s, m, 1.2, vel), o + bt, dt=j * 0.014 + float(r.normal(0.003, 0.003)))
    gt = room(s, loop_filter(s, gt, "hp", 70), 0.18, 1.3, "guitar", damp=5000)
    tn = tune("3:1 5:1 1+:1 | 3+:2 2+:1 | 1+:2 6:1 | 5:3 | 3:1 5:1 1+:1 | 3+:2 1+:1 | 2+:2 7:1 | 2+:2 r:1 |"
              " 3+:1 2+:1 1+:1 | 5:2 3:1 | 4:1 6:1 1+:1 | 3+:2 1+:1 | 6:1 1+:1 4+:1 | 2+:1 7:1 2+:1 | 1+:3 | r:3",
              t, 4, bar=3.0)
    a, b2 = [e for e in tn if e[0] < 24], [e for e in tn if e[0] >= 24]
    hp = lay(s, v_mouth_harp, a, r=r, jit=0.005)
    hp += lay(s, lambda ss, m, du, v: v_mouth_harp(ss, m, du, v, k=1, bend=0.3), second_voice(s, b2, 0.6), r=r, jit=0.005)
    hp = room(s, echo(s, loop_filter(s, hp, "hp", 300), 0.75, 0.1, 0.3, 2, 3000), 0.24, 1.5, "harp", damp=4500,
              predelay=0.02)
    fd = lay(s, lambda ss, m, du, v: v_fid(ss, m, du, v * 0.9, slide=0.5 if du >= 2.0 else 0.0, vib=1.0), b2, r=r,
             jit=0.005)
    fd = room(s, loop_filter(s, loop_filter(s, fd, "hp", 200), "lp", 3600), 0.26, 1.6, "fiddle", damp=4500, predelay=0.02)

    def ones(c, n, i):
        R = root_of(c, 40, 36, 47)
        return [(w * 3, 2.4, R, 0.85) for w in range(int(c.dur // 3))]
    bass = loop_filter(s, line(s, ch, ones, v_upright, r=r, jit=0.004), "lp", 1200)
    fire = loop_filter(s, embers(s), "lp", 6000)
    return {"guitar": gt, "lead": hp, "fiddle": fd, "bass": bass, "fx": fire}


def lap_steel(s, evs, swing=0.0, key="steel"):
    """A lap steel guitar: the bar slides from note to note (a long glide), every note swells in and sings with a
    slow, wide vibrato; clean, round, no pick."""
    ev = [(sw(b, swing, 0.5) if swing else b, d, m, v) for b, d, m, v in evs]
    src, env, onset = render_line(s, events(s, ev), osc="saw", glide=0.07, legato_gap=0.004, attack=0.045, release=0.12,
                                  vib_rate=4.6, vib_depth=0.2, vib_delay=0.22, key=key)
    x = src * env
    x = dsp.lowpass(dsp.highpass(x, 200, s.sr, 2), 2600, s.sr, 2)
    x = dsp.filt(x, "peak", 900, s.sr, q=1.0, gain_db=3.0)
    x = dsp.tube(x / (dsp.peak(x) + 1e-9) * 1.2, 1.2, s.sr, 0.08)
    return wrap(s, x / (dsp.peak(x) + 1e-9))


def tumbleweed_swing(s):
    """126 BPM western swing shuffle: brushes and a ride swing the 8ths, an upright bass walks four to the bar,
    an arch-top guitar 'socks' a chord on every beat (louder on two and four), a lap steel guitar slides through
    the tune and twin fiddles in thirds answer at the ends of its phrases."""
    r = dsp.rng(s.id, "swing")
    t, ch = s.tonic, s.chords
    SW = 0.33
    k = kits(s, "jazz")
    d = s.zeros()
    hits(s, d, k["ride"], "x..x.xx..x.x", r, gain=0.3, jit=0.004)
    hits(s, d, k["tap"], "o.gx.go.gx.g", r, gain=0.55, jit=0.004)
    hits(s, d, k["chick"], "...x.....x..", r, gain=0.4, jit=0.003)
    hits(s, d, k["feather"], "x..x..x..x..", r, gain=0.5, jit=0.003)
    hits(s, d, k["snare"], {3: ".........x.x", 7: "......x..x.x", 11: "...x.....x.."}, r, gain=0.35, jit=0.003)
    d = room(s, loop_filter(s, d, "lp", 8000), 0.12, 0.8, "drums", damp=5500)
    bass = s.zeros()
    for beat, m, v in walk(s, lo=38, hi=55, seed="tumble"):
        s.add(bass, v_upright(s, m, 0.9, v), beat, dt=float(r.normal(0, 0.004)))
    bass = loop_filter(s, bass, "lp", 1800)
    gtr = strum_comp(s, ch, voicing(ch, 55, 71, 63, lambda c: c.tones[:4], span=12),
                     lambda c, i: [(q, 0.3, 0.85 if q % 2 else 0.6) for q in range(int(c.dur))], r=r, bright=0.45,
                     t60=0.5, mute=0.03, spread=0.006, alt=False)
    gtr = room(s, loop_filter(s, gtr, "hp", 150), 0.1, 0.7, "gtr", damp=5000)
    tn = tune("r:.5 5:.5 6:.5 1+:.5 3+:1.5 1+:.5 | 2+:.5 1+:.5 6:.5 5:.5 6:2 | r:.5 4:.5 6:.5 1+:.5 2+:1.5 1+:.5 |"
              " 6:.5 5:.5 3:.5 5:.5 1+:2 | r:.5 6:.5 1+:.5 2+:.5 4+:1.5 2+:.5 | 7:.5 2+:.5 4+:.5 2+:.5 7:1 5:1 |"
              " 3:.5 5:.5 6:.5 1+:.5 3+:1 2+:.5 1+:.5 | 2+:1.5 7:.5 5:1 r:1 | r:.5 5:.5 6:.5 1+:.5 3+:1.5 5+:.5 |"
              " 4+:1 3+:.5 1+:.5 6:2 | 1+:.5 6:.5 4:.5 6:.5 7:.5 5:.5 4:.5 2:.5 | 3:.5 5:.5 1+:2 r:1", t, 4)
    steel = lap_steel(s, tn, SW, key="tumble")
    steel = room(s, echo(s, steel, 0.75, 0.14, 0.3, 2, 2800), 0.2, 1.2, "steel", damp=4500, predelay=0.015)
    fl = tune("r:4 | r:2 3+:.5 2+:.5 1+:1 | r:4 | r:2 3+:.5 5+:.5 3+:1 | r:4 | r:4 | r:4 | r:3 5:.5 7:.5 |"
              " r:4 | r:2 1+:.5 2+:.5 3+:1 | r:4 | r:2.5 3+:.5 5+:.5 3+:.5", t, 4)
    fd = lay(s, lambda ss, m, du, v: v_fid(ss, m, du, v), fl, swing=SW, grid=0.5, r=r, jit=0.004)
    fd += lay(s, lambda ss, m, du, v: v_fid(ss, m, du, v, k=1), thirds_below(fl, t, 0.8), swing=SW, grid=0.5, r=r,
              jit=0.005, dt=0.005)
    fd = room(s, loop_filter(s, fd, "hp", 220), 0.18, 1.1, "fiddles", damp=5500)
    return {"drums": d, "bass": bass, "guitar": gtr, "lead": steel, "fiddle": fd}


def barn_piano_romp(s):
    """138 BPM honky-tonk romp: an out-of-tune upright piano, the left hand striding (a low note on one and
    three, a chord on two and four), the right hand rattling the tune in octaves with a crushed note before the
    long ones; a washboard and spoons keep time, a tub bass thumps along and a banjo strums the off-beats."""
    r = dsp.rng(s.id, "romp")
    t, ch = s.tonic, s.chords
    k = kits(s, "ranch")
    d = s.zeros()
    hits(s, d, k["wash"], "x.o.x.o.x.o.x.o.", r, gain=0.45, jit=0.003)
    hits(s, d, k["wash_acc"], "..x...x...x...x.", r, gain=0.6, jit=0.003)
    hits(s, d, k["spoon_lo"], {"*": "....x.......x...", 3: "....x.......x.x.", 7: "....x.....x.x...", 11: "....x...x.x.x..."},
         r, gain=0.35, jit=0.003)
    hits(s, d, k["spoon_hi"], {"*": "......x.......x.", 11: "......x........."}, r, gain=0.25, jit=0.003)
    d = room(s, d, 0.1, 0.7, "perc", damp=6000)

    def stride(c, n, i):
        R = root_of(c, 43, 38, 49)
        F = R + 7 if R + 7 <= 50 else R - 5
        return [(0, 0.8, R, 0.9), (2, 0.8, F, 0.8)] if c.dur >= 4 else [(0, 0.8, R, 0.9)]
    lh = line(s, ch, stride, lambda ss, m, du, v: v_tonk(ss, m, du, v) + 0.6 * v_tonk(ss, m - 12, du, v), r=r, jit=0.003)
    lh += comp(s, ch, voicing(ch, 55, 71, 63, lambda c: c.tones[:4], span=12),
               lambda c, i: [(q, 0.3, 0.7) for q in range(1, int(c.dur), 2)], lambda ss, m, du, v: v_tonk(ss, m, du, v, 0.06),
               r=r, jit=0.003, spread=0.004)
    lh = room(s, loop_filter(s, lh, "hp", 60), 0.12, 0.8, "lh", damp=5500)
    tn = tune("3:.5 5:.5 1+:.5 5:.5 3+:1 1+:1 | 2+:.5 1+:.5 6:.5 5:.5 6:.5 1+:.5 5:1 | 4:.5 6:.5 1+:.5 6:.5 4+:1 1+:1 |"
              " 3+:.5 2+:.5 1+:.5 6:.5 5:2 | 3:.5 5:.5 1+:.5 5:.5 3+:1 5+:1 | 3+:.5 5+:.5 3+:.5 1+:.5 6:1 3:1 |"
              " 6:.5 1+:.5 2+:.5 1+:.5 4+:1 2+:1 | 7:.5 2+:.5 4+:.5 2+:.5 7:.5 5:.5 2:1 |"
              " 3:.5 5:.5 1+:.5 5:.5 3+:1 1+:1 | 4+:.5 3+:.5 1+:.5 6:.5 4:1 6:1 |"
              " 5:.5 1+:.5 3+:.5 1+:.5 2+:.5 7:.5 5:.5 7:.5 | 1+:1 5:.5 3:.5 1:1 r:1", t, 4)
    rh = s.zeros()
    for b, du, m, v in tn:
        j = float(r.normal(0, 0.003))
        s.add(rh, v_tonk(s, m, du, v, 0.12), b, dt=j)
        s.add(rh, v_tonk(s, m + 12, du, v * 0.75, 0.12), b, dt=j + 0.004)
        if du >= 1.0 and b % 1 == 0:  # the crushed note: the scale step below, a 32nd early
            s.add(rh, v_tonk(s, scale_step(t, m + 12, False), 0.12, v * 0.5, 0.04), b - 0.125, dt=j)
    rh = room(s, loop_filter(s, rh, "hp", 200), 0.14, 0.9, "rh", damp=6500)
    bj = comp(s, ch, voicing(ch, 59, 74, 66, triad, span=12), offbeat(0.15, 0.75), v_banjo, r=r, jit=0.003, spread=0.007)
    bj = room(s, bj, 0.1, 0.7, "banjo", damp=6500)

    def thump(c, n, i):
        R = root_of(c, 43, 38, 49)
        F = R + 7 if R + 7 <= 50 else R - 5
        ap = scale_step(t, root_of(n, 43, 38, 49), False)
        if c.dur < 4:
            return [(0, 0.5, R, 0.9), (1, 0.5, F, 0.75)]
        return [(0, 0.5, R, 0.95), (1, 0.5, F, 0.75), (2, 0.5, R, 0.9), (3, 0.5, F, 0.75), (3.5, 0.4, ap, 0.65)]
    bass = loop_filter(s, line(s, ch, thump, v_tub, r=r, jit=0.003), "lp", 1600)
    return {"drums": d, "keys": lh, "lead": rh, "guitar": bj, "bass": bass}


# ============================================================ BLUES CLUB (E)
# The club beyond its evening shuffle (music.py: the old upright piano, the brush kit, the amplified harmonica, the
# electric bass through the tube amp). Four other kinds of blues, none of them the theme or a song of the genre
# "blues" of songs_rnb.py (also in E: a 112 BPM twelve-bar with piano comping and a clean guitar, a stomp with a
# slide guitar, a slow 12/8 for a harmonica over an organ bed): riverside_jump is a fast jump blues for a horn
# section and a honking tenor sax, lamplight_piano a slow late-night piano blues in triplets with a muted trumpet
# far away, paddle_wheel_shuffle a riverboat shuffle (banjo, washboard, tuba, a clarinet and a cornet, the whistle
# of the steamer), lantern_stroll a rhythm-and-blues stroll (the bass figure doubled by a baritone sax, a guitar
# in triplets, horns, a lazy tenor sax). All of it "major blues": sixth chords on I and IV, the dominant seventh
# only on V (its seventh belongs to the key), tunes on the major pentatonic with the sixth; the only blue notes
# are crushed notes of the piano, a twentieth of a second long.

BT = 2.0 / 3.0  # the swung off-beat: the third triplet of the beat


def v_old(s, m, d, v=0.7, bright=0.85, rel=0.12):
    """The old upright piano of the club."""
    return M.upright_piano(m, round(s.sec(d), 3), s.sr, vel=round(v, 2), bright=bright, release=rel)


def v_ebass(s, m, d, v=0.8):
    return ins.guitar(m, s.sec(d), s.sr, bright=0.32, t60=1.5, pick=0.12, mute=0.06, key=m % 2, damp=0.45) * v


def amp_bass(s, b):
    """The electric bass through the tube amp of the club: round, a little warm drive."""
    b = loop_eq(s, loop_filter(s, b, "lp", 1500), "peak", 700, 3.0, 1.0)
    b = dsp.loop_apply(b / dsp.peak(b) * 1.4, lambda z: dsp.tube(z, 1.3, s.sr, 0.1))
    return room(s, b, 0.06, 0.7, "bass", damp=2500)


def riverside_jump(s):
    """152 BPM jump blues, a twelve-bar with a quick change: a ride and a fat backbeat shuffle, an upright bass
    walks four to the bar, the old piano hammers short chords on the shuffle, a horn section riffs ('bap ba-daa')
    and shouts through the last four bars, a tenor sax honks the tune."""
    r = dsp.rng(s.id, "jump")
    t, ch = s.tonic, s.chords
    k = kits(s, "jazz", "bluesclub")
    d = s.zeros()
    hits(s, d, k["ride"], "x..x.xx..x.x", r, gain=0.4, jit=0.004)
    hits(s, d, k["snare"], {"*": "...X.....X..", 3: "...X.....X.x", 7: "...X..x..X.x", 11: "...X..x.xX.x"}, r, gain=0.7)
    hits(s, d, k["kick"], "X..o..x..o.o", r, gain=0.8)
    hits(s, d, k["hat"], "...x.....x..", r, gain=0.35)
    hits(s, d, k["crash"], {0: "X...........", 8: "X..........."}, r, gain=0.4)
    d = room(s, d, 0.1, 0.8, "drums", damp=6000)
    bass = s.zeros()
    for beat, m, v in walk(s, lo=38, hi=55, seed="jump"):
        s.add(bass, v_upright(s, m, 0.9, v), beat, dt=float(r.normal(0, 0.004)))
    bass = loop_filter(s, bass, "lp", 1800)
    pno = comp(s, ch, voicing(ch, 59, 75, 67, no_root, span=12),
               lambda c, i: [(q + off, 0.22, 0.62 if off == 0 else 0.5) for q in range(int(c.dur)) for off in (0.0, BT)],
               lambda ss, m, du, v: v_old(ss, m, du, v, rel=0.06), r=r, jit=0.003, spread=0.003)
    pno = room(s, loop_filter(s, pno, "hp", 180), 0.12, 0.8, "piano", damp=5500)

    def riff(c, i):
        if c.dur < 4:
            return [(0, 0.3, 0.8), (1 + BT, 0.3, 0.7)]
        if i >= 8:  # the shout chorus
            return [(0, 0.3, 0.85), (BT, 0.3, 0.7), (2, 0.3, 0.85), (2 + BT, 0.9, 0.8)]
        return [(1, 0.25, 0.8), (1 + BT, 0.25, 0.7), (2 + BT, 0.9, 0.8)]
    br = comp(s, ch, voicing(ch, 60, 77, 69, triad, span=12), riff, v_brass, r=r, jit=0.004)
    br = room(s, br, 0.16, 1.0, "horns", damp=5000)
    tn = tune("1:.5 3:.5 5:1 6:.5 5:.5 3:1 | 4:.5 6:.5 1+:1 6:.5 4:.5 6:1 | 1+:1.5 6:.5 5:1 3:1 |"
              " 5:.5 6:.5 5:.5 3:.5 1:2 | 4:.5 4:.5 r:.5 4:.5 6:1 1+:1 | 2+:.5 1+:.5 6:.5 4:.5 6:2 |"
              " 1:.5 3:.5 5:.5 6:.5 1+:1 3+:1 | 2+:.5 1+:.5 6:.5 5:.5 3:2 | 5:.5 7:.5 2+:1 4+:.5 2+:.5 7:1 |"
              " 1+:.5 6:.5 4:.5 6:.5 1+:1 6:1 | 5:.5 3:.5 1:1 4:.5 6:.5 1+:1 | 1+:1 5:1 7:.5 5:.5 2:1", t, 4)
    sax = room(s, mono(s, tn, "sax", swing=0.33, key="jump"), 0.16, 1.0, "sax", damp=4500)
    return {"drums": d, "bass": bass, "keys": pno, "brass": br, "sax": sax}


def lamplight_piano(s):
    """72 BPM slow piano blues, late at night: the right hand of the old upright keeps soft chords going in
    triplets, the left plays low octaves on one and three and steps into the next chord, the tune sings on top
    in octaves (a crushed note before every long one), brushes sweep, an upright bass plays in two and a muted
    trumpet answers from the far end of the room."""
    r = dsp.rng(s.id, "lamplight")
    t, ch = s.tonic, s.chords
    k = kits(s, "bluesclub")
    d = s.zeros()
    for bar in range(s.bars):
        for bt in range(4):
            s.add(d, ins.brush_swish(s.sr, s.sec(0.9), key=(bar * 4 + bt) % 5), bar * 4 + bt, 0.2)
    hits(s, d, k["tap"], "g.gx.gg.gx.g", r, gain=0.6, jit=0.004)
    hits(s, d, k["kick"], "o.....o.....", r, gain=0.5)
    d = room(s, d, 0.16, 1.2, "brushes", damp=5500)
    rh = comp(s, ch, voicing(ch, 59, 73, 66, no_root, span=12),
              lambda c, i: [(q + j / 3.0, 0.3, (0.5, 0.36, 0.42)[j]) for q in range(int(c.dur)) for j in range(3)],
              lambda ss, m, du, v: v_old(ss, m, du, v, bright=0.7, rel=0.1), r=r, jit=0.004, spread=0.004)

    def left(c, n, i):
        R = root_of(c, 43, 40, 51)
        ap = scale_step(t, root_of(n, 43, 40, 51), False)
        if c.dur < 4:
            return [(0, 1.6, R, 0.8), (1 + BT, 0.4, ap, 0.55)]
        return [(0, 1.8, R, 0.85), (2, 1.5, R + 7, 0.7), (3 + BT, 0.4, ap, 0.55)]
    lh = line(s, ch, left, lambda ss, m, du, v: v_old(ss, m, du, v, 0.7) + 0.7 * v_old(ss, m + 12, du, v, 0.7), r=r,
              jit=0.004)
    keys = room(s, loop_filter(s, lh / dsp.peak(lh) + 0.8 * rh / dsp.peak(rh), "hp", 70), 0.2, 1.5, "keys", damp=4500)
    tn = tune("r:1 3:2/3 5:1/3 6:2 | 1+:1 6:2/3 4:1/3 6:2 | 5:2/3 6:1/3 1+:1 3+:2/3 2+:1/3 1+:1 |"
              " 7:1 2+:2/3 7:1/3 5:2 | r:1 3:2/3 5:1/3 1+:1 3+:1 | 4+:1 3+:2/3 1+:1/3 6:2 |"
              " 2+:2/3 1+:1/3 6:1 7:2/3 5:1/3 2+:1 | 1+:3 r:1", t, 4)
    top = s.zeros()
    for b, du, m, v in tn:
        j = float(r.normal(0, 0.004))
        s.add(top, v_old(s, m, du, v, 0.9, 0.2), b, dt=j)
        s.add(top, v_old(s, m + 12, du, v * 0.6, 0.9, 0.2), b, dt=j + 0.006)
        if du >= 2.0:  # the crushed note: a semitone below, a twentieth of a second early
            s.add(top, v_old(s, m - 1, 0.08, 0.4, 0.9, 0.03), b, dt=j - 0.055)
    top = room(s, loop_filter(s, top, "hp", 200), 0.22, 1.6, "top", damp=5000, predelay=0.02)

    def two(c, n, i):
        R = root_of(c, 40, 36, 47)
        F = R + 7 if R + 7 <= 50 else R - 5
        return [(0, 1.8, R, 0.85), (2, 1.8, F, 0.7)] if c.dur >= 4 else [(0, 1.8, R, 0.85)]
    bass = room(s, loop_filter(s, line(s, ch, two, v_upright, r=r), "lp", 1000), 0.08, 0.8, "bass", damp=2500)
    tp = tune("r:4 | r:3 1+:2/3 6:1/3 | r:4 | r:2 5:2/3 7:1/3 2+:1 | r:4 | r:2 6:2/3 1+:1/3 4+:1 | r:4 | r:4", t, 4)
    trp = mono(s, tp, "trumpet", key="lamplight")
    trp = loop_eq(s, loop_filter(s, trp, "lp", 2400), "peak", 1300, 4.0, 1.5)  # a cup mute
    trp = room(s, echo(s, trp, 1.0, 0.12, 0.3, 2, 2200), 0.3, 1.8, "tpt", damp=3500, predelay=0.03)
    return {"drums": d, "keys": keys, "lead": top, "bass": bass, "trumpet": trp}


def steam_whistle(s, spots, notes=(64, 68, 71)):
    """The whistle of a river steamer: three pipes on the tonic triad, breathy, every toot sliding up into pitch.
    spots = [(beat, beats)]."""
    buf = s.zeros()
    for i, (beat, beats) in enumerate(spots):
        n = nsamp(s.sec(beats) + 0.2, s.sr)
        tt = np.arange(n) / s.sr
        x = np.zeros(n)
        for j, m in enumerate(notes):
            f = midi_hz(m - 0.6 * np.exp(-tt / 0.05))
            x += dsp.sine(f, n, s.sr, 0.1 * j) + 0.3 * dsp.sine(2.0 * f, n, s.sr, 0.3 + 0.1 * j)
        env = dsp.env_adsr(n, s.sr, 0.05, 0.1, 0.9, s.sec(beats), 0.12)
        steam = ins.breath(n, s.sr, f"{s.id}/whistle{i}", 1500, 5000)
        x = (x / dsp.peak(x) + 0.35 * steam / (dsp.peak(steam) + 1e-9)) * env
        s.add(buf, dsp.fade(x / dsp.peak(x), s.sr, 0.003, 0.03), beat)
    return buf


def paddle_wheel_shuffle(s):
    """120 BPM riverboat shuffle: a washboard shuffles with a thimble on two and four, a banjo plucks the chord
    on the backbeats and its swung off-beats, a tuba plays root and fifth and walks into the new chord, a
    clarinet has the tune and a cornet answers at the ends of its phrases; the steamer toots as the tune comes
    round."""
    r = dsp.rng(s.id, "paddle")
    t, ch = s.tonic, s.chords
    k = kits(s, "ranch", "bluesclub")
    d = s.zeros()
    hits(s, d, k["wash"], "x.ox.ox.ox.o", r, gain=0.45, jit=0.003)
    hits(s, d, k["wash_acc"], "...x.....x..", r, gain=0.6, jit=0.003)
    hits(s, d, k["kick"], "X.....x.....", r, gain=0.7)
    hits(s, d, k["spoon_hi"], {3: ".........x.x", 7: "......x..x.x", 11: "...x..x..x.x"}, r, gain=0.3)
    d = room(s, d, 0.1, 0.7, "perc", damp=6000)
    bj = comp(s, ch, voicing(ch, 59, 74, 66, triad, span=12),
              [(1, 0.2, 0.8), (1 + BT, 0.15, 0.55), (3, 0.2, 0.8), (3 + BT, 0.15, 0.55)], v_banjo, r=r, jit=0.003,
              spread=0.012)
    bj = room(s, bj, 0.1, 0.7, "banjo", damp=6500)
    tb = []
    for i, c in enumerate(ch):
        nxt = ch[(i + 1) % len(ch)]
        R = root_of(c, 40, 36, 47)
        F = R + 7 if R + 7 <= 47 else R - 5
        tb += [(c.start, 0.7, R, 0.9), (c.start + 2, 0.7, F, 0.8)]
        if nxt.root != c.root:
            tb.append((c.start + 3, 0.6, scale_step(t, root_of(nxt, 40, 36, 47), False), 0.75))
    tuba = loop_filter(s, mono(s, tb, "tuba", key="paddle"), "lp", 1400)
    tn = tune("5:.5 6:.5 1+:1 3+:.5 1+:.5 6:1 | 5:.5 3:.5 5:.5 6:.5 1+:2 | 6:.5 1+:.5 4+:1 2+:.5 1+:.5 6:1 |"
              " 5:.5 6:.5 5:.5 3:.5 1:2 | 2:.5 4:.5 5:.5 7:.5 2+:1 7:1 | 4+:.5 2+:.5 7:.5 5:.5 7:2 |"
              " 3:.5 5:.5 1+:.5 5:.5 3+:1 1+:1 | 2+:.5 1+:.5 6:.5 5:.5 3:1 r:1 | 4:.5 6:.5 1+:.5 6:.5 4+:1 1+:1 |"
              " 3+:.5 2+:.5 1+:.5 6:.5 5:2 | 7:.5 2+:.5 4+:.5 2+:.5 7:.5 5:.5 4:.5 2:.5 | 1:1 3:.5 5:.5 1+:1 r:1", t, 4)
    cl = room(s, mono(s, tn, "clarinet", swing=0.33, key="paddle"), 0.16, 1.0, "clarinet", damp=5000)
    tp = tune("r:4 | r:3 5:.5 6:.5 | r:4 | r:2 3:.5 5:.5 1+:1 | r:4 | r:3 2+:.5 4+:.5 | r:4 | r:3 5:.5 7:.5 |"
              " r:4 | r:3 3+:.5 5+:.5 | r:4 | r:3 5:1", t, 4)
    cornet = room(s, loop_filter(s, mono(s, tp, "trumpet", swing=0.33, key="paddle"), "lp", 3600), 0.2, 1.1, "cornet",
                  damp=4500)
    toot = room(s, loop_filter(s, steam_whistle(s, [(s.beats - 1.0, 0.35), (0.0, 1.3)]), "lp", 5000), 0.3, 1.6, "toot",
                damp=4000)
    return {"drums": d, "guitar": bj, "bass": tuba, "lead": cl, "trumpet": cornet, "fx": toot}


def lantern_stroll(s):
    """108 BPM rhythm-and-blues stroll in 12/8 over I - vi - IV - V: hi-hat triplets, a brushed backbeat with
    hand claps, the stroll figure (root, root, third, fifth) on an electric bass doubled an octave up by a
    baritone sax, a clean guitar picks the chord in triplets through a tremolo, the horns swell at the end of
    every other bar and shout in the last four, a tenor sax takes its time over the tune."""
    r = dsp.rng(s.id, "stroll")
    t, ch = s.tonic, s.chords
    k = kits(s, "lofi", "bluesclub")
    d = s.zeros()
    hits(s, d, k["hat"], "xgoxgoxgoxgo", r, gain=0.3, jit=0.003)
    hits(s, d, k["kick"], "X.....x..o..", r, gain=0.8)
    hits(s, d, k["slap"], "...X.....X..", r, gain=0.8)
    hits(s, d, k["clap"], "...x.....x..", r, gain=0.4)
    hits(s, d, k["tap"], {3: ".........xxx", 7: ".........xxx", 11: "......xxxxxx"}, r, gain=0.5)
    d = room(s, loop_filter(s, d, "lp", 9000), 0.12, 0.9, "drums", damp=5500)

    def stroll(c, n, i):
        R = root_of(c, 43, 40, 51)
        third = R + (3 if 3 in c.tones else 4)
        if c.dur < 4:
            return [(0, 0.9, R, 0.9), (1, 0.9, R + 7, 0.8)]
        return [(0, 1.5, R, 0.95), (1 + BT, 0.3, R, 0.6), (2, 0.9, third, 0.85), (3, 0.9, R + 7, 0.8)]
    bass = amp_bass(s, line(s, ch, stroll, v_ebass, r=r, jit=0.003))
    bari_ev = []
    for i, c in enumerate(ch):
        for bt, du, m, v in stroll(c, None, i):
            bari_ev.append((c.start + bt, min(du, 0.6), m + 12, v))
    bari = room(s, loop_filter(s, mono(s, bari_ev, "sax", key="bari"), "lp", 1800), 0.12, 0.9, "bari", damp=4000)
    gt = s.zeros()
    for c, v in zip(ch, voicing(ch, 57, 73, 65, triad, span=12)):
        for q in range(int(c.dur)):
            for j in range(3):
                m = v[j] if q % 2 == 0 else v[2 - j]
                x = ins.guitar(m, s.sec(0.6), s.sr, bright=0.6, t60=1.2, pick=0.18, mute=0.05, key=j, damp=0.4)
                s.add(gt, x, c.start + q + j / 3.0, 0.8 if j == 0 else 0.6, dt=float(r.normal(0, 0.003)))
    gt = gt * (1.0 - 0.3 * (0.5 + 0.5 * s.lfo(5.5)))
    gt = room(s, loop_filter(s, gt, "hp", 150), 0.2, 1.3, "gtr", damp=4500)

    def horns(c, i):
        if c.dur < 4:
            return [(0, 0.3, 0.8)]
        if i >= 8:
            return [(0, 0.3, 0.85), (1 + BT, 0.3, 0.75), (2, 1.6, 0.8)]
        return [(2 + BT, 1.2, 0.7)] if i % 2 == 1 else []
    br = room(s, comp(s, ch, voicing(ch, 62, 78, 70, no_root, span=12), horns, v_brass, r=r, jit=0.004), 0.18, 1.1,
              "horns", damp=4500)
    tn = tune("3:1.5 5:.5 1+:2 | 6:1.5 1+:.5 3+:2 | 4+:1 3+:.5 1+:.5 6:2 | 7:1 2+:.5 7:.5 5:1 r:1 |"
              " 3:1.5 5:.5 1+:1 3+:1 | 5+:1.5 3+:.5 1+:2 | 6:.5 1+:.5 4+:1 2+:.5 1+:.5 6:1 | 7:.5 2+:.5 4+:1 2+:1 r:1 |"
              " 1+:1 6:.5 4:.5 6:2 | 5:.5 6:.5 1+:1 3+:1 1+:1 | 2+:1.5 7:.5 5:1 7:1 | 1+:2 r:2", t, 4)
    sax = room(s, echo(s, mono(s, tn, "sax", swing=0.33, key="stroll"), 1.0, 0.1, 0.3, 2, 2500), 0.22, 1.4, "sax",
               damp=4000)
    return {"drums": d, "bass": bass, "sax": bari, "guitar": gt, "brass": br, "lead": sax}


# ============================================================ PIXEL ARCADE (C)
# The arcade beyond its theme (music.py: two pulse channels, a triangle channel and a noise channel, nothing
# else). Four other screens of the same console, none of them the theme or a song of the genre "chiptune" of
# songs_ambient.py (also in C: three 16-bar loops on I-V-vi-IV, I-IV-vi-V and a vi-based one, one arpeggio
# pattern, a pulse tune, the kit2 "chip" drums): hero_overworld_march is a march in two (an oom-pah triangle
# bass, a snare with rolls, chords broken into very fast rolls because the console has no channel left for
# them, a fanfare tune that gets a second voice), bubble_level_waltz an underwater waltz in three for soft
# triangle waves with bubbles rising, boss_rush_blitz a gallop at 176 BPM (the tune hammers 16ths against a
# pedal note, then sings long notes over arpeggios), try_again_lullaby the slow "game over, try again" screen
# (broken chords, a round square-wave tune, a music box, no drums).


def v_pulse(duty=0.5, dec=0.0, vib=0.0, lp=4500.0, k=0, gate=1.0):
    """A pulse channel of the console (music.chip_pulse) as a voice (s, midi, beats, vel)."""
    return lambda s, m, d, v: M.chip_pulse(m, round(s.sec(d * gate), 4), s.sr, duty, round(v, 2), dec=dec, vib=vib,
                                           lp=lp, key=k)


def v_ctri(soft=False, vib=0.0, gate=1.0):
    """The triangle channel of the console (music.chip_tri) as a voice."""
    return lambda s, m, d, v: M.chip_tri(m, round(s.sec(d * gate), 4), s.sr, round(v, 2), vib=vib, soft=soft)


def hero_overworld_march(s):
    """120 BPM march across the world map, three four-bar phrases: the triangle bass plays oom-pah (root, its
    octave, fifth, octave), the noise snare marches and rolls into every phrase, the chords are broken into
    rolls of 32nds on every off-beat, a square wave plays the fanfare; in the last phrase a second pulse joins
    it a third below."""
    r = dsp.rng(s.id, "march")
    t, ch = s.tonic, s.chords
    k = kits(s, "arcade")
    d = s.zeros()
    hits(s, d, k["kick"], "X.......X.......", r, gain=0.9, jit=0)
    hits(s, d, k["snare"], {"*": "....X..g....X.gg", 3: "....X..g..xxXxxx", 7: "....X..g..xxXxxx", 11: "x.xxX.xxxxxxX.X."},
         r, gain=0.7, jit=0)
    hits(s, d, k["hat"], "x.x.x.x.x.x.x.x.", r, gain=0.3, jit=0)
    hits(s, d, k["crash"], {0: "X...............", 4: "X...............", 8: "X..............."}, r, gain=0.45, jit=0)
    d = room(s, d, 0.06, 0.5, "drums", damp=6000)

    def oompah(c, n, i):
        R = root_of(c, 45, 41, 52)
        out = []
        for q in range(int(c.dur // 2)):
            low = R if q % 2 == 0 else (R + 7 if R + 7 <= 55 else R - 5)
            out += [(q * 2, 0.6, low, 0.9), (q * 2 + 1, 0.3, R + 12, 0.6)]
        return out
    bass = line(s, ch, oompah, v_ctri())
    rolls = comp(s, ch, voicing(ch, 60, 76, 67, triad, span=12),
                 lambda c, i: [(q + 0.5, 0.12, 0.7) for q in range(int(c.dur))], v_pulse(0.25, dec=0.05, lp=3500.0),
                 spread=s.sec(0.125))
    rolls = room(s, rolls, 0.06, 0.6, "rolls", damp=4500)
    tn = tune("1:.75 1:.25 3:1 5:1.5 3:.5 | 5:1/3 6:1/3 5:1/3 3:1 1:1.5 r:.5 | 4:.75 4:.25 6:1 1+:1.5 6:.5 |"
              " 5:1.5 3:.5 1:1 r:1 | 2:.75 2:.25 5:1 7:1.5 5:.5 | 1+:1 6:.5 1+:.5 3+:2 |"
              " 4+:.5 3+:.5 1+:.5 6:.5 7:.5 1+:.5 2+:1 | 1+:2 r:1 5:.5 5:.5 | 6:1.5 1+:.5 4+:1 1+:1 |"
              " 5:1.5 1+:.5 3+:1 1+:1 | 4+:1 2+:1 7:.5 2+:.5 5+:1 | 3+:1 1+:.5 5:.5 1+:2", t, 5)
    lead = lay(s, v_pulse(0.5, vib=0.2, lp=4000.0, gate=0.9), tn)
    lead += lay(s, v_pulse(0.25, lp=3200.0, k=1, gate=0.9), thirds_below([e for e in tn if e[0] >= 32], t, 0.55))
    lead = room(s, echo(s, lead, 0.5, 0.1, 0.3, 2, 3000), 0.08, 0.7, "lead", damp=4500)
    return {"drums": d, "bass": bass, "keys": rolls, "lead": lead}


def bubble(sr, midi, key=0):
    """A bubble: a soft triangle blip whose pitch runs up most of an octave in a tenth of a second."""
    n = nsamp(0.11, sr)
    u = np.arange(n) / n
    x = dsp.triangle(midi_hz(midi + 9.0 * u ** 1.5), n, sr, 0.1 * key) * np.sin(np.pi * u) ** 0.8
    return dsp.fade(dsp.lowpass(x, 3500.0, sr, 2), sr, 0.002, 0.01)


def bubble_level_waltz(s):
    """108 BPM waltz (three beats a bar, sixteen bars) for the underwater level, all soft: the triangle channel
    sings the tune with a slow vibrato, low triangle notes mark the bars and two soft notes answer on two and
    three, a rounded square wave runs up and down the chord in 8ths like a harp with a long echo, a thin music-box
    pulse doubles the tune an octave up in the second half, and bubbles rise."""
    r = dsp.rng(s.id, "bubbles")
    t, ch = s.tonic, s.chords
    bass, acc, harp = s.zeros(), s.zeros(), s.zeros()
    for c, v in zip(ch, voicing(ch, 60, 74, 67, triad, span=12)):
        R = root_of(c, 45, 41, 52)
        tones = chord_notes(c, 67, 88)
        for w in range(int(c.dur // 3)):
            o = c.start + w * 3
            s.add(bass, M.chip_tri(R if w % 2 == 0 else R + 7, round(s.sec(2.5), 4), s.sr, 0.85), o)
            for bt, vel in ((1, 0.6), (2, 0.5)):
                for m in v[-2:]:
                    s.add(acc, M.chip_tri(m, round(s.sec(0.7), 4), s.sr, vel, soft=True), o + bt)
            for q, j in enumerate((0, 1, 2, 3, 2, 1)):
                s.add(harp, M.chip_pulse(tones[(j + w % 2) % len(tones)], round(s.sec(0.4), 4), s.sr, 0.5,
                                         0.7 if q else 0.9, dec=0.12, lp=2200.0), o + q * 0.5)
    harp = room(s, echo(s, harp, 1.5, 0.3, 0.45, 3, 2500), 0.2, 1.6, "harp", damp=4000)
    tn = tune("5:2 3:1 | 5:2 7:1 | 1+:1.5 7:.5 6:1 | 5:3 | 6:2 4:1 | 5:2 3:1 | 4:1 2:1 4:1 | 2:3 |"
              " 5:2 3:1 | 5:2 7:1 | 1+:1.5 2+:.5 1+:1 | 3+:2 1+:1 | 6:1 1+:1 4+:1 | 2+:1.5 7:.5 5:1 | 1+:3 | r:2 3:1",
              t, 5, bar=3.0)
    lead = lay(s, v_ctri(soft=True, vib=0.18, gate=0.97), tn)
    lead = room(s, echo(s, lead, 1.0, 0.12, 0.3, 2, 2500), 0.22, 1.6, "lead", damp=4000, predelay=0.02)
    box = lay(s, v_pulse(0.125, dec=0.2, lp=3000.0, k=1), [(b, min(du, 1.0), m + 12, v) for b, du, m, v in tn if b >= 24])
    box = room(s, echo(s, box, 0.75, 0.2, 0.35, 2, 3000), 0.2, 1.6, "box", damp=4500)
    fx = s.zeros()
    pent = [m for m in range(74, 92) if (m - t) % 12 in (0, 2, 4, 7, 9)]
    for i in range(22):
        beat = float(r.integers(0, s.beats * 2)) * 0.5 + 0.25
        s.add(fx, bubble(s.sr, pent[int(r.integers(len(pent)))], key=i), beat, float(r.uniform(0.4, 1.0)))
    fx = room(s, fx, 0.3, 1.8, "bubbles", damp=4000)
    return {"bass": bass, "keys": acc, "arp": harp, "lead": lead, "celesta": box, "fx": fx}


def boss_rush_blitz(s):
    """176 BPM boss rush, two eight-bar halves over a falling line of chords: a kick on every beat, the noise
    snare on two and four, galloping hats, tom fills; the triangle bass gallops (an 8th and two 16ths an octave
    up); in the first half the tune hammers 16ths, every note thrown against a pedal note of the chord, and
    the chords flash as rolls on the off-beats; in the second half a square wave sings long notes with vibrato
    over 16th arpeggios."""
    r = dsp.rng(s.id, "boss")
    t, ch = s.tonic, s.chords
    k = kits(s, "arcade")
    d = s.zeros()
    hits(s, d, k["kick"], "X...X...X...X...", r, gain=0.9, jit=0)
    hits(s, d, k["snare"], {"*": "....X.......X...", 3: "....X.......X.xx", 11: "....X.......X.xx", 7: "....X...........",
                            15: "....X..........."}, r, gain=0.75, jit=0)
    hits(s, d, k["hat"], "x.xxx.xxx.xxx.xx", r, gain=0.35, jit=0)
    for drum, pat in (("tom_hi", "........xx......"), ("tom_mid", "..........xx...."), ("tom_lo", "............xxxx")):
        hits(s, d, k[drum], {7: pat, 15: pat}, r, gain=0.7, jit=0)
    hits(s, d, k["crash"], {0: "X...............", 8: "X..............."}, r, gain=0.45, jit=0)
    d = room(s, d, 0.06, 0.5, "drums", damp=6000)

    def gallop(c, n, i):
        R = root_of(c, 45, 41, 52)
        out = []
        for q in range(int(c.dur)):
            up = R + 7 if q % 4 == 3 else R + 12
            out += [(q, 0.3, R, 0.9), (q + 0.5, 0.2, up, 0.7), (q + 0.75, 0.2, up, 0.6)]
        return out
    bass = line(s, ch, gallop, v_ctri())
    a = tune("1+:1 7:1 1+:1 3+:1 | 2+:1 7:1 5:1 7:1 | 1+:1 6:1 1+:1 3+:1 | 7:1 5:1 3:1 5:1 |"
             " 6:1 4:1 6:1 1+:1 | 5:1 3:1 5:1 1+:1 | 4:1 2:1 4:1 6:1 | 7:1 5:1 7:1 2+:1", t, 5)
    riff = s.zeros()
    for beat, _, m, _ in a:
        pedal = chord_notes(s.chord_at(beat), 67, 78)[0]
        for j in range(4):
            s.add(riff, M.chip_pulse(m if j % 2 == 0 else pedal, round(s.sec(0.2), 4), s.sr, 0.25,
                                     0.85 if j % 2 == 0 else 0.5, dec=0.06, lp=4000.0), beat + j * 0.25)
    b2 = tune("5:1.5 1+:.5 3+:2 | 2+:1.5 7:.5 5:2 | 1+:1.5 3+:.5 1+:1 6:1 | 7:3 5:.5 7:.5 |"
              " 1+:1.5 6:.5 4:1 6:1 | 5:1 1+:1 3+:2 | 4+:1 1+:1 2+:1 7:1 | 1+:3 r:1", t, 5)
    sing = lay(s, v_pulse(0.5, vib=0.25, lp=4000.0, gate=0.92), [(b + 32, du, m, v) for b, du, m, v in b2])
    lead = room(s, echo(s, riff + sing, 0.75, 0.1, 0.3, 2, 3000), 0.08, 0.7, "lead", damp=4500)
    first = [c for c in ch if c.start < 32]
    rolls = comp(s, first, voicing(first, 60, 76, 67, triad, span=12),
                 lambda c, i: [(q + 0.5, 0.12, 0.7) for q in range(1, int(c.dur), 2)], v_pulse(0.25, dec=0.05, lp=3500.0),
                 spread=s.sec(0.125))
    arp = s.zeros()
    for c in ch:
        if c.start < 32:
            continue
        tones = chord_notes(c, 64, 84)[:4]
        for q in range(int(c.dur * 4)):
            s.add(arp, M.chip_pulse(tones[(0, 1, 2, 3, 2, 1, 2, 1)[q % 8] % len(tones)], round(s.sec(0.2), 4), s.sr, 0.125,
                                    0.75 if q % 4 == 0 else 0.55, dec=0.05, lp=3500.0, key=1), c.start + q * 0.25)
    return {"drums": d, "bass": bass, "lead": lead, "keys": rolls, "arp": arp}


def try_again_lullaby(s):
    """72 BPM lullaby of the 'game over, try again' screen, no drums: a soft triangle rocks broken chords in
    8ths (low, high, middle, high), the triangle bass holds one long note a chord, a rounded square wave sings
    a slow tune with a little vibrato, and a thin music-box pulse answers at the end of every bar, three notes
    up the chord, and climbs down the C chord over the last one."""
    t, ch = s.tonic, s.chords
    acc = s.zeros()
    for c, v in zip(ch, voicing(ch, 55, 69, 62, triad, span=12)):
        for q in range(int(c.dur * 2)):
            m = (v[0], v[2], v[1], v[2])[q % 4]
            s.add(acc, M.chip_tri(m, round(s.sec(0.48), 4), s.sr, 0.7 if q % 4 == 0 else 0.5, soft=True), c.start + q * 0.5)
    acc = room(s, acc, 0.16, 1.4, "acc", damp=4000)
    bass = line(s, ch, lambda c, n, i: [(0, c.dur * 0.95, root_of(c, 45, 41, 52), 0.8)], v_ctri())
    tn = tune("3:1.5 5:.5 1+:2 | 6:1.5 4:.5 6:2 | 5:1 3:1 1:2 | 2:1.5 3:.5 2:1 r:1 |"
              " 3:1.5 6:.5 1+:2 | 1+:1 6:1 4:2 | 4:1 2:1 7-:1 2:1 | 1:3 r:1", t, 5)
    lead = lay(s, v_pulse(0.5, vib=0.15, lp=2600.0, gate=0.97), tn)
    lead = room(s, echo(s, lead, 1.0, 0.14, 0.3, 2, 2500), 0.2, 1.5, "lead", damp=4000, predelay=0.02)
    box = s.zeros()
    for bar in range(s.bars - 1):
        tones = chord_notes(s.chord_at(bar * 4 + 3), 84, 96)[:3]
        for j, m in enumerate(tones):
            s.add(box, M.chip_pulse(m, 0.3, s.sr, 0.125, 0.7, dec=0.08, lp=4000.0, key=1), bar * 4 + 2.5 + j * 0.5)
    for j, m in enumerate((96, 91, 88, 84, 79)):
        s.add(box, M.chip_pulse(m, 0.3, s.sr, 0.125, 0.7, dec=0.08, lp=4000.0, key=1), (s.bars - 1) * 4 + 1 + j * 0.5)
    box = room(s, echo(s, box, 0.75, 0.25, 0.4, 3, 3000), 0.22, 1.6, "box", damp=4500)
    return {"keys": acc, "bass": bass, "lead": lead, "celesta": box}


# ===================================================== MIDNIGHT CAFE (Db) - Part 2
# The night café beyond its theme (music.py: rainy boom-bap at 68 BPM in Bb minor, an electric piano, a muted horn,
# rain and a wind chime, a neon hum). Its four songs are other hours of the same night, none of them the café of
# the day (rainy_window, pancake_sunday, pixel_cafe, sleepy_cat, in F): night_tram rides the last tram (the rail
# joints are its hats, a far muted horn sings), neon_puddles is jazzy hip-hop after the rain (muted guitar chops,
# a vibraphone, drops echoing in the puddles), three_am_tea has no kick at all (a kettle that starts to sing, a
# music box, slow brushes, the hum of the fridge), rooftop_stars is the hopeful walk home in Db major (a bright
# piano riff, a bouncy bass, finger snaps, a whistled tune).


def rail_click(sr, key=0):
    """A wheel over a rail joint: a hard little click with a ring of steel and the thud of the bogie under it."""
    def mk():
        n = nsamp(0.09, sr)
        t = np.arange(n) / sr
        r = dsp.rng("rail", key)
        x = dsp.bandpass(r.standard_normal(n), 2500, 8000, sr) * np.exp(-t / 0.004)
        x += 0.35 * np.sin(TAU * float(midi_hz(87)) * t) * np.exp(-t / 0.02)  # Eb7: the steel rings in key
        x += 0.6 * np.sin(TAU * 70.0 * t) * np.exp(-t / 0.03) * (1 - np.exp(-t / 0.002))
        return dsp.fade(x / dsp.peak(x), sr, 0.0003, 0.01)
    return M.cached(("railclick", sr, key), mk)


def night_tram(s):
    """72 BPM: the last tram through the rain. A soft kick and a brushed snare, the wheels clicking over the rail
    joints as hats ('clack-clack ... clack-clack'), a warm electric piano with a tape wobble, a round sub bass on
    root and fifth, the tram's bell twice at the top of each half, and far away a muted horn sings the tune."""
    r = dsp.rng(s.id, "tram")
    t, ch = s.tonic, s.chords
    k = kits(s, "midnight")
    d = s.zeros()
    hits(s, d, k["kick"], ["X.........x.....", "X.....o...x....."], r, swing=0.35, gain=0.85, jit=0.004)
    hits(s, d, k["snare"], "....x.......x...", r, gain=0.7, jit=0.004)
    hits(s, d, k["ghost"], {3: "..............og", 7: "............o.og"}, r, swing=0.35, gain=0.6)
    rails = [rail_click(s.sr, i) for i in range(3)]
    hits(s, d, rails, "X.x.....X.x.....", r, gain=0.55, jit=0.002)
    hits(s, d, rails, "......g.......g.", r, gain=0.5, jit=0.003)
    d = room(s, loop_filter(s, d, "lp", 7500), 0.14, 0.8, "drums", damp=5000)
    vo = voicing(ch, 55, 74, 64, no_root)
    rhy = lambda c, i: [(0, 2.4, 0.6), (2.5, 1.3, 0.42)] if c.dur >= 4 else [(0, 1.8, 0.55)]  # noqa: E731
    keys = comp(s, ch, vo, rhy, lambda ss, m, du, v: v_epiano(ss, m, du, v, 0.75, 0.35), spread=0.018, r=r,
                swing=0.35)
    keys = room(s, tape(s, loop_filter(s, keys, "lp", 4500), 9.0, 0.4, 1.5), 0.22, 1.5, "keys", damp=4500)

    def roots(c, n, i):
        R = root_of(c, 42, 36, 47)
        return ([(0, 2.3, R, 0.9), (2.5, 1.2, R + 7 if R + 7 <= 50 else R - 5, 0.65)] if c.dur >= 4
                else [(0, 1.8, R, 0.85)])
    bass = loop_filter(s, line(s, ch, roots, v_sub, r=r, jit=0.003, swing=0.35), "lp", 800)
    ding = s.zeros()
    for bar in (0, 4):
        for j, (bt, m) in enumerate(((0.0, 85), (0.35, 85))):  # Db6 twice: 'ding-ding'
            s.add(ding, bell(s, m, 0.8 - 0.15 * j, t60=1.4), bar * 4 + bt)
    ding = room(s, ding, 0.35, 2.0, "bell", damp=6000)
    tn = tune("r:1 6:.5 1+:.5 3+:1.5 2+:.5 | 7:2 5:1 6:1 | 1+:1.5 6:.5 5:2 | r:2 5:.5 6:.5 1+:1 |"
              " 3+:1.5 2+:.5 1+:1 6:1 | 7:1.5 1+:.5 5:2 | 4+:1 2+:1 1+:1.5 2+:.5 | 6:3 r:1", t, 4)
    trp = mono(s, tn, "trumpet", swing=0.35, key="tram")
    trp = loop_filter(s, loop_eq(s, trp, "peak", 1500, 6.0, 2.0), "lp", 2800)  # the mute, and the distance
    trp = room(s, echo(s, tape(s, trp, 6.0, 0.35), 0.75, 0.25, 0.4, 3, 2500), 0.4, 2.4, "trumpet", damp=3500,
               predelay=0.04)
    return {"drums": d, "keys": keys, "bass": bass, "trumpet": trp, "celesta": ding, "dust": M.vinyl_crackle(s)}


def drip(s, m, key=0):
    """A drop falling into a puddle: a soft round 'plip' that slides down a little from its note."""
    def mk():
        n = nsamp(0.25, s.sr)
        tt = np.arange(n) / s.sr
        f = float(midi_hz(m)) * (1.0 + 0.12 * np.exp(-tt / 0.012))
        x = np.sin(TAU * np.cumsum(f) / s.sr) * np.exp(-tt / 0.06) * (1 - np.exp(-tt / 0.002))
        return dsp.fade(x, s.sr, 0.0005, 0.02)
    return M.cached(("drip", m, s.sr, key), mk)


def neon_puddles(s):
    """84 BPM jazzy hip-hop after the rain: a swung boom-bap, a guitar that chops muted chords on the off-beats,
    a walking upright bass, a vibraphone tune, drops falling into the puddles on the notes of the pentatonic
    scale and echoing long."""
    r = dsp.rng(s.id, "puddles")
    t, ch = s.tonic, s.chords
    k = kits(s, "lofi")
    d = s.zeros()
    # the kick never lands with the snare (a stacked hit on four would eat the headroom of the notes in a level)
    hits(s, d, k["kick"], ["X.....x...x.....", "X.....x..x...x.."], r, swing=0.45, gain=0.9)
    hits(s, d, k["snare"], "....X.......X...", r, swing=0.45, gain=0.8)
    hits(s, d, k["rim"], {1: "..............g.", 5: "..............g.", 7: "...........g.gx."}, r, swing=0.45, gain=0.6)
    hits(s, d, k["hat"], "x.ogx.o.x.ogx.o.", r, swing=0.45, gain=0.5)
    d = room(s, loop_eq(s, dsp.drive(d / dsp.peak(d) * 1.1, 1.2), "highshelf", 4500, 1.5), 0.12, 0.7, "drums",
             damp=6000)
    vo = voicing(ch, 57, 74, 65, no_root)
    gtr = s.zeros()
    for i, c in enumerate(ch):
        for bt, v, up in ((0.5, 0.8, False), (1.5, 0.65, True), (2.5, 0.8, False), (3.25, 0.5, True)):
            if bt >= c.dur:
                continue
            x = v_strum(s, vo[i], 0.12, v, up=up, spread=0.006, bright=0.4, t60=0.35, mute=0.025, key=i % 3)
            s.add(gtr, x, sw(c.start + bt, 0.45), 1.0, dt=float(r.normal(0.003, 0.002)))
    gtr = room(s, loop_eq(s, loop_filter(s, gtr, "hp", 150), "peak", 2200, 2.0, 0.9), 0.15, 0.9, "gtr", damp=5000)

    def walkin(c, n, i):
        R = root_of(c, 43, 36, 50)
        nxt = root_of(n, R, 36, 50)
        ap = scale_step(t, nxt, nxt < R)
        if c.dur < 4:
            return [(0, 0.9, R, 0.9), (1.0, 0.9, ap, 0.7)]
        third = R + (3 if 3 in c.tones else 4)
        return [(0, 0.9, R, 0.9), (1.0, 0.9, third, 0.7), (2.0, 0.9, R + 7 if R + 7 <= 52 else R - 5, 0.8),
                (3.0, 0.9, ap, 0.7)]
    bass = room(s, loop_filter(s, line(s, ch, walkin, v_upright, r=r, jit=0.004, swing=0.45), "lp", 1100), 0.06,
                0.6, "bass", damp=2500)
    tn = tune("6:.5 5:.5 3:1 r:.5 2:.5 3:1 | 5:1.5 3:.5 7-:2 | r:.5 6-:.5 1:.5 3:.5 2:2 | 1:1 7-:.5 5-:.5 1:2 |"
              " 6:.5 5:.5 3:1 r:.5 5:.5 6:1 | 7:1.5 5:.5 3:2 | 2:1 3:.5 4:.5 5:1 4:1 | 3:1 1:1 6-:2", t, 5)
    vib = room(s, echo(s, lay(s, v_vibes, tn, r=r, jit=0.004, swing=0.45), 0.75, 0.2, 0.35, 3, 4500), 0.22, 1.5,
               "vib", damp=6000)
    pent = [m for m in range(85, 98) if (m - t) % 12 in (0, 2, 4, 7, 9)]
    drops = s.zeros()
    for bar in range(s.bars):
        for j in range(2 if bar % 2 else 3):
            bt = bar * 4 + float(r.uniform(0.0, 4.0))
            s.add(drops, drip(s, pent[int(r.integers(len(pent)))], j), bt, float(r.uniform(0.4, 0.9)))
    drops = room(s, echo(s, drops, 0.75, 0.45, 0.55, 5, 3500), 0.35, 2.2, "drops", damp=5000)
    return {"drums": d, "guitar": gtr, "bass": bass, "vibes": vib, "fx": drops, "dust": M.vinyl_crackle(s)}


def three_am_tea(s):
    """64 BPM, three in the morning, no kick drum: a soft pad that breathes, a kettle on the stove that hisses
    and slowly starts to sing (a faint whistle high on the fifth of the key), a music-box tune, brushes swept
    slowly on two and four, and the low hum of the fridge on the root of every chord."""
    r = dsp.rng(s.id, "tea")
    t, ch = s.tonic, s.chords
    d = s.zeros()
    for bar in range(s.bars):
        for bt in (1.0, 3.0):
            s.add(d, ins.brush_swish(s.sr, s.sec(0.9), key=bar * 2 + int(bt)), bar * 4 + bt - 0.35, 0.7)
        for bt, v in ((0.0, 0.35), (2.0, 0.3), (2.75, 0.2)):
            s.add(d, ins.brush_tap(s.sr, key=bar * 3 + int(bt * 4), dur=0.1, tone=float(midi_hz(49))), bar * 4 + bt,
                  v * float(r.uniform(0.85, 1.05)))
    d = room(s, loop_filter(s, d, "lp", 7000), 0.25, 1.4, "drums", damp=5000)
    pad = comp(s, ch, voicing(ch, 53, 72, 62, no_root), lambda c, i: [(0, c.dur * 0.98, 0.7)],
               lambda ss, m, du, v: v_pad(ss, m, du, v, 1400.0, 1.0, 1.4, k=m % 3), r=r)
    pad = room(s, tape(s, loop_filter(s, pad, "hp", 120), 6.0, 0.25, 1.0), 0.3, 2.4, "pad", damp=4000)
    hum = loop_filter(s, line(s, ch, lambda c, n, i: [(0, c.dur * 0.98, root_of(c, 37, 32, 43), 0.8)], v_sub, r=r),
                      "lp", 300)
    tn = tune("5:1 3:1 1+:1.5 7:.5 | 6:2 5:1 3:1 | 4:1 6:1 1+:1 6:1 | 5:3 r:1 |"
              " 3:1 5:1 2+:1.5 1+:.5 | 7:2 5:1 3:1 | 6:1 5:.5 4:.5 6:1 1+:1 | 7:1.5 5:.5 3:2", t, 5)
    box = lay(s, lambda ss, m, du, v: v_celesta(ss, m, du, v * 0.85, t60=1.1), tn, r=r, jit=0.006)
    box = room(s, echo(s, box, 1.0, 0.25, 0.4, 3, 4500), 0.35, 2.4, "box", damp=5000)
    n = s.n
    swell = 0.5 - 0.5 * s.lfo(1.0 / (n / s.sr), 0.25)  # the kettle warms up over the loop and calms again
    hiss = dsp.loop_apply(r.standard_normal(n), lambda z: dsp.bandpass(z, 2500, 7500, s.sr)) * (0.3 + 0.7 * swell)
    tt = np.arange(n) / s.sr
    f = float(midi_hz(nearest((t + 7) % 12, 92, 86, 97)))  # the fifth of the key, high: the kettle's whistle
    f = round(f * n / s.sr) * s.sr / n
    whistle = np.sin(TAU * f * tt) * swell ** 3 * (1 + 0.1 * s.lfo(5.0))
    kettle = hiss / np.std(hiss) + 0.6 * whistle / dsp.peak(whistle)
    kettle = room(s, kettle, 0.3, 1.8, "kettle", damp=6000)
    return {"drums": d, "pad": pad, "bass": hum, "box": box, "fx": kettle}


def rooftop_stars(s):
    """92 BPM, the hopeful walk home over the roofs in Db major: a light boom-bap with finger snaps on two and
    four, a bright piano riff that pushes across the beat, a bouncy bass that hops between root and octave, a
    whistled synth tune, a few high bells (the stars) in the second half."""
    r = dsp.rng(s.id, "stars")
    t, ch = s.tonic, s.chords
    k = kits(s, "lofi")
    snaps = kits(s, "block")["snap"]
    d = s.zeros()
    hits(s, d, k["kick"], ["X.....x...x.....", "X.....x...x..x.."], r, swing=0.3, gain=0.9)
    hits(s, d, k["snare"], {3: "............x.gx", 7: "..........g.x.xx"}, r, swing=0.3, gain=0.5)
    hits(s, d, snaps, "....X.......X...", r, gain=0.9, jit=0.004)
    hits(s, d, k["hat"], "x.o.x.o.x.o.x.oo", r, swing=0.3, gain=0.5)
    d = room(s, loop_eq(s, dsp.drive(d / dsp.peak(d) * 1.1, 1.2), "highshelf", 5000, 2.0), 0.12, 0.7, "drums",
             damp=6500)
    vo = voicing(ch, 58, 77, 67)
    riff = [(0, 0.45, 0.85), (0.75, 0.25, 0.6), (1.5, 0.45, 0.75), (2.5, 0.45, 0.8), (3.25, 0.6, 0.65)]
    pno = comp(s, ch, vo, lambda c, i: within(c, riff), lambda ss, m, du, v: v_piano(ss, m, du, v, 0.9, 0.15),
               spread=0.008, r=r, swing=0.3)
    pno = room(s, loop_filter(s, pno, "hp", 140), 0.18, 1.2, "piano", damp=6000)

    def hop(c, n, i):
        R = root_of(c, 41, 36, 47)
        out = []
        for q in range(int(c.dur * 2)):
            if q % 4 == 1:
                continue
            out.append((q * 0.5, 0.35, R + 12 if q % 2 == 1 else R, 0.9 if q % 4 == 0 else 0.65))
        return out
    bass = loop_filter(s, line(s, ch, hop, lambda ss, m, du, v: v_sbass(ss, m, du, v, 900.0, 0.07), r=r, jit=0.003,
                               swing=0.3), "lp", 1300)
    tn = tune("3:.5 5:.5 1+:1 2+:.5 1+:.5 5:1 | 7-:1 3:1 5:1.5 3:.5 | 6:1.5 5:.5 4:1 3:1 | 5:2 r:1 5:.5 6:.5 |"
              " 1+:1 2+:.5 3+:.5 2+:1 1+:1 | 7:1.5 5:.5 3:2 | 6:1 4:1 5:1 2+:1 | 1+:3 r:1", t, 5)
    whistle = room(s, echo(s, mono(s, tn, "flute", swing=0.3, key="stars"), 0.75, 0.2, 0.35, 3, 5000), 0.25, 1.6,
                   "whistle", damp=6000)
    stars = s.zeros()
    for c in ch:
        if c.start >= 16:
            ns = chord_notes(c, 85, 98)
            for q, j in enumerate((0, 2, 1, 3)):
                s.add(stars, v_celesta(s, ns[j % len(ns)], 0.5, 0.45, t60=0.7), c.start + 0.5 + q * 0.75)
    stars = room(s, echo(s, stars, 0.75, 0.25, 0.35, 3, 6000), 0.3, 1.8, "stars", damp=7000)
    return {"drums": d, "keys": pno, "bass": bass, "lead": whistle, "celesta": stars}


# ============================================================ registry

# id -> (progression, function, {part: relative loudness dB}). The progression is the song's harmony;
# levels overrides LEVELS for the parts it names.
LEVELS = {"drums": -17, "bass": -20, "keys": -19, "guitar": -21, "lead": -19, "vibes": -22, "celesta": -24,
          "arp": -23, "pad": -24, "box": -20, "heart": -27, "rain": -37, "dust": -37, "brass": -21, "voice": -19,
          "trumpet": -21, "sax": -20, "strings": -22, "organ": -25, "choir": -25, "fx": -26, "chops": -24, "tamb": -25,
          "gang": -21, "quack": -24}

# Progressions are in Roman numerals of the genre key: diatonic roots only, so every song stays in its genre's key.
SONGS = {
    # cafe (F major)
    "rainy_window": ("vi7:4 IVmaj7:4 Imaj7:4 V9:4 vi7:4 IVmaj7:4 Imaj7:2 ii7:2 V7sus4:4", rainy_window, {}),
    "pancake_sunday": ("Imaj7:4 IVmaj7:4 ii7:4 V7:4 Imaj7:4 vi7:4 ii7:4 V7:4", pancake_sunday, {}),
    "pixel_cafe": ("I:4 V:4 vi:4 IV:4 I:4 V:4 vi:4 IV:4", pixel_cafe, {"arp": -21, "bass": -19}),
    "sleepy_cat": ("I:4 vi:4 IV:4 V:4 I:4 iii:4 IV:4 V:4", sleepy_cat, {"box": -19, "pad": -24, "heart": -29}),
    # jazz (Bb major)
    "bossa_breeze": ("Imaj7:4 IVmaj7:4 iii7:4 vi7:4 ii7:4 V7:4 Imaj7:4 ii7:2 V7:2", bossa_breeze, {}),
    "moonlight_ballad": ("Imaj9:4 vi7:4 ii7:4 V7:4 Imaj9:4 IVmaj7:4 ii7:4 V7sus4:2 V7:2", moonlight_ballad, {"lead": -19}),
    "scat_parade": ("Imaj7:2 vi7:2 ii7:2 V7:2 Imaj7:2 vi7:2 ii7:2 V7:2 IVmaj7:4 ii7:2 V7:2 iii7:2 vi7:2 ii7:2 V7:2 "
                    "Imaj7:2 vi7:2 ii7:2 V7:2 Imaj7:4 ii7:2 V7:2", scat_parade, {}),
    "boogie_mouse": ("I6:4 I6:4 I6:4 I6:4 IV6:4 IV6:4 I6:4 I6:4 V7:4 IV6:4 I6:4 V7:4", boogie_mouse, {"keys": -17}),
    # square (G major)
    "carnival_samba": ("I6:4 vi7:4 ii7:4 V7:4 I6:4 IVmaj7:4 ii7:2 V7:2 I6:4", carnival_samba, {"drums": -16}),
    "oompah_polka": ("I:4 V7:4 I:4 V7:4 I:4 IV:4 I:4 V7:4 I:4 IV:4 V7:4 I:4", oompah_polka, {}),
    "marching_ducks": ("I:4 I:4 IV:4 I:4 I:4 V:4 I:4 IV:4 V7:4 I:4 V7:4 I:4", marching_ducks, {"drums": -16}),
    "calypso_sun": ("I:4 IV:4 I:4 V7:4 I:4 IV:4 I:2 V7:2 I:4", calypso_sun, {}),
    # stadium (A major)
    "neon_heartbeat": ("vi:4 IV:4 I:4 V:4 vi:4 IV:4 I:4 V:4 vi:4 IV:4 I:4 V:4", neon_heartbeat, {"drums": -15}),
    "idol_ballad": ("I:4 V:4 vi:4 iii:4 IV:4 I:4 IV:4 V:4", idol_ballad, {"keys": -19, "lead": -20}),
    "candy_rush": ("IV:4 V:4 iii:4 vi:4 IV:4 V:4 iii:4 vi:4 IV:4 V:4 iii:4 vi:4", candy_rush, {"drums": -15}),
    "lightstick_wave": ("Imaj7:4 vi7:4 IVmaj7:4 V7sus4:4 Imaj7:4 iii7:4 IVmaj7:4 V7sus4:4", lightstick_wave, {}),
    # garage (E major)
    "surf_splash": ("I:4 vi:4 IV:4 V:4 I:4 vi:4 IV:4 V:4 I:4 vi:4 IV:4 V:4", surf_splash, {"lead": -17, "drums": -16}),
    "skate_sprint": ("I:4 V:4 vi:4 IV:4 I:4 V:4 vi:4 IV:4 I:4 V:4 vi:4 IV:4 I:4 V:4 vi:4 IV:4", skate_sprint, {"drums": -15}),
    "sunrise_ballad": ("I:4 V:4 vi:4 IV:4 I:4 V:4 IV:4 V:4", sunrise_ballad,
                       {"keys": -17, "strings": -20, "drums": -19.5, "lead": -21, "organ": -24}),
    "stomp_clap": ("I:4 IV:4 I:4 V:4 I:4 IV:4 V:4 I:4", stomp_clap, {"drums": -15}),
    # beach (D major)
    "beach_morning_samba": ("Imaj7:4 vi7:4 ii7:4 V7:4 Imaj7:4 IVmaj7:4 iii7:4 vi7:4 ii7:4 V7:4 I6:4 ii7:2 V7:2",
                            beach_morning_samba, {"arp": -24, "guitar": -20}),
    "sunset_hammock": ("Imaj9:4 iii7:4 IVmaj7:4 V7sus4:2 V7:2 vi7:4 ii9:4 IVmaj7:2 V7sus4:2 I6:4", sunset_hammock,
                       {"keys": -23, "guitar": -20, "drums": -19}),
    "night_tide": ("Imaj7:4 IVmaj7:4 Imaj7:4 vi7:4 ii7:4 V7sus4:4 IVmaj7:2 iii7:2 ii7:2 V7:2", night_tide,
                   {"drums": -25, "fx": -31, "guitar": -20, "lead": -20, "vibes": -25, "voice": -27, "bass": -21}),
    "coconut_cha_cha": ("I6:4 IV6:4 V7:4 I6:4 vi7:4 ii7:4 V7:4 I6:4 IV6:4 I6:4 ii7:2 V7:2 I6:4", coconut_cha_cha,
                        {"keys": -21, "lead": -18}),
    # carnival (C major)
    "salsa_confetti": ("I6:4 I6:4 ii7:4 V7:4 ii7:4 V7:4 I6:4 I6:4 IV6:4 IV6:4 I6:4 I6:4 ii7:4 V7:4 I6:4 V7:4",
                       salsa_confetti, {"keys": -20, "brass": -22}),
    "moonlit_cumbia": ("I:4 V7:4 V7:4 I:4 IV:4 I:4 V7:4 I:4", moonlit_cumbia,
                       {"guitar": -20, "flute2": -24, "arp": -22}),
    "candlelight_bolero": ("Imaj7:4 vi7:4 ii7:4 V7:4 Imaj7:4 IVmaj7:4 ii7:2 V7:2 I:4", candlelight_bolero,
                           {"drums": -24, "guitar": -20, "lead": -18, "strings": -26, "bass": -21}),
    "mambo_fireworks": ("I6:4 V7:4 V7:4 I6:4 I6:4 V7:4 V7:4 I6:4 IV6:4 I6:4 V7:4 I6:4 IV6:4 I6:4 ii7:2 V7:2 I6:4",
                        mambo_fireworks, {"sax": -19, "brass": -21, "lead": -19, "keys": -24, "gang": -20}),
    # cinema (Eb major)
    "adventure_overture": ("I:4 I:4 IV:4 I:4 vi:4 ii:4 V:4 V:4 I:4 I:4 IV:4 I:4 IV:4 V:4 I:4 V:4", adventure_overture,
                           {"drums": -21, "timp": -21, "strings": -21, "bass": -21, "lead": -18, "brass": -20}),
    "balcony_waltz": ("I:3 vi:3 ii:3 V7:3 I:3 vi:3 IV:3 V7:3 iii:3 vi:3 ii:3 V7:3 IV:3 V7:3 I:6", balcony_waltz,
                      {"arp": -20, "lead": -18, "clarinet": -22, "bass": -24, "strings": -25, "celesta": -25}),
    "popcorn_chase": ("I:4 I:4 V7:4 V7:4 ii7:4 V7:4 I:4 I:4 IV:4 IV:4 I:4 vi:4 ii:4 V7:4 I:4 V7:4", popcorn_chase,
                      {"drums": -21, "bass": -20, "guitar": -23, "lead": -18, "piccolo": -21, "brass": -23}),
    "closing_credits": ("I:4 iii:4 IV:4 V:4 vi:4 IV:4 ii7:2 V7:2 I:4 IV:4 I:4", closing_credits,
                        {"drums": -23, "timp": -22, "lead": -18, "brass": -21, "choir": -25, "strings": -24,
                         "bass": -21, "arp": -23}),
    # bazaar (G major)
    "spice_market_dance": ("I:4 I:4 IV:4 V:4 I:4 I:4 IV:4 V:4 vi:2 V:2 IV:2 iii:2 IV:2 V:2 I:4", spice_market_dance,
                           {"drums": -19, "tamb": -25, "lead": -18, "arp": -22, "strings": -21, "bass": -20}),
    "caravan_bells": ("vi:4 vi:4 IV:4 iii:4 vi:4 vi:4 V:4 vi:4 IV:2 iii:2 vi:4", caravan_bells,
                      {"drums": -19, "celesta": -25, "lead": -18, "strings": -21, "guitar": -21, "bass": -20,
                       "pad": -27}),
    "desert_starlight": ("ii:4 ii:4 V:4 ii:4 IV:4 vi:4 V:4 ii:4", desert_starlight,
                         {"drums": -27, "lead": -18, "arp": -21, "pad": -24, "celesta": -27, "bass": -24}),
    "wedding_drums": ("V:4 V:4 IV:4 V:4 V:4 V:4 IV:4 V:4 I:4 I:4 V:4 V:4 IV:4 IV:4 V:4 V:4", wedding_drums,
                      {"drums": -18, "tamb": -24, "lead": -18, "strings": -21, "guitar": -22, "bass": -20,
                       "gang": -22}),
    # skyclub (Ab major)
    "rooftop_sunrise": ("IVmaj7:4 I:4 V:4 vi7:4 IVmaj7:4 I:4 V:4 vi7:4 IVmaj7:4 V:4 Iadd9:4 Iadd9:4", rooftop_sunrise,
                        {"drums": -17, "bass": -20, "keys": -20, "pad": -25, "lead": -18.5, "celesta": -25, "fx": -27}),
    "cloud_bounce": ("Imaj9:4 iii7:4 IVmaj9:4 V7sus4:4 vi9:4 iii7:4 IVmaj9:2 V7sus4:2 Iadd9:4", cloud_bounce,
                     {"drums": -17, "keys": -19, "bass": -21, "chops": -19, "celesta": -25, "arp": -24, "fx": -27}),
    "mirrorball_groove": ("I6:4 vi7:4 ii7:4 V7:4 I6:4 vi7:4 ii7:4 V7:4 IVmaj7:4 iii7:4 ii7:4 V7:4", mirrorball_groove,
                          {"drums": -17, "tamb": -26, "bass": -19, "guitar": -22, "keys": -22, "lead": -18.5,
                           "brass": -22}),
    "afterglow_lounge": ("Imaj9:4 vi7:4 IVmaj7:4 V7sus4:4 Imaj9:4 iii7:4 IVmaj7:2 ii7:2 Iadd9:4", afterglow_lounge,
                         {"drums": -25, "keys": -20, "pad": -24, "lead": -19, "celesta": -27, "bass": -22}),
    # block (Bb major)
    "block_party_jam": ("I6:4 I6:4 IVmaj7:4 V7sus4:4 I6:4 I6:4 ii7:4 V7:4 IVmaj7:4 iii7:4 ii7:2 V7sus4:2 I6:4",
                        block_party_jam, {"drums": -16.5, "tamb": -26, "bass": -19, "keys": -23, "organ": -26,
                                          "brass": -18.5, "gang": -23, "fx": -24}),
    "stoop_sunset": ("Imaj9:4 vi7:4 ii9:4 V7sus4:4 Imaj9:4 iii7:4 IVmaj7:2 V7sus4:2 I6:4", stoop_sunset,
                     {"drums": -20, "guitar": -20, "keys": -25, "bass": -20, "lead": -18.5, "trumpet": -19}),
    "hopscotch_bounce": ("I:4 IV:4 I:4 V:4 I:4 IV:4 ii7:2 V7:2 I:4", hopscotch_bounce,
                         {"drums": -17, "bass": -19, "keys": -22, "lead": -18, "celesta": -25, "fx": -25}),
    "we_made_it": ("IVmaj7:4 V:4 iii7:4 vi7:4 IVmaj7:4 V7sus4:4 Iadd9:4 I:4", we_made_it,
                   {"drums": -17, "bass": -20, "keys": -21, "strings": -23, "choir": -25, "brass": -18,
                    "celesta": -26}),
    # island (A major)
    "sunny_side_ska": ("I:4 I:4 IV:4 V7:4 I:4 I:4 IV:4 V7:4 IV:2 V7:2 I:4", sunny_side_ska,
                       {"drums": -18, "guitar": -20, "keys": -24, "bass": -19, "brass": -18}),
    "palm_shade_sway": ("I:4 vi7:4 ii7:4 V7:4 I:4 vi7:4 ii7:2 V7:2 I:4", palm_shade_sway,
                        {"drums": -19, "bass": -19, "guitar": -22, "keys": -24, "organ": -27, "sax": -18.5,
                         "choir": -25}),
    "echo_cove_dub": ("I:4 ii7:4 I:4 ii7:4 IV:4 I:4 ii7:4 I:4", echo_cove_dub,
                      {"drums": -18, "bass": -18, "guitar": -23, "organ": -24, "lead": -20, "vibes": -23, "fx": -27}),
    "steelpan_parade": ("I:4 IV:4 V7:4 I:4 I:4 IV:4 V7:4 I:4 IV:2 V7:2 I:4", steelpan_parade,
                        {"drums": -19, "lead": -17.5, "vibes": -22, "bass": -20, "brass": -20}),
    # ranch (G major)
    "haystack_breakdown": ("I:4 I:4 IV:4 I:4 I:4 IV:4 V7:4 V7:4 I:4 I:4 IV:4 I:4 I:4 V7:4 I:4 I:4", haystack_breakdown,
                           {"lead": -18.5, "fiddle": -18, "chops": -23, "guitar": -20, "bass": -18.5}),
    "campfire_waltz": ("I:3 I:3 IV:3 I:3 I:3 vi:3 V7:3 V7:3 I:3 I:3 IV:3 I:3 IV:3 V7:3 I:6", campfire_waltz,
                       {"guitar": -20, "lead": -18.5, "fiddle": -19, "bass": -23, "fx": -33}),
    "tumbleweed_swing": ("I6:4 I6:4 IV6:4 I6:4 ii7:4 V7:4 I6:4 V7:4 I6:4 IV6:4 ii7:2 V7:2 I6:4", tumbleweed_swing,
                         {"drums": -20, "bass": -19, "guitar": -22, "lead": -18, "fiddle": -20}),
    "barn_piano_romp": ("I:4 I:4 IV:4 I:4 I:4 vi:4 ii7:4 V7:4 I:4 IV:4 I:2 V7:2 I:4", barn_piano_romp,
                        {"drums": -20, "keys": -20, "lead": -18, "guitar": -24, "bass": -21.5}),
    # bluesclub (E major)
    "riverside_jump": ("I6:4 IV6:4 I6:4 I6:4 IV6:4 IV6:4 I6:4 I6:4 V7:4 IV6:4 I6:2 IV6:2 I6:2 V7:2", riverside_jump,
                       {"drums": -17, "bass": -19, "keys": -23, "brass": -20, "sax": -18.5}),
    "lamplight_piano": ("I6:4 IV6:4 I6:4 V7:4 I6:4 IV6:4 ii7:2 V7:2 I6:4", lamplight_piano,
                        {"drums": -25, "keys": -20, "lead": -18, "bass": -22, "trumpet": -23}),
    "paddle_wheel_shuffle": ("I:4 I:4 IV:4 I:4 V7:4 V7:4 I:4 I:4 IV:4 I:4 V7:4 I:4", paddle_wheel_shuffle,
                             {"drums": -20, "guitar": -20, "bass": -19, "lead": -18, "trumpet": -20.5, "fx": -28}),
    "lantern_stroll": ("I6:4 vi7:4 IV6:4 V7:4 I6:4 vi7:4 IV6:4 V7:4 IV6:4 I6:4 V7:4 I6:2 V7:2", lantern_stroll,
                       {"drums": -18.5, "bass": -19, "sax": -22, "guitar": -21, "brass": -22, "lead": -18.5}),
    # arcade (C major)
    "hero_overworld_march": ("I:4 I:4 IV:4 I:4 V:4 vi:4 IV:2 V:2 I:4 IV:4 I:4 ii:2 V:2 I:4", hero_overworld_march,
                             {"drums": -18.5, "bass": -19, "keys": -23, "lead": -18}),
    "bubble_level_waltz": ("I:3 iii:3 IV:3 I:3 IV:3 I:3 ii:3 V:3 I:3 iii:3 IV:3 I:3 IV:3 V:3 I:6", bubble_level_waltz,
                           {"bass": -21, "keys": -22, "arp": -24, "lead": -18, "celesta": -25, "fx": -28}),
    "boss_rush_blitz": ("I:4 V:4 vi:4 iii:4 IV:4 I:4 ii:4 V:4 I:4 V:4 vi:4 iii:4 IV:4 I:4 IV:2 V:2 I:4", boss_rush_blitz,
                        {"drums": -17, "bass": -19, "lead": -18, "keys": -23, "arp": -23}),
    "try_again_lullaby": ("I:4 IV:4 I:4 V:4 vi:4 IV:4 ii:2 V:2 I:4", try_again_lullaby,
                          {"keys": -21, "bass": -22, "lead": -18, "celesta": -24}),
    # midnight_cafe (Db major; the night leans on its relative minor, Bb minor) - Part 2
    "night_tram": ("vi9:4 iii7:4 IVmaj9:4 Imaj7:4 vi9:4 iii7:4 ii9:2 V7sus4:2 vi9:4", night_tram,
                   {"drums": -18, "keys": -19, "bass": -21, "trumpet": -19, "celesta": -25}),
    "neon_puddles": ("IVmaj7:4 iii7:4 vi9:4 Imaj9:4 IVmaj7:4 iii7:4 ii9:2 V7sus4:2 vi9:4", neon_puddles,
                     {"drums": -19.5, "guitar": -21, "bass": -20, "vibes": -19, "fx": -27}),
    "three_am_tea": ("Imaj9:4 vi9:4 IVmaj7:4 V7sus4:4 Imaj9:4 iii7:4 IVmaj9:4 V6:4", three_am_tea,
                     {"drums": -25, "pad": -21, "bass": -25, "box": -18, "fx": -30}),
    "rooftop_stars": ("Iadd9:4 iii7:4 IVmaj7:4 V6:4 Iadd9:4 iii7:4 IVmaj7:2 V7sus4:2 Iadd9:4", rooftop_stars,
                      {"drums": -17, "keys": -20, "bass": -20, "lead": -18, "celesta": -25}),
}


# The songs of the genres that are not districts (content/genres.json) live in songs_<group>.py: each module
# defines SONGS = {id: (prog text, function, level overrides)} like the table above and imports this module as `S`.
EXTRA_MODULES = ("songs_classic", "songs_folk", "songs_latin", "songs_pop", "songs_rnb", "songs_ambient")


def load_extra():
    """Adds the songs of the extra modules that exist to SONGS (a missing module is a genre not written yet)."""
    import importlib
    import importlib.util
    for name in EXTRA_MODULES:
        if importlib.util.find_spec(name) is None:
            continue
        mod = importlib.import_module(name)
        for sid, spec in mod.SONGS.items():
            assert sid not in SONGS, "song %s defined twice" % sid
            SONGS[sid] = spec


def song_for(entry, genre):
    """The Song grid of a catalogue entry (content/districts.json songs[]) in the key of its genre."""
    spec = SONGS[entry["id"]]
    pseudo = {"id": entry["id"], "bpm": entry["bpm"], "bars": entry["bars"],
              "semitones_from_c": genre["semitones_from_c"]}
    tonic = genre["semitones_from_c"] % 12
    s = Song(pseudo, prog(tonic, spec[0]))
    s.tonic = tonic
    return s


# parts without a pitch to speak of: left out of the "is it in key" measurement
UNPITCHED = {"drums", "tamb", "gang", "fx", "heart", "rain", "dust", "quack"}


def render_song(entry, genre):
    """Renders a song of the catalogue. Returns (song, mix, tonal, parts): the mix balanced at the relative
    loudness of every part, the same without the unpitched parts (what the key is measured on) and the raw
    parts {name: signal}. gen_audio.py sets the final level."""
    s = song_for(entry, genre)
    spec = SONGS[entry["id"]]
    parts = spec[1](s)
    levels = dict(LEVELS)
    levels.update(spec[2])
    mix, tonal = s.zeros(), s.zeros()
    for name, x in parts.items():
        x = np.asarray(x, dtype=float)
        assert len(x) == s.n, (entry["id"], name, len(x), s.n)
        assert np.all(np.isfinite(x)), (entry["id"], name)
        y = x * dsp.db_amp(levels[name] - dsp.loudness(x, s.sr))
        mix += y
        if name not in UNPITCHED:
            tonal += y
    return s, mix, tonal, parts


load_extra()
