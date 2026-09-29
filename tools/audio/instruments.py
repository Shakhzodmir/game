"""Instrument voices for GLOW's generated audio.

Every function returns a mono float64 array that starts at the note onset and
contains the full release tail. `sr` is always explicit so the same voices are
used for the 44.1 kHz notes/SFX and the 22.05 kHz music stems.
Expensive voices are memoised (the returned arrays are shared: never modify
them in place, scale on the way out instead).
"""
from functools import lru_cache

import numpy as np

import dsp
from dsp import TAU, LN1000, midi_hz, nsamp


def _ro(x):
    x.setflags(write=False)
    return x


# ------------------------------------------------------------ keyboards

@lru_cache(maxsize=None)
def epiano(midi, dur, sr, vel=0.8, bright=1.0, release=0.35, t60_scale=1.0):
    """FM electric piano (DX-style tine): body pair 1:1 plus a 1:14 tine
    'ping', gentle asymmetric saturation for the pickup 'bark'."""
    f = midi_hz(midi)
    n = nsamp(dur + release, sr)
    t = np.arange(n) / sr
    t60 = float(np.clip(5.0 * (261.6 / f) ** 0.55, 1.4, 7.0)) * t60_scale
    idx = bright * (0.4 + 0.8 * vel) * (1.5 * np.exp(-t / 0.28) + 0.3)
    body = np.sin(TAU * f * t + idx * np.sin(TAU * f * t))
    tine = np.zeros(n)
    if 15.0 * f < 0.45 * sr:
        ti = (0.6 + 1.0 * vel) * bright * np.exp(-t / 0.018)
        tine = np.sin(TAU * f * t + ti * np.sin(TAU * 14.0 * f * t)) * np.exp(-t / 0.35)
    x = body + 0.35 * tine
    env = dsp.env_adsr(n, sr, 0.0015, t60 * 0.43, 0.0, dur, release)
    x = dsp.tube(x * env * 0.8, 1.4, sr, bias=0.2)
    return _ro(dsp.fade(x, sr, 0.0015, 0.01))


@lru_cache(maxsize=None)
def piano(midi, dur, sr, vel=0.7, bright=0.6, release=0.18, key=0):
    """Additive acoustic piano: stiff-string partials, two-stage decay, two
    slightly detuned strings per partial, hammer-position comb, felt thump."""
    f = midi_hz(midi)
    n = nsamp(dur + release + 0.05, sr)
    t = np.arange(n) / sr
    B = 0.00012 * (f / 261.6) ** 0.9
    t60 = float(np.clip(10.0 * (261.6 / f) ** 0.65, 1.6, 16.0))
    r = dsp.rng("piano", midi, key)
    x = np.zeros(n)
    tilt = 0.55 - 0.35 * vel * bright
    for k in range(1, 48):
        fk = k * f * np.sqrt(1.0 + B * k * k)
        if fk > min(0.45 * sr, 9000.0):
            break
        amp = k ** -1.0 * np.exp(-(k - 1) * tilt) * (0.25 + abs(np.sin(np.pi * k * 0.118)))
        if amp < 2e-4:
            break
        tk = t60 / (1.0 + 0.11 * (k - 1) + 0.0004 * (k - 1) ** 2 * f / 100.0)
        dec = 0.62 * np.exp(-LN1000 * t / (tk * 0.22)) + 0.38 * np.exp(-LN1000 * t / tk)
        det = 1.0 + (0.00025 + 0.0002 * r.uniform()) * (1 + 0.05 * k)
        ph1, ph2 = r.uniform(0, TAU, 2)
        x += amp * dec * (np.sin(TAU * fk * t + ph1) + 0.8 * np.sin(TAU * fk * det * t + ph2))
    thump = dsp.lowpass(r.standard_normal(n), 900.0 + 2000.0 * vel, sr, 2) * np.exp(-t / 0.006)
    x = x / 1.8 + 0.05 * vel * thump
    damp = np.exp(-LN1000 * np.maximum(t - dur, 0.0) / max(release, 0.02))
    x *= damp * (0.35 + 0.65 * vel)
    return _ro(dsp.fade(x, sr, 0.001, 0.01))


