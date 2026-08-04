---
type: belief
id: frag-vaxis-terminal-shader
provenance: terminal shader C1 grill + land 2026-07-24 — glyph/fg/bg cell outs
ts: 2026-07-24
tags: [vaxis, shader, terminal, truecolor]
---

# Terminal shaders paint cells, not pixels — C1 outs are the contract

A `koru/vaxis:shader(name)` is an authored **per-cell** fill: the unit of the
terminal surface is the cell, so the fragment out is **glyph + truecolor fg +
optional bg**, not a scalar intensity. Spelling is assignment outs
(`glyph = …`, `fg = rgb(…)`, `bg = rgb(…)`), not one `frag =` — that scalar form
is rejected loud (greenfield; no compatibility rung).

**Why C1, not a float:** intensity demos teach the wrong abstraction. Once you
want Neo rain, chrome stacking, or readable glyphs, you need character + color
as first-class outs. Channels are **0..1** via `rgb` (K1); glyphs are string
literals (G1). Bindings are terminal-native: `u`/`v` ∈ [0,1], **`x`/`y` cell
indices**, `w`/`h`, `t` seconds.

**D3 omit defaults are stack doctrine, not sugar:** omit `glyph` → space; omit
`fg` → white; **omit `bg` → do not write background**. Under-UI / chrome
stacking only works if a fill can leave the cell bg alone. Writing black
"because we have no bg" is a lie about the layer below.

**Params** are thin this rung: extra idents on RHS become `f64` tor fields
(same altitude as component props). **Samplers deferred** — 1D palette after a
real Neo rain wants them; do not invent table sugar ahead of that need.

`pulse` stays the hard-coded twin for the intensity path; new demos author C1.
Probes: `koru-libs/examples/shader_frag.k` (omit-bg). Eyeballs:
`koru-examples/shader_toy`. Implementation: `koru/vaxis` shader transform.
Related altitude: `frag-vaxis-named-pump-attach` (pump fuse) — shaders are
ordinary synthesized tors once declared; they ride the same draw arms.
