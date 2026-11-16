p = 'tools/audio/music.py'
s = open(p, encoding='utf-8', newline='').read()
new = open('.d14tmp/theme.py', encoding='utf-8', newline='').read().replace('\r\n', '\n').replace('\n', '\r\n')
mark = '# ============================================ tension / party (shared)'
assert s.count(mark) == 1
s = s.replace(mark, new + mark)


def rep(a, b, cnt=1):
    global s
    a = a.replace('\n', '\r\n')
    b = b.replace('\n', '\r\n')
    assert s.count(a) == cnt, (a, s.count(a))
    s = s.replace(a, b)


rep('''    "ranch": set(),  # every stem at 22.05 kHz: a washboard, strings and reeds, nothing lives above 10 kHz
''', '''    "ranch": set(),  # every stem at 22.05 kHz: a washboard, strings and reeds, nothing lives above 10 kHz
    "bluesclub": set(),  # every stem at 22.05 kHz: brushes, a dark ride and warm amps, nothing lives above 10 kHz
''')
rep('''        elif name == "ranch":
            k = ranch_kit(sr)
''', '''        elif name == "ranch":
            k = ranch_kit(sr)
        elif name == "bluesclub":
            k = bluesclub_kit(sr)
''')
rep('''            "block": "block", "island": "island", "ranch": "ranch"}''',
    '''            "block": "block", "island": "island", "ranch": "ranch", "bluesclub": "bluesclub"}''', 2)
rep('''    if style == "jazz":
        for i in range(s.beats * 3):''', '''    if style in ("jazz", "bluesclub"):
        for i in range(s.beats * 3):''')
rep('''        elif style == "ranch":  # the bass strings of the guitar, palm-muted, on the chord roots
            x = ins.guitar(m, s.sec(0.3), s.sr, bright=0.55, t60=0.5, pick=0.16, mute=0.04, key=7, damp=0.4)
        else:
            x = ins.pluck_synth(m, s.sr, dur=0.22, cutoff=1500, decay=0.05)
        s.add(pb, x, bt, v)''', '''        elif style == "ranch":  # the bass strings of the guitar, palm-muted, on the chord roots
            x = ins.guitar(m, s.sec(0.3), s.sr, bright=0.55, t60=0.5, pick=0.16, mute=0.04, key=7, damp=0.4)
        elif style == "bluesclub":  # the left hand of the old piano, staccato, on the chord roots, shuffled
            x = upright_piano(m, round(s.sec(0.25), 4), s.sr, vel=0.7, bright=0.8, release=0.06)
            bt = sw8(bt, 1.0 / 3.0)
        else:
            x = ins.pluck_synth(m, s.sr, dur=0.22, cutoff=1500, decay=0.05)
        s.add(pb, x, bt, v)''')
rep('''        s.add(tr, fiddle_note(fifth + 5, hold, s.sr, 0.8, key=4, vib=1.0), 0.0, 0.8)
    else:''', '''        s.add(tr, fiddle_note(fifth + 5, hold, s.sr, 0.8, key=4, vib=1.0), 0.0, 0.8)
    elif style == "bluesclub":  # no synthesizer in the club: the organ holds the fifth of the key, its speaker trembling
        s.add(tr, ins.organ(fifth, round(s.sec(s.beats) - 1.5, 4), s.sr, bars=(0, 0, 8, 5, 0, 3, 0, 0, 0), perc=0.0,
                            click=0.0, attack=0.8, release=0.3), 0.0)
    else:''')
