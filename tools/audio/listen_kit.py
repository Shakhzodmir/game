#!/usr/bin/env python3
"""Listening kit: the district music of GLOW as MP3 files for the producer's ears.

    python tools/audio/listen_kit.py OUT_DIR                      # Part 2 districts + 3 parents + jukebox songs
    python tools/audio/listen_kit.py OUT_DIR --districts sunset_bossa --parents none --no-songs   # one district
    python tools/audio/listen_kit.py OUT_DIR --volume 1.0         # the music slider at its maximum
    python tools/audio/listen_kit.py --help

Run it again after any re-render of tools/audio/gen_audio.py: it reads the shipped files (assets/music/<district>/
*.ogg and assets/music/songs/*.ogg), so the kit always sounds like the game. It writes into OUT_DIR:

  NN_<id>_town_complete.mp3     all the task stems together: a finished town (audio.music(district))
  NN_<id>_concert.mp3           the same + the party layer: the finale concert and the theme of a finished district
                                picked in the jukebox (audio.music(district, {all = true}), client/songs.lua). The
                                game never plays the tension layer together with the party layer (the mixer contract,
                                assets/sounds/manifest.json -> mixer), so neither does the kit.
  NN_<id>_last_moves.mp3        all the task stems + the tension layer: a level with 5 moves or fewer left in a finished
                                town. In a level the game plays the music quieter (music_in_level_db of the mixer
                                contract, -6 dB today, so that the sounds of the pieces are heard), so this is the one
                                kind of file that is quieter than the rest
  NN_parent_<id>_town_complete.mp3, NN_parent_<id>_concert.mp3
                                the same two files of the Part 1 parent of a district, for comparison; NN is the
                                number of the child, so the pair sorts together
  songs/<district>_<song>.mp3   every jukebox song of the districts (one loop)
  README.txt                    in Russian: what each file is, how long, in which order to listen

NN is the number of the district (its position in content/districts.json). The sound is the game's: the stems are
summed at their own levels (the files are levelled by gen_audio.py), nothing is normalised, compressed or limited,
and every file gets the SAME constant gain, the default music volume of the game (0.8, client/audio.lua) with the
static gain of the music group (assets/sounds/manifest.json -> mixer, today 0 dB); the last_moves files get the level's
music offset on top, as in the game (client/audio.lua Mixer:duck_target_db). So the loudness of one district against
another is what a player hears. A district file is --loops (4) loops of the 8-bar loop (the loops are sample-exact,
they join seamlessly), a song is one loop; every file ends with a short fade-out so that it does not stop with a
click. 44.1 kHz mono MP3, constant 192 kbps (ffmpeg, libmp3lame; it is fed 0.264 dB louder because that encoder
decodes 0.264 dB quieter, so the decoded file has exactly the loudness of the game).

Every file is decoded again and measured with the repo's own meters (analysis.py): the duration from ffprobe, the
true peak (no clipping: below -0.5 dBTP) and the loudness (within 0.15 LU of the mix it came from). The exit code is
1 if any check fails. Needs ffmpeg and ffprobe on PATH, numpy, scipy and soundfile (like gen_audio.py).
"""
import argparse
import json
import shutil
import subprocess
import sys
import textwrap
from pathlib import Path

import numpy as np
import soundfile as sf

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import analysis as A  # noqa: E402

ROOT = HERE.parents[1]
HI = 44100                 # the mixing rate of the generator (22.05 kHz files are upsampled exactly)
GAME_MUSIC_VOLUME = 0.8    # the default of the music slider (client/audio.lua Mixer, meta/config.lua)
FADE_OUT = 0.3             # s
BITRATE = "192k"
TRUE_PEAK_MAX = -0.5       # dBTP of a decoded file: no clipping, with room for a player's own resampling
DURATION_TOL = 0.1         # s, ffprobe against the expected length
LOUDNESS_TOL = 0.15        # LU, the decoded file against the mix it came from
# libmp3lame at a constant 192 kbps decodes 0.264 dB quieter than it was fed (measured with sine tones and with the
# district mixes: the same on every one, at any frequency; the variable-bitrate modes lose nothing but their size is
# not 192 kbps). It is fed that much louder, so that the decoded file has the loudness of the game. The constant
# belongs to BITRATE and to this encoder: check_file() fails the run if another setting or version decodes differently.
LAME_LOSS_DB = 0.264
# The Part 1 district a Part 2 district is made from (docs/design/part2-districts.md).
PARENTS = {"midnight_cafe": "cafe", "late_club": "jazz", "nations_fest": "square", "fan_meeting": "stadium",
           "punk_garage": "garage", "sunset_bossa": "beach", "night_carnival": "carnival"}
