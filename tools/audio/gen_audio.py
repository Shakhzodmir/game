#!/usr/bin/env python3
"""GLOW audio generator: piece notes, sound effects and district music.

    python3 tools/audio/gen_audio.py            # everything (a few minutes)
    python3 tools/audio/gen_audio.py --only music --jobs 4

Outputs (all Ogg Vorbis, mono):
    assets/sounds/notes/<color>_<n>.ogg   44.1 kHz, n = 1..11 (C major pentatonic C4..C6)
    assets/sounds/sfx/<name>.ogg          44.1 kHz
    assets/music/<district>/<stem>.ogg    22.05 kHz, bright stems 44.1 kHz; sample-exact seamless loops
    assets/sounds/manifest.json           every file with its measurements, plus the mixer contract
    docs/media/audio_report.md            measurements: loudness, pitch, peaks, headroom, seams, harmony

Levels (all measured on the decoded files; analysis.py has the meters):
  * notes: every note has the same phone-weighted loudness (M-max of a 300 Hz
    high-passed copy, NOTE_TARGET) and a true peak <= NOTE_TP_CAP, reached with
    a look-ahead true-peak limiter (it only trims the first milliseconds of the
    spikiest plucks);
  * SFX: gated K-weighted loudness targets (sfx.SFX), reached with the same
    limiter under a -3 dBTP ceiling (lower for the per-match 'clear');
  * music: stems at relative loudness targets (music.LOUDNESS), then one common
    gain per district so that the loudest combination the game really plays
    (task stems, + tension, + party) has a true peak of about -1.15 dBTP;
  * MIXER (copied to the manifest) is the playback contract for the engine:
    music offset in a level, and how simultaneous match notes are staggered and
    attenuated. run_checks() verifies that, played that way, notes + the clear
    pop + the music in a level stay below 0 dBTP.

Deterministic: all randomness is seeded from names (dsp.rng), and the Ogg
stream serial is fixed, so re-running produces byte-identical files.
Module map: dsp.py (DSP, limiter, Vorbis I/O), analysis.py (meters),
instruments.py (voices), notes.py, sfx.py, music.py (district arrangements),
this file (pipeline, checks, report). Everything here is placeholder audio
meant to be replaced by a composer: the engine only relies on the file paths
and on manifest.json.
"""
import argparse
import itertools
import json
import multiprocessing as mp
import sys
import time
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy import signal

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import analysis as A  # noqa: E402
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
NOTE_TARGET = -20.0   # phone-weighted M-max (LUFS) of every note
NOTE_TOL = 1.0
NOTE_TP_CAP = -7.0    # dBTP
SFX_TP_CAP = -3.0     # dBTP (sfx.TP_CAP lowers it for per-match effects)
SFX_TOL = 1.0
SFX_ENERGY_GR_MAX = 7.0  # dB of an effect's energy the limiter may take
LIMIT_MARGIN = 0.25   # limiter ceiling below the cap (room for Vorbis peak changes)
MIX_TP_MAX = -1.0     # music: worst realistic combination, dBTP (one-sided)
MIX_TP_AIM = -1.15
STEM_TP_MAX = -0.3
UNLOCK_MIN_LU = 10.0  # a task's layer may sit at most this far below the mix it joins
HEADROOM_MAX = 0.0    # notes + clear + music in a level, played per MIXER, dBTP
PHONE_LOSS_MAX = 10.0  # gameplay-feedback SFX: M-max minus phone M-max, dB
FEEDBACK_SFX = ("tap", "swap", "swap_fail", "land", "clear", "box_hit", "concrete_hit", "column_hit",
                "balloon_pop", "wires_snap", "noise_fizz", "moves_low", "button")
PITCHED_SFX_MIN_IN_KEY = 75.0  # % of tonal energy on the C major scale for the short pitched cues
PITCHED_CUES = ("tap", "swap_fail", "bird", "moves_low", "coin", "star", "floor_light")
SIZE_BUDGET = 7 * 1024 * 1024
KEY_NAMES = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

# Playback contract for the engine (copied into manifest.json as "mixer").
MIXER = {
    "group_gain_db": {"music": 0.0, "notes": 0.0, "sfx": 0.0},
    "music_in_level_db": -6.0,
    "music_big_combo_db": -9.0,
    "music_combinations": {
        "level": "task stems unlocked so far (+ tension at <= 5 moves)",
        "finale concert and jukebox": "task stems + party",
        "never": "tension together with party (the -1 dBTP music ceiling is checked on the three real combinations)",
    },
    "notes_same_tick": {
        "dedupe_same_file": True,
        "max_voices": 3,
        "stagger_s": [0.010, 0.022, 0.034],
        "gain_db_by_count": [0.0, -4.5, -6.5],
        "rule": ("Match notes quantised to the same 1/32 tick: play each file once, at most 3 voices "
                 "(keep the lowest steps), start voice i stagger_s[i] after the tick (a quick strum that also "
                 "keeps note attacks off the drum hits on the beat) and play every voice at "
                 "gain_db_by_count[count-1]. Music in a level at music_in_level_db."),
    },
}


# ------------------------------------------------------------------ I/O

def rel(p):
    return str(Path(p).relative_to(ROOT)).replace("\\", "/")


