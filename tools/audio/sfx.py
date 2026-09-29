"""Sound effects (44.1 kHz mono).

Each entry of SFX is name -> (render function, loudness target, key, description).
Loudness targets are gated K-weighted dB (dsp.loudness); gen_audio.py reaches
them with a true-peak limiter (ceiling -3 dBTP), so the files have a consistent
perceived balance out of the box (tap/land quiet, drops and fanfares loud).
Tonal effects are written in C (key "C") so the engine may transpose them to the
district key exactly like the piece notes; effects without a key are unpitched
or too short to carry a pitch.

Phone speakers reproduce almost nothing below ~300 Hz, so every low "boom" is
high-passed at 50 Hz, settles on C2 (65.4 Hz, transposed with the key) and
carries 0.3-2 kHz harmonics/body that small speakers can play.
"""
import numpy as np

import dsp
import instruments as ins
from dsp import TAU, midi_hz, nsamp

SR = 44100
PENTA_HI = [84, 86, 88, 91, 93, 96, 98, 100]  # C6..E7, C major pentatonic

# Effects that start together with match notes on (almost) every match get a
# lower true-peak ceiling than the default -3 dBTP, leaving headroom for the
# notes and the music (see gen_audio.MIXER and the headroom check).
TP_CAP = {"clear": -12.0, "land": -9.0}

_IR = {}


def ir(kind):
    if kind not in _IR:
        t60 = {"room": 0.5, "hall": 1.5, "big": 2.6}[kind]
        _IR[kind] = dsp.reverb_ir(SR, t60=t60, predelay=0.01 if kind == "room" else 0.02,
                                  damp_hz=6000, key=f"sfx-{kind}")
    return _IR[kind]


def verb(x, kind="room", wet=0.2):
    return dsp.mix(x, wet * dsp.convolve(x, ir(kind)))


def finish(x, dur, fade_out=0.05):
    y = dsp.pad_to(x, nsamp(dur, SR))
    y = dsp.highpass(y, 25, SR, 2)
    return dsp.fade(y, SR, 0.002, fade_out)


def at(t, x):
    return np.concatenate([np.zeros(nsamp(t, SR)), x]) if t > 0 else x


def tt(n):
    return np.arange(n) / SR


def chirp(f0, f1, dur, shape=1.0):
    """Sine glide f0 -> f1 (exponential)."""
    n = nsamp(dur, SR)
    u = np.linspace(0, 1, n) ** shape
    f = f0 * (f1 / f0) ** u
    return np.sin(TAU * np.cumsum(f) / SR)


def nz(n, key):
    return dsp.rng("sfx", key).standard_normal(n)


def sparkle(dur, count, key, lo=0, hi=None, level=1.0, decay=0.12):
    """Random high pentatonic pings (fairy dust)."""
    r = dsp.rng("sparkle", key)
    hi = hi or len(PENTA_HI)
    out = np.zeros(nsamp(dur + 0.4, SR))
    for i in range(count):
        m = PENTA_HI[r.integers(lo, hi)] + (12 if r.uniform() < 0.3 else 0)
        f = midi_hz(m)
        n = nsamp(0.35, SR)
        p = np.sin(TAU * f * tt(n) + 0.8 * np.exp(-tt(n) / 0.02) * np.sin(TAU * 2.76 * f * tt(n)))
        p *= dsp.env_perc(n, SR, 3.0 * decay * r.uniform(0.7, 1.4), 0.001)
        dsp.place(out, p * r.uniform(0.4, 1.0), nsamp(r.uniform(0, dur), SR))
    return out * level


def whoosh(dur, f0, f1, key, q=1.5, shape=1.0):
    n = nsamp(dur, SR)
    u = np.linspace(0, 1, n)
    fc = f0 * (f1 / f0) ** (u ** shape)
    x = dsp.sweep_filter(nz(n, key), fc, SR, q=q, kind="bp")
    return x * np.sin(np.pi * u) ** 1.5


def thump(f_hi=150, f_lo=60, t60=0.15, click=0.2, key=0):
    return ins.kick(SR, f_hi, f_lo, 0.02, t60, click, 1.2, key=key)


C2 = float(midi_hz(36))


def boom(dur, t60, start=1.8, tau=0.05, drive=1.5, key="boom"):
    """Sub 'boom' that falls from start*C2 and settles on C2 (65.4 Hz), with
    the 2nd-6th harmonics spelled out (what a phone speaker actually plays)
    and high-passed at 50 Hz (nothing below that is audible anywhere, it
    only eats headroom)."""
    n = nsamp(dur, SR)
    t = tt(n)
    f = C2 * (1.0 + (start - 1.0) * np.exp(-t / tau))
    ph = TAU * np.cumsum(f) / SR
    env = dsp.env_perc(n, SR, t60, 0.003)
    x = np.sin(ph) * env
    x = dsp.tube(x * drive, 1.5, SR, 0.2)
    harm = sum(a * np.sin(k * ph + 0.3 * k) for k, a in ((2, 0.45), (3, 0.35), (4, 0.25), (5, 0.18), (6, 0.12)))
    x = x + harm * dsp.env_perc(n, SR, t60 * 0.6, 0.003)
    return dsp.highpass(x, 50, SR, 4)


def body_hit(key, lo=700, hi=2600, tau=0.03, n_s=0.25):
    """Short mid-range 'body' (a snare-like crack) that gives an impact its
    presence on small speakers."""
    n = nsamp(n_s, SR)
    t = tt(n)
    x = dsp.bandpass(nz(n, key), lo, hi, SR) * np.exp(-t / tau)
    return x / dsp.peak(x)


def bells(midis, dur=1.2, strum=0.03, vel=0.8, t60_scale=0.8):
    return dsp.mix(*[at(i * strum, ins.glock(m, SR, vel=vel, dur=dur, octave_up=False, t60_scale=t60_scale))
                     for i, m in enumerate(midis)])


