# ============================================================ BLUES CLUB (E)
# The club beyond its evening shuffle (music.py: the old upright piano, the brush kit, the amplified harmonica, the
# electric bass through the tube amp). Four other kinds of blues, none of them the theme or a song of the genre
# "blues" of songs_rnb.py (also in E: a 112 BPM twelve-bar with piano comping and a clean guitar, a stomp with a
# slide guitar, a slow 12/8 for a harmonica over an organ bed): riverside_jump is a fast jump blues for a horn
# section and a honking tenor sax, lamplight_piano a slow late-night piano blues in triplets with a muted trumpet
# far away, paddle_wheel_shuffle a riverboat shuffle (banjo, washboard, tuba, a clarinet and a cornet, the whistle
# of the steamer), lantern_stroll a rhythm-and-blues stroll (the bass figure doubled by a baritone sax, a guitar
# in triplets, horns, a lazy tenor sax). All of it "major blues": sixth chords on I and IV, the dominant seventh
# only on V (its seventh belongs to the key), tunes on the major pentatonic with the sixth; the only blue notes
# are crushed notes of the piano, a twentieth of a second long.

BT = 2.0 / 3.0  # the swung off-beat: the third triplet of the beat


def v_old(s, m, d, v=0.7, bright=0.85, rel=0.12):
    """The old upright piano of the club."""
    return M.upright_piano(m, round(s.sec(d), 3), s.sr, vel=round(v, 2), bright=bright, release=rel)


def v_ebass(s, m, d, v=0.8):
    return ins.guitar(m, s.sec(d), s.sr, bright=0.32, t60=1.5, pick=0.12, mute=0.06, key=m % 2, damp=0.45) * v


def amp_bass(s, b):
    """The electric bass through the tube amp of the club: round, a little warm drive."""
    b = loop_eq(s, loop_filter(s, b, "lp", 1500), "peak", 700, 3.0, 1.0)
    b = dsp.loop_apply(b / dsp.peak(b) * 1.4, lambda z: dsp.tube(z, 1.3, s.sr, 0.1))
    return room(s, b, 0.06, 0.7, "bass", damp=2500)


def riverside_jump(s):
    """152 BPM jump blues, a twelve-bar with a quick change: a ride and a fat backbeat shuffle, an upright bass
    walks four to the bar, the old piano hammers short chords on the shuffle, a horn section riffs ('bap ba-daa')
    and shouts through the last four bars, a tenor sax honks the tune."""
    r = dsp.rng(s.id, "jump")
    t, ch = s.tonic, s.chords
    k = kits(s, "jazz", "bluesclub")
    d = s.zeros()
    hits(s, d, k["ride"], "x..x.xx..x.x", r, gain=0.4, jit=0.004)
    hits(s, d, k["snare"], {"*": "...X.....X..", 3: "...X.....X.x", 7: "...X..x..X.x", 11: "...X..x.xX.x"}, r, gain=0.7)
    hits(s, d, k["kick"], "X..o..x..o.o", r, gain=0.8)
    hits(s, d, k["hat"], "...x.....x..", r, gain=0.35)
    hits(s, d, k["crash"], {0: "X...........", 8: "X..........."}, r, gain=0.4)
    d = room(s, d, 0.1, 0.8, "drums", damp=6000)
    bass = s.zeros()
    for beat, m, v in walk(s, lo=38, hi=55, seed="jump"):
        s.add(bass, v_upright(s, m, 0.9, v), beat, dt=float(r.normal(0, 0.004)))
    bass = loop_filter(s, bass, "lp", 1800)
    pno = comp(s, ch, voicing(ch, 59, 75, 67, no_root, span=12),
               lambda c, i: [(q + off, 0.22, 0.62 if off == 0 else 0.5) for q in range(int(c.dur)) for off in (0.0, BT)],
               lambda ss, m, du, v: v_old(ss, m, du, v, rel=0.06), r=r, jit=0.003, spread=0.003)
    pno = room(s, loop_filter(s, pno, "hp", 180), 0.12, 0.8, "piano", damp=5500)

    def riff(c, i):
        if c.dur < 4:
            return [(0, 0.3, 0.8), (1 + BT, 0.3, 0.7)]
        if i >= 8:  # the shout chorus
            return [(0, 0.3, 0.85), (BT, 0.3, 0.7), (2, 0.3, 0.85), (2 + BT, 0.9, 0.8)]
        return [(1, 0.25, 0.8), (1 + BT, 0.25, 0.7), (2 + BT, 0.9, 0.8)]
    br = comp(s, ch, voicing(ch, 60, 77, 69, triad, span=12), riff, v_brass, r=r, jit=0.004)
    br = room(s, br, 0.16, 1.0, "horns", damp=5000)
    tn = tune("1:.5 3:.5 5:1 6:.5 5:.5 3:1 | 4:.5 6:.5 1+:1 6:.5 4:.5 6:1 | 1+:1.5 6:.5 5:1 3:1 |"
              " 5:.5 6:.5 5:.5 3:.5 1:2 | 4:.5 4:.5 r:.5 4:.5 6:1 1+:1 | 2+:.5 1+:.5 6:.5 4:.5 6:2 |"
              " 1:.5 3:.5 5:.5 6:.5 1+:1 3+:1 | 2+:.5 1+:.5 6:.5 5:.5 3:2 | 5:.5 7:.5 2+:1 4+:.5 2+:.5 7:1 |"
              " 1+:.5 6:.5 4:.5 6:.5 1+:1 6:1 | 5:.5 3:.5 1:1 4:.5 6:.5 1+:1 | 1+:1 5:1 7:.5 5:.5 2:1", t, 4)
    sax = room(s, mono(s, tn, "sax", swing=0.33, key="jump"), 0.16, 1.0, "sax", damp=4500)
    return {"drums": d, "bass": bass, "keys": pno, "brass": br, "sax": sax}