DEFAULT_PARENTS = ["sunset_bossa", "night_carnival", "punk_garage"]  # the pairs of the producer, in listening order
LAYERS = ("tension", "party")
LEVEL_KINDS = ("last_moves",)  # the kinds of file that are a level on the screen: the game plays music quieter there


# ------------------------------------------------------------------ reading

def read_hi(path):
    """A loop at 44.1 kHz, mono float (22.05 kHz files: exact band-limited 2x upsampling, like the generator)."""
    x, sr = sf.read(str(path), dtype="float64")
    if x.ndim > 1:
        x = x.mean(axis=1)
    if sr == HI:
        return x
    if sr * 2 == HI:
        return A.up2_loop(x)
    raise ValueError(f"{path}: sample rate {sr} Hz is neither {HI} nor {HI // 2}")


def load_districts(root):
    """{id: district dict + "number"} (the number is the position in districts.json: 16 = midnight_cafe)."""
    data = json.loads((root / "content" / "districts.json").read_text(encoding="utf-8"))["districts"]
    return {d["id"]: dict(d, number=i + 1) for i, d in enumerate(data)}


def load_mixer(root):
    """(dB of the static gain of the music group, dB taken off the music in a level) from the playback contract
    of the game: assets/sounds/manifest.json -> mixer, applied by Mixer:configure in client/audio.lua."""
    path = root / "assets" / "sounds" / "manifest.json"
    try:
        mixer = json.loads(path.read_text(encoding="utf-8"))["mixer"]
        return float(mixer["group_gain_db"]["music"]), float(mixer["music_in_level_db"])
    except (OSError, ValueError, KeyError, TypeError) as e:
        sys.exit(f"{path}: no mixer contract (group_gain_db.music, music_in_level_db) to read: {e!r}")


def district_mixes(root, d, last_moves=True):
    """{kind: one loop at 44.1 kHz} of a district: town_complete (all task stems), concert (+ party layer) and,
    unless last_moves is False, last_moves (+ tension layer). Every stem at its own level, gain 1."""
    folder = root / "assets" / "music" / d["id"]
    tasks = [t["stem"] for t in d["tasks"]]
    st = {k: read_hi(folder / f"{k}.ogg") for k in tasks + list(LAYERS)}
    lengths = {len(v) for v in st.values()}
    if len(lengths) != 1:
        raise ValueError(f"{d['id']}: the stems differ in length: {sorted(lengths)}")
    town = sum(st[k] for k in tasks)
    out = {"town_complete": town, "concert": town + st["party"]}
    if last_moves:
        out["last_moves"] = town + st["tension"]
    return out


# ----------------------------------------------------------------- encoding

def need(tool):
    p = shutil.which(tool)
    if not p:
        sys.exit(f"{tool} not found on PATH (ffmpeg and ffprobe are needed)")
    return p


def render(loop, loops, gain):
    """`loops` loops of one loop at a linear gain, ending in a short raised-cosine fade-out."""
    y = np.tile(loop, loops) * gain
    k = min(len(y), int(round(FADE_OUT * HI)))
    y[-k:] *= 0.5 + 0.5 * np.cos(np.pi * (np.arange(k) + 1) / k)
    return y


def encode_mp3(y, path, title):
    path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [need("ffmpeg"), "-hide_banner", "-loglevel", "error", "-y", "-f", "f32le", "-ar", str(HI), "-ac", "1",
           "-i", "pipe:0", "-map_metadata", "-1", "-metadata", f"title={title}", "-metadata", "artist=GLOW",
           "-metadata", "album=GLOW listening kit", "-id3v2_version", "3", "-codec:a", "libmp3lame", "-b:a", BITRATE,
           "-ar", str(HI), "-ac", "1", str(path)]
    pcm = np.asarray(np.asarray(y) * 10.0 ** (LAME_LOSS_DB / 20.0), dtype="<f4").tobytes()
    subprocess.run(cmd, input=pcm, check=True)