def brass_line(notes, total, key="fan", bright=1.0):
    """Solo synth-brass phrase: notes = (t, dur, midi, vel)."""
    n = nsamp(total, SR)
    src, env, onset = ins.mono_line([(a, b, m, v) for a, b, m, v in notes], n, SR, osc="saw", detune=7.0,
                                    glide=0.02, attack=0.02, release=0.1, vib_rate=5.5, vib_depth=0.18,
                                    vib_delay=0.18, scoop=0.25, key=key)
    x = src * env
    x = dsp.sweep_filter(x, 600 + 3200 * bright * np.clip(0.5 * env + 0.6 * onset, 0, 1.2), SR, q=0.9)
    x = dsp.filt(x, "peak", 1200, SR, q=1.0, gain_db=3.0)
    return dsp.tube(x / dsp.peak(x), 1.3, SR, 0.1)


def formant_chord(midis, dur, vowel="a_alto", attack=0.08, release=0.4, key=0):
    n = nsamp(dur + release, SR)
    r = dsp.rng("fchord", key)
    src = np.zeros(n)
    t = tt(n)
    for m in midis:
        for v in range(3):
            f = midi_hz(m) * 2 ** (r.uniform(-8, 8) / 1200) * (1 + 0.004 * np.sin(TAU * 5.3 * t + r.uniform(0, 6)))
            src += dsp.saw(f, n, SR, r.uniform())
    src += 0.3 * ins.breath(n, SR, f"fc{key}", 800, 6000)
    y = dsp.formant(src, SR, dsp.VOWELS[vowel])
    return y * dsp.env_adsr(n, SR, attack, 0.3, 0.8, dur, release)


# ------------------------------------------------------------ board

def tap():
    # woodblock tuned to G6 (the fifth of C: transposed, it is the fifth of any district key)
    x = ins.woodblock(SR, float(midi_hz(91)), key="tap", t=0.05) * 0.8
    x = dsp.mix(x, 0.3 * dsp.highpass(nz(nsamp(0.004, SR), "tapc"), 3000, SR) * np.linspace(1, 0, nsamp(0.004, SR)))
    return finish(x, 0.07, 0.01)


def swap():
    x = whoosh(0.16, 500, 2600, "swap", q=1.2)
    x = dsp.mix(x / dsp.peak(x), 0.25 * chirp(520, 780, 0.12) * np.sin(np.pi * np.linspace(0, 1, nsamp(0.12, SR))))
    return finish(verb(x, "room", 0.1), 0.2, 0.03)


def swap_fail():
    """Cartoon spring 'boi-oing' G5 -> C5: the pieces bounce back. Pitch
    wobble decays onto the written note, so it reads in key (key C)."""
    def boing(m, dur, depth, rate):
        n = nsamp(dur, SR)
        t = tt(n)
        f = midi_hz(m) * (1 + depth * np.sin(TAU * rate * t) * np.exp(-t / 0.07)) * (1 - 0.1 * np.exp(-t / 0.01))
        ph = TAU * np.cumsum(f) / SR
        s = np.sin(ph) + 0.5 * np.sin(2 * ph + 0.3) + 0.28 * np.sin(3 * ph + 0.6) + 0.14 * np.sin(4 * ph + 0.9)
        return s * dsp.env_perc(n, SR, dur, 0.002)
    knock = dsp.bandpass(nz(nsamp(0.03, SR), "sfk"), 900, 3000, SR) * np.exp(-tt(nsamp(0.03, SR)) / 0.006)
    x = dsp.mix(0.2 * knock / dsp.peak(knock), boing(79, 0.2, 0.05, 17.0), 0.85 * at(0.11, boing(72, 0.26, 0.045, 14.0)))
    x = dsp.filt(x, "peak", 1500, SR, q=0.8, gain_db=2.0)
    return finish(verb(x, "room", 0.1), 0.42, 0.05)


def land():
    x = thump(150, 90, 0.07, 0.0, key="land")
    n = nsamp(0.03, SR)
    # soft plastic 'tock' (unpitched, 0.9-2.8 kHz): what a phone speaker hears of the landing
    tock = dsp.bandpass(nz(n, "landc"), 900, 2800, SR) * np.exp(-tt(n) / 0.006)
    x = dsp.mix(dsp.highpass(x, 80, SR, 2), 1.0 * tock / dsp.peak(tock))
    return finish(dsp.lowpass(x, 5000, SR), 0.12, 0.02)


def clear():
    pop = chirp(900, 1700, 0.03) * np.hanning(nsamp(0.03, SR))
    fizz = dsp.highpass(nz(nsamp(0.12, SR), "clr"), 5000, SR) * np.exp(-tt(nsamp(0.12, SR)) / 0.025)
    x = dsp.mix(pop, 0.35 * fizz, 0.5 * sparkle(0.08, 2, "clear", 3, 7))
    return finish(verb(x, "room", 0.2), 0.32)


def special_create():
    arp = bells([84, 88, 91, 96], dur=0.8, strum=0.035, vel=0.9)
    x = dsp.mix(0.9 * arp / dsp.peak(arp), 0.35 * whoosh(0.3, 400, 6000, "spc", q=1.0, shape=0.7),
                0.5 * thump(120, 55, 0.2, 0.1, key="spc"), 0.35 * at(0.12, sparkle(0.35, 9, "spc")))
    return finish(verb(x, "hall", 0.25), 0.75, 0.12)


# ------------------------------------------------------------ specials

def riff():
    n = nsamp(0.42, SR)
    t = tt(n)
    m = 52 + 24 * (1 - np.exp(-t / 0.09))  # E3 -> E5 slide
    f = midi_hz(m)
    g = 0.7 * dsp.saw(f, n, SR) + 0.3 * dsp.saw(f * 2.003, n, SR, 0.3)
    g *= dsp.env_adsr(n, SR, 0.003, 0.2, 0.7, 0.3, 0.08)
    g = ins.amp_sim(g, SR, gain=10.0, tone=5000)
    pick = dsp.highpass(nz(nsamp(0.01, SR), "pick"), 2000, SR) * np.linspace(1, 0, nsamp(0.01, SR))
    zn = nsamp(0.25, SR)
    zt = tt(zn)
    zap = np.sin(TAU * np.cumsum(3200 * np.exp(-zt / 0.06) + 180) / SR + 3 * np.sin(TAU * 90 * zt))
    zap *= np.exp(-zt / 0.08)
    crackle = dsp.bandpass(nz(zn, "zapc"), 2000, 8000, SR) * (dsp.rng("sfx", "zg").uniform(size=zn) < 0.08)
    x = dsp.mix(g / dsp.peak(g), 0.4 * pick, at(0.14, 0.45 * zap + 0.5 * crackle * np.exp(-zt / 0.1)))
    return finish(verb(x, "room", 0.15), 0.45, 0.06)


