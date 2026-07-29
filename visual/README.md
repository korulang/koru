# ./visual — the matter of koru's face

Forged per-repo and committed here, so a `git clone` brings the whole face. This is
the MATTER; `../visual-identity.json` is the MANIFEST.

The manifest and the convention travel with the ADD methodology. The matter does
**not** — it is forged for THIS repo and never propagates to another.

## Why the mark is duplicated here on purpose

`mark.svg` is a verbatim copy of `korulang_org/static/KoruLogo.svg`, which Lars drew
in Affinity Photo (`KoruLogo.afphoto` in that repo is the source document).

It is copied rather than referenced because **a repo's identity is local**. Anything
reading koru's face — the Court's rail, the War Room, a release page, an OS dock —
gets it from koru's own tree. No consumer has to know that a sibling checkout named
`korulang_org` exists, and none of them break when it doesn't.

The cost of that rule is this copy. If the logo is redrawn, `mark.svg` is updated
deliberately and `forge-avatar.py` re-run — there is no build step reaching across
repos, and there should not be. A cross-repo path would make koru's face depend on
somebody else's working tree, which is the failure the convention is avoiding.

## What is here

| file | what it is |
|---|---|
| `mark.svg` | **The mark.** Authoritative vector, `fill: currentColor` so one asset tints to any colour. What a consumer with a ground of its own should use. |
| `avatar.svg` | **The tile.** The mark placed on koru's declared ground, in koru's accent. For consumers that need a self-contained square and cannot supply a ground. |
| `avatar-{512,256,128,64,32}.png` | The tile rasterised, for consumers that cannot render SVG at all. |
| `background.png` | The backdrop albedo — the picture. |
| `background_depth.png` | The backdrop depth map, driving the parallax offset. White = near. |
| `forge-avatar.py` | Composes `avatar.svg` from `mark.svg` + the manifest palette. Places the mark; never redraws it. |
| `forge.py` | Renders the backdrop pair. Computed, not generated — the frond is a real logarithmic spiral and the depth comes from the same height field as the albedo, so the two are pixel-registered. |

`mark.svg` and the two `background` files are **authored matter**. Everything else is
derived from them and can be thrown away and rebuilt.

## Rebuilding

```sh
python3 visual/forge-avatar.py     # avatar.svg  (stdlib only)
for n in 512 256 128 64 32; do     # the rasters
  magick -background none -density 600 visual/avatar.svg \
    -resize ${n}x${n} visual/avatar-${n}.png
done
python3 visual/forge.py            # the backdrop pair (needs numpy + pillow)
```

The rasters come out of ImageMagick unoptimised — a flat two-colour tile lands around
360 kB at 512. Quantising to a 64-colour adaptive palette is lossless to the eye and
takes it to ~22 kB.

## The size floor is real, and declared

The manifest says `"min": 32`. That is not a formality — the mark is a rosette of
concentric petal rings, and the rings blur into a single dot below about 32 px:

- **≥ 64 px** — excellent, every ring reads
- **46 px** (the Court's rail tile) — holds
- **32 px** — recognisable as the rosette; busy
- **≤ 24 px** — mush, the form is gone

So a consumer rendering smaller than `min` should fall back to `glyph` (🌀), which
exists for exactly that case. A mark rendered below the size it can survive is worse
than the cheap fallback, because it looks like a smudge rather than an identity.

## The safe area

`"safe": 0.74` — all ink in `avatar.svg` sits inside the centred 74% of the tile. A
consumer may round the corners, or mask to a circle or a squircle, without clipping
the mark. The number is measured by `forge-avatar.py` from the mark's real ink bounds
and printed on every run, so it stays a fact about the file rather than a claim.
