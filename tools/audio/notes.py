"""Piece notes: the synesthesia core.

Each piece colour is an instrument; a match plays note n (1..11) of the C major
pentatonic C4 D4 E4 G4 A4 C5 D5 E5 G5 A5 C6. The engine transposes to the
district key with playback speed (within +-7 semitones), so every sample is
written in C and must stay pleasant when played 0.67x..1.5x.
"""
import numpy as np

import dsp
import instruments as ins
from dsp import TAU, midi_hz, nsamp

SR = 44100
SCALE = [60, 62, 64, 67, 69, 72, 74, 76, 79, 81, 84]  # C4 .. C6

# colour -> (instrument description, file length s, octave shift of the sounding pitch)
COLORS = {
    "red": ("electric guitar pluck (Karplus-Strong + gentle overdrive)", 1.10, 0),
    "orange": ("tuned percussion (marimba with steel-pan octave bloom)", 0.90, 0),
    "yellow": ("bells (glockenspiel/celesta), sounds one octave up", 1.20, 12),
    "green": ("warm FM electric piano", 1.10, 0),
    "blue": ("pluck bass, two octaves down (C2..C4)", 0.95, -24),
    "purple": ("synth pad pluck through an 'ah' vowel formant (choir-like)", 1.20, 0),
}

_ROOM = None


def _room():
    global _ROOM
    if _ROOM is None:
        _ROOM = dsp.reverb_ir(SR, t60=0.7, predelay=0.008, damp_hz=5000, key="notes-room")
    return _ROOM


def _finish(x, dur, wet=0.08):
    """Small shared room, trim to length, 2 ms fade-in, fade-out at the end."""
    y = dsp.pad_to(x / dsp.peak(x), nsamp(dur, SR))
    if wet:
        y = y + wet * dsp.convolve(y, _room())[: len(y)]
    return dsp.fade(y, SR, 0.002, min(0.12, dur * 0.12))


def red(m):
    f = midi_hz(m)
    t60 = float(np.clip(1.5 * (261.6 / f) ** 0.3, 0.9, 1.6))
    y = dsp.ks_pluck(f, 1.3, SR, t60=t60, bright=0.75, pick=0.11, key=f"red{m}", damp=0.32)
    P = SR / f  # bridge pickup comb (adds the electric 'snap')
    k = int(round(0.09 * P))
    y = y - 0.55 * np.concatenate([np.zeros(k), y[:-k]])
    y = y / dsp.peak(y)
    y = dsp.tube(y * 2.4, 1.0, SR, bias=0.12)  # gentle overdrive
    y = dsp.highpass(y, 90, SR, 2)
    y = dsp.filt(y, "peak", 2400, SR, q=0.9, gain_db=2.5)
    y = dsp.lowpass(y, 6000, SR, 2)
    return _finish(y, COLORS["red"][1], wet=0.10)


def orange(m):
    y = ins.marimba(m, SR, vel=0.9, dur=1.0).copy()
    y = dsp.filt(y, "peak", midi_hz(m) * 2, SR, q=1.0, gain_db=1.5)
    return _finish(y, COLORS["orange"][1], wet=0.07)


def yellow(m):
    y = ins.glock(m, SR, vel=0.85, dur=1.4, octave_up=True, t60_scale=0.62).copy()
    return _finish(y, COLORS["yellow"][1], wet=0.12)


def green(m):
    y = ins.epiano(m, 0.6, SR, vel=0.75, bright=0.9, release=0.4, t60_scale=0.3).copy()
    y = dsp.lowpass(y, 7000, SR, 2)
    return _finish(y, COLORS["green"][1], wet=0.10)


def blue(m):
    mm = m - 24
    f = midi_hz(mm)
    dur = COLORS["blue"][1]
    n = nsamp(dur + 0.1, SR)
    t = np.arange(n) / SR
    src = 0.55 * dsp.saw(f * 0.999, n, SR) + 0.45 * dsp.pulse(f * 1.001, n, SR, 0.35)
    fc = np.minimum(250.0 + f * (2.0 + 11.0 * np.exp(-t / 0.08)), 5000.0)
    y = dsp.sweep_filter(src, fc, SR, q=1.1)
    y += 0.55 * np.sin(TAU * f * t)  # round sub
    env = dsp.env_perc(n, SR, t60=1.0, attack=0.002)
    y = dsp.tube(y * env * 1.1, 1.8, SR, bias=0.1)  # harmonics for phone speakers
    y = dsp.filt(y, "peak", 700, SR, q=0.8, gain_db=3.0)
    y = dsp.highpass(y, 32, SR, 2)
    return _finish(y, dur, wet=0.0)


def purple(m):
    f = midi_hz(m)
    dur = COLORS["purple"][1]
    n = nsamp(dur + 0.2, SR)
    t = np.arange(n) / SR
    vib = 1 + (2 ** (10 / 1200) - 1) * np.sin(TAU * 5.2 * t) * np.clip((t - 0.15) / 0.3, 0, 1)
    c = 2 ** (5 / 1200) - 1  # ensemble: two voices drifting +-5 cents around the centre (mean pitch exact)
    src = (dsp.saw(f * vib, n, SR, 0.5)
           + 0.7 * dsp.saw(f * vib * (1 + c * np.sin(TAU * 0.9 * t)), n, SR, 0.1)
           + 0.7 * dsp.saw(f * vib * (1 + c * np.sin(TAU * 1.3 * t + 2.1)), n, SR, 0.8))
    src = src + 0.15 * ins.breath(n, SR, f"purple{m}", 800, 5000)
    voc = dsp.formant(src, SR, dsp.VOWELS["a_alto"])
    dry = dsp.lowpass(src, 1800, SR, 2)
    y = 0.8 * voc / dsp.peak(voc) + 0.25 * dry / dsp.peak(dry)
    env = dsp.env_adsr(n, SR, 0.02, 0.3, 0.4, 0.42, 0.55)
    return _finish(y * env, dur, wet=0.16)


VOICES = {"red": red, "orange": orange, "yellow": yellow, "green": green, "blue": blue, "purple": purple}


def render_all():
    """Yield (color, n, midi, sounding_midi, signal)."""
    for color, fn in VOICES.items():
        for i, m in enumerate(SCALE, start=1):
            yield color, i, m, m + COLORS[color][2], fn(m)
