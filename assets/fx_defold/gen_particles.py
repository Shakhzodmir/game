#!/usr/bin/env python3
"""Writes the particle effects of the level board (Defold .particlefx text).

    python3 assets/fx_defold/gen_particles.py

Every effect is a one-shot burst: a very high spawn rate capped by
max_particle_count, so play() emits exactly that many particles at once.
Sizes and speeds are for 80 px cells; client/level_vfx.lua scales the burst
game object to the real cell size and tints every emitter with
particlefx.set_constant(url, emitter, "tint", colour) (white images from
assets/images/fx). Emitters are in world space, so a pooled burst object
can move on once its particles are out.

Effects (emitter ids in brackets):
  pop       a cleared piece: 7 soft dots in the piece colour [dots] + 3 white sparks [sparks]
  sparkle   gold stars rising and twinkling (new special, lit floor, microphone) [stars]
  debris    cardboard bits of a record box, falling with gravity [chunks]
  dust      soft puffs (concrete, noise) [puffs]
  confetti  a balloon popping: confetti ribbons [bits]
  spark     a few quick sparks (wires, blocker hits) [sparks]
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ATLAS = "/assets/gen/game.atlas"
MATERIAL = "/builtins/materials/particlefx.material"


def curve(key, pts, spread=0.0, tag="properties"):
    """pts: [(x, y)] or a constant y."""
    if not isinstance(pts, list):
        pts = [(0.0, float(pts))]
    lines = ["  %s {" % tag, "    key: %s" % key]
    for i, (x, y) in enumerate(pts):
        # linear segments: tangent along the segment
        if len(pts) > 1:
            j = min(i + 1, len(pts) - 1)
            k = max(i - 1, 0) if i == len(pts) - 1 else i
            x0, y0 = pts[k]
            x1, y1 = pts[j]
            dx, dy = (x1 - x0), (y1 - y0)
            n = (dx * dx + dy * dy) ** 0.5 or 1.0
            tx, ty = dx / n, dy / n
        else:
            tx, ty = 1.0, 0.0
        lines += ["    points {", "      x: %.4f" % x, "      y: %.4f" % y, "      t_x: %.4f" % tx,
                  "      t_y: %.4f" % ty, "    }"]
    if spread:
        lines.append("    spread: %.4f" % spread)
    lines.append("  }")
    return lines


def emitter(eid, anim, count, life, life_spread, speed, speed_spread, size, size_spread, radius,
            scale=None, alpha=None, rotation=0.0, rot_spread=0.0, ang_vel=0.0, ang_spread=0.0,
            gravity=0.0, orientation="PARTICLE_ORIENTATION_DEFAULT", stretch_y=None, blend="BLEND_MODE_ALPHA",
            emitter_type="EMITTER_TYPE_CIRCLE", z=0.0):
    L = ["emitters {",
         '  id: "%s"' % eid,
         "  mode: PLAY_MODE_ONCE",
         "  duration: 0.05",
         "  space: EMISSION_SPACE_WORLD",
         "  position {", "    z: %.3f" % z, "  }",
         '  tile_source: "%s"' % ATLAS,
         '  animation: "%s"' % anim,
         '  material: "%s"' % MATERIAL,
         "  blend_mode: %s" % blend,
         "  particle_orientation: %s" % orientation,
         "  inherit_velocity: 0.0",
         "  max_particle_count: %d" % count,
         "  type: %s" % emitter_type,
         "  start_delay: 0.0",
         ]
    L += curve("EMITTER_KEY_SPAWN_RATE", 10000.0)
    L += curve("EMITTER_KEY_SIZE_X", radius)
    L += curve("EMITTER_KEY_SIZE_Y", radius)
    L += curve("EMITTER_KEY_SIZE_Z", 0.0)
    L += curve("EMITTER_KEY_PARTICLE_LIFE_TIME", life, life_spread)
    L += curve("EMITTER_KEY_PARTICLE_SPEED", speed, speed_spread)
    L += curve("EMITTER_KEY_PARTICLE_SIZE", size, size_spread)
    L += curve("EMITTER_KEY_PARTICLE_RED", 1.0)
    L += curve("EMITTER_KEY_PARTICLE_GREEN", 1.0)
    L += curve("EMITTER_KEY_PARTICLE_BLUE", 1.0)
    L += curve("EMITTER_KEY_PARTICLE_ALPHA", 1.0)
    L += curve("EMITTER_KEY_PARTICLE_ROTATION", rotation, rot_spread)
    L += curve("EMITTER_KEY_PARTICLE_ANGULAR_VELOCITY", ang_vel, ang_spread)
    if stretch_y is not None:
        L += curve("EMITTER_KEY_PARTICLE_STRETCH_FACTOR_Y", stretch_y)
    L += curve("PARTICLE_KEY_SCALE", scale or [(0.0, 1.0), (1.0, 0.2)], tag="particle_properties")
    L += curve("PARTICLE_KEY_RED", 1.0, tag="particle_properties")
    L += curve("PARTICLE_KEY_GREEN", 1.0, tag="particle_properties")
    L += curve("PARTICLE_KEY_BLUE", 1.0, tag="particle_properties")
    L += curve("PARTICLE_KEY_ALPHA", alpha or [(0.0, 1.0), (0.6, 0.9), (1.0, 0.0)], tag="particle_properties")
    if gravity:
        L += ["  modifiers {",
              "    type: MODIFIER_TYPE_ACCELERATION",
              "    use_direction: 0",
              "    position {", "    }",
              "    rotation {", "      x: 0.0", "      y: 0.0", "      z: 0.0", "      w: 1.0", "    }",
              "    properties {",
              "      key: MODIFIER_KEY_MAGNITUDE",
              "      points {", "        x: 0.0", "        y: %.1f" % -gravity, "        t_x: 1.0", "        t_y: 0.0",
              "      }",
              "    }",
              "  }"]
    L.append("}")
    return L


EFFECTS = {
    "pop": [
        emitter("dots", "fx_glow_dot", 7, 0.42, 0.12, 230.0, 90.0, 26.0, 8.0, 14.0,
                scale=[(0.0, 1.1), (1.0, 0.1)], gravity=260.0),
        emitter("sparks", "fx_spark", 3, 0.32, 0.08, 300.0, 60.0, 24.0, 6.0, 10.0,
                scale=[(0.0, 1.0), (1.0, 0.2)], rot_spread=180.0, blend="BLEND_MODE_ADD", z=0.01),
    ],
    "sparkle": [
        emitter("stars", "fx_star_particle", 8, 0.7, 0.15, 110.0, 50.0, 24.0, 8.0, 22.0,
                scale=[(0.0, 0.3), (0.2, 1.2), (1.0, 0.1)], rot_spread=180.0, ang_vel=0.0, ang_spread=240.0,
                gravity=-60.0),
    ],
    "debris": [
        emitter("chunks", "fx_confetti", 12, 0.6, 0.12, 260.0, 90.0, 18.0, 6.0, 18.0,
                scale=[(0.0, 1.0), (1.0, 0.6)], rot_spread=180.0, ang_spread=720.0, gravity=900.0),
    ],
    "dust": [
        emitter("puffs", "fx_dust", 8, 0.55, 0.12, 110.0, 40.0, 40.0, 12.0, 20.0,
                scale=[(0.0, 0.6), (1.0, 1.4)], alpha=[(0.0, 0.9), (1.0, 0.0)], rot_spread=180.0,
                ang_spread=90.0),
    ],
    "confetti": [
        emitter("bits", "fx_confetti", 12, 0.75, 0.15, 280.0, 100.0, 20.0, 6.0, 16.0,
                scale=[(0.0, 1.0), (1.0, 0.7)], rot_spread=180.0, ang_spread=900.0, gravity=700.0),
    ],
    "spark": [
        emitter("sparks", "fx_spark", 5, 0.28, 0.08, 260.0, 80.0, 22.0, 6.0, 12.0,
                scale=[(0.0, 1.0), (1.0, 0.2)], rot_spread=180.0, blend="BLEND_MODE_ADD"),
    ],
}


def main():
    for name, emitters in EFFECTS.items():
        lines = []
        for e in emitters:
            lines += e
        path = os.path.join(HERE, name + ".particlefx")
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
    print("gen_particles: %d effects" % len(EFFECTS))


if __name__ == "__main__":
    main()