def sub():
    k = ins.kick(SR, 170, C2, 0.03, 0.5, 0.45, 1.8, key="subk")
    n = nsamp(0.55, SR)
    t = tt(n)
    b = boom(0.55, 0.9, start=1.6, tau=0.05, drive=2.2)
    # '808' growl on C2, saturated and band-limited to the 150-1200 Hz a phone can play
    ph = TAU * np.cumsum(C2 * (1 + 0.6 * np.exp(-t / 0.05))) / SR
    growl = dsp.bandpass(dsp.tube(np.sin(ph) * 3.0, 2.0, SR, 0.2), 150, 1200, SR) * dsp.env_perc(n, SR, 0.7, 0.004)
    whump = dsp.lowpass(nz(n, "whump"), 500, SR) * np.exp(-t / 0.06)
    punch = body_hit("subp", 600, 2200, 0.018)  # speaker-cone slap
    x = dsp.mix(0.7 * dsp.highpass(k, 50, SR, 2), 0.6 * b, 1.4 * growl / dsp.peak(growl),
                0.3 * whump / dsp.peak(whump), 0.45 * punch)
    x = dsp.filt(x, "peak", 400, SR, q=0.8, gain_db=3)
    return finish(x, 0.55, 0.08)


def bird():
    """Songbird trill. Each chirp drops from at most +1 semitone onto its note
    and holds it for the last ~65 % (so the trill is heard in key)."""
    out = np.zeros(nsamp(0.45, SR))
    r = dsp.rng("sfx", "bird")
    tones = [96, 100, 96, 100, 98, 103]  # C7 E7 C7 E7 D7 G7
    up = 2 ** (1 / 12) - 1
    for i, m in enumerate(tones):
        dur = 0.045 if i < 5 else 0.09
        n = nsamp(dur, SR)
        f0 = midi_hz(m)
        u = np.linspace(0, 1, n)
        if i < 5:
            f = f0 * (1 + up * np.clip(1 - u / 0.35, 0, 1) ** 2)
        else:  # the last chirp scoops up from -1 semitone and holds
            f = f0 * (1 - (1 - 2 ** (-1 / 12)) * np.clip(1 - u / 0.3, 0, 1) ** 2)
        s = np.sin(TAU * np.cumsum(f) / SR) + 0.12 * np.sin(2 * TAU * np.cumsum(f) / SR)
        s *= np.sin(np.pi * u) ** 1.2
        dsp.place(out, s * (0.8 if i < 5 else 1.0), nsamp(i * 0.058 + r.uniform(0, 0.006), SR))
    out = dsp.lowpass(out, 7500, SR, 2)
    return finish(verb(out, "room", 0.15), 0.45, 0.05)


def disco():
    dur = 1.3
    n = nsamp(dur, SR)
    t = tt(n)
    glass = bells([72, 76, 79, 86], dur=dur, strum=0.06, vel=0.6, t60_scale=1.2) * 0.5
    sh = sparkle(1.0, 28, "disco", 2, 8, decay=0.1)
    rot = dsp.bandpass(nz(n, "disco"), 3000, 9000, SR) * (0.5 + 0.5 * np.sin(TAU * 6 * t)) * np.sin(np.pi * t / dur)
    sweep = whoosh(0.5, 800, 8000, "disco2", q=2.0)
    x = dsp.mix(glass, 0.7 * sh / dsp.peak(sh), 0.12 * rot / dsp.peak(rot), 0.25 * sweep / dsp.peak(sweep))
    return finish(verb(x, "hall", 0.3), dur, 0.25)


def combo_drop():
    rise_t = 0.92
    n = nsamp(rise_t, SR)
    u = np.linspace(0, 1, n)
    riser = dsp.sweep_filter(nz(n, "cdr"), 300 * (9000 / 300) ** (u ** 1.3), SR, q=2.0, kind="bp") * u ** 1.3
    tone = dsp.saw(midi_hz(48 + 24 * u ** 1.5), n, SR) * u ** 1.5
    tone = dsp.lowpass(tone, 4000, SR)
    roll = np.zeros(n)
    tb = 0.0
    step = 0.12
    while tb < rise_t - 0.02:
        dsp.place(roll, ins.snare(SR, 220, 0.06, 0.12, 0.9, 1500, 9000, key=int(tb * 100)) * (0.45 + 0.55 * tb / rise_t),
                  nsamp(tb, SR))
        tb += step
        step = max(0.03, step * 0.85)
    up = riser / dsp.peak(riser) * 0.6 + 0.35 * tone / dsp.peak(tone) + 0.5 * roll / dsp.peak(roll)
    dn = nsamp(0.9, SR)
    t = tt(dn)
    b = boom(0.9, 0.9, start=1.9, tau=0.06, drive=1.5)
    # growling C2 bass that 'wubs' twice (8th notes): the resonant filter opens to ~2 kHz on
    # each wub, so the drop has a 0.3-2 kHz 'mouth' that small speakers reproduce
    raw = dsp.saw(C2, dn, SR) + dsp.saw(C2 * 1.006, dn, SR, 0.3) + 0.6 * dsp.pulse(2 * C2, dn, SR, 0.3)
    wub = np.exp(-t / 0.14) + np.exp(-np.maximum(t - 0.3, 0) / 0.14) * (t >= 0.3)
    bass = dsp.sweep_filter(raw, 350 + 1650 * np.minimum(wub, 1.0), SR, q=3.0)
    bass = dsp.highpass(dsp.tube(bass, 2.0, SR) * dsp.env_adsr(dn, SR, 0.004, 0.2, 0.7, 0.6, 0.25), 50, SR, 2)
    stab = dsp.mix(*[ins.supersaw(m, 0.22, SR, attack=0.002, release=0.2, key=i)
                     for i, m in enumerate((60, 64, 67, 72))])  # bright C major stab on each wub
    stab = dsp.sweep_filter(stab, 1200 + 5000 * np.exp(-tt(len(stab)) / 0.1), SR, q=0.9)
    stabs = dsp.mix(stab, 0.85 * at(0.3, stab))
    claps = dsp.mix(ins.clap(SR, key="cd1", tail=0.15), 0.8 * at(0.3, ins.clap(SR, key="cd2", tail=0.15)))
    kick = dsp.highpass(ins.kick(SR, 180, C2, 0.03, 0.5, 0.5, 2.0, key="cdk"), 50, SR, 2)
    drop = dsp.mix(0.65 * b, 0.7 * bass / dsp.peak(bass), 0.6 * stabs / dsp.peak(stabs), 0.45 * kick,
                   0.35 * claps / dsp.peak(claps), 0.35 * body_hit("cdb", 800, 3000, 0.04),
                   0.35 * ins.crash(SR, key="cdc", t60=1.2))
    x = dsp.mix(up, at(rise_t, drop))
    return finish(verb(x, "hall", 0.15), 1.6, 0.25)