def lamplight_piano(s):
    """72 BPM slow piano blues, late at night: the right hand of the old upright keeps soft chords going in
    triplets, the left plays low octaves on one and three and steps into the next chord, the tune sings on top
    in octaves (a crushed note before every long one), brushes sweep, an upright bass plays in two and a muted
    trumpet answers from the far end of the room."""
    r = dsp.rng(s.id, "lamplight")
    t, ch = s.tonic, s.chords
    k = kits(s, "bluesclub")
    d = s.zeros()
    for bar in range(s.bars):
        for bt in range(4):
            s.add(d, ins.brush_swish(s.sr, s.sec(0.9), key=(bar * 4 + bt) % 5), bar * 4 + bt, 0.2)
    hits(s, d, k["tap"], "g.gx.gg.gx.g", r, gain=0.6, jit=0.004)
    hits(s, d, k["kick"], "o.....o.....", r, gain=0.5)
    d = room(s, d, 0.16, 1.2, "brushes", damp=5500)
    rh = comp(s, ch, voicing(ch, 59, 73, 66, no_root, span=12),
              lambda c, i: [(q + j / 3.0, 0.3, (0.5, 0.36, 0.42)[j]) for q in range(int(c.dur)) for j in range(3)],
              lambda ss, m, du, v: v_old(ss, m, du, v, bright=0.7, rel=0.1), r=r, jit=0.004, spread=0.004)

    def left(c, n, i):
        R = root_of(c, 43, 40, 51)
        ap = scale_step(t, root_of(n, 43, 40, 51), False)
        if c.dur < 4:
            return [(0, 1.6, R, 0.8), (1 + BT, 0.4, ap, 0.55)]
        return [(0, 1.8, R, 0.85), (2, 1.5, R + 7, 0.7), (3 + BT, 0.4, ap, 0.55)]
    lh = line(s, ch, left, lambda ss, m, du, v: v_old(ss, m, du, v, 0.7) + 0.7 * v_old(ss, m + 12, du, v, 0.7), r=r,
              jit=0.004)
    keys = room(s, loop_filter(s, lh / dsp.peak(lh) + 0.8 * rh / dsp.peak(rh), "hp", 70), 0.2, 1.5, "keys", damp=4500)
    tn = tune("r:1 3:2/3 5:1/3 6:2 | 1+:1 6:2/3 4:1/3 6:2 | 5:2/3 6:1/3 1+:1 3+:2/3 2+:1/3 1+:1 |"
              " 7:1 2+:2/3 7:1/3 5:2 | r:1 3:2/3 5:1/3 1+:1 3+:1 | 4+:1 3+:2/3 1+:1/3 6:2 |"
              " 2+:2/3 1+:1/3 6:1 7:2/3 5:1/3 2+:1 | 1+:3 r:1", t, 4)
    top = s.zeros()
    for b, du, m, v in tn:
        j = float(r.normal(0, 0.004))
        s.add(top, v_old(s, m, du, v, 0.9, 0.2), b, dt=j)
        s.add(top, v_old(s, m + 12, du, v * 0.6, 0.9, 0.2), b, dt=j + 0.006)
        if du >= 2.0:  # the crushed note: a semitone below, a twentieth of a second early
            s.add(top, v_old(s, m - 1, 0.08, 0.4, 0.9, 0.03), b, dt=j - 0.055)
    top = room(s, loop_filter(s, top, "hp", 200), 0.22, 1.6, "top", damp=5000, predelay=0.02)

    def two(c, n, i):
        R = root_of(c, 40, 36, 47)
        F = R + 7 if R + 7 <= 50 else R - 5
        return [(0, 1.8, R, 0.85), (2, 1.8, F, 0.7)] if c.dur >= 4 else [(0, 1.8, R, 0.85)]
    bass = room(s, loop_filter(s, line(s, ch, two, v_upright, r=r), "lp", 1000), 0.08, 0.8, "bass", damp=2500)
    tp = tune("r:4 | r:3 1+:2/3 6:1/3 | r:4 | r:2 5:2/3 7:1/3 2+:1 | r:4 | r:2 6:2/3 1+:1/3 4+:1 | r:4 | r:4", t, 4)
    trp = mono(s, tp, "trumpet", key="lamplight")
    trp = loop_eq(s, loop_filter(s, trp, "lp", 2400), "peak", 1300, 4.0, 1.5)  # a cup mute
    trp = room(s, echo(s, trp, 1.0, 0.12, 0.3, 2, 2200), 0.3, 1.8, "tpt", damp=3500, predelay=0.03)
    return {"drums": d, "keys": keys, "lead": top, "bass": bass, "trumpet": trp}