@lru_cache(maxsize=None)
def organ(midi, dur, sr, bars=(8, 8, 6, 0, 0, 0, 0, 0, 0), perc=0.0, click=0.25,
          attack=0.006, release=0.04):
    """Tonewheel organ. bars = drawbars 16' 5⅓' 8' 4' 2⅔' 2' 1⅗' 1⅓' 1'."""
    ratios = (0.5, 1.5, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0)
    f = midi_hz(midi)
    n = nsamp(dur + release * 3, sr)
    t = np.arange(n) / sr
    r = dsp.rng("organ", midi)
    x = np.zeros(n)
    for ratio, b in zip(ratios, bars):
        if b and ratio * f < 0.45 * sr:
            x += 10 ** ((b - 8) * 3 / 20) * np.sin(TAU * ratio * f * t + r.uniform(0, TAU))
    if perc and 3 * f < 0.45 * sr:
        x += perc * np.sin(TAU * 3 * f * t) * np.exp(-LN1000 * t / 0.45)
    x /= max(1.0, sum(1 for b in bars if b)) ** 0.7
    env = dsp.env_adsr(n, sr, attack, 0.05, 1.0, dur, release)
    x *= env
    if click:
        c = dsp.bandpass(r.standard_normal(nsamp(0.012, sr)), 800, 6000, sr) * np.exp(
            -np.arange(nsamp(0.012, sr)) / (0.003 * sr))
        x[: len(c)] += click * 0.4 * c
    return _ro(dsp.fade(x, sr, 0.001, 0.01))


# ----------------------------------------------------------- mallets/bells

@lru_cache(maxsize=None)
def marimba(midi, sr, vel=0.8, dur=1.0, pan_sheen=0.18):
    """Marimba bar (1 : 3.93 : 9.2 modes) with a soft steel-pan octave bloom."""
    f = midi_hz(midi)
    n = nsamp(dur, sr)
    t = np.arange(n) / sr
    t60 = float(np.clip(1.25 * (261.6 / f) ** 0.5, 0.45, 1.6))
    x = dsp.additive(f, [(1.0, 1.0, t60), (3.93, 0.32 * vel, 0.16), (9.2, 0.08 * vel, 0.05)], n, sr)
    bloom = np.sin(TAU * 2.0 * f * t) * (1 - np.exp(-t / 0.012)) * np.exp(-LN1000 * t / (t60 * 0.7))
    x += pan_sheen * bloom
    r = dsp.rng("marimba", midi)
    m = nsamp(0.006, sr)
    mallet = dsp.lowpass(r.standard_normal(m), 2500 + 2500 * vel, sr) * np.exp(-np.arange(m) / (0.0015 * sr))
    x[:m] += 0.25 * vel * mallet
    return _ro(dsp.fade(x, sr, 0.001, 0.03))


@lru_cache(maxsize=None)
def glock(midi, sr, vel=0.8, dur=1.2, octave_up=True, t60_scale=1.0):
    """Glockenspiel/celesta: free-bar modes 1 : 2.76 : 5.40 : 8.93, soft
    hammer. Sounds an octave above written pitch when octave_up."""
    f = midi_hz(midi + (12 if octave_up else 0))
    n = nsamp(dur, sr)
    t = np.arange(n) / sr
    t60 = float(np.clip(2.4 * (523.0 / f) ** 0.35, 0.9, 3.0)) * t60_scale
    parts = [(1.0, 1.0, t60), (2.0, 0.07, t60 * 0.5), (2.756, 0.22 * vel, 0.35),
             (5.404, 0.08 * vel, 0.14), (8.933, 0.03 * vel, 0.07)]
    x = dsp.additive(f, parts, n, sr)
    r = dsp.rng("glock", midi)
    m = nsamp(0.003, sr)
    x[:m] += 0.12 * vel * dsp.highpass(r.standard_normal(m), 3000, sr) * np.linspace(1, 0, m)
    return _ro(dsp.fade(x, sr, 0.0008, 0.03))


