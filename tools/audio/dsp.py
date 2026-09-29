"""Small numpy/scipy DSP toolkit used by gen_audio.py.

Everything here is deterministic: randomness always comes from rng(*keys),
which seeds numpy's PCG64 with a CRC32 of the keys (stable across runs,
machines and Python hash randomisation).
"""
import io
import struct
import zlib

import numpy as np
import soundfile as sf
from scipy import signal

TAU = 2.0 * np.pi
LN1000 = np.log(1000.0)  # exp(-LN1000 * t / t60) reaches -60 dB at t60


# ----------------------------------------------------------------- basics

def midi_hz(m):
    return 440.0 * 2.0 ** ((np.asarray(m, dtype=float) - 69.0) / 12.0)


def db_amp(d):
    return 10.0 ** (d / 20.0)


def amp_db(a):
    return 20.0 * np.log10(np.maximum(a, 1e-12))


def rng(*keys):
    """Deterministic generator keyed by strings/numbers."""
    seed = zlib.crc32("/".join(str(k) for k in keys).encode("utf-8"))
    return np.random.default_rng(seed)


def nsamp(sec, sr):
    return max(1, int(round(sec * sr)))


def peak(x):
    return float(np.max(np.abs(x))) if len(x) else 0.0


def normalize(x, peak_db):
    p = peak(x)
    return x * (db_amp(peak_db) / p) if p > 0 else x


def pad_to(x, n):
    if len(x) >= n:
        return x[:n]
    return np.concatenate([x, np.zeros(n - len(x))])


def mix(*parts):
    """Sum signals of different lengths (all start at sample 0)."""
    n = max(len(p) for p in parts)
    out = np.zeros(n)
    for p in parts:
        out[: len(p)] += p
    return out


def place(buf, sig, pos, gain=1.0):
    """Add sig into buf at sample pos (clipped at the buffer end)."""
    if pos >= len(buf) or pos + len(sig) <= 0:
        return buf
    a = max(0, pos)
    b = min(len(buf), pos + len(sig))
    buf[a:b] += gain * sig[a - pos: b - pos]
    return buf


# -------------------------------------------------------------- envelopes

def fade(x, sr, fade_in=0.002, fade_out=0.02):
    """Raised-cosine fade in/out (declicking)."""
    y = np.array(x, dtype=float)
    ni = min(len(y), nsamp(fade_in, sr))
    no = min(len(y), nsamp(fade_out, sr))
    if ni > 1:
        y[:ni] *= 0.5 - 0.5 * np.cos(np.pi * np.arange(ni) / ni)
    if no > 1:
        y[-no:] *= 0.5 + 0.5 * np.cos(np.pi * (np.arange(no) + 1) / no)
    return y


def env_perc(n, sr, t60, attack=0.002, hold=0.0, curve=1.0):
    """Attack (raised cosine) then exponential decay reaching -60 dB at t60."""
    t = np.arange(n) / sr
    e = np.exp(-LN1000 * np.maximum(t - attack - hold, 0.0) / t60)
    if curve != 1.0:
        e = e ** curve
    na = min(n, nsamp(attack, sr))
    if na > 1:
        e[:na] *= 0.5 - 0.5 * np.cos(np.pi * np.arange(na) / na)
    return e


def env_adsr(n, sr, a, d, s, gate, r):
    """ADSR: cosine attack, exponential decay towards s, exponential release
    (-60 dB after r seconds) starting at `gate` seconds."""
    t = np.arange(n) / sr
    a = max(a, 1e-4)
    d = max(d, 1e-4)

    def level(tt):
        tt = np.asarray(tt, dtype=float)
        att = 0.5 - 0.5 * np.cos(np.pi * np.clip(tt / a, 0.0, 1.0))
        dec = s + (1.0 - s) * np.exp(-3.0 * np.maximum(tt - a, 0.0) / d)
        return np.where(tt < a, att, dec)

    e = level(t)
    rel = t >= gate
    if np.any(rel):
        e[rel] = float(level(gate)) * np.exp(-LN1000 * (t[rel] - gate) / max(r, 1e-3))
    return e


