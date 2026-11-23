"""The list of pictures the producer's drawings were installed as (assets/art_ready/installed.json).

tools/art/install_ready.py writes it; tools/art/gen_art.py reads it and leaves those files alone (neither redraws
nor deletes them). The optional "sources" map says where a listed file came from: a note "placeholder: ..." (made by
tools/art/make_part2_placeholders.py: not the producer's picture yet, the script may replace it) or a digest
(install_ready.py). Every installer keeps the map when it saves the list (the installers of a district, an icon sheet,
an items sheet and a level background only knew the files and used to drop it). Standard library only.
"""
import json
import os

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PATH = os.path.join(ROOT, "assets", "art_ready", "installed.json")


def read(path=None):
    """The whole file as a dict ({} without it or when it is broken). path=None: PATH, looked up when called (a test may
    point PATH somewhere else)."""
    try:
        with open(path or PATH, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def load(path=None):
    """Set of image paths relative to assets/images (e.g. 'bit/cheer_1.png'); empty without the file."""
    return {p for p in read(path).get("files", []) if isinstance(p, str)}


def load_sources(path=None):
    """{image path: where it came from} (see above); empty without the file or the map."""
    src = read(path).get("sources", {})
    return {k: v for k, v in src.items() if isinstance(k, str) and isinstance(v, str)} if isinstance(src, dict) else {}


def sibling(rel):
    """The same loose picture under the other extension: x.png <-> x.jpg (None for any other file)."""
    base, ext = os.path.splitext(rel)
    return {".png": base + ".jpg", ".jpg": base + ".png"}.get(ext.lower())


def unmark(sources, rel):
    """A picture was installed over rel: it is not a placeholder any more, under either extension of its key."""
    sources.pop(rel, None)
    other = sibling(rel)
    if other:
        sources.pop(other, None)


def record(files, sources, rel, images):
    """An installer wrote the picture images/rel: it is listed, it is not a placeholder any more, and the same picture under
    the other extension (an older x.jpg beside the new x.png would be one image key twice) is deleted."""
    other = sibling(rel)
    if other:
        old = os.path.join(images, other)
        if os.path.isfile(old):
            os.remove(old)
        files.discard(other)
    files.add(rel)
    unmark(sources, rel)


def save(files, sources=None, path=None):
    """Writes the list. sources: {file: note}; None keeps the map the file already has (for the files that are still
    listed), so an installer that only knows the files does not lose the notes of the others."""
    files = set(files)
    path = path or PATH
    if sources is None:
        sources = {k: v for k, v in load_sources(path).items() if k in files}
    os.makedirs(os.path.dirname(path), exist_ok=True)
    data = {"version": 1,
            "note": "Written by tools/art/install_ready.py: pictures of assets/images that come from the producer's "
                    "drawings (assets/art_ready). tools/art/gen_art.py does not redraw or delete them.",
            "files": sorted(files)}
    if sources:
        data["sources"] = dict(sorted(sources.items()))
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1, ensure_ascii=False)
        f.write("\n")


def rename(renamed, path=None):
    """Files were renamed ([(old, new)], tools/art/to_jpeg_backgrounds.py: x.png -> x.jpg): the list and the notes follow,
    and a file stays listed once (a text replace used to list the new name twice)."""
    files, sources = load(path), load_sources(path)
    for old, new in renamed:
        listed = old in files
        files.discard(old)
        if listed:
            files.add(new)
        if old in sources:
            sources[new] = sources.pop(old)
        elif listed:
            sources.pop(new, None)      # the picture that was converted decides: it carried no note
    save(files, sources, path)