def finale():
    dur = 2.8
    n = nsamp(dur, SR)
    t = tt(n)
    b = boom(dur, 1.0, start=1.9, tau=0.08, drive=1.4)
    burst = dsp.lowpass(nz(n, "fin"), 6000, SR) * np.exp(-t / 0.12)
    # the grand C major chord is held at full strength for ~1.4 s (brass, supersaw, choir),
    # over a timpani-style roll on C3: a big moment, not just a big peak
    chord = dsp.mix(*[ins.brass(m, 1.4, SR, vel=0.95, bright=1.2, release=0.6, key=i)
                      for i, m in enumerate((48, 55, 60, 64, 67, 72, 76))])
    pad = dsp.mix(*[ins.supersaw(m, 1.3, SR, attack=0.003, release=0.6, key=i)
                    for i, m in enumerate((64, 67, 72, 76, 79))])
    choir = formant_chord([60, 64, 67, 72], 1.3, "a_sop", attack=0.04, release=0.6, key=11)
    roll = np.zeros(nsamp(1.5, SR))
    for i in range(20):
        dsp.place(roll, ins.tom(SR, float(midi_hz(48)), 0.35, key=f"fr{i % 4}") * (0.9 - 0.03 * i), nsamp(0.06 * i, SR))
    glk = bells([84, 88, 91, 96, 100], dur=2.0, strum=0.05, vel=0.9)
    kick = dsp.highpass(ins.kick(SR, 160, C2, 0.03, 0.7, 0.5, 2.0, key="fink"), 50, SR, 2)
    x = dsp.mix(0.6 * b, 0.3 * burst / dsp.peak(burst), 0.45 * ins.crash(SR, key="finc", t60=2.6),
                0.9 * chord / dsp.peak(chord), 0.6 * pad / dsp.peak(pad), 0.5 * choir / dsp.peak(choir),
                0.3 * dsp.highpass(roll, 60, SR, 2) / dsp.peak(roll), 0.35 * at(0.1, glk / dsp.peak(glk)),
                0.45 * kick, 0.3 * body_hit("finb", 700, 2600, 0.05, 0.4),
                0.25 * ins.snare(SR, 220, 0.12, 0.3, 1.0, 1300, 8000, key="fins"))
    return finish(verb(x, "big", 0.3), dur, 0.6)


# ------------------------------------------------------------ blockers

def box_hit():
    n = nsamp(0.2, SR)
    t = tt(n)
    card = dsp.bandpass(nz(n, "box"), 350, 1400, SR) * np.exp(-t / 0.025)
    knock = np.sin(TAU * 170 * t) * np.exp(-t / 0.03)
    clack = np.sin(TAU * 2400 * t) * np.exp(-t / 0.008)
    x = card / dsp.peak(card) + 0.6 * knock + 0.2 * at(0.012, clack)[:n]
    return finish(verb(x, "room", 0.1), 0.22, 0.04)


def box_break():
    r = dsp.rng("sfx", "boxbreak")
    x = 1.2 * box_hit()
    n = nsamp(0.35, SR)
    t = tt(n)
    tear = dsp.bandpass(nz(n, "tear"), 700, 3200, SR) * (0.3 + (r.uniform(size=n) < 0.3)) * np.exp(-t / 0.12)
    x = dsp.mix(x, 0.5 * at(0.03, dsp.lowpass(tear, 4000, SR) / dsp.peak(tear)))
    for i in range(5):  # records clattering out
        f = r.uniform(1400, 3200)
        m = nsamp(0.05, SR)
        c = np.sin(TAU * f * tt(m)) * np.exp(-tt(m) / 0.01) + 0.4 * np.sin(TAU * f * 1.7 * tt(m)) * np.exp(-tt(m) / 0.006)
        x = dsp.mix(x, 0.25 * r.uniform(0.5, 1) * at(0.09 + i * 0.07 + r.uniform(0, 0.02), c))
    sn = nsamp(0.16, SR)  # a tiny record scratch
    u = np.linspace(0, 1, sn)
    scr = dsp.sweep_filter(nz(sn, "scr"), 900 + 1600 * np.sin(np.pi * u) ** 2, SR, q=4, kind="bp") * np.sin(np.pi * u)
    x = dsp.mix(x, 0.35 * at(0.05, scr / dsp.peak(scr)))
    return finish(verb(x, "room", 0.12), 0.6, 0.08)


def concrete_hit():
    n = nsamp(0.2, SR)
    t = tt(n)
    x = np.sin(TAU * 260 * t) * np.exp(-t / 0.035) + 0.5 * np.sin(TAU * 610 * t) * np.exp(-t / 0.02)
    grit = dsp.bandpass(nz(n, "conc"), 1500, 7000, SR) * np.exp(-t / 0.018)
    x = x + 0.7 * grit / dsp.peak(grit)
    x[: nsamp(0.002, SR)] += 0.5
    return finish(verb(dsp.drive(x * 0.8, 1.5), "room", 0.1), 0.22, 0.04)


