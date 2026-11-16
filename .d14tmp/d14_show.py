import json
import sys

m = json.load(open('assets/sounds/manifest.json', encoding='utf-8'))
d = m['music']['bluesclub']
print('chords', d['chords'], 'loop', d['loop_seconds'], d['exact_seconds'])
tot = 0
for s in d['stems']:
    tot += s['bytes']
    print('%-10s %6d B sr %5d lufs %6.1f tp %6.2f harm %s centroid %s seam %s' % (
        s['stem'], s['bytes'], s['sample_rate'], s['lufs'], s['true_peak_dbtp'], s['harmony_in_scale_pct'], s['centroid_hz'],
        s['seam']))
print('district bytes', tot, round(tot / 1024 / 1024, 3), 'MB')
print('combos', json.dumps(d['combos']))
print('tension/party delta', d['tension_delta_lu'], d['party_delta_lu'])
for u in d['unlock']:
    print('unlock', u)
print('key', json.dumps(d['key_reading']))
print('brightness', d['brightness'], 'mix_seam', d['mix_seam'])
print('headroom', json.dumps(m['headroom']))
print('total', m['total_bytes'], 'counts', m['counts'])
sb = sum(v['bytes'] for v in m['songs'].values())
print('base MB', (m['total_bytes'] - sb) / 1024 / 1024, 'songs MB', sb / 1024 / 1024)
gen = {g['id'] for g in json.load(open('content/genres.json', encoding='utf-8'))['genres']}
print('district songs MB', sum(v['bytes'] for v in m['songs'].values() if v['genre'] not in gen) / 1024 / 1024)
for sid in sys.argv[1:]:
    v = m['songs'][sid]
    print(sid, {k: v[k] for k in ('bpm', 'bars', 'loop_seconds', 'bytes', 'lufs', 'true_peak_dbtp', 'limiter_gr_db',
                                  'limiter_energy_gr_db', 'harmony_in_scale_pct', 'harmony_in_scale_full_mix_pct',
                                  'key_reading', 'seam', 'parts', 'chords')})
