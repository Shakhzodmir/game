#!/usr/bin/env python3
"""GLOW audio generator: piece notes, sound effects and district music.

    python3 tools/audio/gen_audio.py            # everything (about a minute)
    python3 tools/audio/gen_audio.py --only music --jobs 4

Outputs (all Ogg Vorbis, mono):
    assets/sounds/notes/<color>_<n>.ogg   44.1 kHz, n = 1..11 (C major pentatonic C4..C6)
    assets/sounds/sfx/<name>.ogg          44.1 kHz
    assets/music/<district>/<stem>.ogg    22.05 kHz, sample-exact seamless loops
    assets/sounds/manifest.json           every file with duration and peak
    docs/media/audio_report.md            measurements: pitch, loudness, peaks, loop seams, harmony

Deterministic: all randomness is seeded from names (dsp.rng), and the Ogg
stream serial is fixed, so re-running produces byte-identical files.
Module map: dsp.py (DSP + Vorbis I/O), instruments.py (voices), notes.py,
sfx.py, music.py (district arrangements), this file (pipeline + analysis).
Everything here is placeholder audio meant to be replaced by a composer: the
engine only relies on the file paths and on manifest.json.
"""
import argparse
import json
import multiprocessing as mp
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import dsp  # noqa: E402
import music  # noqa: E402
import notes  # noqa: E402
import sfx  # noqa: E402

ROOT = HERE.parents[1]
DIR_NOTES = ROOT / "assets" / "sounds" / "notes"
DIR_SFX = ROOT / "assets" / "sounds" / "sfx"
DIR_MUSIC = ROOT / "assets" / "music"
MANIFEST = ROOT / "assets" / "sounds" / "manifest.json"
REPORT = ROOT / "docs" / "media" / "audio_report.md"
DISTRICTS = ROOT / "content" / "districts.json"

Q_NOTES, Q_SFX, Q_MUSIC = 0.6, 0.5, 0.3  # Vorbis quality (0..1)
NOTE_PEAK_DB = -3.0
SFX_PEAK_CAP_DB = -3.0
MIX_PEAK_DB = -1.0
SIZE_BUDGET = 7 * 1024 * 1024
KEY_NAMES = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]


# ------------------------------------------------------------------ I/O

def rel(p):
    return str(Path(p).relative_to(ROOT)).replace("\\", "/")