def steam_whistle(s, spots, notes=(64, 68, 71)):
    """The whistle of a river steamer: three pipes on the tonic triad, breathy, every toot sliding up into pitch.
    spots = [(beat, beats)]."""
    buf = s.zeros()
    for i, (beat, beats) in enumerate(spots):
        n = nsamp(s.sec(beats) + 0.2, s.sr)
        tt = np.arange(n) / s.sr
        x = np.zeros(n)
        for j, m in enumerate(notes):
            f = midi_hz(m - 0.6 * np.exp(-tt / 0.05))
            x += dsp.sine(f, n, s.sr, 0.1 * j) + 0.3 * dsp.sine(2.0 * f, n, s.sr, 0.3 + 0.1 * j)
        env = dsp.env_adsr(n, s.sr, 0.05, 0.1, 0.9, s.sec(beats), 0.12)
        steam = ins.breath(n, s.sr, f"{s.id}/whistle{i}", 1500, 5000)
        x = (x / dsp.peak(x) + 0.35 * steam / (dsp.peak(steam) + 1e-9)) * env
        s.add(buf, dsp.fade(x / dsp.peak(x), s.sr, 0.003, 0.03), beat)
    return buf


def paddle_wheel_shuffle(s):
    """120 BPM riverboat shuffle: a washboard shuffles with a thimble on two and four, a banjo plucks the chord
    on the backbeats and its swung off-beats, a tuba plays root and fifth and walks into the new chord, a
    clarinet has the tune and a cornet answers at the ends of its phrases; the steamer toots as the tune comes
    round."""
    r = dsp.rng(s.id, "paddle")
    t, ch = s.tonic, s.chords
    k = kits(s, "ranch", "bluesclub")
    d = s.zeros()
    hits(s, d, k["wash"], "x.ox.ox.ox.o", r, gain=0.45, jit=0.003)
    hits(s, d, k["wash_acc"], "...x.....x..", r, gain=0.6, jit=0.003)
    hits(s, d, k["kick"], "X.....x.....", r, gain=0.7)
    hits(s, d, k["spoon_hi"], {3: ".........x.x", 7: "......x..x.x", 11: "...x..x..x.x"}, r, gain=0.3)
    d = room(s, d, 0.1, 0.7, "perc", damp=6000)
    bj = comp(s, ch, voicing(ch, 59, 74, 66, triad, span=12),
              [(1, 0.2, 0.8), (1 + BT, 0.15, 0.55), (3, 0.2, 0.8), (3 + BT, 0.15, 0.55)], v_banjo, r=r, jit=0.003,
              spread=0.012)
    bj = room(s, bj, 0.1, 0.7, "banjo", damp=6500)
    tb = []
    for i, c in enumerate(ch):
        nxt = ch[(i + 1) % len(ch)]
        R = root_of(c, 40, 36, 47)
        F = R + 7 if R + 7 <= 47 else R - 5
        tb += [(c.start, 0.7, R, 0.9), (c.start + 2, 0.7, F, 0.8)]
        if nxt.root != c.root:
            tb.append((c.start + 3, 0.6, scale_step(t, root_of(nxt, 40, 36, 47), False), 0.75))
    tuba = loop_filter(s, mono(s, tb, "tuba", key="paddle"), "lp", 1400)
    tn = tune("5:.5 6:.5 1+:1 3+:.5 1+:.5 6:1 | 5:.5 3:.5 5:.5 6:.5 1+:2 | 6:.5 1+:.5 4+:1 2+:.5 1+:.5 6:1 |"
              " 5:.5 6:.5 5:.5 3:.5 1:2 | 2:.5 4:.5 5:.5 7:.5 2+:1 7:1 | 4+:.5 2+:.5 7:.5 5:.5 7:2 |"
              " 3:.5 5:.5 1+:.5 5:.5 3+:1 1+:1 | 2+:.5 1+:.5 6:.5 5:.5 3:1 r:1 | 4:.5 6:.5 1+:.5 6:.5 4+:1 1+:1 |"
              " 3+:.5 2+:.5 1+:.5 6:.5 5:2 | 7:.5 2+:.5 4+:.5 2+:.5 7:.5 5:.5 4:.5 2:.5 | 1:1 3:.5 5:.5 1+:1 r:1", t, 4)
    cl = room(s, mono(s, tn, "clarinet", swing=0.33, key="paddle"), 0.16, 1.0, "clarinet", damp=5000)
    tp = tune("r:4 | r:3 5:.5 6:.5 | r:4 | r:2 3:.5 5:.5 1+:1 | r:4 | r:3 2+:.5 4+:.5 | r:4 | r:3 5:.5 7:.5 |"
              " r:4 | r:3 3+:.5 5+:.5 | r:4 | r:3 5:1", t, 4)
    cornet = room(s, loop_filter(s, mono(s, tp, "trumpet", swing=0.33, key="paddle"), "lp", 3600), 0.2, 1.1, "cornet",
                  damp=4500)
    toot = room(s, loop_filter(s, steam_whistle(s, [(s.beats - 1.0, 0.35), (0.0, 1.3)]), "lp", 5000), 0.3, 1.6, "toot",
                damp=4000)
    return {"drums": d, "guitar": bj, "bass": tuba, "lead": cl, "trumpet": cornet, "fx": toot}