@lru_cache(maxsize=None)
def vibes(midi, sr, vel=0.7, dur=2.0, trem=5.5, release=None):
    """Vibraphone: 1 : 4 : 10 tuned bar, motor tremolo, soft yarn mallet."""
    f = midi_hz(midi)
    n = nsamp(dur, sr)
    t = np.arange(n) / sr
    t60 = float(np.clip(4.0 * (349.0 / f) ** 0.4, 1.8, 6.0))
    x = dsp.additive(f, [(1.0, 1.0, t60), (4.0, 0.22 * vel, t60 * 0.25), (10.0, 0.04 * vel, 0.12)], n, sr)
    x *= 1.0 - 0.28 * (0.5 - 0.5 * np.cos(TAU * trem * t))
    m = nsamp(0.004, sr)
    x[:m] += 0.08 * vel * dsp.lowpass(dsp.rng("vib", midi).standard_normal(m), 3000, sr)
    if release is not None:
        x *= np.exp(-LN1000 * np.maximum(t - release, 0.0) / 0.25)
    return _ro(dsp.fade(x, sr, 0.001, 0.05))


def bell_fm(f, dur, sr, ratio=3.5, index=2.0, t60=1.6):
    """Simple FM bell (used for SFX sparkles and chimes)."""
    n = nsamp(dur, sr)
    t = np.arange(n) / sr
    idx = index * np.exp(-t / (t60 * 0.25))
    x = np.sin(TAU * f * t + idx * np.sin(TAU * f * ratio * t)) * dsp.env_perc(n, sr, t60, 0.001)
    return dsp.fade(x, sr, 0.001, 0.02)


# ---------------------------------------------------------------- strings

@lru_cache(maxsize=None)
def guitar(midi, dur, sr, bright=0.55, t60=2.2, pick=0.14, mute=0.06, key=0, damp=0.5, attack=0.0005):
    """Clean plucked string (tuned Karplus-Strong), damped at note-off.
    A longer `attack` (seconds) gives a softer, thumb-like pluck."""
    f = midi_hz(midi)
    n_rel = mute
    y = dsp.ks_pluck(f, dur + n_rel + 0.02, sr, t60=t60, bright=bright, pick=pick,
                     key=f"g{midi}/{key}", damp=damp)
    t = np.arange(len(y)) / sr
    y = y * np.exp(-LN1000 * np.maximum(t - dur, 0.0) / max(mute, 0.01))
    return _ro(dsp.fade(y, sr, attack, 0.008))


def strum(midis, dur, sr, spread=0.012, up=False, vel=1.0, **kw):
    """Sum of guitar strings with a strum delay (down = low to high)."""
    order = list(midis)[::-1] if up else list(midis)
    parts = []
    for i, m in enumerate(order):
        s = guitar(m, dur, sr, **kw)
        parts.append(np.concatenate([np.zeros(nsamp(i * spread, sr)), s]))
    return dsp.mix(*parts) * vel


def ks_bass(midi, dur, sr, bright=0.3, t60=1.8, pick=0.2, mute=0.05, key=0, damp=0.5):
    return guitar(midi, dur, sr, bright=bright, t60=t60, pick=pick, mute=mute, key=key, damp=damp)


def amp_sim(x, sr, gain=6.0, tone=3800.0, key_hz=1400.0):
    """Guitar amp: pre-emphasis, asymmetric drive, 4x12-ish cabinet."""
    y = dsp.highpass(x, 90.0, sr, 2)
    y = dsp.filt(y, "peak", 900.0, sr, q=0.7, gain_db=6.0)
    y = dsp.tube(y * gain, 1.0, sr, bias=0.1)
    y = dsp.lowpass(y, tone, sr, 4)
    y = dsp.filt(y, "peak", key_hz, sr, q=1.0, gain_db=3.0)
    y = dsp.filt(y, "peak", 120.0, sr, q=0.8, gain_db=2.0)
    return y


# ------------------------------------------------------------ mono lines

