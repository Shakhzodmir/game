"""Measurements used by gen_audio.py for levels, checks and the report.

All functions take mono float arrays and are deterministic.

* lufs():       ITU-R BS.1770-4 loudness (K-weighting for any sample rate,
                400 ms blocks with 75 % overlap, absolute -70 LUFS gate and
                relative -10 LU gate). Returns (integrated, M-max) where M-max
                is the loudest 400 ms block (momentary maximum).
* phone():      a rough phone-speaker model: 4th-order Butterworth high-pass
                at 300 Hz (24 dB/octave). "Phone M-max" = lufs(phone(x))[1].
* true_peak():  4x oversampled peak in dBTP (what a resampling mixer can hit).
* yin():        YIN fundamental estimate (de Cheveigne & Kawahara 2002) with
                the usual 0.1 absolute threshold: the pitch a listener (and a
                tuner) most likely hears.
* centroid(), band_db(), key_estimate(): brightness and key reading.
"""
import numpy as np
from scipy import signal

NAMES = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]


def db(a):
    return 20.0 * np.log10(np.maximum(np.abs(a), 1e-12))


# ---------------------------------------------------------------- loudness

def _kw_coeffs(sr):
    """BS.1770 K-weighting (shelf + RLB high-pass) re-derived for any rate."""
    G, Q, fc = 3.999843853973347, 0.7071752369554196, 1681.974450955533
    A = 10 ** (G / 40)
    w0 = 2 * np.pi * fc / sr
    al = np.sin(w0) / (2 * Q)
    c = np.cos(w0)
    b1 = [A * ((A + 1) + (A - 1) * c + 2 * np.sqrt(A) * al), -2 * A * ((A - 1) + (A + 1) * c),
          A * ((A + 1) + (A - 1) * c - 2 * np.sqrt(A) * al)]
    a1 = [(A + 1) - (A - 1) * c + 2 * np.sqrt(A) * al, 2 * ((A - 1) - (A + 1) * c),
          (A + 1) - (A - 1) * c - 2 * np.sqrt(A) * al]
    Q2, fc2 = 0.5003270373238773, 38.13547087602444
    w0 = 2 * np.pi * fc2 / sr
    al = np.sin(w0) / (2 * Q2)
    c = np.cos(w0)
    b2 = [(1 + c) / 2, -(1 + c), (1 + c) / 2]
    a2 = [1 + al, -2 * c, 1 - al]
    return (b1, a1), (b2, a2)


def k_weight(x, sr, circular=False):
    (b1, a1), (b2, a2) = _kw_coeffs(sr)
    if circular:  # a loop: prime the filters with the end of the loop
        m = min(len(x), sr)
        y = signal.lfilter(b2, a2, signal.lfilter(b1, a1, np.concatenate([x[-m:], x])))
        return y[m:]
    return signal.lfilter(b2, a2, signal.lfilter(b1, a1, x))


def lufs(x, sr, circular=False):
    """(integrated LUFS, M-max LUFS). Short files are zero-padded to 400 ms."""
    y = k_weight(np.asarray(x, dtype=float), sr, circular)
    w, h = int(0.4 * sr), int(0.1 * sr)
    if circular:
        n = len(y)
        y = np.concatenate([y, y[:w]])
        starts = range(0, n, h)
    else:
        if len(y) < w:
            y = np.pad(y, (0, w - len(y)))
        starts = range(0, len(y) - w + 1, h)
    c = np.cumsum(np.concatenate([[0.0], y * y]))
    ms = np.array([(c[i + w] - c[i]) / w for i in starts])
    lv = -0.691 + 10 * np.log10(ms + 1e-20)
    g = ms[lv > -70]
    if len(g) == 0:
        return -99.0, -99.0
    rel = -0.691 + 10 * np.log10(g.mean()) - 10
    g2 = ms[(lv > -70) & (lv > rel)]
    return float(-0.691 + 10 * np.log10(g2.mean())), float(lv.max())


_PHONE = {}


def phone(x, sr, circular=False):
    if sr not in _PHONE:
        _PHONE[sr] = signal.butter(4, 300.0, "highpass", fs=sr, output="sos")
    if circular:
        m = min(len(x), sr)
        return signal.sosfilt(_PHONE[sr], np.concatenate([x[-m:], x]))[m:]
    return signal.sosfilt(_PHONE[sr], x)


def mmax(x, sr):
    return lufs(x, sr)[1]


def phone_mmax(x, sr):
    return lufs(phone(x, sr), sr)[1]


def true_peak(x, circular=False):
    """4x oversampled peak (dBTP)."""
    x = np.asarray(x, dtype=float)
    if circular:
        m = min(len(x), 64)
        x = np.concatenate([x[-m:], x, x[:m]])
    return float(db(np.max(np.abs(signal.resample_poly(x, 4, 1)))))


def sample_peak(x):
    return float(db(np.max(np.abs(x))))


# ------------------------------------------------------------------- pitch

