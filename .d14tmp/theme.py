# ================================================ BLUES CLUB (E major)

BT = 2.0 / 3.0  # the swung off-beat of the shuffle: the third triplet of the beat


def bluesclub_song(d):
    # cozy evening blues in E, 96 BPM, a shuffle: a twelve-bar blues folded into eight bars, I - I - IV - I,
    # V - IV - I - (I V). It is a MAJOR blues: sixth chords on I and IV (E6, A6: the boogie sixth instead of the
    # flat seventh, so every chord tone is on the E major scale) and one real dominant, B7, whose seventh (A)
    # belongs to the key. The blue notes are only touched: grace notes of the piano and bends of the harmonica and
    # the guitar that start a semitone low and are in tune a tenth of a second later.
    # The jazz club (Bb) swings altered ninth chords with a sax, the garage (also E) is straight rock on triads,
    # the ranch harmonica answers a fiddle high up in G; the songs of the genre "blues" are a 112 BPM twelve-bar
    # with a clean guitar, a stomp with a slide guitar and a slow 12/8 with an organ bed.
    E, A, B = 4, 9, 11
    six, dom = [0, 4, 7, 9], [0, 4, 7, 10]
    return Song(d, progression([
        (4, E, six, "E6"), (4, E, six, "E6"), (4, A, six, "A6"), (4, E, six, "E6"),
        (4, B, dom, "B7"), (4, A, six, "A6"), (4, E, six, "E6"), (2, E, six, "E6"), (2, B, dom, "B7"),
    ]))


def upright_piano(midi, dur, sr, vel=0.7, bright=0.75, release=0.12):
    """The old upright of the club: the two strings of every note have drifted a few cents apart (a slow warm
    beat, far from the sour honky-tonk of the ranch), the hammers are a little hard."""
    def mk():
        a = ins.piano(midi - 0.03, dur, sr, vel=vel, bright=bright, release=release, key=0)
        b = ins.piano(midi + 0.04, dur, sr, vel=vel, bright=bright, release=release, key=1)
        return a + 0.7 * b
    return cached(("upright_piano", midi, round(dur, 4), sr, round(vel, 2), bright, release), mk)


def blues_harp(midi, dur, sr, vel=0.8, key=0, bend=0.0, bend_t=0.09, wah=4.2):
    """A blues harmonica cupped round a bullet microphone into a small tube amp: two reeds a few cents apart,
    dark and nasal (a peak near 1 kHz, nothing above 3 kHz), driven by the amp. A draw note may be bent: it starts
    `bend` semitones low and is in tune after `bend_t` seconds; a held note gets a throat vibrato and the hands
    open and close over it (`wah` times a second)."""
    def mk():
        n = nsamp(dur + 0.1, sr)
        t = np.arange(n) / sr
        r = dsp.rng("bluesharp", midi, key)
        u = np.clip(t / bend_t, 0.0, 1.0)
        off = -bend * (1.0 - u * u * (3.0 - 2.0 * u))
        vib = 0.12 * np.clip((t - 0.25) / 0.2, 0.0, 1.0) * np.sin(TAU * 5.0 * t + r.uniform(0, TAU))
        f = midi_hz(midi + off + vib)
        x = dsp.pulse(f * 2 ** (4 / 1200), n, sr, 0.3, r.uniform()) + dsp.pulse(f * 2 ** (-4 / 1200), n, sr, 0.34, r.uniform())
        x = dsp.highpass(x, 250, sr, 2)
        x = dsp.filt(x, "peak", 1000, sr, q=1.2, gain_db=6.0)
        x = dsp.filt(x, "peak", 2400, sr, q=1.5, gain_db=3.0)
        x = dsp.lowpass(x, 3200, sr, 2)
        env = dsp.env_adsr(n, sr, 0.025, 0.1, 0.85, dur, 0.06)
        hands = 1.0 - 0.4 * np.clip((t - 0.18) / 0.2, 0.0, 1.0) * (0.5 - 0.5 * np.cos(TAU * wah * t))
        x = x * env * hands + 0.08 * ins.breath(n, sr, f"bluesharp{midi}{key}", 1500, 4000) * env
        x = dsp.tube(x / dsp.peak(x) * 2.2, 1.6, sr, 0.15)
        return dsp.fade(x / dsp.peak(x), sr, 0.002, 0.02) * vel
    return cached(("bluesharp", midi, round(dur, 3), sr, round(vel, 2), key, bend, bend_t, wah), mk)