def concrete_break():
    r = dsp.rng("sfx", "cbreak")
    n = nsamp(0.9, SR)
    t = tt(n)
    thud = np.sin(TAU * np.cumsum(70 + 60 * np.exp(-t / 0.03)) / SR) * np.exp(-t / 0.12)
    thud = dsp.highpass(thud, 50, SR, 2)
    crunch = dsp.bandpass(nz(n, "crunch"), 500, 4500, SR) * (0.2 + (r.uniform(size=n) < 0.25)) * np.exp(-t / 0.16)
    x = dsp.mix(0.45 * thud, 1.0 * crunch / dsp.peak(crunch), 0.4 * concrete_hit())
    for i in range(16):  # debris
        tb = 0.08 + r.uniform(0, 0.6) ** 1.5
        m = nsamp(0.03, SR)
        f = r.uniform(900, 4000)
        d = dsp.bandpass(nz(m, f"deb{i}"), f * 0.7, f * 1.4, SR) * np.exp(-tt(m) / 0.006)
        x = dsp.mix(x, 0.4 * (1 - tb) * at(tb, d / dsp.peak(d)))
    dust = dsp.bandpass(nz(n, "dust"), 300, 2500, SR) * (1 - np.exp(-t / 0.03)) * np.exp(-t / 0.25)
    x = dsp.mix(x, 0.25 * dust / dsp.peak(dust))
    return finish(verb(x, "room", 0.15), 0.85, 0.12)


def wires_snap():
    n = nsamp(0.4, SR)
    t = tt(n)
    crack = dsp.highpass(nz(nsamp(0.004, SR), "crack"), 1500, SR)
    tw = dsp.saw(1300 * np.exp(-t / 0.12) + 250, n, SR) * np.exp(-t / 0.09)
    tw = dsp.lowpass(tw, 4000, SR)
    buzz = dsp.saw(110, n, SR) * (dsp.rng("sfx", "buzz").uniform(size=n) < 0.6) * np.exp(-t / 0.18)
    buzz = dsp.bandpass(buzz, 300, 3500, SR)
    sparks = dsp.bandpass(nz(n, "spark"), 3000, 9000, SR) * (dsp.rng("sfx", "sp").uniform(size=n) < 0.03) * np.exp(-t / 0.15)
    x = dsp.mix(0.45 * crack, 0.8 * tw / dsp.peak(tw), 0.5 * buzz / dsp.peak(buzz), 0.4 * sparks / (dsp.peak(sparks) + 1e-9))
    return finish(verb(x, "room", 0.1), 0.4, 0.06)