def write_bytes(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_bytes() == data:
        return
    path.write_bytes(data)


OFFSETS = [0.0] + [sgn * 0.02 * k for k in range(1, 16) for sgn in (-1, 1)]


def encode(path, x, sr, quality, peak_db=None, cap_db=None):
    """Encode to Vorbis and hit a decoded peak target.

    Lossy coding moves the peak of a transient by up to about +-0.5 dB, and
    not smoothly with the input gain. So: encode once, correct for the measured
    overshoot, then try small gain offsets around that and keep the closest
    result (peak_db: exact target within 0.03 dB; cap_db: ceiling).
    Returns (bytes, decoded signal)."""
    x = np.asarray(x, dtype=float)
    data, dec = dsp.encode_vorbis(x, sr, quality, rel(path))
    p0 = dsp.amp_db(dsp.peak(dec))
    target = peak_db if peak_db is not None else cap_db
    if target is None or (peak_db is None and p0 <= cap_db):
        return data, dec
    best = (abs(p0 - target) if peak_db is not None else np.inf, data, dec)
    base = target - p0 - (0.03 if peak_db is None else 0.0)
    for off in OFFSETS:
        data, dec = dsp.encode_vorbis(x * dsp.db_amp(base + off), sr, quality, rel(path))
        p = dsp.amp_db(dsp.peak(dec))
        if peak_db is not None:
            if abs(p - peak_db) < best[0]:
                best = (abs(p - peak_db), data, dec)
            if best[0] <= 0.03:
                break
        elif p <= cap_db:
            return data, dec
    return best[1], best[2]


def file_entry(path, dec, sr, nbytes, **extra):
    e = {"path": rel(path), "duration": round(len(dec) / sr, 4), "samples": len(dec), "sample_rate": sr,
         "peak_dbfs": round(dsp.amp_db(dsp.peak(dec)), 2), "rms_dbfs": round(dsp.rms_db(dec), 2),
         "bytes": nbytes}
    e.update(extra)
    return e


# ------------------------------------------------------------- analysis

def pitch_of(x, sr, expected_hz):
    """Pitch of the partial nearest expected_hz (within half a semitone):
    power-weighted centroid of the spectral line (+-25 cents around its peak)
    in a zero-padded Hann FFT of 0.02..0.5 s. The centroid equals the peak
    frequency for a single line and the mean pitch for chorused voices.
    Also returns the strongest partial and the line's level relative to it."""
    a, b = int(0.02 * sr), int(min(len(x), 0.5 * sr))
    seg = x[a:b] * np.hanning(b - a)
    nfft = 1 << 20
    mag = np.abs(np.fft.rfft(seg, nfft))
    fr = np.fft.rfftfreq(nfft, 1.0 / sr)
    lo, hi = np.searchsorted(fr, [expected_hz * 2 ** (-0.5 / 12), expected_hz * 2 ** (0.5 / 12)])
    i = lo + int(np.argmax(mag[lo:hi]))
    c0, c1 = np.searchsorted(fr, [fr[i] * 2 ** (-25 / 1200), fr[i] * 2 ** (25 / 1200)])
    pw = mag[c0:c1] ** 2
    f = float(np.sum(fr[c0:c1] * pw) / np.sum(pw))
    band = (fr > 40) & (fr < 8000)
    dom = fr[band][np.argmax(mag[band])]
    rel_db = dsp.amp_db(mag[i] / (mag[band].max() + 1e-12))
    return f, 1200 * np.log2(f / expected_hz), dom, rel_db


def seam_check(y, sr, beat_samples, pre=None):
    """Loop-seam measurements on a stem that is played end -> start forever.
    Drums and notes legitimately start on beat lines, so the seam (the
    downbeat of bar 1) is compared with the other 31 beat lines of the loop:
    a discontinuity added by looping would make it stand out.

    step_vs_beats:  |x[0] - x[end]| / largest |x[i+1] - x[i]| within +-3 ms of
                    any other beat line.
    click_vs_beats: 2nd-difference ("click") energy in a 3 ms window across the
                    seam / largest such value on the other beat lines.
    codec_edge:     RMS Vorbis error (decoded - pre-encoding) in the first and
                    last 10 ms / 99th percentile of that error over the file.
    """
    n = len(y)
    d1 = np.abs(np.roll(y, -1) - y)  # d1[n-1] is the seam step
    e2 = (np.roll(y, -1) - 2.0 * y + np.roll(y, 1)) ** 2
    w = max(3, int(0.003 * sr))
    idx = np.arange(-w, w + 1)
    beats = [int(round(k * beat_samples)) for k in range(1, int(round(n / beat_samples)))]
    step_ref = max(d1[(p + idx) % n].max() for p in beats) + 1e-20
    click_ref = max(e2[(p + idx) % n].mean() for p in beats) + 1e-20
    out = {"step_vs_beats": round(float(d1[n - 1] / step_ref), 3),
           "click_vs_beats": round(float(e2[idx % n].mean() / click_ref), 3)}
    if pre is not None:
        err = y - pre
        m = int(0.01 * sr)
        k = len(err) // m
        win = np.sqrt(np.mean(err[: k * m].reshape(k, m) ** 2, axis=1))
        edge = max(np.sqrt(np.mean(err[:m] ** 2)), np.sqrt(np.mean(err[-m:] ** 2)))
        out["codec_edge"] = round(float(edge / (np.percentile(win, 99) + 1e-12)), 2)
    return out


def harmony_check(x, sr, tonic):
    """Share of tonal energy (the 6 strongest spectral peaks per 186 ms frame,
    80 Hz..2 kHz) that falls on the district's major scale. Drum and noise
    stems are reported but not judged."""
    nfft, hop = 4096, 2048
    scale = {(tonic + k) % 12 for k in (0, 2, 4, 5, 7, 9, 11)}
    fr = np.fft.rfftfreq(nfft, 1.0 / sr)
    band = (fr >= 80) & (fr <= 2000)
    pcs = (np.round(12 * np.log2(fr[band] / 440.0) + 69).astype(int)) % 12
    inside = np.isin(pcs, list(scale))
    tot = ins = 0.0
    win = np.hanning(nfft)
    for i in range(0, len(x) - nfft, hop):
        m = np.abs(np.fft.rfft(x[i: i + nfft] * win))[band]
        if m.max() <= 1e-6:
            continue
        pk = (m > np.roll(m, 1)) & (m >= np.roll(m, -1)) & (m > m.max() * 0.03)
        top = np.argsort(m * pk)[-6:]  # the 6 strongest spectral peaks of the frame
        keep = np.zeros_like(pk)
        keep[top] = pk[top]
        e = (m * keep) ** 2
        tot += e.sum()
        ins += e[inside].sum()
    return round(100.0 * ins / tot, 1) if tot > 0 else None


# ----------------------------------------------------------------- notes

def build_notes():
    rows = []
    for color, n, midi, sounding, x in notes.render_all():
        path = DIR_NOTES / f"{color}_{n}.ogg"
        data, dec = encode(path, x, notes.SR, Q_NOTES, peak_db=NOTE_PEAK_DB)
        write_bytes(path, data)
        f_exp = float(dsp.midi_hz(sounding))
        f, cents, dom, rel_db = pitch_of(dec, notes.SR, f_exp)
        tail = dsp.amp_db(dsp.peak(dec[-int(0.01 * notes.SR):]))
        head = abs(dec[0])
        rows.append(file_entry(path, dec, notes.SR, len(data), color=color, n=n, midi=midi,
                               sounding_midi=sounding, freq_hz=round(f_exp, 2),
                               measured_hz=round(f, 2), cents=round(cents, 2),
                               strongest_partial_hz=round(float(dom), 1),
                               fundamental_rel_db=round(float(rel_db), 1),
                               first_sample=round(float(head), 5), last10ms_peak_dbfs=round(float(tail), 1)))
    return rows


# ------------------------------------------------------------------- sfx

def build_sfx():
    rows = []
    for name, (fn, target, key, desc) in sfx.SFX.items():
        x = np.asarray(fn(), dtype=float)
        x = x - np.mean(x)
        g = dsp.db_amp(target - dsp.loudness(x, sfx.SR, win=0.05))
        g = min(g, dsp.db_amp(SFX_PEAK_CAP_DB) / dsp.peak(x))
        path = DIR_SFX / f"{name}.ogg"
        data, dec = encode(path, x * g, sfx.SR, Q_SFX, cap_db=SFX_PEAK_CAP_DB)
        write_bytes(path, data)
        rows.append(file_entry(path, dec, sfx.SR, len(data), name=name, key=key, description=desc,
                               loudness_db=round(dsp.loudness(dec, sfx.SR, win=0.05), 1),
                               loudness_target_db=target))
    return rows


# ----------------------------------------------------------------- music

def build_district(d):
    t0 = time.time()
    song, raw = music.render_district(d)
    sr = song.sr
    targets = music.LOUDNESS[d["id"]]
    gains = {k: dsp.db_amp(targets[k] - dsp.loudness(x, sr)) for k, x in raw.items()}
    mix = sum(gains[k] * x for k, x in raw.items())
    common = dsp.db_amp(MIX_PEAK_DB) / dsp.peak(mix)
    worst = max(common * gains[k] * dsp.peak(x) for k, x in raw.items())
    if worst > dsp.db_amp(-0.3):  # no single stem may clip
        common *= dsp.db_amp(-0.3) / worst
    def encode_all(c):
        enc = {}
        for k, x in raw.items():
            path = DIR_MUSIC / d["id"] / f"{k}.ogg"
            enc[k] = (path,) + dsp.encode_vorbis(x * gains[k] * c, sr, Q_MUSIC, rel(path))
        dmix = sum(v[2] for v in enc.values())
        return enc, dmix, MIX_PEAK_DB - dsp.amp_db(dsp.peak(dmix))

    enc, dmix, err = encode_all(common)
    best = (abs(err), enc, dmix, common)
    base = common * dsp.db_amp(err)
    for off in OFFSETS[:13]:
        if best[0] <= 0.03:
            break
        c = base * dsp.db_amp(off)
        enc, dmix, err = encode_all(c)
        if abs(err) < best[0]:
            best = (abs(err), enc, dmix, c)
    _, enc, dmix, common = best
    task_of = {t["stem"]: t for t in d["tasks"]}
    stems = []
    for k, (path, data, dec) in enc.items():
        write_bytes(path, data)
        assert len(dec) == song.n, (path, len(dec), song.n)
        pre = raw[k] * gains[k] * common
        stems.append(file_entry(
            path, dec, sr, len(data), stem=k, task=task_of[k]["id"] if k in task_of else None,
            cost=task_of[k]["cost"] if k in task_of else None,
            loudness_db=round(dsp.loudness(dec, sr), 1),
            harmony_in_scale_pct=harmony_check(dec, sr, song.tonic),
            seam=seam_check(dec, sr, song.bs * sr, pre)))
    return {
        "id": d["id"], "bpm": d["bpm"], "key": d["key"], "bars": d["bars"], "sample_rate": sr,
        "loop_samples": song.n, "loop_seconds": round(song.n / sr, 6),
        "exact_seconds": round(d["bars"] * 4 * 60.0 / d["bpm"], 6),
        "chords": [c.name for c in song.chords], "chord_beats": [c.dur for c in song.chords],
        "stem_gain_db": {k: round(dsp.amp_db(gains[k] * common), 2) for k in raw},
        "mix_peak_dbfs": round(dsp.amp_db(dsp.peak(dmix)), 2), "mix_rms_dbfs": round(dsp.rms_db(dmix), 2),
        "mix_seam": seam_check(dmix, sr, song.bs * sr),
        "first_stem_alone_peak_dbfs": stems[0]["peak_dbfs"],
        "stems": stems, "render_s": round(time.time() - t0, 1),
    }


# ---------------------------------------------------------------- report

def clean_stale(dirpath, keep):
    if not dirpath.exists():
        return []
    removed = []
    for p in dirpath.rglob("*.ogg"):
        if rel(p) not in keep:
            p.unlink()
            removed.append(rel(p))
    return removed


def write_report(man):
    L = []
    a = L.append
    a("# GLOW audio report")
    a("")
    a("Generated by `tools/audio/gen_audio.py` (numpy synthesis, deterministic). All numbers below are measured")
    a("on the **decoded Ogg Vorbis files**, i.e. what the game actually plays. Re-run the script to refresh.")
    a("")
    tb = man["total_bytes"]
    a(f"**Total size:** {tb / 1024 / 1024:.2f} MB of {SIZE_BUDGET / 1024 / 1024:.0f} MB budget "
      f"({man['counts']['notes']} notes, {man['counts']['sfx']} SFX, {man['counts']['music']} music stems).")
    a("")
    a("## 1. Piece notes (synesthesia core)")
    a("")
    a("C major pentatonic C4 D4 E4 G4 A4 C5 D5 E5 G5 A5 C6 (n = 1..11); the engine transposes to the district key")
    a("with playback speed (within ±7 semitones). 44.1 kHz mono, Vorbis q0.6, 2 ms fade-in, fade-out at the end,")
    a("peak normalised to -3.0 dBFS after encoding.")
    a("")
    a("Pitch check: Hann-windowed FFT (0.02–0.5 s, zero-padded to 2^20 points, parabolic interpolation) of the")
    a("partial nearest the expected sounding pitch. *Cents* is the error of that partial against equal temperament")
    a("(A4 = 440 Hz). *Fund. rel.* is its level relative to the strongest partial (0 dB = the fundamental is the")
    a("strongest; the bass relies on its 2nd–4th harmonics to stay audible on phone speakers).")
    a("")
    a("| Colour | Instrument | Sounding range | Length s | Peak dBFS | Max abs cents | Fund. rel. dB (min) | Last 10 ms dBFS (max) |")
    a("|---|---|---|---|---|---|---|---|")
    by = {}
    for r in man["notes"]["files"]:
        by.setdefault(r["color"], []).append(r)
    for c, rows in by.items():
        lo = min(r["sounding_midi"] for r in rows)
        hi = max(r["sounding_midi"] for r in rows)
        name = lambda m: f"{KEY_NAMES[m % 12]}{m // 12 - 1}"
        a(f"| {c} | {notes.COLORS[c][0]} | {name(lo)}–{name(hi)} | {rows[0]['duration']:.2f} | "
          f"{max(r['peak_dbfs'] for r in rows):.2f} | {max(abs(r['cents']) for r in rows):.1f} | "
          f"{min(r['fundamental_rel_db'] for r in rows):.1f} | {max(r['last10ms_peak_dbfs'] for r in rows):.1f} |")
    a("")
    worst = max(man["notes"]["files"], key=lambda r: abs(r["cents"]))
    a(f"Worst pitch error: `{worst['path']}` {worst['cents']:+.2f} cents. Every note starts at "
      f"|x[0]| ≤ {max(r['first_sample'] for r in man['notes']['files']):.4f} (fade-in) and ends in silence.")
    a("")
    a("## 2. Sound effects")
    a("")
    a("44.1 kHz mono, Vorbis q0.5. Levels are set by a loudness target (gated K-weighted RMS, a light LUFS")
    a("stand-in) with a hard ceiling of -3 dBFS peak, so quiet UI ticks and big drops are balanced out of the box.")
    a("*Key* = C means the effect is tonal and written in C, so it can be transposed to the district key like the notes.")
    a("")
    a("| Name | s | Peak dBFS | Loudness dB (target) | Key | Content |")
    a("|---|---|---|---|---|---|")
    for r in man["sfx"]:
        a(f"| `{r['name']}` | {r['duration']:.2f} | {r['peak_dbfs']:.1f} | {r['loudness_db']:.1f} "
          f"({r['loudness_target_db']}) | {r['key'] or '–'} | {r['description']} |")
    a("")
    a("## 3. District music")
    a("")
    a("22.05 kHz mono, Vorbis q0.3. Every stem of a district has exactly the same number of samples,")
    a("`round(bars × 4 × 60 / bpm × 22050)`; for 104 and 110 BPM that is not an integer, so the loop is rounded to")
    a("the nearest sample (< 23 µs) and the beat grid is stretched by that amount so bar lines stay on the loop.")
    a("Events that ring past the loop end are wrapped to the start and all effects are circular, so each stem is")
    a("exactly periodic. Balance: stems are first set to relative loudness targets (`music.LOUDNESS`), then the")
    a("whole district is scaled by **one common factor** so the full mix of all stems (including tension and party)")
    a("peaks at -1 dBFS after decoding, with no stem above -0.3 dBFS.")
    a("")
    a("Seam check (on decoded files). Drums and notes hit beat lines on purpose, so the seam (downbeat of bar 1)")
    a("is compared with the other 31 beat lines of the same loop: *step/beats* = |x[0] − x[end]| divided by the")
    a("largest sample step within ±3 ms of any other beat line; *click/beats* = 2nd-difference energy in a ±3 ms")
    a("window across the seam divided by the largest such value on the other beat lines (a seam click would make")
    a("either ≫ 1; pass ≤ 1.5). *Codec edge* = Vorbis coding error in the first/last")
    a("10 ms relative to the 99th percentile of that error over the file (encoder edge artifacts would make it ≫ 1).")
    a("*In-scale %* = share of the energy of the 6 strongest spectral peaks per frame (80 Hz–2 kHz) that falls on the district's major scale; drum and")
    a("noise stems naturally score lower, and the jazz dominants deliberately use altered tones.")
    a("")
    for dd in man["music"].values():
        a(f"### {dd['id']} — {dd['key']} major, {dd['bpm']} BPM, {dd['bars']} bars")
        a("")
        a(f"Loop: {dd['loop_samples']} samples = {dd['loop_seconds']:.6f} s (exact {dd['exact_seconds']:.6f} s). "
          f"Chords: {' | '.join(dd['chords'])}. Full mix peak {dd['mix_peak_dbfs']:.2f} dBFS, RMS "
          f"{dd['mix_rms_dbfs']:.1f} dBFS, mix seam step/beats {dd['mix_seam']['step_vs_beats']}, click/beats "
          f"{dd['mix_seam']['click_vs_beats']}.")
        a("")
        a("| Stem | Task (cost) | Gain dB | Peak dBFS | RMS dBFS | Loudness dB | In-scale % | Step/beats | Click/beats | Codec edge |")
        a("|---|---|---|---|---|---|---|---|---|---|")
        for s in dd["stems"]:
            task = f"{s['task']} ({s['cost']})" if s["task"] else "level stem"
            a(f"| `{s['stem']}` | {task} | {dd['stem_gain_db'][s['stem']]:+.1f} | {s['peak_dbfs']:.1f} | "
              f"{s['rms_dbfs']:.1f} | {s['loudness_db']:.1f} | {s['harmony_in_scale_pct']} | "
              f"{s['seam']['step_vs_beats']} | {s['seam']['click_vs_beats']} | {s['seam']['codec_edge']} |")
        a("")
    a("## 4. Checks")
    a("")
    for line in man["checks"]:
        a(f"- {line}")
    a("")
    a("## 5. Replacing the placeholders")
    a("")
    a("Keep the file names, formats and loop lengths; `assets/sounds/manifest.json` lists every file. Music stems")
    a("of one district must stay sample-identical in length and start on the same downbeat. Notes must stay in C")
    a("(the engine transposes them). Re-run `python3 tools/audio/gen_audio.py` any time to restore the placeholders.")
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text("\n".join(L) + "\n", encoding="utf-8")


def run_checks(man):
    out, ok = [], True
    nf = man["notes"]["files"]
    c1 = all(abs(r["peak_dbfs"] - NOTE_PEAK_DB) <= 0.1 for r in nf)
    c2 = max(abs(r["cents"]) for r in nf)
    c3 = all(0.6 <= r["duration"] <= 1.2 for r in nf)
    out.append(f"Notes: {len(nf)} files, peaks at -3.0 ± 0.1 dBFS: {'PASS' if c1 else 'FAIL'}; "
               f"max pitch error {c2:.2f} cents: {'PASS' if c2 < 5 else 'FAIL'}; "
               f"lengths 0.6–1.2 s: {'PASS' if c3 else 'FAIL'}.")
    ok &= c1 and c2 < 5 and c3
    c4 = all(r["peak_dbfs"] <= SFX_PEAK_CAP_DB + 0.01 for r in man["sfx"])
    out.append(f"SFX: {len(man['sfx'])} files, all peaks ≤ -3 dBFS: {'PASS' if c4 else 'FAIL'}.")
    ok &= c4
    for dd in man["music"].values():
        lens = {s["samples"] for s in dd["stems"]}
        c5 = lens == {dd["loop_samples"]}
        c6 = abs(dd["mix_peak_dbfs"] - MIX_PEAK_DB) <= 0.1
        c7 = all(s["peak_dbfs"] < 0 for s in dd["stems"])
        c8 = all(s["seam"]["step_vs_beats"] <= 1.5 and s["seam"]["click_vs_beats"] <= 1.5
                 and s["seam"]["codec_edge"] <= 1.5 for s in dd["stems"])
        out.append(f"Music `{dd['id']}`: {len(dd['stems'])} stems, identical length {dd['loop_samples']}: "
                   f"{'PASS' if c5 else 'FAIL'}; mix peak {dd['mix_peak_dbfs']:.2f} dBFS: {'PASS' if c6 else 'FAIL'}; "
                   f"no stem clips: {'PASS' if c7 else 'FAIL'}; seams clean: {'PASS' if c8 else 'FAIL'}.")
        ok &= c5 and c6 and c7 and c8
    c9 = man["total_bytes"] <= SIZE_BUDGET
    out.append(f"Total size {man['total_bytes'] / 1024 / 1024:.2f} MB ≤ 7 MB: {'PASS' if c9 else 'FAIL'}.")
    ok &= c9
    return out, ok


# ------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--only", default="notes,sfx,music", help="comma list of notes,sfx,music")
    ap.add_argument("--jobs", type=int, default=min(5, mp.cpu_count()))
    args = ap.parse_args()
    parts = set(args.only.split(","))
    t0 = time.time()
    districts = json.loads(DISTRICTS.read_text(encoding="utf-8"))["districts"]
    prev = json.loads(MANIFEST.read_text(encoding="utf-8")) if MANIFEST.exists() else {}

    pool = None
    if "music" in parts:
        if args.jobs > 1:
            pool = mp.get_context("fork").Pool(args.jobs)
            pending = pool.map_async(build_district, districts)
        else:
            pending = None
    man = {"generator": "tools/audio/gen_audio.py", "format": "Ogg Vorbis, mono"}
    man["notes"] = {"sample_rate": notes.SR, "scale": "C major pentatonic", "midi": notes.SCALE,
                    "colors": {c: v[0] for c, v in notes.COLORS.items()},
                    "files": build_notes() if "notes" in parts else prev.get("notes", {}).get("files", [])}
    print(f"notes: {len(man['notes']['files'])} files  ({time.time() - t0:.1f}s)")
    man["sfx"] = build_sfx() if "sfx" in parts else prev.get("sfx", [])
    print(f"sfx:   {len(man['sfx'])} files  ({time.time() - t0:.1f}s)")
    if "music" in parts:
        res = pending.get() if pool else [build_district(d) for d in districts]
        if pool:
            pool.close()
            pool.join()
        man["music"] = {r["id"]: r for r in res}
    else:
        man["music"] = prev.get("music", {})
    print(f"music: {sum(len(v['stems']) for v in man['music'].values())} stems  ({time.time() - t0:.1f}s)")

    all_files = man["notes"]["files"] + man["sfx"] + [s for v in man["music"].values() for s in v["stems"]]
    keep = {f["path"] for f in all_files}
    removed = clean_stale(DIR_NOTES, keep) + clean_stale(DIR_SFX, keep) + clean_stale(DIR_MUSIC, keep)
    man["total_bytes"] = sum(f["bytes"] for f in all_files)
    man["counts"] = {"notes": len(man["notes"]["files"]), "sfx": len(man["sfx"]),
                     "music": sum(len(v["stems"]) for v in man["music"].values())}
    man["checks"], ok = run_checks(man)
    for v in man["music"].values():
        v.pop("render_s", None)
    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST.write_text(json.dumps(man, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    write_report(man)

    print()
    print(f"GLOW audio: {man['counts']['notes']} notes, {man['counts']['sfx']} sfx, "
          f"{man['counts']['music']} music stems in {len(man['music'])} districts")
    by_dir = {}
    for f in all_files:
        top = "/".join(f["path"].split("/")[:3])
        by_dir[top] = by_dir.get(top, 0) + f["bytes"]
    for k, v in sorted(by_dir.items()):
        print(f"  {k:28s} {v / 1024:8.1f} KB")
    print(f"  {'total':28s} {man['total_bytes'] / 1024:8.1f} KB  (budget {SIZE_BUDGET // 1024} KB)")
    for dd in man["music"].values():
        print(f"  {dd['id']:8s} {dd['bpm']:3d} BPM {dd['key']:>2s}  loop {dd['loop_samples']} smp  "
              f"mix peak {dd['mix_peak_dbfs']:.2f} dBFS  first stem '{dd['stems'][0]['stem']}' alone "
              f"{dd['first_stem_alone_peak_dbfs']:.1f} dBFS")
    for line in man["checks"]:
        print("  " + line)
    if removed:
        print(f"  removed stale: {', '.join(removed)}")
    print(f"  manifest: {rel(MANIFEST)}   report: {rel(REPORT)}   ({time.time() - t0:.1f}s)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
