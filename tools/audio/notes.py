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
    # long, even sustain (the loudness of a 1 s note should not all sit in its first 50 ms)
    t60 = float(np.clip(2.2 * (261.6 / f) ** 0.1, 1.6, 2.4))
    y = dsp.ks_pluck(f, 1.3, SR, t60=t60, bright=0.75, pick=0.11, key=f"red{m}", damp=0.2)
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
    """Pluck bass. A phone speaker plays nothing below ~300 Hz, so besides the
    round fundamental the note carries explicit 2nd-4th harmonics, a filter
    that opens to ~2 kHz on the pluck and a 0.45-1.8 kHz 'bark' band. The
    body sustains (instead of dying in 0.3 s), so its loudness is not all in
    the first peak."""
    mm = m - 24
    f = midi_hz(mm)
    dur = COLORS["blue"][1]
    n = nsamp(dur + 0.1, SR)
    t = np.arange(n) / SR
    src = 0.8 * dsp.saw(f * 0.999, n, SR) + 0.2 * dsp.pulse(f * 1.001, n, SR, 0.35)
    fc = np.minimum(500.0 + f * (6.0 + 20.0 * np.exp(-t / 0.15)), 7000.0)
    y = dsp.sweep_filter(src, fc, SR, q=1.4)
    y += sum(a * np.sin(TAU * k * f * t + 1.1 * k * k) for k, a in ((2, 0.35), (3, 0.3), (4, 0.25)))
    # harmonics 5-12 (up to 2.5 kHz) with spread phases: phone-band energy without a peaky waveform
    y += 0.3 * sum((5.0 / k) * np.sin(TAU * k * f * t + 2.3 * k * k) for k in range(5, 13) if k * f < 2500) \
        * np.exp(-t / 0.5)
    y += 0.25 * np.sin(TAU * f * t)  # round sub
    y = dsp.filt(y, "hp", 0.9 * f, SR, q=0.6)  # the fundamental stays, but no longer dominates the peak
    env = (0.8 + 0.2 * np.exp(-t / 0.12)) * dsp.env_perc(n, SR, t60=5.0, attack=0.003)
    env *= np.exp(-dsp.LN1000 * np.maximum(t - 0.5, 0.0) / 0.45)  # released from 0.5 s: silent by the end
    y = dsp.tube(y * env * 1.1, 2.5, SR, bias=0.1)
    y = y + dsp.bandpass(y, 450, 1800, SR, 2)
    y = dsp.highpass(y, 40, SR, 2)
    return _finish(y, dur, wet=0.0)


def purple(m):
    """Synth pad pluck through an 'ah' formant.

    Pitch safety: the three ensemble saws start at phases 0 / 0.02 / 0.58 of a
    cycle. (The old 0.5 / 0.1 / 0.8 cancelled the fundamental and added up the
    3rd harmonic, which then sat on the 800 Hz first formant for C4/D4: those
    notes were heard an octave and a fifth too high.) On C4-E4 the first
    formant is also widened and 5 dB lower, and a pitch-following 'chest' band
    (1.5 x f0) keeps harmonics 1-2 strong on every note."""
    f = midi_hz(m)
    dur = COLORS["purple"][1]
    n = nsamp(dur + 0.2, SR)
    t = np.arange(n) / SR
    vib = 1 + (2 ** (10 / 1200) - 1) * np.sin(TAU * 5.2 * t) * np.clip((t - 0.15) / 0.3, 0, 1)
    # ensemble: two voices drifting +-5 cents in mirror image around the centre, so the
    # mean pitch is exact at every instant (not just on average over a long note)
    c = (2 ** (5 / 1200) - 1) * np.cos(TAU * 0.9 * t)
    src = (dsp.saw(f * vib, n, SR, 0.0)
           + 0.7 * dsp.saw(f * vib * (1 + c), n, SR, 0.02)
           + 0.7 * dsp.saw(f * vib * (1 - c), n, SR, 0.58))
    src = src + 0.15 * ins.breath(n, SR, f"purple{m}", 800, 5000)
    table = list(dsp.VOWELS["a_alto"])
    low = m <= 64
    if low:
        table[0] = (800, 160, -5)
    voc = dsp.formant(src, SR, table)
    dry = dsp.lowpass(src, 1800, SR, 2)
    chest = dsp.filt(src, "bp", 1.5 * f, SR, q=0.8)
    y = 0.8 * voc / dsp.peak(voc) + 0.25 * dry / dsp.peak(dry) + (0.3 if low else 0.35) * chest / dsp.peak(chest)
    env = dsp.env_adsr(n, SR, 0.02, 0.3, 0.4, 0.42, 0.55)
    return _finish(y * env, dur, wet=0.16)


VOICES = {"red": red, "orange": orange, "yellow": yellow, "green": green, "blue": blue, "purple": purple}


def render_all():
    """Yield (color, n, midi, sounding_midi, signal)."""
    for color, fn in VOICES.items():
        for i, m in enumerate(SCALE, start=1):
            yield color, i, m, m + COLORS[color][2], fn(m)
