"""The list of pictures the producer's drawings were installed as (assets/art_ready/installed.json).

tools/art/install_ready.py writes it; tools/art/gen_art.py reads it and leaves those files alone (neither redraws
nor deletes them). Standard library only.
"""
import json
import os

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PATH = os.path.join(ROOT, "assets", "art_ready", "installed.json")


def load(path=PATH):
    """Set of image paths relative to assets/images (e.g. 'bit/cheer_1.png'); empty without the file."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return set()
    return {p for p in data.get("files", []) if isinstance(p, str)}


def save(files, sources=None, path=PATH):
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