def write_bytes(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_bytes() == data:
        return
    path.write_bytes(data)


def level(x, sr, measure, target, ceiling, lookahead, release):
    """Gain + true-peak limiter (ceiling dBTP) so that measure(y) == target.
    Returns (y, largest gain reduction dB, energy gain reduction dB). The last
    is what the limiter took from the whole sound: near 0 when it only trims
    transients, large if it squashes."""
    x = np.asarray(x, dtype=float)
    g = dsp.db_amp(target - measure(x))
    y, gc = x * g, np.ones(len(x))
    for _ in range(14):
        y, gc = dsp.limiter(x * g, sr, ceiling, lookahead, release)
        err = target - measure(y)
        if abs(err) < 0.02:
            break
        g *= dsp.db_amp(err)
    egr = 10.0 * np.log10(np.sum(y ** 2) / max(np.sum((x * g) ** 2), 1e-30))
    return y, round(float(dsp.amp_db(gc.min())), 2), round(float(egr), 2)


def level_encode(path, x, sr, quality, measure, target, tp_cap, lookahead, release):
    """level() under tp_cap - LIMIT_MARGIN, encode, and if lossy coding pushed
    the decoded true peak over tp_cap, limit a little deeper and encode again
    (the loudness target is kept). Returns (bytes, decoded, gr, energy gr)."""
    margin = LIMIT_MARGIN
    for _ in range(8):
        y, gr, egr = level(x, sr, measure, target, tp_cap - margin, lookahead, release)
        data, dec = dsp.encode_vorbis(y, sr, quality, rel(path))
        tp = A.true_peak(dec)
        if tp <= tp_cap:
            break
        margin += tp - tp_cap + 0.03
    return data, dec, gr, egr


def file_entry(path, dec, sr, nbytes, **extra):
    e = {"path": rel(path), "duration": round(len(dec) / sr, 4), "samples": len(dec), "sample_rate": sr,
         "peak_dbfs": round(dsp.amp_db(dsp.peak(dec)), 2), "true_peak_dbtp": round(A.true_peak(dec), 2),
         "rms_dbfs": round(dsp.rms_db(dec), 2), "bytes": nbytes}
    e.update(extra)
    return e


def hi_rate(x, sr):
    """A loop at the 44.1 kHz mixing rate (22.05 kHz stems: exact 2x upsampling)."""
    return x if sr == music.SR_HI else A.up2_loop(x)


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
    stems are reported but not judged. 44.1 kHz stems are measured at 22.05 kHz."""
    if sr == music.SR_HI:
        x, sr = signal.resample_poly(x, 1, 2), music.SR
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
    rows, decs = [], {}
    pm = lambda z: A.phone_mmax(z, notes.SR)  # noqa: E731
    for color, n, midi, sounding, x in notes.render_all():
        path = DIR_NOTES / f"{color}_{n}.ogg"
        data, dec, gr, egr = level_encode(path, x, notes.SR, Q_NOTES, pm, NOTE_TARGET, NOTE_TP_CAP, 0.0015, 0.05)
        write_bytes(path, data)
        decs[(color, n)] = dec
        f_exp = float(dsp.midi_hz(sounding))
        f, cents, dom, rel_db = pitch_of(dec, notes.SR, f_exp)
        fy, dip = A.yin(dec, notes.SR, fmin=40.0, fmax=2600.0)
        tail = dsp.amp_db(dsp.peak(dec[-int(0.01 * notes.SR):]))
        rows.append(file_entry(
            path, dec, notes.SR, len(data), color=color, n=n, midi=midi, sounding_midi=sounding,
            freq_hz=round(f_exp, 2), measured_hz=round(f, 2), cents=round(cents, 2),
            yin_hz=round(fy, 2), yin_cents=round(1200 * np.log2(fy / f_exp), 1), yin_dip=round(dip, 3),
            harmonics_db=A.harmonics_db(dec, notes.SR, f_exp, 4),
            strongest_partial_hz=round(float(dom), 1), fundamental_rel_db=round(float(rel_db), 1),
            mmax_lufs=round(A.mmax(dec, notes.SR), 2), phone_mmax_lufs=round(pm(dec), 2),
            limiter_gr_db=gr, limiter_energy_gr_db=egr, first_sample=round(float(abs(dec[0])), 5),
            last10ms_peak_dbfs=round(float(tail), 1)))
    return rows, decs


# ------------------------------------------------------------------- sfx

def build_sfx():
    rows, decs = [], {}
    ld = lambda z: dsp.loudness(z, sfx.SR, win=0.05)  # noqa: E731
    for name, (fn, target, key, desc) in sfx.SFX.items():
        x = np.asarray(fn(), dtype=float)
        x = x - np.mean(x)
        cap = sfx.TP_CAP.get(name, SFX_TP_CAP)
        path = DIR_SFX / f"{name}.ogg"
        data, dec, gr, egr = level_encode(path, x, sfx.SR, Q_SFX, ld, target, cap, 0.002, 0.04)
        write_bytes(path, data)
        decs[name] = dec
        mm, pmx = A.mmax(dec, sfx.SR), A.phone_mmax(dec, sfx.SR)
        rows.append(file_entry(
            path, dec, sfx.SR, len(data), name=name, key=key, description=desc,
            loudness_db=round(ld(dec), 1), loudness_target_db=target, tp_cap_dbtp=cap, limiter_gr_db=gr,
            limiter_energy_gr_db=egr,
            mmax_lufs=round(mm, 1), phone_mmax_lufs=round(pmx, 1), phone_loss_db=round(mm - pmx, 1),
            in_c_major_pct=round(100 * A.in_scale_share(dec, sfx.SR, 0), 1) if key == "C" else None))
    return rows, decs


# ----------------------------------------------------------------- music

def build_district(d):
    t0 = time.time()
    song, raw, rates = music.render_district(d)
    fs = music.SR_HI
    targets = music.LOUDNESS[d["id"]]
    gains = {k: dsp.db_amp(targets[k] - dsp.loudness(x, rates[k])) for k, x in raw.items()}
    tasks = [t["stem"] for t in d["tasks"]]
    combos = {"tasks": tasks, "tasks+tension": tasks + ["tension"], "tasks+party": tasks + ["party"]}

    def combo_tp(sig):
        return {name: A.true_peak(sum(sig[k] for k in ks), circular=True) for name, ks in combos.items()}

    pre = {k: hi_rate(gains[k] * x, rates[k]) for k, x in raw.items()}
    common = dsp.db_amp(MIX_TP_AIM - max(combo_tp(pre).values()))
    worst_stem = max(A.true_peak(v, circular=True) for v in pre.values()) + dsp.amp_db(common)
    if worst_stem > STEM_TP_MAX - 0.2:  # no single stem may get near clipping
        common *= dsp.db_amp(STEM_TP_MAX - 0.2 - worst_stem)

    def encode_all(c):
        enc = {}
        for k, x in raw.items():
            path = DIR_MUSIC / d["id"] / f"{k}.ogg"
            enc[k] = (path,) + dsp.encode_vorbis(x * gains[k] * c, rates[k], Q_MUSIC, rel(path))
        dec_hi = {k: hi_rate(v[2], rates[k]) for k, v in enc.items()}
        return enc, dec_hi, combo_tp(dec_hi)

    enc, dec_hi, tps = encode_all(common)
    for _ in range(5):  # Vorbis moves peaks a little: settle the worst combination in [-1.35, -1.02] dBTP
        w = max(tps.values())
        if MIX_TP_AIM - 0.2 <= w <= MIX_TP_MAX - 0.02:
            break
        common *= dsp.db_amp(MIX_TP_AIM - w)
        enc, dec_hi, tps = encode_all(common)

    task_of = {t["stem"]: t for t in d["tasks"]}
    lu = lambda z: A.lufs(z, fs, circular=True)[0]  # noqa: E731
    stems = []
    for k, (path, data, dec) in enc.items():
        write_bytes(path, data)
        sr = rates[k]
        assert len(dec) == song.n * (sr // music.SR), (path, len(dec), song.n)
        pre_k = raw[k] * gains[k] * common
        stems.append(file_entry(
            path, dec, sr, len(data), stem=k, task=task_of[k]["id"] if k in task_of else None,
            cost=task_of[k]["cost"] if k in task_of else None,
            loudness_db=round(dsp.loudness(dec, sr), 1), lufs=round(lu(dec_hi[k]), 1),
            centroid_hz=round(A.centroid(dec, sr)),
            harmony_in_scale_pct=harmony_check(dec, sr, song.tonic),
            seam=seam_check(dec, sr, song.bs * sr, pre_k)))

    mixes = {name: sum(dec_hi[k] for k in ks) for name, ks in combos.items()}
    everything = sum(dec_hi.values())
    combo_stats = {name: {"peak_dbfs": round(A.sample_peak(m), 2), "true_peak_dbtp": round(tps[name], 2),
                          "lufs": round(lu(m), 1)} for name, m in mixes.items()}
    combo_stats["all stems (never played together)"] = {
        "peak_dbfs": round(A.sample_peak(everything), 2),
        "true_peak_dbtp": round(A.true_peak(everything, circular=True), 2), "lufs": round(lu(everything), 1)}
    # what each task adds when it unlocks
    ladder, acc = [], np.zeros(len(everything))
    for k in tasks:
        before = lu(acc) if acc.any() else None
        acc = acc + dec_hi[k]
        after = lu(acc)
        sl = lu(dec_hi[k])
        ladder.append({"stem": k, "task": task_of[k]["id"], "cost": task_of[k]["cost"], "stem_lufs": round(sl, 1),
                       "mix_before_lufs": None if before is None else round(before, 1),
                       "stem_vs_mix_lu": None if before is None else round(sl - before, 1),
                       "delta_lu": None if before is None else round(after - before, 2)})
    tmix = mixes["tasks"]
    maj = f"{KEY_NAMES[song.tonic]} maj"
    mnr = f"{KEY_NAMES[(song.tonic + 9) % 12]} min"

    def keyread(x):  # at 22.05 kHz (finer low-frequency bins, comparable with earlier reviews)
        ks = A.key_scores(signal.resample_poly(x, 1, 2), music.SR)
        best = max(ks, key=ks.get)
        return {"major": round(ks[maj], 2), "relative_minor": round(ks[mnr], 2), "best": best,
                "best_r": round(ks[best], 2)}

    return {
        "id": d["id"], "bpm": d["bpm"], "key": d["key"], "bars": d["bars"], "sample_rate": music.SR,
        "loop_samples": song.n, "loop_samples_44100": song.n * 2, "loop_seconds": round(song.n / music.SR, 6),
        "exact_seconds": round(d["bars"] * 4 * 60.0 / d["bpm"], 6),
        "chords": [c.name for c in song.chords], "chord_beats": [c.dur for c in song.chords],
        "stem_gain_db": {k: round(dsp.amp_db(gains[k] * common), 2) for k in raw},
        "combos": combo_stats,
        "tension_delta_lu": round(combo_stats["tasks+tension"]["lufs"] - combo_stats["tasks"]["lufs"], 2),
        "party_delta_lu": round(combo_stats["tasks+party"]["lufs"] - combo_stats["tasks"]["lufs"], 2),
        "unlock": ladder,
        "brightness": {"centroid_hz": round(A.centroid(tmix, fs)),
                       "hf_2k_8k_vs_mid_db": round(A.band_db(tmix, fs, 2000, 8000), 1),
                       "air_8k_16k_vs_mid_db": round(A.band_db(tmix, fs, 8000, 16000), 1),
                       "share_below_150hz_pct": round(100 * A.share_below(tmix, fs, 150), 1)},
        "key_reading": {"tasks": keyread(tmix), "tasks+party": keyread(mixes["tasks+party"]),
                        "party alone": keyread(dec_hi["party"]), "tension alone": keyread(dec_hi["tension"])},
        "mix_seam": seam_check(everything, fs, song.bs * fs),
        "stems": stems, "render_s": round(time.time() - t0, 1),
    }


# -------------------------------------------------------------- headroom

def headroom(man, note_dec, clear_dec):
    """Sample-aligned sums the game really produces: k match notes of one
    cascade wave (same step n, different colours, every colour combination
    and order) + the clear pop, all starting on the same 1/32 tick, played per
    MIXER; then with the level's music bed (task stems + tension at
    music_in_level_db) with the tick on each of its 32 beats (where the kick
    and snare transients are). 'raw' = the same without the MIXER note rules."""
    rule = MIXER["notes_same_tick"]
    sr = notes.SR

    def summ(parts):
        L = max(len(p) + o for p, o in parts)
        s = np.zeros(L)
        for p, o in parts:
            s[o: o + len(p)] += p
        return s

    beds = []
    for dd in man["music"].values():
        sig = None
        for s in dd["stems"]:
            if s["stem"] == "party":
                continue
            x, r = sf.read(ROOT / s["path"], dtype="float64")
            x = hi_rate(x, r)
            sig = x if sig is None else sig + x
        sig = sig * dsp.db_amp(MIXER["music_in_level_db"] + MIXER["group_gain_db"]["music"])
        nb = dd["bars"] * 4
        beds.append((dd["id"], sig, [int(round(b * len(sig) / nb)) for b in range(nb)]))
    g_notes = MIXER["group_gain_db"]["notes"]
    g_sfx = dsp.db_amp(MIXER["group_gain_db"]["sfx"])
    out = {}
    for k in (1, 2, 3):
        res = []
        for n in range(1, 12):
            for combo in itertools.combinations(notes.COLORS, k):
                for perm in (itertools.permutations(combo) if k > 1 else [combo]):
                    g = dsp.db_amp(g_notes + rule["gain_db_by_count"][k - 1])
                    parts = [(note_dec[(c, n)] * g, int(round(rule["stagger_s"][i] * sr))) for i, c in enumerate(perm)]
                    s = summ(parts + [(clear_dec * g_sfx, 0)])
                    raw_s = summ([(note_dec[(c, n)], 0) for c in perm] + [(clear_dec, 0)])
                    res.append((A.true_peak(s), A.true_peak(raw_s), n, perm, s))
        res.sort(key=lambda z: -z[0])
        worst_raw = max(res, key=lambda z: z[1])
        best_w = (-99.0, None, None, None)
        for tp0, _, n, perm, s in res[:6]:  # the loudest note sums, against every beat of every level bed
            for did, bed, starts in beds:
                for p0 in starts:
                    seg = bed[p0: p0 + len(s)]
                    if len(seg) < len(s):
                        seg = np.concatenate([seg, bed[: len(s) - len(seg)]])
                    v = A.true_peak(s + seg)
                    if v > best_w[0]:
                        best_w = (v, (n, perm), did, starts.index(p0))
        out[k] = {"notes_clear_dbtp": round(res[0][0], 2), "notes_clear_combo": [res[0][2], list(res[0][3])],
                  "raw_notes_clear_dbtp": round(worst_raw[1], 2),
                  "raw_combo": [worst_raw[2], list(worst_raw[3])],
                  "with_music_dbtp": round(best_w[0], 2), "with_music_combo": [best_w[1][0], list(best_w[1][1])],
                  "with_music_district": best_w[2], "with_music_beat": best_w[3]}
    return out


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
    a("Meters (`tools/audio/analysis.py`): **LUFS** = ITU-R BS.1770-4 loudness; **M-max** = the loudest 400 ms")
    a("(momentary maximum); **phone** = the same after a 4th-order 300 Hz high-pass, a rough phone-speaker model;")
    a("**dBTP** = 4x oversampled true peak (what a resampling mixer can reach). SFX loudness targets use the")
    a("generator's gated K-weighted meter with 50 ms windows (`dsp.loudness`).")
    a("")
    tb = man["total_bytes"]
    a(f"**Total size:** {tb / 1024 / 1024:.2f} MB of {SIZE_BUDGET / 1024 / 1024:.0f} MB budget "
      f"({man['counts']['notes']} notes, {man['counts']['sfx']} SFX, {man['counts']['music']} music stems).")
    a("")
    # ----------------------------------------------------------- notes
    a("## 1. Piece notes (synesthesia core)")
    a("")
    a("C major pentatonic C4 D4 E4 G4 A4 C5 D5 E5 G5 A5 C6 (n = 1..11); the engine transposes to the district key")
    a("with playback speed (within ±7 semitones). 44.1 kHz mono, Vorbis q0.6, 2 ms fade-in, fade-out at the end.")
    a(f"**Level:** every note is normalised to **{NOTE_TARGET:.0f} LUFS phone-weighted M-max** (±{NOTE_TOL:.0f} dB), so")
    a(f"all six colours are equally loud on a phone, with a true peak ≤ {NOTE_TP_CAP:.0f} dBTP (a look-ahead limiter")
    a("trims only the first milliseconds of the spikiest plucks; *GR* is its largest gain reduction). Bells sound")
    a("an octave above the written note on purpose (a glockenspiel at C4 would be a dull thud).")
    a("")
    a("*Cents*: error of the partial nearest the expected pitch (Hann FFT 0.02–0.5 s, 2^20 points). *YIN*: the pitch")
    a("a tuner (and the ear) locks onto, YIN with the usual 0.1 threshold — it must be the written note, not a")
    a("harmonic. *H1/H2*: level of the fundamental and 2nd harmonic relative to the strongest of harmonics 1–4.")
    a("")
    a("| Colour | Instrument | Sounding range | s | Phone M-max LUFS | Full M-max LUFS | dBTP (max) | GR dB (max) | Max abs cents | YIN max abs cents | H1 dB (min) | H2 dB (min) |")
    a("|---|---|---|---|---|---|---|---|---|---|---|---|")
    by = {}
    for r in man["notes"]["files"]:
        by.setdefault(r["color"], []).append(r)
    name = lambda m: f"{KEY_NAMES[m % 12]}{m // 12 - 1}"  # noqa: E731
    for c, rows in by.items():
        lo = min(r["sounding_midi"] for r in rows)
        hi = max(r["sounding_midi"] for r in rows)
        pmx = [r["phone_mmax_lufs"] for r in rows]
        mm = [r["mmax_lufs"] for r in rows]
        a(f"| {c} | {notes.COLORS[c][0]} | {name(lo)}–{name(hi)} | {rows[0]['duration']:.2f} | "
          f"{min(pmx):.1f} … {max(pmx):.1f} | {min(mm):.1f} … {max(mm):.1f} | "
          f"{max(r['true_peak_dbtp'] for r in rows):.1f} | {min(r['limiter_gr_db'] for r in rows):.1f} | "
          f"{max(abs(r['cents']) for r in rows):.1f} | {max(abs(r['yin_cents']) for r in rows):.1f} | "
          f"{min(r['harmonics_db'][0] for r in rows):.1f} | {min(r['harmonics_db'][1] for r in rows):.1f} |")
    a("")
    nf = man["notes"]["files"]
    worst = max(nf, key=lambda r: abs(r["cents"]))
    a(f"Worst pitch error: `{worst['path']}` {worst['cents']:+.2f} cents. Every note starts at "
      f"|x[0]| ≤ {max(r['first_sample'] for r in nf):.4f} (fade-in) and ends in silence "
      f"(last 10 ms ≤ {max(r['last10ms_peak_dbfs'] for r in nf):.1f} dBFS). Spread of phone M-max over all 66 notes: "
      f"{max(r['phone_mmax_lufs'] for r in nf) - min(r['phone_mmax_lufs'] for r in nf):.2f} dB.")
    pl = [r for r in nf if r["color"] == "purple" and r["n"] <= 3]
    a("Purple C4/D4/E4 (the notes of waves 1–3), harmonics 1–4 dB: " + "; ".join(
        f"`purple_{r['n']}` {r['harmonics_db']} (YIN {r['yin_hz']:.1f} Hz)" for r in pl) + ".")
    a("")
    # ----------------------------------------------------------- headroom
    hr = man["headroom"]
    rule = MIXER["notes_same_tick"]
    a("### 1.1 Headroom: notes that start together")
    a("")
    a("The engine quantises match notes to the same 1/32 tick, so the notes of one cascade wave (same step, different")
    a("colours) start together with the `clear` pop. Mixer contract (`manifest.json` → `mixer`, the engine must")
    a(f"follow it): identical files play once; at most {rule['max_voices']} voices; voice *i* starts "
      f"{', '.join(f'{1000 * s:.0f}' for s in rule['stagger_s'])} ms after the tick (a quick strum, well inside the")
    a(f"1/32 grid); every voice plays at {', '.join(f'{g:+.1f}' for g in rule['gain_db_by_count'])} dB for 1/2/3 voices;")
    a(f"music in a level at {MIXER['music_in_level_db']:+.0f} dB. The table is the worst true peak over every step, colour")
    a("combination and order (`clear` at its own level), then the loudest of those sums placed on each of the 32 beats of")
    a("each district's in-level bed (task stems + tension, i.e. on the kick and snare transients).")
    a("")
    a("| Voices | Notes + clear, raw (all at 0 dB, no strum) | Notes + clear, per mixer | + music bed in a level (worst beat) |")
    a("|---|---|---|---|")
    for k, v in hr.items():
        a(f"| {k} | {v['raw_notes_clear_dbtp']:+.2f} dBTP | {v['notes_clear_dbtp']:+.2f} dBTP | "
          f"{v['with_music_dbtp']:+.2f} dBTP (`{v['with_music_district']}` beat {v['with_music_beat'] + 1}, "
          f"step {v['with_music_combo'][0]}, {'+'.join(v['with_music_combo'][1])}) |")
    a("")
    # ----------------------------------------------------------- sfx
    a("## 2. Sound effects")
    a("")
    a("44.1 kHz mono, Vorbis q0.5. Levels are set by a loudness target (gated K-weighted, 50 ms windows) reached with a")
    a(f"look-ahead true-peak limiter under a {SFX_TP_CAP:.0f} dBTP ceiling (lower for per-match effects: "
      + ", ".join(f"`{k}` {v:.0f}" for k, v in sfx.TP_CAP.items()) + " dBTP),")
    a("so quiet UI ticks and big drops are balanced out of the box. *Key* = C: tonal and written in C, transposed to the")
    a("district key like the notes. *Phone loss* = full M-max − phone M-max. *In C* = share of tonal energy (100 Hz–4 kHz)")
    a("on the C major scale. Every low boom is high-passed at 50 Hz, settles on C2 and carries 0.3–2 kHz body.")
    a("")
    a("*GR* = the limiter's largest gain reduction (on the attack transient) / how much of the effect's energy it took")
    a(f"(≤ {SFX_ENERGY_GR_MAX:.0f} dB: it shapes transients, it does not squash the sound).")
    a("")
    a("| Name | s | dBTP | Loudness dB (target) | GR dB peak / energy | M-max | Phone M-max | Phone loss | Key | In C % | Content |")
    a("|---|---|---|---|---|---|---|---|---|---|---|")
    for r in man["sfx"]:
        ic = f"{r['in_c_major_pct']:.0f}" if r["in_c_major_pct"] is not None else "–"
        a(f"| `{r['name']}` | {r['duration']:.2f} | {r['true_peak_dbtp']:.1f} | {r['loudness_db']:.1f} "
          f"({r['loudness_target_db']}) | {r['limiter_gr_db']:.1f} / {r['limiter_energy_gr_db']:.1f} | "
          f"{r['mmax_lufs']:.1f} | {r['phone_mmax_lufs']:.1f} | "
          f"{r['phone_loss_db']:.1f} | {r['key'] or '–'} | {ic} | {r['description']} |")
    a("")
    # ----------------------------------------------------------- music
    a("## 3. District music")
    a("")
    a("Mono, Vorbis q0.3, 22.05 kHz; the bright stems (hats, shakers, tambourine, arpeggios, snaps, the café twinkle and")
    a("every party stem) are 44.1 kHz so they keep their 11–16 kHz sparkle. The loop is `round(bars × 4 × 60 / bpm ×")
    a("22050)` samples on the 22.05 kHz grid and exactly twice that at 44.1 kHz, so all stems of a district have")
    a("exactly the same duration; for 104 and 110 BPM the loop is rounded to the nearest 22.05 kHz sample (< 23 µs)")
    a("and the beat grid is stretched by that amount. Events that ring past the loop end wrap to the start and every")
    a("effect is circular, so each stem is exactly periodic.")
    a("")
    a("**Balance:** stems are first set to relative loudness targets (`music.LOUDNESS`; sparse layers of expensive tasks")
    a("sit 3–6 dB hotter so an unlock is heard), then each district is scaled by **one common factor** so the loudest")
    a(f"combination the game plays — task stems, + tension (last moves), + party (finale) — has a true peak of "
      f"{MIX_TP_AIM:.2f} dBTP")
    a(f"(check: ≤ {MIX_TP_MAX:.1f} dBTP and ≤ {MIX_TP_MAX:.1f} dBFS sample peak, measured after exact 2x upsampling of the")
    a("22.05 kHz stems, i.e. as a resampling mixer sees it). All stems summed (never played) is listed for information.")
    a("")
    a("Seam check (decoded files): *step/beats* = |x[0] − x[end]| / largest sample step within ±3 ms of any other beat")
    a("line; *click/beats* = 2nd-difference energy across the seam / largest such value on the other beat lines (pass")
    a("≤ 1.5). *Codec edge* = Vorbis coding error in the first/last 10 ms / 99th percentile of that error over the file.")
    a("*In-scale %* = share of the 6 strongest spectral peaks per frame (80 Hz–2 kHz) on the district's major scale")
    a("(drum and noise stems naturally score lower; jazz dominants deliberately use altered tones).")
    a("")
    a("**Unlock audibility** (below each district): *stem vs mix* = the stem's loudness relative to the mix it joins;")
    a("*Δ mix* = how much the mix loudness rises when it unlocks (sparse layers such as shouts or risers add little")
    a("integrated loudness even when clearly heard, so both are listed).")
    a("")
    for dd in man["music"].values():
        a(f"### {dd['id']} — {dd['key']} major, {dd['bpm']} BPM, {dd['bars']} bars")
        a("")
        a(f"Loop: {dd['loop_samples']} samples at 22.05 kHz ({dd['loop_samples_44100']} at 44.1 kHz) = "
          f"{dd['loop_seconds']:.6f} s (exact {dd['exact_seconds']:.6f} s). Chords: {' | '.join(dd['chords'])}. "
          f"Mix seam step/beats {dd['mix_seam']['step_vs_beats']}, click/beats {dd['mix_seam']['click_vs_beats']}.")
        a("")
        a("| Combination | Peak dBFS | True peak dBTP | LUFS |")
        a("|---|---|---|---|")
        for cn, cs in dd["combos"].items():
            a(f"| {cn} | {cs['peak_dbfs']:.2f} | {cs['true_peak_dbtp']:.2f} | {cs['lufs']:.1f} |")
        b = dd["brightness"]
        kr = dd["key_reading"]
        a("")
        a(f"Tension adds {dd['tension_delta_lu']:+.1f} LU, party {dd['party_delta_lu']:+.1f} LU. Brightness of the task mix: "
          f"centroid {b['centroid_hz']} Hz, 2–8 kHz {b['hf_2k_8k_vs_mid_db']:+.1f} dB and 8–16 kHz "
          f"{b['air_8k_16k_vs_mid_db']:+.1f} dB vs 0.2–2 kHz, {b['share_below_150hz_pct']:.0f} % of the energy below 150 Hz. "
          f"Key reading (Krumhansl, major vs relative minor): " + "; ".join(
              f"{kn} {v['major']:.2f} / {v['relative_minor']:.2f} (best {v['best']})" for kn, v in kr.items()) + ".")
        a("")
        a("| Stem | Task (cost) | Hz | Gain dB | Peak dBFS | dBTP | LUFS | In-scale % | Step/beats | Click/beats | Codec edge |")
        a("|---|---|---|---|---|---|---|---|---|---|---|")
        for s in dd["stems"]:
            task = f"{s['task']} ({s['cost']})" if s["task"] else "level stem"
            a(f"| `{s['stem']}` | {task} | {s['sample_rate']} | {dd['stem_gain_db'][s['stem']]:+.1f} | {s['peak_dbfs']:.1f} | "
              f"{s['true_peak_dbtp']:.1f} | {s['lufs']:.1f} | {s['harmony_in_scale_pct']} | "
              f"{s['seam']['step_vs_beats']} | {s['seam']['click_vs_beats']} | {s['seam']['codec_edge']} |")
        a("")
        a("| Unlock order | Task (cost) | Stem LUFS | Stem vs mix LU | Δ mix LU |")
        a("|---|---|---|---|---|")
        for u in dd["unlock"]:
            svm = "–" if u["stem_vs_mix_lu"] is None else f"{u['stem_vs_mix_lu']:+.1f}"
            dl = "first layer" if u["delta_lu"] is None else f"{u['delta_lu']:+.2f}"
            a(f"| `{u['stem']}` | {u['task']} ({u['cost']}) | {u['stem_lufs']:.1f} | {svm} | {dl} |")
        a("")
    a("## 4. Checks")
    a("")
    for line in man["checks"]:
        a(f"- {line}")
    a("")
    a("## 5. Engine requirements and known limitations")
    a("")
    a("- The headroom above holds only if the engine follows `manifest.json` → `mixer`: music at "
      f"{MIXER['music_in_level_db']:+.0f} dB in a level, match notes of one tick de-duplicated, at most "
      f"{rule['max_voices']} voices, strummed and attenuated as listed. Tension and party are never played together.")
    a("- Effects marked key C (`tap`, `swap_fail`, `sub`, `bird`, `moves_low`, the bells and fanfares, …) are written in C")
    a("  and must be transposed to the district key with playback speed exactly like the notes; played untransposed")
    a("  they clash with some district keys (e.g. `moves_low` over the A and E tension stems).")
    a("- Stems of one district have different sample rates (22.05 or 44.1 kHz) but exactly the same duration;")
    a("  start them in the same frame as before. Worth one on-device test that Defold honours the Ogg end-of-stream")
    a("  trim (the decoded length must equal `samples`), otherwise loops would drift.")
    a("- Vorbis coding noise at the loop seam of a few very quiet, band-limited stems (e.g. `jazz/organ`,")
    a("  `cafe/bass`) is at about −75 to −90 dBFS: inaudible under the mix, so it is left as is (Vorbis cannot start")
    a("  decoding in the middle of an encoded pre-roll without a decoder-side trim, which is riskier than the noise).")
    a("")
    a("## 6. Replacing the placeholders")
    a("")
    a("Keep the file names, formats and loop durations; `assets/sounds/manifest.json` lists every file (with its sample")
    a("rate) and the mixer contract. Music stems of one district must stay exactly the same duration and start on the")
    a("same downbeat. Notes and key-C effects must stay in C (the engine transposes them). Re-run")
    a("`python3 tools/audio/gen_audio.py` any time to restore the placeholders.")
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text("\n".join(L) + "\n", encoding="utf-8")


def run_checks(man):
    out, ok = [], True

    def chk(label, cond):
        nonlocal ok
        ok &= bool(cond)
        return f"{label}: {'PASS' if cond else 'FAIL'}"

    nf = man["notes"]["files"]
    pm = [r["phone_mmax_lufs"] for r in nf]
    tp = max(r["true_peak_dbtp"] for r in nf)
    cents = max(abs(r["cents"]) for r in nf)
    yin_bad = [r["path"].split("/")[-1] for r in nf if abs(r["yin_cents"]) > 50]
    purple_bad = [r["path"].split("/")[-1] for r in nf
                  if r["color"] == "purple" and r["n"] <= 3 and min(r["harmonics_db"][:2]) < -10]
    out.append("Notes: " + "; ".join([
        chk(f"{len(nf)} files, phone M-max {min(pm):.2f} … {max(pm):.2f} LUFS within {NOTE_TARGET:.0f} ± {NOTE_TOL:.0f}",
            all(abs(v - NOTE_TARGET) <= NOTE_TOL for v in pm)),
        chk(f"true peak ≤ {NOTE_TP_CAP:.0f} dBTP (max {tp:.2f})", tp <= NOTE_TP_CAP + 1e-9),
        chk(f"max pitch error {cents:.2f} cents < 5", cents < 5),
        chk("YIN hears the written pitch on every note" + (f" (not: {', '.join(yin_bad)})" if yin_bad else ""),
            not yin_bad),
        chk("purple C4–E4 harmonics 1–2 within 10 dB of the loudest", not purple_bad),
        chk("lengths 0.6–1.2 s", all(0.6 <= r["duration"] <= 1.2 for r in nf))]) + ".")
    hr = man["headroom"]
    wm = max(v["with_music_dbtp"] for v in hr.values())
    out.append("Headroom (1–3 notes + clear + music in a level, played per the mixer contract): " + chk(
        f"worst {wm:+.2f} dBTP ≤ {HEADROOM_MAX:+.1f}", wm <= HEADROOM_MAX) + ".")
    sx = man["sfx"]
    lbad = [f"{r['name']} {r['loudness_db'] - r['loudness_target_db']:+.1f}" for r in sx
            if abs(r["loudness_db"] - r["loudness_target_db"]) > SFX_TOL]
    tbad = [r["name"] for r in sx if r["true_peak_dbtp"] > r["tp_cap_dbtp"] + 1e-9]
    pbad = [f"{r['name']} {r['phone_loss_db']:.1f}" for r in sx
            if r["name"] in FEEDBACK_SFX and r["phone_loss_db"] > PHONE_LOSS_MAX]
    ebad = [f"{r['name']} {r['limiter_energy_gr_db']:.1f}" for r in sx if r["limiter_energy_gr_db"] < -SFX_ENERGY_GR_MAX]
    kbad = [f"{r['name']} {r['in_c_major_pct']:.0f} %" for r in sx
            if r["name"] in PITCHED_CUES and (r["in_c_major_pct"] or 0) < PITCHED_SFX_MIN_IN_KEY]
    out.append("SFX: " + "; ".join([
        chk(f"{len(sx)} files, every loudness within ±{SFX_TOL:.0f} dB of its target"
            + (f" (not: {', '.join(lbad)})" if lbad else ""), not lbad),
        chk(f"every true peak ≤ its ceiling ({SFX_TP_CAP:.0f} dBTP, per-match effects lower)"
            + (f" (not: {', '.join(tbad)})" if tbad else ""), not tbad),
        chk(f"limiter takes ≤ {SFX_ENERGY_GR_MAX:.0f} dB of any effect's energy"
            + (f" (not: {', '.join(ebad)})" if ebad else ""), not ebad),
        chk(f"gameplay feedback loses ≤ {PHONE_LOSS_MAX:.0f} dB on a phone"
            + (f" (not: {', '.join(pbad)})" if pbad else ""), not pbad),
        chk(f"short pitched cues ≥ {PITCHED_SFX_MIN_IN_KEY:.0f} % in key"
            + (f" (not: {', '.join(kbad)})" if kbad else ""), not kbad)]) + ".")
    for dd in man["music"].values():
        dur = {s["samples"] * music.SR // s["sample_rate"] for s in dd["stems"]}
        exact = all(s["samples"] * music.SR % s["sample_rate"] == 0 for s in dd["stems"])
        real = {k: v for k, v in dd["combos"].items() if not k.startswith("all")}
        wtp = max(v["true_peak_dbtp"] for v in real.values())
        wpk = max(v["peak_dbfs"] for v in real.values())
        stp = max(s["true_peak_dbtp"] for s in dd["stems"])
        seams = all(s["seam"]["step_vs_beats"] <= 1.5 and s["seam"]["click_vs_beats"] <= 1.5
                    and s["seam"]["codec_edge"] <= 1.5 for s in dd["stems"])
        quiet = [f"{u['stem']} {u['stem_vs_mix_lu']:+.1f}" for u in dd["unlock"]
                 if u["stem_vs_mix_lu"] is not None and u["stem_vs_mix_lu"] < -UNLOCK_MIN_LU]
        out.append(f"Music `{dd['id']}`: " + "; ".join([
            chk(f"{len(dd['stems'])} stems, identical duration ({dd['loop_samples']} samples at 22.05 kHz)",
                exact and dur == {dd["loop_samples"]}),
            chk(f"worst realistic mix {wtp:.2f} dBTP / {wpk:.2f} dBFS ≤ {MIX_TP_MAX:.1f}",
                wtp <= MIX_TP_MAX and wpk <= MIX_TP_MAX),
            chk(f"no stem above {STEM_TP_MAX} dBTP (max {stp:.2f})", stp <= STEM_TP_MAX),
            chk(f"every unlocked layer within {UNLOCK_MIN_LU:.0f} LU of the mix it joins"
                + (f" (not: {', '.join(quiet)})" if quiet else ""), not quiet),
            chk("seams clean", seams)]) + ".")
    size = man["total_bytes"]
    out.append(chk(f"Total size {size / 1024 / 1024:.2f} MB ≤ 7 MB", size <= SIZE_BUDGET) + ".")
    return out, ok


# ------------------------------------------------------------------ main

def load_decoded(rows):
    return {r["path"]: sf.read(ROOT / r["path"], dtype="float64")[0] for r in rows}


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
    if "music" in parts and args.jobs > 1:
        pool = mp.get_context("fork").Pool(args.jobs)
        pending = pool.map_async(build_district, districts)
    man = {"generator": "tools/audio/gen_audio.py", "format": "Ogg Vorbis, mono", "mixer": MIXER}
    if "notes" in parts:
        nrows, ndec = build_notes()
    else:
        nrows = prev.get("notes", {}).get("files", [])
        dm = load_decoded(nrows)
        ndec = {(r["color"], r["n"]): dm[r["path"]] for r in nrows}
    man["notes"] = {"sample_rate": notes.SR, "scale": "C major pentatonic", "midi": notes.SCALE,
                    "colors": {c: v[0] for c, v in notes.COLORS.items()},
                    "level": {"phone_mmax_lufs": NOTE_TARGET, "true_peak_cap_dbtp": NOTE_TP_CAP},
                    "files": nrows}
    print(f"notes: {len(nrows)} files  ({time.time() - t0:.1f}s)")
    if "sfx" in parts:
        man["sfx"], sdec = build_sfx()
    else:
        man["sfx"] = prev.get("sfx", [])
        dm = load_decoded(man["sfx"])
        sdec = {r["name"]: dm[r["path"]] for r in man["sfx"]}
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
    man["headroom"] = headroom(man, ndec, sdec["clear"])
    print(f"headroom checked  ({time.time() - t0:.1f}s)")

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
    for line in man["checks"]:
        print("  " + line)
    if removed:
        print(f"  removed stale: {', '.join(removed)}")
    print(f"  manifest: {rel(MANIFEST)}   report: {rel(REPORT)}   ({time.time() - t0:.1f}s)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