def bluesclub_kit(sr):
    """A club kit played with brushes, made for 22.05 kHz: brush taps and a brushed backbeat on the snare (its
    body on E3), short sweeps, a soft kick that settles on E2, a dark ride, the foot hi-hat and a small splash."""
    unit = lambda x: x / dsp.peak(x)  # noqa: E731
    k = {}
    k["tap"] = [unit(ins.brush_tap(sr, key=800 + i, dur=0.1, tone=float(midi_hz(52)))) for i in range(4)]
    k["slap"] = [unit(dsp.lowpass(ins.snare(sr, float(midi_hz(52)), 0.08, 0.14, 0.6, 1200, 6000, key=810 + i), 7000, sr))
                 for i in range(3)]
    k["swish"] = [unit(ins.brush_swish(sr, 0.16, key=820 + i)) for i in range(3)]
    k["kick"] = [unit(dsp.lowpass(ins.kick(sr, 110.0, float(midi_hz(40)), 0.025, 0.3, 0.05, 1.2, key=830 + i), 1500, sr))
                 for i in range(2)]
    k["ride"] = [unit(dsp.lowpass(ins.ride(sr, key=840 + i, t60=1.5, bell=0.35), 9500, sr, 2)) for i in range(3)]
    k["hat"] = [unit(dsp.lowpass(ins.hat(sr, 0.035, key=850 + i, lo=3500, tone=0.6), 9500, sr, 2)) for i in range(3)]
    k["crash"] = [dsp.lowpass(ins.crash(sr, key=83, t60=1.5), 9500, sr, 2)]
    return k


# The left hand of the boogie, E2-G#3: the root with its fifth, then with its sixth, two swung 8ths each ('chunk-a
# chunk-a'); a walk up the scale in octaves into the dominant. The right hand, G#4-D#5: light three-note chords.
BLUES_RH = {"E6": (68, 71, 73), "A6": (66, 69, 73), "B7": (66, 69, 75)}
BLUES_COMP = {  # bar (or 'a' / 'b' for the even / odd bars) -> (beat, beats, vel, with a crushed note)
    "a": [(1.0, 0.3, 0.55, False), (2 + BT, 0.5, 0.62, True)],
    "b": [(BT, 0.3, 0.5, False), (2.0, 0.3, 0.55, False), (3 + BT, 0.45, 0.6, True)],
    3: [(1.0, 0.3, 0.55, False)],
    7: [(1.0, 0.3, 0.55, True), (2.0, 0.3, 0.6, False), (3.0, 0.3, 0.55, False), (3 + BT, 0.3, 0.6, False)],
}
BLUES_TINKLE = [(2.0, 88), (2 + 1 / 3, 85), (2 + 2 / 3, 83), (3.0, 80), (3 + 1 / 3, 83), (3 + 2 / 3, 85)]  # bar 4, high up
BLUES_WALKUP = [(2.0, 40), (2 + BT, 42), (3.0, 44), (3 + BT, 45)]  # bar 4: E F# G# A, into B