def smooth_steps(values, times, n, sr, glide):
    """Piecewise-constant control signal with exponential glides (for pitch)."""
    out = np.full(n, float(values[0]))
    for v, t0 in zip(values[1:], times[1:]):
        i = nsamp(t0, sr)
        if i < n:
            out[i:] = v
    if glide > 0:
        k = 1.0 - np.exp(-1.0 / (glide * sr))
        out = signal.lfilter([k], [1.0, k - 1.0], out, zi=[out[0] * (1 - k)])[0]
    return out


# ------------------------------------------------------------ oscillators

def _phase(freq, n, sr, phase0=0.0):
    f = np.broadcast_to(np.asarray(freq, dtype=float), (n,))
    dt = f / sr
    ph = (phase0 + np.cumsum(dt) - dt[0]) % 1.0
    return ph, dt


def _blep(t, dt):
    y = np.zeros_like(t)
    m = t < dt
    x = t[m] / dt[m]
    y[m] = x + x - x * x - 1.0
    m = t > 1.0 - dt
    x = (t[m] - 1.0) / dt[m]
    y[m] = x * x + x + x + 1.0
    return y


def sine(freq, n, sr, phase0=0.0):
    ph, _ = _phase(freq, n, sr, phase0)
    return np.sin(TAU * ph)


def saw(freq, n, sr, phase0=0.0):
    """Band-limited (polyBLEP) sawtooth, freq may be an array."""
    ph, dt = _phase(freq, n, sr, phase0)
    return 2.0 * ph - 1.0 - _blep(ph, dt)


def pulse(freq, n, sr, width=0.5, phase0=0.0):
    ph, dt = _phase(freq, n, sr, phase0)
    ph2 = (ph + width) % 1.0
    return (2.0 * ph - _blep(ph, dt)) - (2.0 * ph2 - _blep(ph2, dt))


def triangle(freq, n, sr, phase0=0.0):
    ph, _ = _phase(freq, n, sr, phase0)
    return 1.0 - 4.0 * np.abs(ph - 0.5)


def additive(f0, partials, n, sr, rand=None):
    """partials: list of (ratio, amp, t60). Partials above Nyquist are skipped."""
    t = np.arange(n) / sr
    out = np.zeros(n)
    for i, (ratio, amp, t60) in enumerate(partials):
        f = f0 * ratio
        if f >= 0.47 * sr or amp == 0:
            continue
        ph = rand.uniform(0, TAU) if rand is not None else 0.0
        out += amp * np.sin(TAU * f * t + ph) * np.exp(-LN1000 * t / t60)
    return out


def noise(n, key):
    return rng("noise", key).standard_normal(n)


# ---------------------------------------------------------------- filters

