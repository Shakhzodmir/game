p = 'tools/audio/music.py'
s = open(p, encoding='utf-8', newline='').read()
def rep(a, b):
    global s
    a = a.replace('\n', '\r\n'); b = b.replace('\n', '\r\n')
    assert s.count(a) == 1, a
    s = s.replace(a, b)
rep('''            s.add(lh, upright_piano(R, du, s.sr, vel=v, bright=0.7, release=0.1), o + bt, 1.0, dt=dt)
            s.add(lh, upright_piano(up, du, s.sr, vel=round(v * 0.9, 2), bright=0.7, release=0.1), o + bt, 1.0, dt=dt + 0.003)''',
'''            s.add(lh, upright_piano(R, du, s.sr, vel=v, bright=0.9, release=0.1), o + bt, 0.85, dt=dt)
            s.add(lh, upright_piano(up, du, s.sr, vel=v, bright=0.9, release=0.1), o + bt, 1.0, dt=dt + 0.003)''')
rep('''        s.add(lh, upright_piano(m, round(s.sec(0.45), 4), s.sr, vel=v, bright=0.7, release=0.1), 12 + bt, 1.0, dt=dt)
        s.add(lh, upright_piano(m + 12, round(s.sec(0.45), 4), s.sr, vel=round(v * 0.8, 2), bright=0.7, release=0.1),
              12 + bt, 1.0, dt=dt + 0.003)''',
'''        s.add(lh, upright_piano(m, round(s.sec(0.45), 4), s.sr, vel=v, bright=0.9, release=0.1), 12 + bt, 0.85, dt=dt)
        s.add(lh, upright_piano(m + 12, round(s.sec(0.45), 4), s.sr, vel=v, bright=0.9, release=0.1),
              12 + bt, 1.0, dt=dt + 0.003)''')
rep('''    lh = loop_filter(s, lh, "hp", 60)
    b = lh / dsp.peak(lh) + 0.6 * rh / dsp.peak(rh)
    b = loop_eq(s, b, "peak", 2500, 2.0, 0.9)''',
'''    lh = loop_filter(s, lh, "hp", 90)  # what a phone cannot play of the left hand is taken out, its overtones lifted
    b = lh / dsp.peak(lh) + 0.85 * rh / dsp.peak(rh)
    b = loop_eq(s, loop_eq(s, b, "peak", 1500, 4.0, 0.7), "peak", 3000, 2.0, 0.9)''')
rep('''"harmonica": -18, "lead": -18,
                  "tension": -18, "party": -16},''', '''"harmonica": -18, "lead": -17.5,
                  "tension": -18, "party": -16},''')
open(p, 'w', encoding='utf-8', newline='').write(s)