def lantern_stroll(s):
    """108 BPM rhythm-and-blues stroll in 12/8 over I - vi - IV - V: hi-hat triplets, a brushed backbeat with
    hand claps, the stroll figure (root, root, third, fifth) on an electric bass doubled an octave up by a
    baritone sax, a clean guitar picks the chord in triplets through a tremolo, the horns swell at the end of
    every other bar and shout in the last four, a tenor sax takes its time over the tune."""
    r = dsp.rng(s.id, "stroll")
    t, ch = s.tonic, s.chords
    k = kits(s, "lofi", "bluesclub")
    d = s.zeros()
    hits(s, d, k["hat"], "xgoxgoxgoxgo", r, gain=0.3, jit=0.003)
    hits(s, d, k["kick"], "X.....x..o..", r, gain=0.8)
    hits(s, d, k["slap"], "...X.....X..", r, gain=0.8)
    hits(s, d, k["clap"], "...x.....x..", r, gain=0.4)
    hits(s, d, k["tap"], {3: ".........xxx", 7: ".........xxx", 11: "......xxxxxx"}, r, gain=0.5)
    d = room(s, loop_filter(s, d, "lp", 9000), 0.12, 0.9, "drums", damp=5500)

    def stroll(c, n, i):
        R = root_of(c, 43, 40, 51)
        third = R + (3 if 3 in c.tones else 4)
        if c.dur < 4:
            return [(0, 0.9, R, 0.9), (1, 0.9, R + 7, 0.8)]
        return [(0, 1.5, R, 0.95), (1 + BT, 0.3, R, 0.6), (2, 0.9, third, 0.85), (3, 0.9, R + 7, 0.8)]
    bass = amp_bass(s, line(s, ch, stroll, v_ebass, r=r, jit=0.003))
    bari_ev = []
    for i, c in enumerate(ch):
        for bt, du, m, v in stroll(c, None, i):
            bari_ev.append((c.start + bt, min(du, 0.6), m + 12, v))
    bari = room(s, loop_filter(s, mono(s, bari_ev, "sax", key="bari"), "lp", 1800), 0.12, 0.9, "bari", damp=4000)
    gt = s.zeros()
    for c, v in zip(ch, voicing(ch, 57, 73, 65, triad, span=12)):
        for q in range(int(c.dur)):
            for j in range(3):
                m = v[j] if q % 2 == 0 else v[2 - j]
                x = ins.guitar(m, s.sec(0.6), s.sr, bright=0.6, t60=1.2, pick=0.18, mute=0.05, key=j, damp=0.4)
                s.add(gt, x, c.start + q + j / 3.0, 0.8 if j == 0 else 0.6, dt=float(r.normal(0, 0.003)))
    gt = gt * (1.0 - 0.3 * (0.5 + 0.5 * s.lfo(5.5)))
    gt = room(s, loop_filter(s, gt, "hp", 150), 0.2, 1.3, "gtr", damp=4500)

    def horns(c, i):
        if c.dur < 4:
            return [(0, 0.3, 0.8)]
        if i >= 8:
            return [(0, 0.3, 0.85), (1 + BT, 0.3, 0.75), (2, 1.6, 0.8)]
        return [(2 + BT, 1.2, 0.7)] if i % 2 == 1 else []
    br = room(s, comp(s, ch, voicing(ch, 62, 78, 70, no_root, span=12), horns, v_brass, r=r, jit=0.004), 0.18, 1.1,
              "horns", damp=4500)
    tn = tune("3:1.5 5:.5 1+:2 | 6:1.5 1+:.5 3+:2 | 4+:1 3+:.5 1+:.5 6:2 | 7:1 2+:.5 7:.5 5:1 r:1 |"
              " 3:1.5 5:.5 1+:1 3+:1 | 5+:1.5 3+:.5 1+:2 | 6:.5 1+:.5 4+:1 2+:.5 1+:.5 6:1 | 7:.5 2+:.5 4+:1 2+:1 r:1 |"
              " 1+:1 6:.5 4:.5 6:2 | 5:.5 6:.5 1+:1 3+:1 1+:1 | 2+:1.5 7:.5 5:1 7:1 | 1+:2 r:2", t, 4)
    sax = room(s, echo(s, mono(s, tn, "sax", swing=0.33, key="stroll"), 1.0, 0.1, 0.3, 2, 2500), 0.22, 1.4, "sax",
               damp=4000)
    return {"drums": d, "bass": bass, "sax": bari, "guitar": gt, "brass": br, "lead": sax}