def yin(x, sr, fmin=50.0, fmax=2500.0, t0=0.05, t1=0.35, thr=0.1):
    """YIN pitch of the segment t0..t1 s. Returns (f0 Hz, dip value)."""
    a, b = int(t0 * sr), int(min(len(x), t1 * sr))
    seg = np.asarray(x[a:b], dtype=float)
    tmax = int(sr / fmin)
    tmin = max(2, int(sr / fmax))
    W = len(seg) - tmax
    if W < 256:
        return None, None
    # difference function via FFT autocorrelation (cumulative energies)
    n = len(seg)
    nfft = 1 << int(np.ceil(np.log2(n + W)))
    fx = np.fft.rfft(seg, nfft)
    fw = np.fft.rfft(seg[:W], nfft)
    corr = np.fft.irfft(fx * np.conj(fw), nfft)[: tmax + 1]
    cs = np.cumsum(np.concatenate([[0.0], seg * seg]))
    e0 = cs[W] - cs[0]
    et = cs[np.arange(tmax + 1) + W] - cs[np.arange(tmax + 1)]
    d = e0 + et - 2 * corr
    d[0] = 0.0
    cm = np.cumsum(d[1:])
    dn = np.ones_like(d)
    dn[1:] = d[1:] * np.arange(1, tmax + 1) / np.maximum(cm, 1e-20)
    tau = None
    for t in range(tmin, tmax):
        if dn[t] < thr:
            while t + 1 < tmax and dn[t + 1] < dn[t]:
                t += 1
            tau = t
            break
    if tau is None:
        tau = tmin + int(np.argmin(dn[tmin:tmax]))
    if 1 <= tau < tmax:  # parabolic refinement
        y0, y1, y2 = dn[tau - 1], dn[tau], dn[tau + 1]
        den = y0 - 2 * y1 + y2
        tf = tau + (0.5 * (y0 - y2) / den if abs(den) > 1e-12 else 0.0)
    else:
        tf = tau
    return float(sr / tf), float(dn[tau])


def harmonics_db(x, sr, f0, count=6, t0=0.02, t1=0.5):
    """Levels of harmonics 1..count relative to the strongest of them."""
    a, b = int(t0 * sr), int(min(len(x), t1 * sr))
    seg = x[a:b] * np.hanning(b - a)
    nfft = 1 << 19
    m = np.abs(np.fft.rfft(seg, nfft))
    fr = np.fft.rfftfreq(nfft, 1.0 / sr)
    out = []
    for h in range(1, count + 1):
        lo, hi = np.searchsorted(fr, [h * f0 * 2 ** (-30 / 1200), h * f0 * 2 ** (30 / 1200)])
        out.append(m[lo:hi].max() if hi > lo else 0.0)
    out = np.array(out)
    return [round(float(v), 1) for v in db(out / (out.max() + 1e-20))]


# -------------------------------------------------------------- brightness

def centroid(x, sr):
    f, P = signal.welch(x, sr, nperseg=4096)
    return float(np.sum(f * P) / np.sum(P))


def band_db(x, sr, lo, hi, ref=(200.0, 2000.0)):
    """Energy in lo..hi Hz relative to the ref band, dB."""
    f, P = signal.welch(x, sr, nperseg=8192)
    e = P[(f >= lo) & (f < hi)].sum()
    r = P[(f >= ref[0]) & (f < ref[1])].sum()
    return float(10 * np.log10((e + 1e-30) / (r + 1e-30)))


def share_below(x, sr, hz):
    f, P = signal.welch(x, sr, nperseg=8192)
    return float(P[f < hz].sum() / P.sum())


# --------------------------------------------------------------------- key

KMAJ = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
KMIN = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])


def chroma(x, sr, fmin=65.0, fmax=2000.0):
    x = np.asarray(x, dtype=float)
    if len(x) < 4096:
        x = np.pad(x, (0, 4096 - len(x)))
    f, _, Z = signal.stft(x, sr, nperseg=4096, noverlap=2048)
    P = np.abs(Z) ** 2
    band = (f >= fmin) & (f <= fmax)
    pc = (np.round(12 * np.log2(f[band] / 440.0) + 69).astype(int)) % 12
    E = P[band].sum(axis=1)
    c = np.array([E[pc == k].sum() for k in range(12)])
    return c / c.sum()


def key_scores(x, sr, fmin=65.0, fmax=2000.0):
    """Krumhansl-Kessler correlations: {'F maj': r, 'D min': r, ...}."""
    c = chroma(x, sr, fmin, fmax)
    out = {}
    for t in range(12):
        out[f"{NAMES[t]} maj"] = float(np.corrcoef(np.roll(KMAJ, t), c)[0, 1])
        out[f"{NAMES[t]} min"] = float(np.corrcoef(np.roll(KMIN, t), c)[0, 1])
    return out


def in_scale_share(x, sr, tonic=0, fmin=100.0, fmax=4000.0):
    c = chroma(x, sr, fmin, fmax)
    return float(sum(c[(tonic + k) % 12] for k in (0, 2, 4, 5, 7, 9, 11)))


# ---------------------------------------------------------------- resample

def up2_loop(x):
    """Exact band-limited 2x upsampling of a periodic signal (FFT zero-pad)."""
    n = len(x)
    X = np.fft.rfft(x)
    Y = np.zeros(n + 1, dtype=complex)
    Y[: len(X)] = X
    if n % 2 == 0:
        Y[n // 2] *= 0.5
    return np.fft.irfft(Y, 2 * n) * 2.0
