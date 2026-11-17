"""Redraws only the UI surfaces (buttons, panels, the window title plate) from tools/art/ui.py into assets/images/ui.
The full generator (gen_art.py) can no longer run as a whole: the districts use the producer's installed drawings.

    python tools/art/install_ui_surfaces.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import palette  # noqa: E402
import ui  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets", "images", "ui")


def main():
    jobs = []
    for k in palette.BUTTONS:
        jobs.append((f"button_{k}.png", ui.draw_button, (k,)))
        jobs.append((f"button_small_{k}.png", ui.draw_button_small, (k,)))
    jobs += [("panel.png", ui.draw_panel, ()), ("panel_tint.png", ui.draw_panel_tint, ()), ("ribbon.png", ui.draw_ribbon, ())]
    for name, fn, args in jobs:
        fn(*args).image().save(os.path.join(OUT, name), optimize=True)
        print("wrote", name)


if __name__ == "__main__":
    main()