def decode_mp3(path):
    cmd = [need("ffmpeg"), "-hide_banner", "-loglevel", "error", "-i", str(path), "-f", "f32le", "-ac", "1",
           "-ar", str(HI), "pipe:1"]
    return np.frombuffer(subprocess.run(cmd, capture_output=True, check=True).stdout, dtype="<f4").astype(np.float64)


def probe_duration(path):
    cmd = [need("ffprobe"), "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", str(path)]
    return float(subprocess.run(cmd, capture_output=True, check=True, text=True).stdout.strip())


def check_file(path, y_src):
    """The encoded file decoded again and measured against the signal it was made from."""
    dec = decode_mp3(path)
    row = {"seconds": probe_duration(path), "expected": len(y_src) / HI, "decoded_s": len(dec) / HI,
           "true_peak": A.true_peak(dec), "sample_peak": A.sample_peak(dec),
           "lufs": A.lufs(dec, HI)[0], "lufs_src": A.lufs(y_src, HI)[0]}
    row["ok"] = bool(abs(row["seconds"] - row["expected"]) <= DURATION_TOL and row["true_peak"] <= TRUE_PEAK_MAX
                     and abs(row["lufs"] - row["lufs_src"]) <= LOUDNESS_TOL)
    return row


# ------------------------------------------------------------------- README

def mmss(sec):
    s = int(round(sec))
    return f"{s // 60}:{s % 60:02d}"


def krugov(n):
    """'круг' / 'круга' / 'кругов' after a number."""
    if n % 10 == 1 and n % 100 != 11:
        return "круг"
    return "круга" if n % 10 in (2, 3, 4) and n % 100 not in (12, 13, 14) else "кругов"


def wrap(text, first="", rest="   ", width=100):
    """The lines of a paragraph of the README: wrapped at `width`, the first line led by `first`, the others by `rest`."""
    return textwrap.wrap(text, width=width, initial_indent=first, subsequent_indent=rest, break_long_words=False,
                         break_on_hyphens=False)