def mono_line(notes, n, sr, osc="saw", glide=0.035, legato_gap=0.03, attack=0.02,
              release=0.08, vib_rate=5.2, vib_depth=0.15, vib_delay=0.18, scoop=0.0,
              key="line", pw=0.5, detune=0.0):
    """Render a monophonic phrase with continuous phase.

    notes: iterable of (t_sec, dur_sec, midi, vel[, opts]) where opts may hold
    'bend' (semitones approached from below), 'bend_t', 'scoop', 'vib'.
    Returns (signal, amp_env, onset_env).
    """
    notes = sorted(notes, key=lambda z: z[0])
    t = np.arange(n) / sr
    m = np.full(n, float(notes[0][2]))
    gate = np.zeros(n)
    onset = np.zeros(n)
    offs = np.zeros(n)
    vibd = np.zeros(n)
    prev_end = -1.0
    for i, nt in enumerate(notes):
        t0, d, mid, vel = nt[:4]
        o = nt[4] if len(nt) > 4 else {}
        i0 = nsamp(t0, sr) if t0 > 0 else 0
        i1 = min(n, nsamp(t0 + d, sr))
        if i0 >= n:
            continue
        # pitch target: switch during the silence for detached notes
        sw = i0 if (t0 - prev_end) < legato_gap else min(i0, nsamp(prev_end + 0.01, sr))
        m[max(sw, 0):] = mid
        gate[i0:i1] = vel
        if (t0 - prev_end) < legato_gap and i > 0:
            gate[max(0, nsamp(prev_end, sr)):i0] = vel
        ln = n - i0
        tt = t[:ln]
        onset[i0:] = np.maximum(onset[i0:], vel * np.exp(-tt / 0.12))
        sc = o.get("scoop", scoop)
        bend = o.get("bend", 0.0)
        if sc:
            offs[i0:] -= sc * np.exp(-tt / 0.045)
        if bend:
            bt = o.get("bend_t", 0.09)
            offs[i0:i1] -= bend * (1.0 - np.clip(tt[: i1 - i0] / bt, 0, 1) ** 2 * (3 - 2 * np.clip(tt[: i1 - i0] / bt, 0, 1)))
        vd = o.get("vib", vib_depth)
        if vd and d > vib_delay + 0.05:
            ramp = np.clip((tt[: i1 - i0] - vib_delay) / 0.25, 0, 1)
            vibd[i0:i1] = np.maximum(vibd[i0:i1], vd * ramp)
        prev_end = t0 + d
    if glide > 0:
        k = 1.0 - np.exp(-1.0 / (glide * sr))
        from scipy.signal import lfilter
        m = lfilter([k], [1.0, k - 1.0], m, zi=[m[0] * (1 - k)])[0]
    from scipy.signal import lfilter
    ka = 1.0 - np.exp(-1.0 / (max(attack, 1e-4) * sr))
    kr = 1.0 - np.exp(-1.0 / (max(release, 1e-4) * sr))
    env = np.maximum(lfilter([ka], [1, ka - 1], gate), lfilter([kr], [1, kr - 1], gate))
    lfo = np.sin(TAU * vib_rate * t + dsp.rng("vib", key).uniform(0, TAU))
    freq = midi_hz(m + offs + vibd * lfo)
    if osc == "saw":
        src = dsp.saw(freq, n, sr)
        if detune:
            src = 0.5 * (src + dsp.saw(freq * 2 ** (detune / 1200), n, sr, 0.37))
    elif osc == "pulse":
        src = dsp.pulse(freq, n, sr, pw)
    elif osc == "sine":
        src = dsp.sine(freq, n, sr)
    elif osc == "tri":
        src = dsp.triangle(freq, n, sr)
    else:
        raise ValueError(osc)
    return src, env, onset


def line_to_notes(song_t, events, swing_fn=None):
    """Helper: (beat, beats, midi[, vel, opts]) -> (sec, sec, midi, vel, opts)."""
    out = []
    for e in events:
        b, d, m = e[:3]
        v = e[3] if len(e) > 3 else 0.8
        o = e[4] if len(e) > 4 else {}
        bb = swing_fn(b) if swing_fn else b
        out.append((song_t(bb), song_t(d) * 0.98, m, v, o))
    return out


# ------------------------------------------------------------ synth voices

