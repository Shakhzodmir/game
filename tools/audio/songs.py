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


def tune(text, tonic, octave=5):
    """Tune in scale degrees -> [(beat, beats, midi, vel)] ; octave = the octave of degree 1 (C4 = 60)."""
    base = 12 * (octave + 1) + tonic
    out = []
    for bar, chunk in enumerate(text.split("|")):
        pos = bar * 4.0
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
        if abs(pos - (bar + 1) * 4.0) > 1e-6:
            raise ValueError("bar %d of the tune has %.3f beats" % (bar + 1, pos - bar * 4.0))
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
}


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