def bluesclub_piano(s):
    """Boogie shuffle on the old upright: the left hand rolls the root with its fifth and its sixth on the swung
    8ths (and walks up the scale in octaves into the dominant), the right hand drops light three-note chords
    between its accents, some of them with a crushed note (the minor third slipping up into the major one), and
    tinkles a triplet figure high up before the second half. Alone it already says the key, the chords and the
    shuffle."""
    r = dsp.rng(s.id, "piano")
    lh = s.zeros()
    for bar in range(s.bars):
        o = bar * 4
        for q in range(8):
            bt = q // 2 + (BT if q % 2 else 0.0)
            if bar == 3 and bt >= 2.0:
                continue
            c = s.chord_at(o + bt)
            R = nearest(c.root, 43, 40, 51)
            up = R + (7 if (q // 2) % 2 == 0 else 9)
            v = 0.8 if q % 2 == 0 else 0.55
            du = round(s.sec(0.6 if q % 2 == 0 else 0.3), 4)
            dt = r.normal(0, 0.003)
            s.add(lh, upright_piano(R, du, s.sr, vel=v, bright=0.7, release=0.1), o + bt, 1.0, dt=dt)
            s.add(lh, upright_piano(up, du, s.sr, vel=round(v * 0.9, 2), bright=0.7, release=0.1), o + bt, 1.0, dt=dt + 0.003)
    for bt, m in BLUES_WALKUP:
        dt = r.normal(0, 0.003)
        v = 0.82 if bt % 1 == 0 else 0.66
        s.add(lh, upright_piano(m, round(s.sec(0.45), 4), s.sr, vel=v, bright=0.7, release=0.1), 12 + bt, 1.0, dt=dt)
        s.add(lh, upright_piano(m + 12, round(s.sec(0.45), 4), s.sr, vel=round(v * 0.8, 2), bright=0.7, release=0.1),
              12 + bt, 1.0, dt=dt + 0.003)
    rh = s.zeros()
    for bar in range(s.bars):
        o = bar * 4
        pat = BLUES_COMP.get(bar, BLUES_COMP["a" if bar % 2 == 0 else "b"])
        for bt, du, v, crushed in pat:
            c = s.chord_at(o + bt)
            notes = BLUES_RH[c.name]
            dt = r.normal(0, 0.004)
            for j, m in enumerate(notes):
                s.add(rh, upright_piano(m, round(s.sec(du), 4), s.sr, vel=v, bright=0.85, release=0.1), o + bt, 1.0,
                      dt=dt + j * 0.005)
            if crushed:  # the blue third of the chord, a 20th of a second before the major third takes its place
                third = [m for m in notes if (m - c.root) % 12 == 4]
                m = (third[0] if third else nearest((c.root + 4) % 12, 70, 64, 76)) - 1
                s.add(rh, upright_piano(m, 0.05, s.sr, vel=0.4, bright=0.85, release=0.03), o + bt, 1.0, dt=dt - 0.05)
    for bt, m in BLUES_TINKLE:
        s.add(rh, upright_piano(m, round(s.sec(0.3), 4), s.sr, vel=0.45, bright=0.9, release=0.15), 12 + bt, 0.8,
              dt=r.normal(0, 0.004))
    lh = loop_filter(s, lh, "hp", 60)
    b = lh / dsp.peak(lh) + 0.6 * rh / dsp.peak(rh)
    b = loop_eq(s, b, "peak", 2500, 2.0, 0.9)
    return room(s, b, 0.14, 1.0, "piano", damp=5000)


# The walking bass, E2-F#3, four to the bar: up the E6 chord and down again, up the A6, down the scale to the
# dominant, round the B7, up the scale from A into the top of the E, and E - G# - B - D# to turn round. bar -> midi
BLUES_WALK = {
    0: (40, 44, 47, 49), 1: (52, 49, 47, 44), 2: (45, 49, 52, 54), 3: (52, 51, 49, 47),
    4: (47, 51, 54, 51), 5: (45, 47, 49, 51), 6: (52, 47, 49, 44), 7: (40, 44, 47, 51),
}
BLUES_SKIPS = (1, 3, 6)  # bars whose last beat is played twice, the second time on the swung off-beat


def bluesclub_bass(s):
    """A walking bass on an electric bass guitar through the tube amp (round, a little warm drive): a note on
    every beat, the first and the third leaning in, and a soft swung skip note before some bar lines."""
    b = s.zeros()
    r = dsp.rng(s.id, "bass")
    for bar, notes in BLUES_WALK.items():
        for q, m in enumerate(notes):
            x = ins.guitar(m, s.sec(0.88), s.sr, bright=0.32, t60=1.5, pick=0.12, mute=0.06, key=q % 2, damp=0.45)
            s.add(b, x, bar * 4 + q, 0.92 if q % 2 == 0 else 0.8, dt=r.normal(0.003, 0.003))
        if bar in BLUES_SKIPS:
            x = ins.guitar(notes[3], s.sec(0.25), s.sr, bright=0.32, t60=0.6, pick=0.12, mute=0.04, key=2, damp=0.45)
            s.add(b, x, bar * 4 + 3 + BT, 0.4, dt=r.normal(0.003, 0.003))
    b = loop_eq(s, loop_filter(s, b, "lp", 1500), "peak", 700, 3.0, 1.0)
    b = dsp.loop_apply(b / dsp.peak(b) * 1.4, lambda z: dsp.tube(z, 1.3, s.sr, 0.1))
    return room(s, b, 0.06, 0.7, "bass", damp=2500)


def bluesclub_drums(s):
    """Brushes: the shuffle is tapped on the snare (the beat and the swung off-beat, the middle triplet swept),
    a brushed backbeat on two and four, a soft kick on one and three, and a lazy ride that only marks the beats,
    a touch behind them; three triplet taps lead into each half."""
    k = kit("bluesclub", s.sr)
    r = dsp.rng(s.id, "drums")
    b = s.zeros()
    for bar in range(s.bars):
        o = bar * 4
        fill = bar in (3, 7)
        for bt in range(4):
            hit(s, b, k["tap"], o + bt, 0.5, r, 0.003)
            hit(s, b, k["tap"], o + bt + BT, 0.34, r, 0.004)
            if not (fill and bt == 3):
                hit(s, b, k["swish"], o + bt + 0.2, 0.22, r, 0.004)
            hit(s, b, k["ride"], o + bt + 0.022, 0.42 if bt % 2 else 0.3, r, 0.004)
        for bt in (1, 3):
            hit(s, b, k["slap"], o + bt, 0.85, r, 0.003)
            hit(s, b, k["hat"], o + bt, 0.3, r, 0.002)
        hit(s, b, k["kick"], o, 0.85, r, 0.002)
        hit(s, b, k["kick"], o + 2, 0.7, r, 0.002)
        if bar % 2 == 1:
            hit(s, b, k["kick"], o + 3 + BT, 0.45, r, 0.003)
            hit(s, b, k["ride"], o + 3 + BT + 0.022, 0.2, r, 0.004)
        if fill:
            for j, v in enumerate((0.45, 0.6, 0.75)):
                hit(s, b, k["tap"], o + 3 + j / 3.0, v, r, 0.003)
            hit(s, b, k["slap"], o + 3 + BT, 0.5, r, 0.003)
    return room(s, b, 0.14, 1.0, "drums", damp=6000)


BLUES_PAD = {"E6": (59, 64, 68), "A6": (61, 64, 69), "B7": (59, 63, 69)}  # B3-A4: the soft bed
BLUES_STAB = {"E6": (68, 73, 76), "A6": (69, 73, 78), "B7": (69, 75, 78)}  # G#4-F#5: the short chords


def bluesclub_organ(s):
    """A tonewheel organ: soft held chords under everything through a slow rotary speaker, and short percussive
    stabs on top: 'da-daa' on four and its swung off-beat in every other bar, one push in the bars between."""
    pad = s.zeros()
    r = dsp.rng(s.id, "organ")
    for c in s.chords:
        for m in BLUES_PAD[c.name]:
            x = ins.organ(m, round(s.sec(c.dur) - 0.05, 4), s.sr, bars=(6, 0, 8, 4, 0, 2, 0, 0, 0), perc=0.0, click=0.0,
                          attack=0.18, release=0.3)
            s.add(pad, x, c.start - 0.05)
    pad = leslie(s, pad, 0.8, 0.3)
    st = s.zeros()
    for bar in range(s.bars):
        o = bar * 4
        for bt, du, v in (((3.0, 0.2, 0.7), (3 + BT, 0.45, 0.85)) if bar % 2 == 0 else ((1 + BT, 0.3, 0.75),)):
            c = s.chord_at(o + bt)
            dt = r.normal(0, 0.003)
            for m in BLUES_STAB[c.name]:
                x = ins.organ(m, round(s.sec(du), 4), s.sr, bars=(6, 4, 8, 6, 0, 3, 0, 0, 0), perc=0.3, click=0.25,
                              attack=0.005, release=0.04)
                s.add(st, x, o + bt, v, dt=dt)
    st = leslie(s, st, 6.0, 0.2)
    b = pad / dsp.peak(pad) + 0.8 * st / dsp.peak(st)
    b = dsp.loop_apply(b / dsp.peak(b) * 1.5, lambda z: dsp.tube(z, 1.2, s.sr, 0.1))
    b = loop_filter(s, loop_filter(s, b, "hp", 120), "lp", 3200)
    return room(s, b, 0.2, 1.3, "organ", damp=4000)


# The harmonica tune, E4-F#5, singable: 'da-da DAAA, da-daa' on E (the long E bent up into), the same from A, a
# third higher on the dominant, a sigh on A, then all the way up the E chord, down again and home on a long low E
# that is bent up from the leading note. It breathes in the second half of every other bar: there the guitar
# answers. bar -> (beat, beats, midi[, bend in semitones])
BLUES_HARP = bars({
    0: [(0.0, BT, 71), (BT, 1 / 3, 73), (1.0, 1.5, 76, 1.0), (2 + BT, 1 / 3, 73), (3.0, 0.9, 71)],
    1: [(0.0, 1.0, 68, 1.0), (1.0, 0.8, 64)],
    2: [(0.0, BT, 69), (BT, 1 / 3, 73), (1.0, 1.5, 76, 1.0), (2 + BT, 1 / 3, 78), (3.0, 0.9, 76)],
    3: [(0.0, BT, 73), (BT, 1 / 3, 71), (1.0, 0.9, 68, 1.0)],
    4: [(0.0, BT, 71), (BT, 1 / 3, 75), (1.0, 1.5, 78, 1.0), (2 + BT, 1 / 3, 75), (3.0, 0.9, 71)],
    5: [(0.0, 1.0, 73, 1.0), (1.0, 0.8, 69)],
    6: [(0.0, BT, 64), (BT, 1 / 3, 68), (1.0, BT, 71), (1 + BT, 1 / 3, 73), (2.0, 1.0, 76, 1.0), (3.0, BT, 73),
        (3 + BT, 1 / 3, 71)],
    7: [(0.0, 1.9, 64, 1.0)],
})


def bluesclub_harmonica(s):
    """The harmonica sings the tune through its little amp: the long notes are draw notes bent up into (they
    start a semitone low and are in tune a tenth of a second later), held with a throat vibrato and the hands
    opening; under a long note the next hole of the chord sounds too."""
    b = s.zeros()
    r = dsp.rng(s.id, "harmonica")
    for e in BLUES_HARP:
        bt, du, m = e[:3]
        bend = e[3] if len(e) > 3 else 0.0
        v = 0.9 if bt % 1 == 0 else 0.76
        d = round(s.sec(du) * 0.95, 4)
        s.add(b, blues_harp(m, d, s.sr, round(v, 2), key=0, bend=bend, bend_t=0.1), bt, 1.0, dt=r.normal(0, 0.003))
        if du >= 1.0:
            pcs = s.chord_at(bt).pcs()
            under = [x for x in range(m - 9, m - 2) if x % 12 in pcs]
            if under:
                s.add(b, blues_harp(under[-1], d, s.sr, round(v * 0.45, 2), key=1), bt, 1.0, dt=0.012 + r.normal(0, 0.003))
    b = loop_filter(s, b, "hp", 220)
    b = echo(s, b / dsp.peak(b), 1.0, 0.1, 0.3, 2, 2500)
    return room(s, b, 0.2, 1.3, "harmonica", damp=4000, predelay=0.02)


# The guitar answers where the harmonica breathes (the second halves of bars 2, 4, 6 and 8): down the E6 chord,
# a triplet up it and a whole-tone bend into the top, down the A6 chord, and the turnaround up the B7. The long
# notes are bent up into (from a semitone or a tone below). bar -> (beat, beats, midi[, vel, opts])
BLUES_GTR = bars({
    1: [(2.0, BT, 76, 0.85), (2 + BT, 1 / 3, 73, 0.7), (3.0, 0.9, 71, 0.85, {"bend": 1.0})],
    3: [(2.0, 1 / 3, 71, 0.75), (2 + 1 / 3, 1 / 3, 73, 0.75), (2 + 2 / 3, 1 / 3, 76, 0.8),
        (3.0, 0.9, 80, 0.9, {"bend": 2.0, "bend_t": 0.12})],
    5: [(2.0, BT, 81, 0.85), (2 + BT, 1 / 3, 78, 0.7), (3.0, BT, 76, 0.8), (3 + BT, 1 / 3, 73, 0.7)],
    7: [(2.0, BT, 71, 0.8), (2 + BT, 1 / 3, 75, 0.75), (3.0, 0.9, 78, 0.9, {"bend": 2.0, "bend_t": 0.12})],
})
BLUES_CHIPS = {"E6": (59, 68), "A6": (61, 69), "B7": (63, 71)}  # sixths: the third of the chord and its root above


def bluesclub_lead(s):
    """A clean electric guitar on the neck pickup through the same small amp (a slow tremolo, a short slap echo):
    it answers the harmonica with licks whose long notes are bent up into, and while the harmonica sings it only
    chips a muted sixth on two and four."""
    src, env, onset = render_line(s, events(s, BLUES_GTR), osc="saw", glide=0.004, legato_gap=0.004, attack=0.003,
                                  release=0.07, vib_rate=5.2, vib_depth=0.14, vib_delay=0.3, key="bluesgtr")
    x = src * env * (0.3 + 0.7 * np.clip(onset, 0, 1))
    x = dsp.lowpass(dsp.highpass(x, 200, s.sr, 2), 2800, s.sr, 2)
    licks = wrap(s, x / dsp.peak(x))
    chips = s.zeros()
    r = dsp.rng(s.id, "lead")
    for bar in (0, 2, 4, 6):
        for bt, v in ((1.0, 0.5), (3.0, 0.42)):
            c = s.chord_at(bar * 4 + bt)
            y = ins.strum(BLUES_CHIPS[c.name], s.sec(0.2), s.sr, spread=0.008, bright=0.5, t60=0.4, pick=0.16, mute=0.03,
                          key=bar % 2, damp=0.4)
            s.add(chips, y, bar * 4 + bt, v, dt=r.normal(0, 0.003))
    b = licks + 0.5 * chips / dsp.peak(chips)
    b = dsp.loop_apply(b / dsp.peak(b), lambda z: ins.amp_sim(z, s.sr, gain=2.2, tone=3600, key_hz=1800))
    b = b * (1.0 - 0.22 * (0.5 + 0.5 * s.lfo(4.8)))
    b = echo(s, b / dsp.peak(b), 1 / 3, 0.2, 0.2, 2, 2800)
    return room(s, b, 0.18, 1.2, "lead", damp=4500)