def biquad(kind, f0, sr, q=0.7071, gain_db=0.0):
    """RBJ cookbook biquad coefficients (b, a)."""
    f0 = float(np.clip(f0, 10.0, 0.49 * sr))
    w = TAU * f0 / sr
    cw, sw = np.cos(w), np.sin(w)
    alpha = sw / (2.0 * q)
    A = 10.0 ** (gain_db / 40.0)
    if kind == "lp":
        b = [(1 - cw) / 2, 1 - cw, (1 - cw) / 2]
        a = [1 + alpha, -2 * cw, 1 - alpha]
    elif kind == "hp":
        b = [(1 + cw) / 2, -(1 + cw), (1 + cw) / 2]
        a = [1 + alpha, -2 * cw, 1 - alpha]
    elif kind == "bp":  # constant 0 dB peak gain
        b = [alpha, 0.0, -alpha]
        a = [1 + alpha, -2 * cw, 1 - alpha]
    elif kind == "peak":
        b = [1 + alpha * A, -2 * cw, 1 - alpha * A]
        a = [1 + alpha / A, -2 * cw, 1 - alpha / A]
    elif kind in ("lowshelf", "highshelf"):
        sq = 2.0 * np.sqrt(A) * alpha
        if kind == "lowshelf":
            b = [A * ((A + 1) - (A - 1) * cw + sq), 2 * A * ((A - 1) - (A + 1) * cw),
                 A * ((A + 1) - (A - 1) * cw - sq)]
            a = [(A + 1) + (A - 1) * cw + sq, -2 * ((A - 1) + (A + 1) * cw),
                 (A + 1) + (A - 1) * cw - sq]
        else:
            b = [A * ((A + 1) + (A - 1) * cw + sq), -2 * A * ((A - 1) + (A + 1) * cw),
                 A * ((A + 1) + (A - 1) * cw - sq)]
            a = [(A + 1) - (A - 1) * cw + sq, 2 * ((A - 1) - (A + 1) * cw),
                 (A + 1) - (A - 1) * cw - sq]
    else:
        raise ValueError(kind)
    b = np.array(b) / a[0]
    a = np.array(a) / a[0]
    return b, a


def filt(x, kind, f0, sr, q=0.7071, gain_db=0.0):
    b, a = biquad(kind, f0, sr, q, gain_db)
    return signal.lfilter(b, a, x)


def lowpass(x, fc, sr, order=2):
    fc = min(fc, 0.45 * sr)
    return signal.sosfilt(signal.butter(order, fc, "lowpass", fs=sr, output="sos"), x)


def highpass(x, fc, sr, order=2):
    return signal.sosfilt(signal.butter(order, fc, "highpass", fs=sr, output="sos"), x)


def bandpass(x, lo, hi, sr, order=2):
    hi = min(hi, 0.45 * sr)
    return signal.sosfilt(signal.butter(order, [lo, hi], "bandpass", fs=sr, output="sos"), x)


def onepole_lp(x, fc, sr):
    k = 1.0 - np.exp(-TAU * fc / sr)
    return signal.lfilter([k], [1.0, k - 1.0], x)