rep('''                hit(s, b, k["spoon_" + drum], o + bt, 0.5 * v, r, 0.002)
        else:''', '''                hit(s, b, k["spoon_" + drum], o + bt, 0.5 * v, r, 0.002)
        elif style == "bluesclub":  # the whole club: the brushes shuffle, the kick and the ride on every beat
            for bt in range(4):
                hit(s, b, k["tap"], o + bt, 0.3, r, 0.003)
                hit(s, b, k["swish"], o + bt + 0.2, 0.14, r, 0.003)
                hit(s, b, k["tap"], o + bt + BT, 0.22, r, 0.003)
                hit(s, b, k["kick"], o + bt, 0.5, r, 0.0)
                hit(s, b, k["ride"], o + bt, 0.26, r, 0.0)
                if bt % 2:
                    hit(s, b, k["ride"], o + bt + BT, 0.15, r, 0.003)
        else:''')
rep('''        if bar in (3, 7):
            for j in range(8):
                hit(s, b, dk["snare"], o + 2 + j * 0.25, 0.3 + 0.06 * j, r, 0.002)''', '''        if bar in (3, 7) and style == "bluesclub":  # the roll into each half in triplets, as everything here
            for j in range(6):
                hit(s, b, dk["snare"], o + 2 + j / 3.0, 0.3 + 0.08 * j, r, 0.002)
        elif bar in (3, 7):
            for j in range(8):
                hit(s, b, dk["snare"], o + 2 + j * 0.25, 0.3 + 0.06 * j, r, 0.002)''')
rep('''                   "block": (0.0, 1.5, 2.0, 3.5)}.get(  # horn stabs: on 1, pushed into 3, on 3, pushed into 1
                       style, (0.5, 1.5, 2.5, 3.5)):''', '''                   "block": (0.0, 1.5, 2.0, 3.5),  # horn stabs: on 1, pushed into 3, on 3, pushed into 1
                   "bluesclub": (0.0, 1 + BT, 2.0, 3 + BT)}.get(  # the horns of a rhythm-and-blues band, shuffled
                       style, (0.5, 1.5, 2.5, 3.5)):''')
rep('''            elif style == "ranch":  # a second banjo runs up the chord, an octave under the glockenspiel's place
                x = banjo_note(m - 12, 0.3, s.sr, 0.9, key=i % 2)
            else:
                x = ins.glock(m, s.sr, vel=0.7, dur=0.8, octave_up=False)
            s.add(arp, x, c.start + i * 0.5, 0.8 if i % 2 == 0 else 0.6)''', '''            elif style == "ranch":  # a second banjo runs up the chord, an octave under the glockenspiel's place
                x = banjo_note(m - 12, 0.3, s.sr, 0.9, key=i % 2)
            elif style == "bluesclub":  # the top of the old piano, an octave under the glockenspiel's place
                x = upright_piano(m - 12, 0.3, s.sr, vel=0.8, bright=1.0, release=0.2)
            else:
                x = ins.glock(m, s.sr, vel=0.7, dur=0.8, octave_up=False)
            at = c.start + i * 0.5
            s.add(arp, x, sw8(at, 1.0 / 3.0) if style == "bluesclub" else at, 0.8 if i % 2 == 0 else 0.6)''')
rep('''        "fiddle": ranch_fiddle, "harmonica": ranch_harmonica}),
}''', '''        "fiddle": ranch_fiddle, "harmonica": ranch_harmonica}),
    "bluesclub": dict(song=bluesclub_song, stems={
        "piano": bluesclub_piano, "bass": bluesclub_bass, "drums": bluesclub_drums, "organ": bluesclub_organ,
        "harmonica": bluesclub_harmonica, "lead": bluesclub_lead}),
}''')
rep('''    "ranch": {"drums": -17, "banjo": -19, "guitar": -19, "claps": -18, "fiddle": -18, "harmonica": -18,
              "tension": -18, "party": -16},
}''', '''    "ranch": {"drums": -17, "banjo": -19, "guitar": -19, "claps": -18, "fiddle": -18, "harmonica": -18,
              "tension": -18, "party": -16},
    "bluesclub": {"piano": -17, "bass": -19, "drums": -18, "organ": -20, "harmonica": -18, "lead": -18,
                  "tension": -18, "party": -16},
}''')
open(p, 'w', encoding='utf-8', newline='').write(s)
print("ok")