def readme(items, songs, loops, volume, level_db):
    """The Russian README. items: [{number, id, name, genre, prefix, parent_of (the child's id, or None), files:
    [(kind, file name, seconds)]}] in listening order; songs: [(district id, file name, Russian title, seconds)];
    level_db: the dB the game takes off the music in a level (the last_moves files are rendered that much lower)."""
    quiet = level_db <= -0.5  # a level is audibly quieter than the town: the files of a level say so
    kinds = [
        ("town_complete", "город достроен: играют все инструменты района"),
        ("concert", "концерт в конце района: те же инструменты и праздничный слой (хлопки, тарелки, яркие аккорды)"),
        ("last_moves", "уровень, в котором осталось 5 ходов или меньше, а город уже достроен: все инструменты района "
                       "и «нервный» слой (быстрый пульс и частые тарелочки)"
                       + (". В уровне игра приглушает музыку, чтобы были слышны звуки фишек, поэтому этот файл "
                          "тише остальных" if quiet else "")),
    ]
    by_id = {it["id"]: it for it in items}
    parents = [it for it in items if it["parent_of"]]
    paired = {it["id"] for it in parents} | {it["parent_of"] for it in parents}
    rest = [it for it in items if it["id"] not in paired]
    width = max([len(f[1]) for it in items for f in it["files"]] + [len("songs/" + s[1]) for s in songs] + [1])
    L = ["НАБОР ДЛЯ ПРОСЛУШИВАНИЯ: музыка части 2", "",
         "ЧТО ЭТО",
         "Здесь музыка новых районов ровно так, как её играет игра. До сих пор её проверяли только приборами,",
         "а послушать её ещё никто не успел. Громкость файлов не выравнивали: она такая же, как в игре при",
         f"обычных настройках (ползунок музыки на {round(volume * 100)} %). Поэтому тихая музыка здесь тихая, а громкая — громкая.",
         f"В каждом файле музыка идёт {loops} {krugov(loops)} подряд (в игре она так и крутится по кругу), в самом конце",
         "короткое затухание. Число в начале имени файла — номер района на карте.", "",
         "В КАКОМ ПОРЯДКЕ СЛУШАТЬ"]
    n = 1
    if parents:
        L += [f"{n}. Пары «было — стало». Каждый новый район — другая версия района из части 1: тот же жанр, но другое",
              "   время суток и настроение. Слушай сначала старый, потом новый (сначала оба «город достроен»,",
              "   потом оба «концерт») и реши на слух: это правда другая музыка или почти то же самое?"]
        for p in parents:
            c = by_id[p["parent_of"]]
            L.append(f"   - {p['name']} (район {p['number']}) и {c['name']} (район {c['number']}): "
                     f"файлы {p['prefix']}_... и {c['prefix']}_...")
        n += 1
    if rest:
        L.append(f"{n}. Остальные новые районы по номерам: " + ", ".join(f"{it['number']} {it['name']}" for it in rest) + ".")
        n += 1
    if songs:
        L.append(f"{n}. Песни автомата: папка songs, по четыре на район. Каждая песня звучит один раз (в игре её крутят")
        L.append("   по кругу). Имя файла: район_песня.")
        n += 1
    if any(f[0] in LEVEL_KINDS for it in items for f in it["files"]):
        L += wrap("Файлы last_moves — в последнюю очередь, по желанию: так район звучит в уровне, когда осталось мало "
                  "ходов (в игре это слышно в каждом уровне, в концерте этого слоя нет)."
                  + (" Эти файлы тише остальных: в уровне игра приглушает музыку, чтобы были слышны звуки фишек. "
                     "Так и задумано; если плохо слышно, прибавь громкость." if quiet else ""), f"{n}. ")
        n += 1
    L += ["", "ЧТО ЗНАЧАТ СЛОВА В ИМЕНАХ ФАЙЛОВ"]
    if parents:
        kinds.append(("parent", "район из части 1 для сравнения (число в начале такое же, как у нового района, чтобы "
                                "пара стояла рядом)"))
    for kind, text in kinds:
        if kind == "parent" or any(f[0] == kind for it in items for f in it["files"]):
            L += wrap(f"{kind} — {text}.", "  ", "      ")
    L += ["", "ФАЙЛЫ И ДЛИТЕЛЬНОСТЬ (минуты:секунды)"]
    for it in items:
        what = "район части 1, для сравнения" if it["parent_of"] else it["genre"]
        L += ["", f"Район {it['number']}: {it['name']} ({what})"]
        for kind, name, sec in it["files"]:
            L.append(f"  {name.ljust(width)}  {mmss(sec)}")
    if songs:
        L += ["", "ПЕСНИ (папка songs)"]
        last = None
        for did, name, title, sec in songs:
            if did != last:
                L += ["", f"Район {by_id[did]['number']}: {by_id[did]['name']}"]
                last = did
            L.append(f"  {('songs/' + name).ljust(width)}  {mmss(sec)}  {title}")
    L += ["", "Набор собирает программа tools/audio/listen_kit.py из тех же файлов, что лежат в игре: после любой",
          "пересборки музыки её можно запустить снова, и набор обновится."]
    return "\n".join(L) + "\n"


