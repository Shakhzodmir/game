import json

p = 'tools/audio/songs.py'
s = open(p, encoding='utf-8', newline='').read()
new = open('.d14tmp/songs_sec.py', encoding='utf-8', newline='').read().replace('\r\n', '\n').replace('\n', '\r\n')
mark = '# ============================================================ registry'
assert s.count(mark) == 1
s = s.replace(mark, new + mark)
a = '''                        {"drums": -20, "keys": -20, "lead": -18, "guitar": -24, "bass": -21.5}),
}'''.replace('\n', '\r\n')
b = '''                        {"drums": -20, "keys": -20, "lead": -18, "guitar": -24, "bass": -21.5}),
    # bluesclub (E major)
    "riverside_jump": ("I6:4 IV6:4 I6:4 I6:4 IV6:4 IV6:4 I6:4 I6:4 V7:4 IV6:4 I6:2 IV6:2 I6:2 V7:2", riverside_jump,
                       {"drums": -17, "bass": -19, "keys": -23, "brass": -20, "sax": -18.5}),
    "lamplight_piano": ("I6:4 IV6:4 I6:4 V7:4 I6:4 IV6:4 ii7:2 V7:2 I6:4", lamplight_piano,
                        {"drums": -25, "keys": -20, "lead": -18, "bass": -22, "trumpet": -23}),
    "paddle_wheel_shuffle": ("I:4 I:4 IV:4 I:4 V7:4 V7:4 I:4 I:4 IV:4 I:4 V7:4 I:4", paddle_wheel_shuffle,
                             {"drums": -20, "guitar": -20, "bass": -19, "lead": -18, "trumpet": -20.5, "fx": -28}),
    "lantern_stroll": ("I6:4 vi7:4 IV6:4 V7:4 I6:4 vi7:4 IV6:4 V7:4 IV6:4 I6:4 V7:4 I6:2 V7:2", lantern_stroll,
                       {"drums": -18.5, "bass": -19, "sax": -22, "guitar": -21, "brass": -22, "lead": -18.5}),
}'''.replace('\n', '\r\n')
assert s.count(a) == 1
s = s.replace(a, b)
open(p, 'w', encoding='utf-8', newline='').write(s)

p = 'content/districts.json'
raw = open(p, encoding='utf-8', newline='').read()
d = json.loads(raw)
assert json.dumps(d, indent=2, ensure_ascii=False) + "\n" == raw.replace('\r\n', '\n'), "no exact round trip"
blues = d['districts'][-1]
assert blues['id'] == 'bluesclub' and blues['songs'] == []
blues['songs'] = [
    {"id": "riverside_jump", "name": {"ru": "Джамп у реки", "en": "Riverside Jump", "ko": "강변 점프"},
     "bpm": 152, "bars": 12,
     "mood": "fast jump blues for dancing: a ride and a fat backbeat shuffle, a walking upright bass, the old piano hammering short chords, a horn section riffing and shouting, a honking tenor sax tune"},
    {"id": "lamplight_piano", "name": {"ru": "Пианино под лампой", "en": "Lamplight Piano", "ko": "등불 아래 피아노"},
     "bpm": 72, "bars": 8,
     "mood": "slow late-night piano blues in triplets: soft right-hand chords, low octaves in the left, the tune in octaves with crushed notes, brushes, an upright bass in two, a muted trumpet answering from far away"},
    {"id": "paddle_wheel_shuffle", "name": {"ru": "Шаффл на пароходе", "en": "Paddle Wheel Shuffle", "ko": "외륜선 셔플"},
     "bpm": 120, "bars": 12,
     "mood": "riverboat shuffle: a washboard with a thimble backbeat, banjo plucks, a tuba on root and fifth, a clarinet tune answered by a cornet, the whistle of the steamer"},
    {"id": "lantern_stroll", "name": {"ru": "Прогулка под фонарями", "en": "Lantern Stroll", "ko": "가로등 아래 스트롤"},
     "bpm": 108, "bars": 12,
     "mood": "rhythm-and-blues stroll in 12/8: hi-hat triplets and a clapped backbeat, the stroll bass figure doubled by a baritone sax, a tremolo guitar picking triplets, horn swells and shouts, a lazy tenor sax tune"},
]
out = (json.dumps(d, indent=2, ensure_ascii=False) + "\n").replace('\n', '\r\n')
open(p, 'w', encoding='utf-8', newline='').write(out)
print('ok')