def sweep_filter(x, fc, sr, q=0.7071, kind="lp", block=32):
    """Time-varying biquad: coefficients updated every `block` samples."""
    n = len(x)
    fc = np.broadcast_to(np.asarray(fc, dtype=float), (n,))
    y = np.empty(n)
    zi = np.zeros(2)
    for i in range(0, n, block):
        j = min(n, i + block)
        b, a = biquad(kind, fc[(i + j) // 2], sr, q)
        y[i:j], zi = signal.lfilter(b, a, x[i:j], zi=zi)
    return y


def formant(x, sr, table, gain=1.0):
    """Parallel resonators. table: list of (freq, bandwidth, amp_db)."""
    out = np.zeros(len(x))
    for f, bw, adb in table:
        if f < 0.45 * sr:
            out += db_amp(adb) * filt(x, "bp", f, sr, q=f / bw)
    return gain * out


VOWELS = {
    # (freq Hz, bandwidth Hz, level dB) — classic Csound/Peterson-Barney style tables
    "a_alto": [(800, 80, 0), (1150, 90, -4), (2800, 120, -20), (3500, 130, -36)],
    "a_sop": [(800, 80, 0), (1150, 90, -6), (2900, 120, -32), (3900, 130, -20)],
    "a_tenor": [(650, 80, 0), (1080, 90, -6), (2650, 120, -7), (2900, 130, -8)],
    "o_alto": [(450, 70, 0), (800, 80, -9), (2830, 100, -16), (3500, 130, -28)],
    "u_alto": [(325, 50, 0), (700, 60, -12), (2530, 170, -30), (3500, 180, -40)],
    "e_tenor": [(420, 70, 0), (1750, 80, -12), (2600, 100, -12), (3200, 120, -16)],
    "i_tenor": [(290, 60, 0), (1950, 90, -18), (2700, 100, -14), (3300, 120, -20)],
    "e_open": [(550, 80, 0), (1800, 90, -8), (2500, 110, -10), (3300, 130, -16)],
}


# ------------------------------------------------------------- nonlinear

def drive(x, amount):
    """Soft saturation normalised so that |x|=1 maps to 1."""
    return np.tanh(amount * x) / np.tanh(amount)


def tube(x, amount, sr, bias=0.15):
    """Asymmetric saturation (adds even harmonics), DC removed afterwards."""
    y = np.tanh(amount * (x + bias)) - np.tanh(amount * bias)
    return highpass(y, 15.0, sr, 1) / np.tanh(amount)


def tp_envelope(x, oversample=4):
    """Per-sample true-peak envelope: the largest |x| of the band-limited
    (4x oversampled) signal between sample n-1 and n+1."""
    x = np.asarray(x, dtype=float)
    os_ = np.abs(signal.resample_poly(x, oversample, 1))[: len(x) * oversample]
    env = os_.reshape(-1, oversample).max(axis=1)
    env = np.maximum(env, np.abs(x))
    return np.maximum(env, np.concatenate([env[1:], env[-1:]]))


def true_peak(x):
    return float(np.max(tp_envelope(x))) if len(x) else 0.0


def limiter(x, sr, ceiling_db, lookahead=0.0025, release=0.08):
    """Look-ahead brick-wall limiter on the true peak.

    Required gain g_req = min(1, ceiling / true-peak envelope). The gain
    follows the minimum of g_req over the next `lookahead` seconds, recovers
    exponentially (`release` = time constant) and is smoothed by a moving
    average as long as the look-ahead, so it never exceeds g_req where the
    peak is and changes smoothly (no clicks, little distortion).
    Returns (limited signal, gain curve)."""
    x = np.asarray(x, dtype=float)
    c = db_amp(ceiling_db)
    greq = np.minimum(1.0, c / np.maximum(tp_envelope(x), 1e-12))
    L = max(1, nsamp(lookahead, sr))
    padded = np.concatenate([greq, np.ones(L)])
    ga = np.lib.stride_tricks.sliding_window_view(padded, L + 1).min(axis=1)[: len(x)]
    # exponential recovery of the attenuation a = 1 - g, as a running max of
    # a[n] * exp(n / tau) (log domain, so it vectorises)
    lam = -1.0 / max(release * sr, 1.0)
    a = np.maximum(1.0 - ga, 1e-30)
    idx = np.arange(len(x))
    ar = np.exp(np.maximum.accumulate(np.log(a) - idx * lam) + idx * lam)
    gr = 1.0 - np.minimum(ar, 1.0)
    k = np.ones(L + 1) / (L + 1)
    g = np.convolve(np.concatenate([np.full(L, gr[0]), gr]), k, "valid")[: len(x)]
    g = np.minimum(g, 1.0)
    return x * g, g


# ------------------------------------------------------------------ space

def reverb_ir(sr, t60=1.4, predelay=0.012, damp_hz=3500.0, key="room", density=1.0):
    """Mono reverb impulse response: exponentially decaying noise with faster
    high-frequency decay and a handful of early reflections. Unit energy."""
    n = nsamp(t60 * 1.05, sr)
    r = rng("ir", key)
    nz = r.standard_normal(n) * (r.uniform(size=n) < density * 0.6 + 0.4)
    t = np.arange(n) / sr
    lo = lowpass(nz, damp_hz, sr, 2)
    hi = nz - lo
    ir = lo * np.exp(-LN1000 * t / t60) + 0.6 * hi * np.exp(-LN1000 * t / (t60 * 0.35))
    na = nsamp(0.012, sr)
    ir[:na] *= np.linspace(0.0, 1.0, na) ** 2
    for k in range(6):  # early reflections
        d = nsamp(0.004 + 0.009 * k + r.uniform(0, 0.004), sr)
        if d < n:
            ir[d] += (0.8 - 0.1 * k) * np.std(ir[: nsamp(0.05, sr)]) * 6 * (1 if k % 2 else -1)
    ir = highpass(ir, 120.0, sr, 2)
    ir = np.concatenate([np.zeros(nsamp(predelay, sr)), ir])
    return ir / np.sqrt(np.sum(ir ** 2))


def convolve(x, ir):
    """Linear convolution; output has the full tail."""
    return signal.fftconvolve(x, ir)


def convolve_loop(x, ir):
    """Circular convolution: steady-state reverb of a periodic signal."""
    n = len(x)
    if len(ir) > n:
        ir = np.pad(ir, (0, (-len(ir)) % n)).reshape(-1, n).sum(axis=0)
    return np.fft.irfft(np.fft.rfft(x) * np.fft.rfft(ir, n), n)


def loop_apply(x, fn):
    """Run a (causal, short-memory) process on a periodic signal so that its
    output is periodic too: process two periods and keep the second."""
    n = len(x)
    return fn(np.concatenate([x, x]))[n:]


def loop_lfo(n, sr, hz, phase=0.0):
    """Sine LFO with an integer number of cycles in n samples (loop-safe)."""
    cycles = max(1, int(round(hz * n / sr)))
    return np.sin(TAU * (cycles * np.arange(n) / n + phase))


def mod_delay(x, delay_s, sr):
    """Read x with a time-varying delay (seconds, array) using linear interp.
    Treats x as periodic (wraps), so it is loop-safe."""
    n = len(x)
    idx = np.arange(n) - np.asarray(delay_s) * sr
    i0 = np.floor(idx).astype(np.int64)
    fr = idx - i0
    return x[i0 % n] * (1.0 - fr) + x[(i0 + 1) % n] * fr


def delay_loop(x, sr, delay_s, feedback=0.35, taps=4, lp_hz=3000.0):
    """Circular feedback-style echo for loops (sum of rolled, darkened copies)."""
    d = nsamp(delay_s, sr)
    out = np.zeros(len(x))
    cur = x
    for k in range(taps):
        cur = loop_apply(np.roll(cur, d), lambda s: lowpass(s, lp_hz, sr, 1)) * feedback
        out += cur
    return out


# ------------------------------------------------------ Karplus–Strong

def _ap_phase_delay(c, w):
    z = np.exp(-1j * w)
    return -np.angle((c + z) / (1 + c * z)) / w


def ks_pluck(f0, dur, sr, t60=1.5, bright=0.5, pick=0.13, key="ks", damp=0.5,
             excite=None):
    """Tuned Karplus-Strong string rendered with one scipy lfilter call.

    Loop: y = x + g * z^-N * L(z) * A(z) * y with the loss filter
    L = (1-damp) + damp z^-1 and a first-order allpass A tuned so that the
    total phase delay at f0 is exactly sr/f0 (accurate pitch).
    """
    n = nsamp(dur, sr)
    P = sr / f0
    w0 = TAU * f0 / sr
    s0, s1 = 1.0 - damp, damp
    Lw = s0 + s1 * np.exp(-1j * w0)
    pdL = -np.angle(Lw) / w0
    N = int(np.floor(P - pdL - 0.5))
    d = P - N - pdL  # required allpass phase delay, in [0.5, 1.5)
    lo, hi = -0.99, 0.99  # phase delay decreases with c
    for _ in range(60):
        mid = 0.5 * (lo + hi)
        if _ap_phase_delay(mid, w0) > d:
            lo = mid
        else:
            hi = mid
    c = 0.5 * (lo + hi)
    g = min(0.99995, 10.0 ** (-3.0 / (t60 * f0)) / abs(Lw))
    a = np.zeros(N + 3)
    a[0], a[1] = 1.0, c
    a[N] -= g * s0 * c
    a[N + 1] -= g * (s0 + s1 * c)
    a[N + 2] -= g * s1
    b = np.array([1.0, c])
    if excite is None:
        m = max(4, int(round(P)))
        e = rng("ks", key).uniform(-1, 1, m)
        e = onepole_lp(e, 200.0 + bright * 9000.0, sr)
        e -= e.mean()
        k = max(1, int(round(pick * P)))
        e = e - np.concatenate([np.zeros(k), e[:-k]])  # pluck position comb
        e *= np.hanning(m + 2)[1:-1] ** 0.25
    else:
        e = excite
    x = np.zeros(n)
    x[: min(n, len(e))] = e[:n]
    y = signal.lfilter(b, a, x)
    return y


# ------------------------------------------------------- measurement

def k_weight(x, sr):
    """Approximate ITU-R BS.1770 K-weighting (RLB highpass + high shelf)."""
    y = filt(x, "hp", 60.0, sr, q=0.5)
    return filt(y, "highshelf", 1600.0, sr, q=0.7071, gain_db=4.0)


def loudness(x, sr, gate_db=-30.0, win=0.1):
    """Gated K-weighted RMS in dB (a lightweight LUFS stand-in). Frames more
    than gate_db below the loudest frame are ignored, so sparse parts are
    measured by what they play, not by their silence."""
    y = k_weight(x, sr)
    w = nsamp(win, sr)
    m = len(y) // w
    if m == 0:
        return amp_db(np.sqrt(np.mean(y ** 2)) + 1e-12)
    fr = np.mean(y[: m * w].reshape(m, w) ** 2, axis=1)
    top = fr.max()
    keep = fr[fr >= top * db_amp(gate_db) ** 2]
    return float(10.0 * np.log10(np.mean(keep) + 1e-24))


def rms_db(x):
    return float(amp_db(np.sqrt(np.mean(np.square(x))) + 1e-12))


# ---------------------------------------------------------- Ogg/Vorbis

_REV = bytes(int(f"{i:08b}"[::-1], 2) for i in range(256))


def _ogg_crc(page):
    # Ogg uses the non-reflected CRC-32 (poly 0x04C11DB7, init 0, no xorout).
    # Computed with zlib's reflected CRC on bit-reversed bytes.
    r = zlib.crc32(page.translate(_REV)) ^ zlib.crc32(bytes(len(page)))
    return int(f"{r & 0xFFFFFFFF:032b}"[::-1], 2)


def _ogg_set_serial(data, serial):
    """libsndfile picks a time-seeded random Ogg stream serial; rewrite it
    (and page CRCs) so identical audio produces byte-identical files."""
    out = bytearray(data)
    pos = 0
    while pos < len(out):
        if out[pos: pos + 4] != b"OggS":
            raise ValueError("not an Ogg page")
        nseg = out[pos + 26]
        plen = 27 + nseg + sum(out[pos + 27: pos + 27 + nseg])
        struct.pack_into("<I", out, pos + 14, serial)
        struct.pack_into("<I", out, pos + 22, 0)
        struct.pack_into("<I", out, pos + 22, _ogg_crc(bytes(out[pos: pos + plen])))
        pos += plen
    return bytes(out)


def encode_vorbis(x, sr, quality, serial_key):
    """Encode mono float audio to Ogg Vorbis bytes (deterministic) and return
    (bytes, decoded float64 array)."""
    x = np.clip(np.asarray(x, dtype=np.float64), -1.0, 1.0).astype(np.float32)
    bio = io.BytesIO()
    sf.write(bio, x, sr, format="OGG", subtype="VORBIS", compression_level=1.0 - quality)
    data = _ogg_set_serial(bio.getvalue(), zlib.crc32(serial_key.encode()) & 0x7FFFFFFF)
    dec, _ = sf.read(io.BytesIO(data), dtype="float64")
    return data, dec