# --------------------------------------------------------------------- main

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0], epilog=__doc__.split("\n", 1)[1],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out_dir", help="the folder the kit is written to (created; files of the same names are replaced)")
    ap.add_argument("--repo", default=str(ROOT), help="the repository root (default: this checkout)")
    ap.add_argument("--districts", default="part2", help="comma list of district ids, or 'part2': every district with "
                    "\"part\": 2 in content/districts.json (the default)")
    ap.add_argument("--parents", default=",".join(DEFAULT_PARENTS), help="comma list of districts whose Part 1 parent is "
                    "added for comparison (town_complete and concert), or 'none' (default: %(default)s)")
    ap.add_argument("--no-songs", action="store_true", help="do not write the jukebox songs")
    ap.add_argument("--loops", type=int, default=4, help="loops of a district theme in a file (default %(default)s)")
    ap.add_argument("--volume", type=float, default=GAME_MUSIC_VOLUME,
                    help="the music volume of the game, the same for every file; default %(default)s, 1.0 = the slider at "
                    "maximum (the last_moves files sit lower than that by the level's offset, as in the game)")
    args = ap.parse_args(argv)
    if args.loops < 1:
        ap.error("--loops must be at least 1")
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    root, out = Path(args.repo), Path(args.out_dir)
    ds = load_districts(root)
    want = [i for i, d in ds.items() if d.get("part") == 2] if args.districts == "part2" \
        else [x for x in args.districts.split(",") if x]
    if [x for x in want if x not in ds]:
        sys.exit("not in content/districts.json: " + ", ".join(x for x in want if x not in ds))
    with_parent = [] if args.parents == "none" else [x for x in args.parents.split(",") if x]
    if [x for x in with_parent if x not in PARENTS]:
        sys.exit("no Part 1 parent known for: " + ", ".join(x for x in with_parent if x not in PARENTS))
    need("ffmpeg")
    need("ffprobe")
    # the gains of the game (client/audio.lua Mixer:music_group_gain): the music volume x the static gain of the music
    # group; in a level the music also sits level_db lower (Mixer:duck_target_db)
    group_db, level_db = load_mixer(root)
    gain_town = args.volume * 10.0 ** (group_db / 20.0)
    gain_level = gain_town * 10.0 ** (level_db / 20.0)
    # listening order: the pairs first (the parent, then its child), then the other districts by number
    order = [x for x in with_parent if x in want] + sorted((x for x in want if x not in with_parent),
                                                           key=lambda i: ds[i]["number"])
    items, rows = [], []
    for did in order:
        d = ds[did]
        todo = []
        if did in with_parent:
            todo.append((ds[PARENTS[did]], f"{d['number']:02d}_parent_{PARENTS[did]}", did, False))
        todo.append((d, f"{d['number']:02d}_{did}", None, True))
        for src, prefix, parent_of, last_moves in todo:
            files = []
            for kind, loop in district_mixes(root, src, last_moves).items():
                name = f"{prefix}_{kind}.mp3"
                y = render(loop, args.loops, gain_level if kind in LEVEL_KINDS else gain_town)
                encode_mp3(y, out / name, name[:-4])
                rows.append(dict(check_file(out / name, y), name=name))
                files.append((kind, name, rows[-1]["seconds"]))
            items.append({"number": src["number"], "id": src["id"], "name": src["name"]["ru"], "prefix": prefix,
                          "genre": src["genre"]["ru"], "parent_of": parent_of, "files": files})
    songs = []
    if not args.no_songs:
        for did in sorted(want, key=lambda i: ds[i]["number"]):
            for s in ds[did].get("songs", []):
                name = f"{did}_{s['id']}.mp3"
                y = render(read_hi(root / "assets" / "music" / "songs" / f"{s['id']}.ogg"), 1, gain_town)
                encode_mp3(y, out / "songs" / name, name[:-4])
                rows.append(dict(check_file(out / "songs" / name, y), name="songs/" + name))
                songs.append((did, name, s["name"]["ru"], rows[-1]["seconds"]))
    out.mkdir(parents=True, exist_ok=True)
    (out / "README.txt").write_text(readme(items, songs, args.loops, args.volume, level_db), encoding="utf-8-sig",
                                    newline="\r\n")
    print(f"{'file':54s} {'seconds':>8s} {'expected':>8s} {'dBTP':>7s} {'LUFS':>7s} {'source':>7s}")
    for r in rows:
        print(f"{r['name']:54s} {r['seconds']:8.2f} {r['expected']:8.2f} {r['true_peak']:7.2f} {r['lufs']:7.1f} "
              f"{r['lufs_src']:7.1f}{'' if r['ok'] else '  <-- FAILS'}")
    ok = all(r["ok"] for r in rows)
    print(f"{len(rows)} files and README.txt in {out}: {'all checks PASS' if ok else 'SOME CHECKS FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