def _fizz(dur, key, lo=2000, hi=7000):
    n = nsamp(dur, SR)
    r = dsp.rng("sfx", key)
    hold = np.repeat(r.standard_normal(n // 12 + 1), 12)[:n]  # sample-and-hold grit
    x = 0.6 * hold + nz(n, key)
    x = dsp.bandpass(x, lo, hi, SR)
    gate = dsp.onepole_lp((r.uniform(size=n) < 0.004).astype(float) * 40, 80, SR) + 0.35
    return x * np.clip(gate, 0, 1.2)


def noise_fizz():
    x = _fizz(0.36, "fizz") * np.sin(np.pi * np.linspace(0, 1, nsamp(0.36, SR))) ** 0.6
    return finish(dsp.lowpass(x, 7000, SR), 0.38, 0.06)


def noise_break():
    n = nsamp(0.3, SR)
    u = np.linspace(0, 1, n)
    fz = _fizz(0.3, "nbreak")
    fz = dsp.sweep_filter(fz, 6000 * (500 / 6000) ** u, SR, q=0.8) * (1 - u) ** 1.5
    ting = bells([88, 91], dur=0.8, strum=0.03, vel=0.8)
    x = dsp.mix(fz / dsp.peak(fz), 0.6 * at(0.16, ting / dsp.peak(ting)), 0.3 * at(0.16, sparkle(0.2, 5, "nb")))
    return finish(verb(x, "room", 0.2), 0.8, 0.12)


def balloon_pop():
    n = nsamp(0.25, SR)
    t = tt(n)
    burst = nz(n, "pop") * np.exp(-t / 0.004)
    body = dsp.bandpass(nz(n, "pop2"), 900, 4000, SR) * np.exp(-t / 0.05)
    rush = dsp.bandpass(nz(n, "pop3"), 1200, 6000, SR) * (1 - np.exp(-t / 0.004)) * np.exp(-t / 0.07)  # air escaping
    whump = np.sin(TAU * 120 * t) * np.exp(-t / 0.04)
    x = 0.5 * burst + 0.9 * body / dsp.peak(body) + 0.6 * rush / dsp.peak(rush) + 0.4 * whump
    return finish(verb(x, "room", 0.15), 0.28, 0.05)


def column_hit():
    n = nsamp(0.4, SR)
    t = tt(n)
    thud = np.sin(TAU * np.cumsum(70 + 40 * np.exp(-t / 0.02)) / SR) * np.exp(-t / 0.08)
    # the dusty cone rattles: a buzzy 72 Hz pulse heard through its 0.4-1.6 kHz 'mouth'
    cone = dsp.bandpass(dsp.pulse(72, n, SR, 0.3), 400, 1600, SR) * np.exp(-t / 0.06)
    knock = dsp.bandpass(nz(n, "colk"), 350, 1500, SR) * np.exp(-t / 0.02)  # cabinet knock
    dust = dsp.bandpass(nz(n, "coldust"), 900, 4000, SR) * (1 - np.exp(-t / 0.02)) * np.exp(-t / 0.1)
    x = (0.8 * thud + 0.6 * cone / dsp.peak(cone) + 0.5 * knock / dsp.peak(knock)
         + 0.3 * dust / dsp.peak(dust))
    x = dsp.highpass(dsp.tube(x, 1.5, SR, 0.2), 50, SR, 2)
    return finish(verb(x, "room", 0.12), 0.4, 0.06)


def column_on():
    click = dsp.bandpass(nz(nsamp(0.01, SR), "relay"), 1000, 6000, SR) * np.linspace(1, 0, nsamp(0.01, SR))
    n = nsamp(0.5, SR)
    u = np.linspace(0, 1, n)
    hum = dsp.saw(midi_hz(36), n, SR)  # C2 hum powering up
    hum = dsp.sweep_filter(hum, 150 + 1500 * u ** 2, SR, q=1.2) * u ** 1.5
    notes = [(0.42, 36), (0.56, 43), (0.7, 48)]
    riff = dsp.mix(*[at(tb, ins.guitar(m, 0.25, SR, bright=0.4, t60=1.0, pick=0.15, mute=0.05, key=1))
                     for tb, m in notes])
    riff = dsp.tube(riff / dsp.peak(riff) * 1.5, 1.4, SR)
    x = dsp.mix(0.6 * click, 0.5 * hum / dsp.peak(hum), riff, 0.35 * at(0.7, sparkle(0.3, 6, "colon", 0, 5)))
    return finish(verb(x, "room", 0.15), 1.1, 0.15)


def floor_light():
    x = bells([91, 96], dur=0.7, strum=0.025, vel=0.7)
    x = dsp.mix(x / dsp.peak(x), 0.25 * sparkle(0.15, 3, "floor", 4, 8))
    return finish(verb(x, "room", 0.2), 0.65, 0.12)


def mic_collect():
    n = nsamp(0.12, SR)
    t = tt(n)
    tapm = np.sin(TAU * 110 * t) * np.exp(-t / 0.03) + 0.3 * dsp.lowpass(nz(n, "mic"), 2000, SR) * np.exp(-t / 0.01)
    ah = dsp.mix(formant_chord([72], 0.12, "a_alto", 0.02, 0.08, key=1),
                 at(0.14, formant_chord([76], 0.3, "a_alto", 0.02, 0.2, key=2)))
    x = dsp.mix(0.6 * tapm, 0.8 * at(0.05, ah / dsp.peak(ah)), 0.3 * at(0.2, sparkle(0.3, 6, "mic")))
    return finish(verb(x, "room", 0.2), 0.8, 0.12)


def goal_done():
    b = bells([72, 76, 79, 86], dur=1.1, strum=0.02, vel=0.9)
    ep = dsp.mix(*[ins.epiano(m, 0.5, SR, vel=0.8, bright=1.0, release=0.4) for m in (60, 64, 67, 74)])
    x = dsp.mix(b / dsp.peak(b), 0.5 * ep / dsp.peak(ep), 0.3 * at(0.05, sparkle(0.5, 8, "goal")))
    return finish(verb(x, "hall", 0.2), 1.1, 0.2)


def moves_low():
    # tick-tock C6 -> G5 (key C: transposed with the district, never clashes with the tension stem)
    a = ins.woodblock(SR, float(midi_hz(84)), key="ml1", t=0.13)
    b = ins.woodblock(SR, float(midi_hz(79)), key="ml2", t=0.13)
    x = dsp.mix(a, 0.85 * at(0.16, b))
    return finish(verb(x, "room", 0.12), 0.36, 0.05)


# ------------------------------------------------------------ results & meta

def win():
    notes = [(0.00, 0.10, 67, 0.8), (0.11, 0.10, 72, 0.85), (0.22, 0.10, 76, 0.9), (0.33, 0.28, 79, 1.0),
             (0.64, 0.12, 76, 0.85), (0.78, 1.0, 84, 1.0)]
    lead = brass_line(notes, 2.0, key="win")
    chord = dsp.mix(*[at(0.78, ins.brass(m, 0.9, SR, vel=0.8, bright=0.9, release=0.35, key=i))
                      for i, m in enumerate((55, 60, 64, 67))])
    roll = np.zeros(nsamp(0.8, SR))
    for i in range(12):
        dsp.place(roll, ins.snare(SR, 230, 0.05, 0.1, 1.0, 1800, 9000, key=i) * (0.2 + 0.05 * i), nsamp(0.22 + i * 0.045, SR))
    x = dsp.mix(lead, 0.35 * chord / dsp.peak(chord), 0.3 * roll / dsp.peak(roll),
                0.35 * at(0.78, ins.crash(SR, key="winc", t60=1.8)), 0.4 * at(0.78, ins.kick(SR, 150, 45, 0.03, 0.4, 0.3, 1.6)),
                0.25 * at(0.8, sparkle(0.9, 14, "win")))
    return finish(verb(x, "hall", 0.22), 2.0, 0.35)


def lose():
    seq = [(0.0, 76), (0.28, 74), (0.56, 72), (0.84, 69)]
    x = dsp.mix(*[at(tb, ins.vibes(m, SR, vel=0.55, dur=1.1, trem=4.5, release=0.5)) for tb, m in seq])
    ch = dsp.mix(*[at(1.12 + 0.03 * i, ins.epiano(m, 0.7, SR, vel=0.45, bright=0.7, release=0.5, t60_scale=0.7))
                   for i, m in enumerate((53, 57, 60, 64))])  # soft Fmaj7: "try again", not sad
    x = dsp.mix(x / dsp.peak(x), 0.55 * ch / dsp.peak(ch))
    x = dsp.lowpass(x, 5000, SR)
    return finish(verb(x, "hall", 0.3), 2.2, 0.4)


def star():
    b = bells([96, 103], dur=0.9, strum=0.04, vel=0.9)
    x = dsp.mix(b / dsp.peak(b), 0.3 * whoosh(0.2, 2000, 9000, "star", q=1.5), 0.35 * at(0.04, sparkle(0.4, 10, "star", 3, 8)))
    return finish(verb(x, "hall", 0.2), 0.85, 0.15)


def coin():
    def ping(m, dur):
        n = nsamp(dur, SR)
        f = midi_hz(m)
        s = 0.6 * dsp.lowpass(dsp.pulse(f, n, SR, 0.5), 5000, SR) + np.sin(TAU * f * tt(n))
        return s * dsp.env_perc(n, SR, dur * 0.9, 0.001)
    x = dsp.mix(0.8 * ping(91, 0.07), at(0.065, ping(96, 0.38)))
    return finish(verb(x, "room", 0.15), 0.45, 0.08)


def chest_open():
    n = nsamp(0.3, SR)
    t = tt(n)
    creak = dsp.saw(160 + 60 * np.sin(TAU * 3 * t), n, SR)
    creak = dsp.bandpass(creak * (0.6 + 0.4 * (np.sin(TAU * 38 * t) > 0)), 400, 2500, SR) * np.sin(np.pi * t / 0.3)
    clunk = thump(200, 90, 0.1, 0.3, key="clunk")
    arp = bells([84, 88, 91, 96, 100], dur=1.1, strum=0.07, vel=0.85)
    choir = formant_chord([60, 64, 67, 72], 0.7, "a_sop", attack=0.25, release=0.5, key=5)
    x = dsp.mix(0.25 * creak / dsp.peak(creak), 0.6 * at(0.28, clunk), 0.7 * at(0.34, arp / dsp.peak(arp)),
                0.35 * at(0.34, choir / dsp.peak(choir)), 0.3 * at(0.5, sparkle(0.8, 16, "chest")))
    return finish(verb(x, "hall", 0.3), 1.6, 0.35)


def button():
    x = 0.8 * chirp(850, 1150, 0.04) * dsp.env_perc(nsamp(0.04, SR), SR, 0.04, 0.001)
    return finish(verb(x, "room", 0.08), 0.09, 0.02)


def shuffle():
    r = dsp.rng("sfx", "shuffle")
    x = np.zeros(nsamp(0.8, SR))
    for i in range(11):
        tb = i * 0.055 + r.uniform(0, 0.01)
        w = whoosh(0.07, 800 + 180 * i, 3000 + 400 * i, f"sh{i}", q=1.5)
        c = ins.woodblock(SR, 900 + 90 * i, key=i, t=0.03) * 0.3
        dsp.place(x, w / dsp.peak(w) * 0.7 + dsp.pad_to(c, len(w)), nsamp(tb, SR))
    x = dsp.mix(x, 0.4 * at(0.62, bells([91], dur=0.3, vel=0.6)))
    return finish(verb(x, "room", 0.12), 0.85, 0.1)


def booster():
    n = nsamp(0.45, SR)
    u = np.linspace(0, 1, n)
    s = dsp.saw(midi_hz(60 + 12 * u ** 1.4), n, SR) + dsp.saw(midi_hz(60.1 + 12 * u ** 1.4), n, SR, 0.4)
    s = dsp.sweep_filter(s, 300 + 5000 * u ** 2, SR, q=2.0) * u ** 1.2
    x = dsp.mix(0.6 * s / dsp.peak(s), at(0.44, 0.6 * thump(170, 60, 0.2, 0.3, key="bst")),
                at(0.44, 0.6 * bells([84, 91], dur=0.5, vel=0.9)), 0.4 * at(0.44, sparkle(0.25, 8, "bst")))
    return finish(verb(x, "hall", 0.18), 0.95, 0.15)


def unlock():
    n = nsamp(0.7, SR)
    u = np.linspace(0, 1, n)
    rise = dsp.sweep_filter(nz(n, "unl"), 400 * (8000 / 400) ** u, SR, q=2.0, kind="bp") * u ** 2
    run = bells([72, 74, 76, 79, 81, 84, 86, 88], dur=0.5, strum=0.07, vel=0.7)
    hitc = bells([84, 88, 91, 96], dur=1.0, strum=0.012, vel=1.0)
    x = dsp.mix(0.45 * rise / dsp.peak(rise), 0.6 * at(0.15, run / dsp.peak(run)), 0.9 * at(0.72, hitc / dsp.peak(hitc)),
                0.45 * at(0.72, sparkle(0.6, 18, "unl")), 0.4 * at(0.72, thump(150, 60, 0.25, 0.2, key="unl")))
    return finish(verb(x, "hall", 0.25), 1.5, 0.3)


# ------------------------------------------------------------ praise stingers

def praise_1():  # juicy
    x = dsp.mix(ins.epiano(79, 0.1, SR, vel=0.9, release=0.2), at(0.09, ins.epiano(84, 0.25, SR, vel=0.95, release=0.35)))
    x = dsp.mix(x / dsp.peak(x), 0.25 * at(0.1, sparkle(0.2, 4, "p1")))
    return finish(verb(x, "room", 0.2), 0.65, 0.12)


def praise_2():  # hit
    stab = [(0.0, 60), (0.07, 64), (0.14, 67)]
    x = dsp.mix(*[at(tb, ins.brass(m + 12, 0.08, SR, vel=0.9, key=i)) for i, (tb, m) in enumerate(stab)])
    ch = dsp.mix(*[at(0.24, ins.brass(m, 0.3, SR, vel=1.0, bright=1.1, key=i)) for i, m in enumerate((60, 64, 67, 72))])
    x = dsp.mix(x / dsp.peak(x), 0.9 * ch / dsp.peak(ch), 0.5 * at(0.24, ins.snare(SR, 200, 0.1, 0.2, 0.9, key=7)),
                0.4 * at(0.24, ins.kick(SR, key=3)))
    return finish(verb(x, "room", 0.2), 0.85, 0.15)


def praise_3():  # drive
    n = nsamp(0.25, SR)
    u = np.linspace(0, 1, n)
    rise = dsp.sweep_filter(nz(n, "p3"), 600 * (7000 / 600) ** u, SR, q=2.0, kind="bp") * u ** 2
    pc = dsp.mix(*[ins.guitar(m, 0.55, SR, bright=0.8, t60=2.5, key=j) for j, m in enumerate((48, 55, 60, 67))])
    pc = ins.amp_sim(pc / dsp.peak(pc), SR, gain=9.0, tone=5000)
    x = dsp.mix(0.4 * rise / dsp.peak(rise), at(0.24, pc / dsp.peak(pc)), 0.7 * at(0.24, ins.kick(SR, 160, 48, key=9)),
                0.4 * at(0.24, ins.crash(SR, key="p3", t60=1.2)))
    return finish(verb(x, "room", 0.18), 1.0, 0.2)


def praise_4():  # vibe
    ss = dsp.mix(*[ins.supersaw(m, 0.6, SR, attack=0.005, release=0.3, key=i) for i, m in enumerate((60, 64, 67, 71, 74))])
    n = len(ss)
    ss = dsp.sweep_filter(ss, 600 + 5000 * (1 - np.exp(-tt(n) / 0.12)), SR, q=1.2)
    vox = formant_chord([67, 72, 76], 0.5, "a_sop", attack=0.05, release=0.4, key=4)
    claps = dsp.mix(ins.clap(SR, key=1), at(0.28, ins.clap(SR, key=2)))
    x = dsp.mix(0.8 * ss / dsp.peak(ss), 0.5 * vox / dsp.peak(vox), 0.4 * claps / dsp.peak(claps),
                0.3 * at(0.1, sparkle(0.5, 10, "p4")))
    return finish(verb(x, "hall", 0.25), 1.2, 0.3)


def praise_5():  # legend
    run = [(0.0, 0.09, 60, 0.8), (0.1, 0.09, 64, 0.85), (0.2, 0.09, 67, 0.9), (0.3, 0.9, 72, 1.0)]
    lead = brass_line(run, 1.5, key="p5", bright=1.1)
    ch = dsp.mix(*[at(0.3, ins.brass(m, 0.8, SR, vel=0.9, release=0.4, key=i)) for i, m in enumerate((48, 55, 60, 64, 67))])
    vox = formant_chord([60, 64, 67, 72], 0.8, "a_sop", attack=0.1, release=0.5, key=9)
    roll = np.zeros(nsamp(0.35, SR))
    for i in range(8):
        dsp.place(roll, ins.snare(SR, 230, 0.05, 0.1, 1.0, key=20 + i) * (0.3 + 0.1 * i), nsamp(i * 0.037, SR))
    x = dsp.mix(0.9 * lead, 0.55 * ch / dsp.peak(ch), 0.45 * at(0.3, vox / dsp.peak(vox)), 0.35 * roll / dsp.peak(roll),
                0.5 * at(0.3, ins.crash(SR, key="p5c", t60=1.8)), 0.6 * at(0.3, ins.kick(SR, 160, 42, 0.03, 0.6, 0.4, 2.0)),
                0.3 * at(0.35, sparkle(1.0, 20, "p5")))
    return finish(verb(x, "hall", 0.28), 1.7, 0.35)


# name -> (fn, loudness target, key, description)
SFX = {
    "tap": (tap, -26, "C", "touch tick (woodblock G6)"),
    "swap": (swap, -24, None, "swap whoosh"),
    "swap_fail": (swap_fail, -22, "C", "cartoon spring boing G5-C5"),
    "land": (land, -28, None, "soft landing thump + plastic tock"),
    "clear": (clear, -24, None, "pop + fizz + pings"),
    "special_create": (special_create, -18, "C", "bell arpeggio + whoosh"),
    "riff": (riff, -16, None, "guitar glissando E3-E5 + electric zap"),
    "sub": (sub, -15, "C", "kick + sub boom settling on C2, cone slap"),
    "bird": (bird, -20, "C", "songbird trill C7-E7-D7-G7"),
    "disco": (disco, -18, "C", "mirror-ball shimmer"),
    "combo_drop": (combo_drop, -14, "C", "riser, then C2 bass drop + bright stab at 0.92 s"),
    "finale": (finale, -13, "C", "huge impact + C major brass/orchestra hit/bells tail"),
    "box_hit": (box_hit, -21, None, "cardboard thud"),
    "box_break": (box_break, -18, None, "box bursts, records clatter, tiny scratch"),
    "concrete_hit": (concrete_hit, -20, None, "stone knock"),
    "concrete_break": (concrete_break, -17, None, "crumble + debris"),
    "wires_snap": (wires_snap, -19, None, "crack + twang + buzz"),
    "noise_fizz": (noise_fizz, -23, None, "static fizz"),
    "noise_break": (noise_break, -19, "C", "static dissolves into a bell"),
    "balloon_pop": (balloon_pop, -17, None, "pop"),
    "column_hit": (column_hit, -19, None, "dusty speaker thump + cone rattle"),
    "column_on": (column_on, -16, "C", "relay click, hum powers up, bass riff"),
    "floor_light": (floor_light, -20, "C", "chime G6+C7"),
    "mic_collect": (mic_collect, -17, "C", "mic tap + vocal 'ah-ha' C5-E5"),
    "goal_done": (goal_done, -16, "C", "bright Cadd9 chord"),
    "moves_low": (moves_low, -18, "C", "tick-tock warning C6-G5"),
    "win": (win, -14, "C", "2 s brass fanfare G4-C5-E5-G5-C6"),
    "lose": (lose, -19, "C", "gentle descending vibes E5-D5-C5-A4, soft Fmaj7"),
    "star": (star, -17, "C", "star ding C7+G7"),
    "coin": (coin, -18, "C", "coin G6-C7"),
    "chest_open": (chest_open, -16, "C", "creak, clunk, bells, choir"),
    "button": (button, -22, None, "UI blip"),
    "shuffle": (shuffle, -19, None, "board shuffle flurry"),
    "booster": (booster, -16, "C", "power-up riser + hit"),
    "unlock": (unlock, -15, "C", "task completed: riser, run, sparkle chord"),
    "praise_1": (praise_1, -17, "C", "'Juicy!' two-note e-piano"),
    "praise_2": (praise_2, -16, "C", "'Hit!' brass arpeggio + stab"),
    "praise_3": (praise_3, -15, "C", "'Drive!' riser + power chord + crash"),
    "praise_4": (praise_4, -15, "C", "'Vibe!' supersaw Cmaj9 + choir + claps"),
    "praise_5": (praise_5, -13, "C", "'Legend!' brass run, choir, drums, sparkles"),
}