@lru_cache(maxsize=None)
def supersaw(midi, dur, sr, voices=7, spread=18.0, attack=0.02, release=0.25, key=0):
    f = midi_hz(midi)
    n = nsamp(dur + release * 2, sr)
    r = dsp.rng("ssaw", midi, key)
    x = np.zeros(n)
    for i in range(voices):
        c = (i - (voices - 1) / 2) / ((voices - 1) / 2) * spread
        x += dsp.saw(f * 2 ** (c / 1200), n, sr, r.uniform()) * (1.0 if i == voices // 2 else 0.75)
    x /= voices ** 0.6
    env = dsp.env_adsr(n, sr, attack, 0.3, 0.85, dur, release)
    return _ro(dsp.fade(x * env, sr, 0.001, 0.01))


@lru_cache(maxsize=None)
def pluck_synth(midi, sr, dur=0.3, cutoff=3500.0, decay=0.12, q=1.2, key=0):
    """Bright synth pluck (saw + square, fast filter envelope)."""
    f = midi_hz(midi)
    n = nsamp(dur, sr)
    t = np.arange(n) / sr
    src = 0.6 * dsp.saw(f, n, sr) + 0.4 * dsp.pulse(f * 1.003, n, sr, 0.5)
    fc = 300.0 + cutoff * np.exp(-t / decay)
    y = dsp.sweep_filter(src, fc, sr, q=q, kind="lp")
    y *= dsp.env_perc(n, sr, dur * 0.9, 0.001)
    return _ro(dsp.fade(y, sr, 0.001, 0.02))


@lru_cache(maxsize=None)
def brass(midi, dur, sr, vel=0.8, bright=1.0, release=0.09, key=0):
    """Brass section voice: two detuned saws, pitch scoop, 'blat' filter env."""
    f = midi_hz(midi)
    n = nsamp(dur + release * 3, sr)
    t = np.arange(n) / sr
    cents = -35.0 * np.exp(-t / 0.03)
    fr = f * 2 ** (cents / 1200)
    src = dsp.saw(fr * 2 ** (5 / 1200), n, sr, 0.1) + dsp.saw(fr * 2 ** (-5 / 1200), n, sr, 0.6)
    env = dsp.env_adsr(n, sr, 0.012, 0.12, 0.75, dur, release)
    fc = (500.0 + 2600.0 * bright * vel * (0.55 + 0.45 * np.exp(-t / 0.09))) * np.clip(env * 1.3, 0.25, 1.0)
    y = dsp.sweep_filter(src, fc, sr, q=0.9)
    y = dsp.filt(y, "peak", 1300, sr, q=1.2, gain_db=3.0)
    return _ro(dsp.fade(y * env * vel * 0.5, sr, 0.001, 0.01))


def breath(n, sr, key, lo=1200.0, hi=4000.0):
    return dsp.bandpass(dsp.rng("breath", key).standard_normal(n), lo, hi, sr)


# ------------------------------------------------------------------ voices

def vowel_shout(sr, f0=190.0, vowel_a="e_open", vowel_b="i_tenor", dur=0.28, key=0, h=0.05):
    """One 'hey!' voice: aspirated onset, glottal saw with falling pitch,
    formant morph between two vowels."""
    r = dsp.rng("shout", key)
    n = nsamp(dur + 0.08 + h, sr)
    t = np.arange(n) / sr
    tv = np.maximum(t - h, 0)
    f = f0 * (1.08 - 0.18 * np.clip(tv / dur, 0, 1)) * (1 + 0.006 * np.sin(TAU * 6 * t + r.uniform(0, 6)))
    src = dsp.saw(f, n, sr) + 0.25 * r.standard_normal(n)
    a = dsp.formant(src, sr, dsp.VOWELS[vowel_a])
    b = dsp.formant(src, sr, dsp.VOWELS[vowel_b])
    w = np.clip((tv - dur * 0.45) / (dur * 0.5), 0, 1)
    voiced = (1 - w) * a + w * b
    env_v = dsp.env_adsr(n, sr, 0.018, 0.15, 0.7, h + dur, 0.06) * (t >= h * 0.6)
    asp = dsp.bandpass(r.standard_normal(n), 900, 5000, sr) * np.exp(-((t - h * 0.6) / (h * 0.6)) ** 2)
    y = voiced * env_v + 0.35 * asp * np.max(np.abs(voiced)) / 3
    return dsp.fade(y, sr, 0.002, 0.03)


def crowd_hey(sr, key, voices=7, f_lo=120.0, f_hi=260.0, dur=0.26, spread=0.03):
    r = dsp.rng("crowd", key)
    parts = []
    for i in range(voices):
        f0 = r.uniform(f_lo, f_hi)
        v = vowel_shout(sr, f0=f0, dur=dur * r.uniform(0.85, 1.15), key=f"{key}/{i}")
        parts.append(np.concatenate([np.zeros(nsamp(r.uniform(0, spread), sr)), v * r.uniform(0.7, 1.0)]))
    y = dsp.mix(*parts)
    return y / dsp.peak(y)


def whistle(sr, f=2350.0, dur=0.3, trill=36.0, key=0):
    """Pea whistle: sine with the pea's fast FM/AM trill and a little breath."""
    r = dsp.rng("whistle", key)
    n = nsamp(dur + 0.03, sr)
    t = np.arange(n) / sr
    tr = np.sin(TAU * trill * t + r.uniform(0, 6))
    x = dsp.sine(f * (1 + 0.025 * tr), n, sr) * (0.75 + 0.25 * tr)
    x += 0.08 * dsp.bandpass(r.standard_normal(n), f * 0.8, min(f * 1.3, 0.45 * sr), sr)
    env = dsp.env_adsr(n, sr, 0.012, 0.05, 0.9, dur, 0.02)
    return dsp.fade(x * env, sr, 0.003, 0.01)


# ------------------------------------------------------------------ drums

def kick(sr, f_hi=130.0, f_lo=48.0, tau=0.035, t60=0.42, click=0.25, drv=1.6, key=0):
    n = nsamp(t60 + 0.05, sr)
    t = np.arange(n) / sr
    f = f_lo + (f_hi - f_lo) * np.exp(-t / tau)
    body = np.sin(TAU * np.cumsum(f) / sr) * dsp.env_perc(n, sr, t60, 0.0008)
    c = dsp.bandpass(dsp.rng("kick", key).standard_normal(n), 1000, 5000, sr) * np.exp(-t / 0.0025)
    y = dsp.drive(body + click * c, drv)
    return dsp.fade(y, sr, 0.0005, 0.02)


def snare(sr, tone=185.0, t_tone=0.14, t_noise=0.24, snappy=0.8, lo=1300.0, hi=7000.0, key=0):
    n = nsamp(max(t_tone, t_noise) + 0.05, sr)
    t = np.arange(n) / sr
    f = tone * (1 + 0.25 * np.exp(-t / 0.01))
    body = (np.sin(TAU * np.cumsum(f) / sr) + 0.45 * np.sin(TAU * np.cumsum(f * 1.62) / sr))
    body *= dsp.env_perc(n, sr, t_tone, 0.0006)
    nz = dsp.bandpass(dsp.rng("snare", key).standard_normal(n), lo, hi, sr)
    nz *= dsp.env_perc(n, sr, t_noise, 0.0008, curve=1.2)
    y = 0.7 * body + snappy * 0.55 * nz
    return dsp.fade(dsp.drive(y, 1.3), sr, 0.0005, 0.02)


def hat(sr, t60=0.06, open_=False, key=0, lo=6500.0, tone=0.35):
    t60 = 0.45 if open_ else t60
    n = nsamp(t60 + 0.02, sr)
    t = np.arange(n) / sr
    r = dsp.rng("hat", key)
    metal = np.zeros(n)
    for fr in (205.3, 304.4, 369.6, 522.7, 540.0, 800.0):
        metal += dsp.pulse(fr * 2.2, n, sr, 0.5, r.uniform())
    x = tone * metal + r.standard_normal(n)
    x = dsp.highpass(x, min(lo, 0.4 * sr), sr, 2)
    x *= dsp.env_perc(n, sr, t60, 0.0005, curve=1.0)
    return dsp.fade(x / 3.0, sr, 0.0003, 0.005)


def clap(sr, key=0, tail=0.12, lo=900.0, hi=3200.0):
    r = dsp.rng("clap", key)
    n = nsamp(0.03 + tail + 0.05, sr)
    t = np.arange(n) / sr
    env = np.zeros(n)
    for k, off in enumerate((0.0, 0.009, 0.017, 0.026)):
        tt = t - off - r.uniform(0, 0.002)
        env += np.where(tt >= 0, np.exp(-np.maximum(tt, 0) / 0.0045), 0.0) * (0.8 if k < 3 else 1.0)
    tt = t - 0.026
    env += np.where(tt >= 0, 0.55 * np.exp(-np.maximum(tt, 0) / (tail / 6.9)), 0.0)
    x = dsp.bandpass(r.standard_normal(n), lo, hi, sr) * env
    return dsp.fade(x, sr, 0.0003, 0.01)


def snap(sr, key=0):
    r = dsp.rng("snap", key)
    n = nsamp(0.08, sr)
    t = np.arange(n) / sr
    x = dsp.bandpass(r.standard_normal(n), 1800, 4200, sr) * np.exp(-t / 0.012)
    x += 0.6 * np.sin(TAU * 2600 * t) * np.exp(-t / 0.004)
    return dsp.fade(x, sr, 0.0002, 0.01)


def _metal(n, sr, key, scale=1.0):
    """Six detuned square waves at the classic inharmonic 808 ratios: a dense,
    non-pitched metallic spectrum (no single ringing partial)."""
    r = dsp.rng("metal", key)
    x = np.zeros(n)
    for fr in (205.3, 304.4, 369.6, 522.7, 540.0, 800.0):
        x += dsp.pulse(fr * scale * r.uniform(0.985, 1.015), n, sr, 0.5, r.uniform())
    return x / 6.0


def ride(sr, key=0, t60=2.0, bell=0.3):
    r = dsp.rng("ride", key)
    n = nsamp(t60, sr)
    t = np.arange(n) / sr
    wash = dsp.bandpass(_metal(n, sr, f"r{key}", 3.4), 4000, min(10000, 0.45 * sr), sr)
    wash *= dsp.env_perc(n, sr, t60, 0.001)
    hiss = dsp.highpass(r.standard_normal(n), min(5000, 0.3 * sr), sr) * dsp.env_perc(n, sr, t60 * 0.5, 0.001)
    ping = dsp.bandpass(r.standard_normal(n), 2500, 6000, sr) * np.exp(-t / 0.015)
    bl = dsp.bandpass(_metal(n, sr, f"rb{key}", 1.3), 700, 2600, sr) * dsp.env_perc(n, sr, 0.45, 0.001)
    x = wash / (dsp.peak(wash) + 1e-9) + 0.5 * hiss / (dsp.peak(hiss) + 1e-9) + 0.45 * ping / (dsp.peak(ping) + 1e-9)
    x += bell * bl / (dsp.peak(bl) + 1e-9)
    return dsp.fade(0.8 * x / dsp.peak(x), sr, 0.0004, 0.05)


def crash(sr, key=0, t60=2.6):
    r = dsp.rng("crash", key)
    n = nsamp(t60, sr)
    t = np.arange(n) / sr
    metal = dsp.highpass(_metal(n, sr, f"c{key}", 2.6), 2200, sr, 2)
    nz = dsp.lowpass(dsp.highpass(r.standard_normal(n), 2500, sr, 2), min(11000, 0.45 * sr), sr, 1)
    x = 0.6 * metal / dsp.peak(metal) + nz / dsp.peak(nz)
    x *= dsp.env_perc(n, sr, t60, 0.002) * (1 + 1.2 * np.exp(-t / 0.06))
    return dsp.fade(0.8 * x / dsp.peak(x), sr, 0.0005, 0.1)


def tom(sr, f0=110.0, t60=0.55, key=0):
    n = nsamp(t60 + 0.05, sr)
    t = np.arange(n) / sr
    f = f0 * (1 + 0.45 * np.exp(-t / 0.035))
    x = np.sin(TAU * np.cumsum(f) / sr) + 0.25 * np.sin(TAU * np.cumsum(f * 1.5) / sr) * np.exp(-t / 0.08)
    x *= dsp.env_perc(n, sr, t60, 0.0008)
    x += 0.3 * dsp.bandpass(dsp.rng("tom", key).standard_normal(n), 400, 4000, sr) * np.exp(-t / 0.012)
    return dsp.fade(dsp.drive(x, 1.4), sr, 0.0005, 0.03)


def shaker(sr, key=0, dur=0.09, accent=1.0):
    r = dsp.rng("shaker", key)
    n = nsamp(dur + 0.02, sr)
    t = np.arange(n) / sr
    env = (1 - np.exp(-t / 0.008)) * np.exp(-t / (dur * 0.35))
    x = dsp.bandpass(r.standard_normal(n), 3800, min(10000, 0.44 * sr), sr) * env * accent
    return dsp.fade(x, sr, 0.001, 0.01)


def tambourine(sr, key=0, dur=0.18, hit=0.0):
    r = dsp.rng("tamb", key)
    n = nsamp(dur + 0.03, sr)
    t = np.arange(n) / sr
    x = np.zeros(n)
    for i in range(14):
        f = r.uniform(5200, min(10200, 0.44 * sr))
        x += np.sin(TAU * f * t + r.uniform(0, 6)) * np.exp(-t / r.uniform(0.03, dur * 0.6))
    x = x / 5.0 + 0.6 * dsp.highpass(r.standard_normal(n), 6000, sr) * np.exp(-t / 0.03)
    x *= (1 - np.exp(-t / 0.002)) * (1 + 0.5 * np.sin(TAU * 34 * t))
    if hit:
        x += hit * np.sin(TAU * 330 * t) * np.exp(-t / 0.03)
    return dsp.fade(x, sr, 0.0005, 0.01)


def cowbell(sr, key=0, f1=587.3, f2=880.0, t60=0.35):
    n = nsamp(t60 + 0.02, sr)
    t = np.arange(n) / sr
    x = dsp.pulse(f1, n, sr, 0.5) + 0.8 * dsp.pulse(f2, n, sr, 0.5)
    x = dsp.bandpass(x, 600, 3500, sr)
    x *= 0.6 * np.exp(-t / 0.02) + 0.4 * dsp.env_perc(n, sr, t60, 0.0005)
    return dsp.fade(x, sr, 0.0005, 0.01)


def brush_tap(sr, key=0, dur=0.12, tone=175.0):
    r = dsp.rng("brtap", key)
    n = nsamp(dur, sr)
    t = np.arange(n) / sr
    x = dsp.bandpass(r.standard_normal(n), 1500, 7000, sr) * (1 - np.exp(-t / 0.003)) * np.exp(-t / 0.035)
    x += 0.2 * np.sin(TAU * tone * t) * np.exp(-t / 0.025)
    return dsp.fade(x, sr, 0.0005, 0.01)


def brush_swish(sr, dur, key=0):
    r = dsp.rng("brswish", key)
    n = nsamp(dur, sr)
    t = np.arange(n) / sr
    x = dsp.bandpass(r.standard_normal(n), 1800, 7000, sr)
    shape = np.sin(np.pi * np.clip(t / dur, 0, 1)) ** 1.5
    return dsp.fade(x * shape * (0.8 + 0.2 * np.sin(TAU * 7 * t)), sr, 0.005, 0.01)


def rim(sr, key=0, f=1750.0):
    n = nsamp(0.06, sr)
    t = np.arange(n) / sr
    x = np.sin(TAU * f * t) * np.exp(-t / 0.012) + 0.5 * np.sin(TAU * f * 2.3 * t) * np.exp(-t / 0.006)
    x += 0.4 * dsp.highpass(dsp.rng("rim", key).standard_normal(n), 2000, sr) * np.exp(-t / 0.002)
    return dsp.fade(x, sr, 0.0003, 0.01)


def woodblock(sr, f=1250.0, key=0, t=0.07):
    n = nsamp(t, sr)
    tt = np.arange(n) / sr
    x = np.sin(TAU * f * tt) * np.exp(-tt / (t / 5)) + 0.35 * np.sin(TAU * f * 2.73 * tt) * np.exp(-tt / (t / 9))
    x += 0.2 * dsp.highpass(dsp.rng("wood", key).standard_normal(n), 2500, sr) * np.exp(-tt / 0.0015)
    return dsp.fade(x, sr, 0.0003, 0.008)
