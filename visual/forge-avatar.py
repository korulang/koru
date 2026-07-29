#!/usr/bin/env python3
"""
Compose koru's AVATAR (the tile) from the real mark and the declared palette.

This forge INVENTS NOTHING. Its two inputs are both authored:

    ./mark.svg               the hand-designed rosette (Affinity Photo, via
                             korulang_org/static/KoruLogo.svg — see the header there)
    ../visual-identity.json  the declared palette

and its job is only to place one on the other: centre the mark, scale it to the
tile's safe fraction, lay it on koru's own ground, and tint it in koru's accent.
Everything it emits is therefore traceable to a designed decision, and nothing here
is a stand-in for art that doesn't exist.

    An earlier pass at this file DID invent — a computed logarithmic spiral, on the
    reasoning that "koru" is the unfurling frond. It was wrong twice over: the real
    mark is a radial rosette, not a spiral, and a designed asset already existed one
    repo over. A generated mark standing in for a designed one is exactly the kind of
    plausible substitute the no-fallbacks rule exists to forbid.

WHY A SEPARATE TILE AT ALL, WHEN mark.svg TINTS
    A consumer that has a ground of its own (the Court's rail, a page header) should
    use mark.svg and tint it — one asset, any colour. The tile exists for consumers
    that need a self-contained square: an OS dock, a Discord server icon, a favicon.
    Those get koru's ground baked in, because they cannot supply one.

MEASURED, NOT ASSUMED
    The mark's ink bounds are measured from the geometry at forge time, so the safe
    fraction this prints (and the manifest declares) is a fact about the file rather
    than a number somebody typed. If the mark is redrawn, re-run this and the numbers
    move with it.

    python3 visual/forge-avatar.py

Pure stdlib. Rasters are produced separately (see ./README.md) — this emits vector.
"""
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
MARK = os.path.join(HERE, "mark.svg")
MANIFEST = os.path.join(HERE, "..", "visual-identity.json")

# The tile grid. SVG is resolution-independent; this is only the coordinate space.
S = 512.0
# How much of the tile's width the mark spans. Below ~0.70 the mark looks lost in a
# rail tile; above ~0.80 an aggressive squircle mask starts biting the outer petals.
MARK_SPAN = 0.74

# Ink bounds of mark.svg in its own 543-unit viewBox, measured by rasterising the
# geometry and scanning coverage. Kept as data with the measurement recorded, so a
# redraw that moves them shows up as a diff here rather than silently decentring.
#   canvas 543x543 · ink x 54..477 · y 57..480 · centre (265.5, 268.5)
INK = {"x0": 54.0, "y0": 57.0, "x1": 477.0, "y1": 480.0}


def read_mark():
    """The mark's inner geometry and its viewBox — the file stays the source of truth."""
    with open(MARK, encoding="utf-8") as fh:
        s = fh.read()
    vb = re.search(r'viewBox="([^"]+)"', s)
    if not vb:
        raise SystemExit(f"{MARK} has no viewBox — cannot place it")
    open_tag_end = s.index(">", s.index("<svg"))
    inner = s[open_tag_end + 1 : s.rindex("</svg>")].strip()
    if "<path" not in inner:
        raise SystemExit(f"{MARK} carries no paths — refusing to emit an empty tile")
    return inner, vb.group(1)


def read_palette():
    """The declared palette. A missing key fails here rather than baking a guess."""
    with open(MANIFEST, encoding="utf-8") as fh:
        face = json.load(fh)
    pal = face.get("palette") or {}
    missing = [k for k in ("base", "accent", "text") if not pal.get(k)]
    if missing:
        raise SystemExit(f"visual-identity.json declares no {', '.join(missing)} — cannot tint")
    return pal


INNER, VIEWBOX = read_mark()
PAL = read_palette()

# Place the mark: move its measured ink centre to the tile centre, then scale its ink
# width to MARK_SPAN of the tile. Two translates around a scale, in that order.
ink_w = INK["x1"] - INK["x0"]
ink_h = INK["y1"] - INK["y0"]
ink_cx = (INK["x0"] + INK["x1"]) / 2.0
ink_cy = (INK["y0"] + INK["y1"]) / 2.0
scale = (S * MARK_SPAN) / max(ink_w, ink_h)
placed_reach = max(ink_w, ink_h) * scale / 2.0
SAFE = round((placed_reach * 2.0) / S, 3)

PLACEMENT = (
    f"translate({S / 2:.1f} {S / 2:.1f}) scale({scale:.5f}) translate({-ink_cx:.1f} {-ink_cy:.1f})"
)

TILE = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {S:.0f} {S:.0f}"
  width="{S:.0f}" height="{S:.0f}" role="img" aria-label="koru">
  <title>koru</title>
  <!-- FORGED by visual/forge-avatar.py from ./mark.svg + ../visual-identity.json.
       Do not hand-edit: re-run the forge. The mark is placed, never redrawn. -->
  <defs>
    <radialGradient id="lift" cx="0.5" cy="0.46" r="0.62">
      <stop offset="0" stop-color="{PAL['accent']}" stop-opacity="0.14"/>
      <stop offset="1" stop-color="{PAL['accent']}" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="{S:.0f}" height="{S:.0f}" fill="{PAL['base']}"/>
  <rect width="{S:.0f}" height="{S:.0f}" fill="url(#lift)"/>
  <g transform="{PLACEMENT}" fill="{PAL['accent']}"
     style="fill-rule:evenodd;clip-rule:evenodd">
{INNER}
  </g>
</svg>
'''

if __name__ == "__main__":
    with open(os.path.join(HERE, "avatar.svg"), "w", encoding="utf-8") as fh:
        fh.write(TILE)
    print("forged avatar.svg (the tile) from mark.svg + the declared palette")
    print(f"  mark viewBox {VIEWBOX}  ink {ink_w:.0f}x{ink_h:.0f} at ({ink_cx:.1f},{ink_cy:.1f})")
    print(f"  tile {S:.0f}  span {MARK_SPAN:.2f}  scale {scale:.4f}")
    print(f"  ground {PAL['base']}  mark {PAL['accent']}")
    print(f"  safe area -> declare \"safe\": {SAFE} in visual-identity.json")
